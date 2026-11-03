import 'dart:async';

import 'package:fishing_build/data/maps/current_location_gateway.dart';
import 'package:fishing_build/data/maps/map_location.dart';
import 'package:fishing_build/data/maps/water_area.dart';
import 'package:fishing_build/data/models/external_data.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/services/external_data_service.dart';
import 'package:fishing_build/data/services/network_status_service.dart';
import 'package:fishing_build/data/tides/tide_models.dart';
import 'package:fishing_build/data/tides/tide_service.dart';
import 'package:fishing_build/data/tides/tide_station_catalog.dart';
import 'package:fishing_build/data/water_temperature/water_temperature_models.dart';
import 'package:fishing_build/data/water_temperature/water_temperature_service.dart';
import 'package:fishing_build/presentation/map/location_conditions_card.dart';
import 'package:fishing_build/presentation/map/map_detail_page.dart';
import 'package:fishing_build/presentation/map/map_page.dart';
import 'package:fishing_build/presentation/map/map_selection_controller.dart';
import 'package:fishing_build/presentation/record/record_form_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fixed_water_area_service.dart';
import 'support/test_database.dart';

final _sea = MapLocation(
  name: '팔미도 인근 바다',
  latitude: 37.312,
  longitude: 126.508,
);
final _otherSea = MapLocation(
  name: '새로 선택한 바다',
  latitude: 37.32,
  longitude: 126.52,
);
const _tideStation = TideStation(
  code: 'DT_0052',
  name: '인천송도',
  latitude: 37.3382,
  longitude: 126.586,
);
const _waterStation = WaterTemperatureStation(
  code: 'TW_TEST',
  name: '수온 관측소',
  latitude: 37.34,
  longitude: 126.58,
);

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await NetworkStatusService.instance.resetForTesting();
    await resetTestDatabase();
    AuthSessionRepository.instance.clearMemoryOnlyForTesting();
    FishingRecordRepository.instance.clearCacheOnlyForTesting();
    await AuthSessionRepository.instance.setSessionForTesting(
      plan: UserPlan.free,
      email: 'water-temperature-map@example.com',
    );
  });

  testWidgets('water observation succeeds independently of failed weather', (
    tester,
  ) async {
    final weather = _Weather(failure: true);
    final harness = await _open(tester, weather: weather);
    expect(harness.water.locations, [_sea]);
    expect(weather.locations, [_sea]);
    expect(_conditions(tester).weatherData, isNull);
    expect(_conditions(tester).waterTemperatureObservation?.location, _sea);
    expect(find.text('16.2℃'), findsOneWidget);
    expect(find.textContaining('수온 관측소 ·'), findsOneWidget);
    expect(find.text('날씨 다시 조회'), findsOneWidget);
    expect(find.text('수온 다시 조회'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending weather never blocks a current water observation', (
    tester,
  ) async {
    final weather = _Weather(deferred: true);
    final harness = await _open(tester, weather: weather, settle: false);
    await _pumpRequests(tester);
    expect(weather.pending, hasLength(1));
    expect(harness.water.locations, [_sea]);
    expect(find.text('16.2℃'), findsOneWidget);
    expect(_conditions(tester).weatherLoading, isTrue);
    weather.pending.single.completeError(
      const ExternalDataException(ExternalDataFailure.noData),
    );
    await tester.pumpAndSettle();
    expect(find.text('16.2℃'), findsOneWidget);
    expect(_conditions(tester).weatherData, isNull);
    expect(tester.takeException(), isNull);
  });

  for (final invalid in ['name', 'coordinates', 'stale', 'future']) {
    testWidgets(
      '$invalid water result is discarded without affecting weather',
      (tester) async {
        final water = _WaterTemperatures(
          result: (location) => _observation(
            invalid == 'name'
                ? MapLocation(
                    name: '다른 항구',
                    latitude: location.latitude,
                    longitude: location.longitude,
                  )
                : invalid == 'coordinates'
                ? MapLocation(name: location.name, latitude: 35, longitude: 129)
                : location,
            age: switch (invalid) {
              'stale' => const Duration(hours: 3),
              'future' => const Duration(minutes: -5),
              _ => const Duration(minutes: 10),
            },
          ),
        );
        await _open(tester, water: water);
        expect(_conditions(tester).waterTemperatureObservation, isNull);
        expect(find.text('16.2℃'), findsNothing);
        expect(find.text('99℃'), findsNothing);
        expect(find.textContaining('수온 관측소 ·'), findsNothing);
        expect(find.text('맑음'), findsOneWidget);
        expect(find.text('20℃'), findsOneWidget);
        expect(find.text('수온 다시 조회'), findsOneWidget);
        expect(find.textContaining('WaterTemperatureException'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'moving discards a late water result after the newer one arrives',
    (tester) async {
      final water = _WaterTemperatures(deferred: true);
      final harness = await _open(tester, water: water, settle: false);
      await _pumpRequests(tester);
      expect(water.pending, hasLength(1));
      harness.controller.selectLocation(_otherSea);
      await _pumpRequests(tester);
      expect(water.locations, [_sea, _otherSea]);
      expect(_conditions(tester).waterTemperatureObservation, isNull);
      water.pending[1].complete(_observation(_otherSea, temperature: 14.8));
      await tester.pumpAndSettle();
      expect(find.text('14.8℃'), findsOneWidget);
      water.pending[0].complete(_observation(_sea));
      await tester.pumpAndSettle();
      expect(find.text('14.8℃'), findsOneWidget);
      expect(find.text('16.2℃'), findsNothing);
      expect(
        _conditions(tester).waterTemperatureObservation?.location,
        _otherSea,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('manually choosing freshwater discards pending marine water', (
    tester,
  ) async {
    final water = _WaterTemperatures(deferred: true);
    await _open(tester, water: water, settle: false);
    await _pumpRequests(tester);
    expect(water.pending, hasLength(1));
    await _tap(tester, '민물');
    water.pending.single.complete(_observation(_sea));
    await tester.pumpAndSettle();
    expect(water.locations, [_sea]);
    expect(_conditions(tester).waterArea, WaterArea.freshwater);
    expect(_conditions(tester).waterTemperatureObservation, isNull);
    expect(find.text('수온'), findsNothing);
    expect(find.text('16.2℃'), findsNothing);
    expect(find.text('수온 다시 조회'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'inactive map discards pending water and refetches on activation',
    (tester) async {
      final water = _WaterTemperatures(deferred: true);
      final harness = await _open(tester, water: water, settle: false);
      await _pumpRequests(tester);
      await tester.pumpWidget(harness.page(isActive: false));
      await tester.pumpAndSettle();
      water.pending.single.complete(_observation(_sea));
      await tester.pumpAndSettle();
      expect(_conditions(tester).waterTemperatureObservation, isNull);
      expect(find.text('16.2℃'), findsNothing);
      await tester.pumpWidget(harness.page());
      await _pumpRequests(tester);
      expect(water.locations, [_sea, _sea]);
      expect(_conditions(tester).waterTemperatureObservation, isNull);
      water.pending.last.complete(_observation(_sea, temperature: 18.1));
      await tester.pumpAndSettle();
      expect(find.text('18.1℃'), findsOneWidget);
      expect(find.text('16.2℃'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an initially inactive map never requests water temperature', (
    tester,
  ) async {
    final harness = await _open(tester, isActive: false);
    expect(harness.water.locations, isEmpty);
    expect(harness.weather.locations, isEmpty);
    expect(_conditions(tester).waterTemperatureObservation, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'water retry is independent and never reuses the previous place',
    (tester) async {
      final weather = _Weather(failure: true);
      final harness = await _open(tester, weather: weather);
      expect(find.text('16.2℃'), findsOneWidget);
      harness.water.failure = WaterTemperatureFailure.noData;
      harness.controller.selectLocation(_otherSea);
      await tester.pumpAndSettle();
      expect(_conditions(tester).waterTemperatureObservation, isNull);
      expect(find.text('16.2℃'), findsNothing);
      expect(find.text('수온 다시 조회'), findsOneWidget);
      final weatherCalls = weather.locations.length;
      final tideCalls = harness.tides.calls;
      harness.water
        ..failure = null
        ..deferred = true;
      await tester.ensureVisible(find.text('수온 다시 조회'));
      await tester.tap(find.text('수온 다시 조회'));
      await _pumpRequests(tester);
      expect(harness.water.forceRefreshes, [false, false, true]);
      expect(weather.locations, hasLength(weatherCalls));
      expect(harness.tides.calls, tideCalls);
      expect(
        find.byKey(const ValueKey('water-temperature-loading')),
        findsOneWidget,
      );
      expect(find.text('16.2℃'), findsNothing);
      expect(_conditions(tester).waterTemperatureObservation, isNull);
      harness.water.pending.single.complete(
        _observation(_otherSea, temperature: 14.8),
      );
      await tester.pumpAndSettle();
      expect(find.text('14.8℃'), findsOneWidget);
      weather.failure = false;
      final waterCalls = harness.water.locations.length;
      await _tap(tester, '날씨 다시 조회');
      expect(weather.forceRefreshes.last, isTrue);
      expect(harness.water.locations, hasLength(waterCalls));
      expect(harness.tides.calls, tideCalls);
      expect(find.text('14.8℃'), findsOneWidget);
      expect(find.text('맑음'), findsOneWidget);
      expect(find.text('99℃'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('configuration failure does not offer a water retry', (
    tester,
  ) async {
    await _open(
      tester,
      water: _WaterTemperatures(failure: WaterTemperatureFailure.configuration),
    );
    expect(_conditions(tester).waterTemperatureObservation, isNull);
    expect(find.text('수온 다시 조회'), findsNothing);
    expect(find.text('맑음'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final area in [
    WaterArea.marine,
    WaterArea.freshwater,
    WaterArea.inland,
    WaterArea.unknown,
  ]) {
    for (final viaDetail in [false, true]) {
      testWidgets(
        '$area record via detail=$viaDetail receives marine water only',
        (tester) async {
          final harness = await _open(
            tester,
            area: area,
            weather: _Weather(failure: true),
          );
          final marine = area == WaterArea.marine;
          final observation = _conditions(tester).waterTemperatureObservation;
          expect(observation != null, marine);
          expect(harness.water.locations.length, marine ? 1 : 0);
          if (viaDetail) {
            await _tap(tester, '자세히 보기');
            final detail = tester.widget<MapDetailPage>(
              find.byType(MapDetailPage),
            );
            expect(detail.waterArea, area);
            expect(detail.waterTemperatureObservation, same(observation));
            expect(detail.externalData, isNull);
            expect(
              _conditions(tester).waterTemperatureObservation,
              same(observation),
            );
            await _tap(tester, '기록 작성으로 이동');
          } else {
            await _tap(tester, '기록 작성');
          }
          final form = tester.widget<RecordFormPage>(
            find.byType(RecordFormPage),
          );
          expect(form.initialLocation, _sea.name);
          expect(form.initialLatitude, _sea.latitude);
          expect(form.initialLongitude, _sea.longitude);
          expect(form.initialWaterTemperatureObservation, same(observation));
          expect(form.allowAutomaticWaterTemperature, marine);
          expect(form.initialWaterTemperature, isNull);
          expect(form.initialExternalData, isNull);
          final waterField = tester.widget<TextField>(
            find.byKey(const ValueKey('record-water-temperature')),
          );
          expect(waterField.controller!.text, marine ? '16.2' : '');
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final area in [
    WaterArea.freshwater,
    WaterArea.inland,
    WaterArea.unknown,
  ]) {
    testWidgets(
      'detail suppresses an explicitly supplied observation for $area',
      (tester) async {
        _prepareView(tester);
        await tester.pumpWidget(
          MaterialApp(
            home: MapDetailPage(
              selectedLocation: _sea.name,
              latitude: _sea.latitude,
              longitude: _sea.longitude,
              waterArea: area,
              waterTemperatureObservation: _observation(_sea),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(_conditions(tester).waterTemperatureObservation, isNull);
        expect(find.text('수온'), findsNothing);
        expect(find.text('16.2℃'), findsNothing);
        await _tap(tester, '기록 작성으로 이동');
        final form = tester.widget<RecordFormPage>(find.byType(RecordFormPage));
        expect(form.initialWaterTemperatureObservation, isNull);
        expect(form.allowAutomaticWaterTemperature, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

Future<_Harness> _open(
  WidgetTester tester, {
  _WaterTemperatures? water,
  _Weather? weather,
  WaterArea area = WaterArea.marine,
  bool isActive = true,
  bool settle = true,
}) async {
  _prepareView(tester);
  final harness = _Harness(
    water: water ?? _WaterTemperatures(),
    weather: weather ?? _Weather(),
    area: area,
  );
  addTearDown(harness.controller.dispose);
  await tester.pumpWidget(harness.page(isActive: isActive));
  if (settle) await tester.pumpAndSettle();
  return harness;
}

void _prepareView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
}

class _Harness {
  _Harness({required this.water, required this.weather, required this.area});

  final _WaterTemperatures water;
  final _Weather weather;
  final WaterArea area;
  final tides = _Tides();
  final catalog = TideStationCatalog(stations: [_tideStation]);
  final controller = MapSelectionController(
    locationGateway: _NoGps(),
    initialSelection: _sea,
  );

  Widget page({bool isActive = true}) => MaterialApp(
    home: MapPage(
      key: const ValueKey('map-under-test'),
      controller: controller,
      isActive: isActive,
      waterAreaService: FixedWaterAreaService(area),
      externalDataService: weather,
      tideService: tides,
      tideStations: catalog,
      waterTemperatureService: water,
      mapBuilder: (_, _, _) => const SizedBox(),
    ),
  );
}

class _WaterTemperatures implements WaterTemperatureService {
  _WaterTemperatures({this.deferred = false, this.failure, this.result});

  bool deferred;
  WaterTemperatureFailure? failure;
  final WaterTemperatureObservation Function(MapLocation)? result;
  final locations = <MapLocation>[];
  final forceRefreshes = <bool>[];
  final pending = <Completer<WaterTemperatureObservation>>[];

  @override
  Future<WaterTemperatureObservation> fetchCurrentData({
    required MapLocation location,
    bool forceRefresh = false,
  }) {
    locations.add(location);
    forceRefreshes.add(forceRefresh);
    if (deferred) {
      final request = Completer<WaterTemperatureObservation>();
      pending.add(request);
      return request.future;
    }
    final error = failure;
    if (error != null) return Future.error(WaterTemperatureException(error));
    return Future.value(result?.call(location) ?? _observation(location));
  }
}

class _Weather implements ExternalDataService {
  _Weather({this.failure = false, this.deferred = false});

  bool failure;
  final bool deferred;
  final locations = <MapLocation>[];
  final forceRefreshes = <bool>[];
  final pending = <Completer<ExternalData>>[];

  @override
  Future<ExternalData> fetchCurrentData({
    required MapLocation location,
    bool forceRefresh = false,
  }) {
    locations.add(location);
    forceRefreshes.add(forceRefresh);
    if (deferred) {
      final request = Completer<ExternalData>();
      pending.add(request);
      return request.future;
    }
    if (failure) {
      return Future.error(
        const ExternalDataException(ExternalDataFailure.noData),
      );
    }
    final now = DateTime.now().toUtc();
    return Future.value(
      ExternalData(
        locationName: location.name,
        latitude: location.latitude!,
        longitude: location.longitude!,
        weather: '맑음',
        airTemperature: 20,
        waterTemperature: 99,
        gridX: 1,
        gridY: 1,
        issuedAt: now,
        validAt: DateTime.utc(now.year, now.month, now.day, now.hour),
        fetchedAt: now,
      ),
    );
  }
}

class _Tides implements TideService {
  int calls = 0;

  @override
  Future<TideForecast> fetchForecast({
    required TideStation station,
    required TideDay day,
    bool forceRefresh = false,
  }) async {
    calls++;
    return TideForecast(
      station: station,
      day: day,
      fetchedAt: DateTime.now(),
      events: [
        TideEvent(
          at: DateTime.utc(day.year, day.month, day.day, 1),
          heightCm: 609,
          kind: TideEventKind.high,
        ),
      ],
    );
  }
}

class _NoGps implements CurrentLocationGateway {
  @override
  Future<MapLocation> currentLocation({bool requestPermission = true}) async =>
      throw const CurrentLocationException(CurrentLocationFailure.denied);

  @override
  Future<bool> openAppSettings() async => true;

  @override
  Future<bool> openLocationSettings() async => true;
}

WaterTemperatureObservation _observation(
  MapLocation location, {
  double temperature = 16.2,
  Duration age = const Duration(minutes: 10),
}) {
  final now = DateTime.now().toUtc();
  return WaterTemperatureObservation(
    location: location,
    station: _waterStation,
    temperatureCelsius: temperature,
    observedAt: now.subtract(age),
    fetchedAt: now,
  );
}

Future<void> _pumpRequests(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

Future<void> _tap(WidgetTester tester, String text) async {
  final target = find.text(text);
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

LocationConditionsCard _conditions(WidgetTester tester) =>
    tester.widget<LocationConditionsCard>(find.byType(LocationConditionsCard));
