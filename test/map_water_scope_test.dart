import 'dart:async';

import 'package:fishing_build/data/maps/current_location_gateway.dart';
import 'package:fishing_build/data/maps/map_location.dart';
import 'package:fishing_build/data/maps/water_area.dart';
import 'package:fishing_build/data/maps/water_area_service.dart';
import 'package:fishing_build/data/models/external_data.dart';
import 'package:fishing_build/data/services/external_data_service.dart';
import 'package:fishing_build/data/services/network_status_service.dart';
import 'package:fishing_build/data/tides/tide_models.dart';
import 'package:fishing_build/data/tides/tide_service.dart';
import 'package:fishing_build/data/tides/tide_station_catalog.dart';
import 'package:fishing_build/presentation/map/location_conditions_card.dart';
import 'package:fishing_build/presentation/map/map_page.dart';
import 'package:fishing_build/presentation/map/map_selection_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _station = TideStation(
  code: 'DT_0052',
  name: '인천송도',
  latitude: 37.3382,
  longitude: 126.586,
);
final _river = MapLocation(name: '한강', latitude: 37.535, longitude: 126.934);
final _sea = MapLocation(
  name: '팔미도 인근 바다',
  latitude: 37.312,
  longitude: 126.508,
);

void main() {
  setUp(() => NetworkStatusService.instance.resetForTesting());

  for (final area in [
    WaterArea.freshwater,
    WaterArea.inland,
    WaterArea.unknown,
  ]) {
    testWidgets('$area never queries or displays nearby marine information', (
      tester,
    ) async {
      final tides = _Tides();
      await _open(tester, _Areas(result: area), tides, location: _river);
      expect(tides.calls, 0);
      expect(find.text('맑음'), findsOneWidget);
      expect(find.text('20℃'), findsOneWidget);
      expect(find.text('물때'), findsNothing);
      expect(find.text('수온'), findsNothing);
      expect(find.text('23℃'), findsNothing);
      expect(find.text('만조·간조'), findsNothing);
      final conditions = tester.widget<LocationConditionsCard>(
        find.byType(LocationConditionsCard),
      );
      expect(conditions.waterArea, area);
      expect(conditions.tideForecast, isNull);
      expect(conditions.tideName, isNull);
      if (area == WaterArea.inland) {
        expect(find.text('자동 판별 · 내륙'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('marine classification enables one unified conditions card', (
    tester,
  ) async {
    final tides = _Tides();
    await _open(tester, _Areas(result: WaterArea.marine), tides);
    expect(tides.calls, 1);
    final card = find.byType(LocationConditionsCard);
    expect(card, findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.byType(Card)),
      findsOneWidget,
    );
    expect(find.text('날씨·낚시 정보'), findsOneWidget);
    expect(find.text('물때'), findsOneWidget);
    expect(find.text('수온'), findsOneWidget);
    expect(find.text('23℃'), findsOneWidget);
    expect(find.text('만조'), findsOneWidget);
    expect(find.text('609 cm'), findsOneWidget);
    expect(find.textContaining('제공:'), findsNothing);
    expect(find.textContaining('예보 격자'), findsNothing);
    expect(find.text('수동 입력'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a late geographic result cannot turn a river into sea', (
    tester,
  ) async {
    final areas = _Areas(deferred: true);
    final tides = _Tides();
    final controller = await _open(tester, areas, tides, settle: false);
    await tester.pump();
    expect(areas.pending, hasLength(1));
    controller.selectLocation(_river);
    await tester.pump();
    expect(areas.pending, hasLength(2));
    areas.pending[1].complete(WaterArea.freshwater);
    await tester.pumpAndSettle();
    areas.pending[0].complete(WaterArea.marine);
    await tester.pumpAndSettle();
    expect(tides.calls, 0);
    expect(find.text('물때'), findsNothing);
    expect(find.text('수온'), findsNothing);
    expect(
      tester
          .widget<LocationConditionsCard>(find.byType(LocationConditionsCard))
          .waterArea,
      WaterArea.freshwater,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching to freshwater rejects a pending marine forecast', (
    tester,
  ) async {
    final tides = _Tides(deferred: true);
    await _open(tester, _Areas(result: WaterArea.marine), tides, settle: false);
    await tester.pump();
    await tester.pump();
    expect(tides.calls, 1);
    await tester.tap(find.text('민물'));
    await tester.pumpAndSettle();
    tides.pending.complete(_forecast(tides.lastDay!));
    await tester.pumpAndSettle();
    expect(find.text('물때'), findsNothing);
    expect(find.text('수온'), findsNothing);
    expect(find.text('609 cm'), findsNothing);
    expect(
      tester
          .widget<LocationConditionsCard>(find.byType(LocationConditionsCard))
          .tideForecast,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('an explicit sea selection can override an uncertain location', (
    tester,
  ) async {
    final tides = _Tides();
    await _open(tester, _Areas(result: WaterArea.unknown), tides);
    expect(tides.calls, 0);
    await tester.tap(find.text('바다'));
    await tester.pumpAndSettle();
    expect(tides.calls, 1);
    expect(find.text('수온'), findsOneWidget);
    await tester.tap(find.text('민물'));
    await tester.pumpAndSettle();
    expect(find.text('수온'), findsNothing);
    expect(find.text('물때'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the real map controls fit a narrow screen with large text', (
    tester,
  ) async {
    await _open(
      tester,
      _Areas(result: WaterArea.marine),
      _Tides(),
      viewSize: const Size(320, 1100),
      textScale: 2,
    );
    await tester.ensureVisible(find.text('609 cm'));
    await tester.pumpAndSettle();
    expect(find.text('609 cm'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<MapSelectionController> _open(
  WidgetTester tester,
  WaterAreaService areas,
  TideService tides, {
  MapLocation? location,
  bool settle = true,
  Size viewSize = const Size(1000, 2400),
  double textScale = 1,
}) async {
  tester.view.physicalSize = viewSize;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = MapSelectionController(
    locationGateway: _NoGps(),
    initialSelection: location ?? _sea,
  );
  addTearDown(controller.dispose);
  addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: MapPage(
        controller: controller,
        waterAreaService: areas,
        externalDataService: _Weather(),
        tideService: tides,
        tideStations: TideStationCatalog(stations: [_station]),
        mapBuilder: (_, _, _) => const SizedBox(),
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
  return controller;
}

class _Areas implements WaterAreaService {
  _Areas({this.result = WaterArea.unknown, this.deferred = false});
  final WaterArea result;
  final bool deferred;
  final pending = <Completer<WaterArea>>[];

  @override
  Future<WaterArea> classify(
    MapLocation location, {
    bool forceRefresh = false,
  }) {
    if (!deferred) return Future.value(result);
    final request = Completer<WaterArea>();
    pending.add(request);
    return request.future;
  }
}

class _Weather implements ExternalDataService {
  @override
  Future<ExternalData> fetchCurrentData({
    required MapLocation location,
    bool forceRefresh = false,
  }) async => ExternalData(
    locationName: location.name,
    latitude: location.latitude!,
    longitude: location.longitude!,
    weather: '맑음',
    airTemperature: 20,
    waterTemperature: 23,
    gridX: 1,
    gridY: 1,
    issuedAt: DateTime.utc(2026, 11, 3),
    validAt: DateTime.utc(2026, 11, 3),
    fetchedAt: DateTime.utc(2026, 11, 3),
  );
}

class _Tides implements TideService {
  _Tides({this.deferred = false});
  final bool deferred;
  int calls = 0;
  TideDay? lastDay;
  final pending = Completer<TideForecast>();

  @override
  Future<TideForecast> fetchForecast({
    required TideStation station,
    required TideDay day,
    bool forceRefresh = false,
  }) {
    calls++;
    lastDay = day;
    return deferred ? pending.future : Future.value(_forecast(day));
  }
}

TideForecast _forecast(TideDay day) => TideForecast(
  station: _station,
  day: day,
  fetchedAt: DateTime.utc(2026, 11, 3),
  events: [
    TideEvent(
      at: DateTime.utc(day.year, day.month, day.day, 1),
      heightCm: 609,
      kind: TideEventKind.high,
    ),
  ],
);

class _NoGps implements CurrentLocationGateway {
  @override
  Future<MapLocation> currentLocation({bool requestPermission = true}) async =>
      throw const CurrentLocationException(CurrentLocationFailure.denied);
  @override
  Future<bool> openAppSettings() async => true;
  @override
  Future<bool> openLocationSettings() async => true;
}
