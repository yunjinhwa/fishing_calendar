import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fishing_build/data/maps/current_location_gateway.dart';
import 'package:fishing_build/data/maps/map_location.dart';
import 'package:fishing_build/data/models/external_data.dart';
import 'package:fishing_build/data/services/external_data_service.dart';
import 'package:fishing_build/data/services/network_status_service.dart';
import 'package:fishing_build/data/tides/tide_models.dart';
import 'package:fishing_build/data/tides/tide_service.dart';
import 'package:fishing_build/data/tides/tide_station_catalog.dart';
import 'package:fishing_build/data/water_temperature/water_temperature_models.dart';
import 'package:fishing_build/data/water_temperature/water_temperature_service.dart';
import 'package:fishing_build/presentation/map/location_conditions_card.dart';
import 'package:fishing_build/presentation/map/map_page.dart';
import 'package:fishing_build/presentation/map/map_selection_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixed_water_area_service.dart';

final _sea = MapLocation(
  name: 'Selected fishing harbor',
  latitude: 37.312,
  longitude: 126.508,
);
const _tideStation = TideStation(
  code: 'DT_0052',
  name: 'Test tide station',
  latitude: 37.3382,
  longitude: 126.586,
);
const _waterStation = WaterTemperatureStation(
  code: 'TW_TEST',
  name: 'Test water station',
  latitude: 37.34,
  longitude: 126.58,
);

void main() {
  final network = NetworkStatusService.instance;
  late _Connectivity connectivity;

  setUp(() async {
    connectivity = _Connectivity();
    await network.resetForTesting(gateway: connectivity);
  });

  tearDown(() async {
    await network.close();
    await connectivity.close();
  });

  testWidgets(
    'same selected location refreshes weather and water at ten minutes',
    (tester) async {
      final harness = await _open(tester);
      final firstWeather = _conditions(tester).weatherData;
      final firstWater = _conditions(tester).waterTemperatureObservation;
      expect(firstWeather, isNotNull);
      expect(firstWater, isNotNull);

      await _advance(
        tester,
        harness.clock,
        const Duration(minutes: 9, seconds: 59),
      );
      expect(harness.weather.locations, [_sea]);
      expect(harness.water.locations, [_sea]);

      await _advance(tester, harness.clock, const Duration(seconds: 1));
      expect(harness.weather.locations, [_sea, _sea]);
      expect(harness.water.locations, [_sea, _sea]);
      expect(_conditions(tester).weatherData, isNot(same(firstWeather)));
      expect(
        _conditions(tester).waterTemperatureObservation,
        isNot(same(firstWater)),
      );
      expect(harness.controller.selection, same(_sea));
      expect(harness.gps.requests, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('weather expires at its forecast hour before the fetch TTL', (
    tester,
  ) async {
    final harness = await _open(
      tester,
      now: DateTime.utc(2026, 11, 16, 10, 58),
    );
    harness.weather.deferred = true;

    await _advance(tester, harness.clock, const Duration(minutes: 2));
    expect(harness.weather.locations, [_sea, _sea]);
    expect(harness.weather.pending, hasLength(1));
    expect(_conditions(tester).weatherData, isNull);
    expect(_conditions(tester).weatherLoading, isTrue);
    expect(harness.water.locations, [_sea]);
    expect(_conditions(tester).waterTemperatureObservation, isNotNull);

    harness.weather.pending.single.complete(_weather(_sea, harness.clock.now));
    await _pump(tester);
    expect(_conditions(tester).weatherData?.validAt.hour, 11);
    expect(tester.takeException(), isNull);
  });

  testWidgets('frequent fresh resumes reuse data and the selected location', (
    tester,
  ) async {
    final harness = await _open(tester);
    final initialWeather = _conditions(tester).weatherData;
    final initialWater = _conditions(tester).waterTemperatureObservation;

    for (var resume = 0; resume < 4; resume++) {
      await _lifecycle(tester, AppLifecycleState.paused);
      await _advance(tester, harness.clock, const Duration(seconds: 30));
      await _lifecycle(tester, AppLifecycleState.resumed);
    }

    expect(harness.weather.locations, [_sea]);
    expect(harness.water.locations, [_sea]);
    expect(_conditions(tester).weatherData, same(initialWeather));
    expect(_conditions(tester).waterTemperatureObservation, same(initialWater));
    expect(harness.controller.selection, same(_sea));
    expect(harness.gps.requests, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('elapsed background time refreshes once on resume without GPS', (
    tester,
  ) async {
    final harness = await _open(tester);
    await _lifecycle(tester, AppLifecycleState.paused);
    await _advance(tester, harness.clock, const Duration(minutes: 12));
    expect(harness.weather.locations, [_sea]);
    expect(harness.water.locations, [_sea]);

    await _lifecycle(tester, AppLifecycleState.resumed);
    await _lifecycle(tester, AppLifecycleState.resumed);
    expect(harness.weather.locations, [_sea, _sea]);
    expect(harness.water.locations, [_sea, _sea]);
    expect(harness.controller.selection, same(_sea));
    expect(harness.gps.requests, 1);
    expect(_conditions(tester).weatherData?.fetchedAt, harness.clock.now);
    expect(
      _conditions(tester).waterTemperatureObservation?.fetchedAt,
      harness.clock.now,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'inactive tabs and offline periods gate requests and hide expiry',
    (tester) async {
      final harness = await _open(tester, isActive: false);
      expect(harness.weather.locations, isEmpty);
      expect(harness.water.locations, isEmpty);

      await tester.pumpWidget(harness.page());
      await _pump(tester);
      expect(harness.weather.locations, [_sea]);
      expect(harness.water.locations, [_sea]);

      connectivity.setConnected(false);
      await _pump(tester);
      await _advance(tester, harness.clock, const Duration(hours: 3));
      expect(harness.weather.locations, [_sea]);
      expect(harness.water.locations, [_sea]);
      expect(_conditions(tester).weatherData, isNull);
      expect(_conditions(tester).waterTemperatureObservation, isNull);

      await tester.pumpWidget(harness.page(isActive: false));
      await _pump(tester);
      connectivity.setConnected(true);
      await _pump(tester);
      await _advance(tester, harness.clock, const Duration(minutes: 15));
      expect(harness.weather.locations, [_sea]);
      expect(harness.water.locations, [_sea]);

      await tester.pumpWidget(harness.page());
      await _pump(tester);
      expect(harness.weather.locations, [_sea, _sea]);
      expect(harness.water.locations, [_sea, _sea]);
      expect(_conditions(tester).weatherData, isNotNull);
      expect(_conditions(tester).waterTemperatureObservation, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reconnect preserves fresh data and refreshes expired data once',
    (tester) async {
      final harness = await _open(tester);
      final initialWeather = _conditions(tester).weatherData;
      final initialWater = _conditions(tester).waterTemperatureObservation;
      connectivity.setConnected(false);
      await _pump(tester);
      await _advance(tester, harness.clock, const Duration(minutes: 1));
      connectivity.setConnected(true);
      await _pump(tester);

      expect(harness.weather.locations, [_sea]);
      expect(harness.water.locations, [_sea]);
      expect(_conditions(tester).weatherData, same(initialWeather));
      expect(
        _conditions(tester).waterTemperatureObservation,
        same(initialWater),
      );

      connectivity.setConnected(false);
      await _pump(tester);
      await _advance(tester, harness.clock, const Duration(minutes: 10));
      connectivity.setConnected(true);
      await _pump(tester);
      expect(harness.weather.locations, [_sea, _sea]);
      expect(harness.water.locations, [_sea, _sea]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'recovery through unknown reconnects without bypassing cooldown',
    (tester) async {
      connectivity.connected = false;
      final clock = _Clock(DateTime.utc(2026, 11, 16, 10, 12));
      final harness = await _open(
        tester,
        clock: clock,
        weather: _Weather(clock)..failure = ExternalDataFailure.noData,
        water: _Water(clock)..failure = WaterTemperatureFailure.noData,
      );
      expect(harness.weather.locations, isEmpty);
      expect(harness.water.locations, isEmpty);

      connectivity.reportUnknown();
      await _pump(tester);
      connectivity.setConnected(true);
      await _pump(tester);
      expect(harness.weather.locations, [_sea]);
      expect(harness.water.locations, [_sea]);

      harness.weather.failure = null;
      harness.water.failure = null;
      connectivity.setConnected(false);
      await _pump(tester);
      await _advance(tester, clock, const Duration(minutes: 4, seconds: 59));
      connectivity.reportUnknown();
      await _pump(tester);
      connectivity.setConnected(true);
      await _pump(tester);
      expect(harness.weather.locations, [_sea]);
      expect(harness.water.locations, [_sea]);

      await _advance(tester, clock, const Duration(seconds: 1));
      expect(harness.weather.locations, [_sea, _sea]);
      expect(harness.water.locations, [_sea, _sea]);
      expect(_conditions(tester).weatherData, isNotNull);
      expect(_conditions(tester).waterTemperatureObservation, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a late expired weather response is hidden while water succeeds',
    (tester) async {
      final clock = _Clock(DateTime.utc(2026, 11, 16, 10, 58));
      final weather = _Weather(clock)..deferred = true;
      final harness = await _open(tester, clock: clock, weather: weather);
      final expiredResponse = _weather(_sea, clock.now);
      expect(weather.pending, hasLength(1));
      expect(harness.water.locations, [_sea]);
      expect(_conditions(tester).waterTemperatureObservation, isNotNull);

      await _advance(tester, clock, const Duration(minutes: 3));
      weather.pending.single.complete(expiredResponse);
      await _pump(tester);
      expect(_conditions(tester).weatherData, isNull);
      expect(_conditions(tester).weatherLoading, isFalse);
      expect(_conditions(tester).waterTemperatureObservation, isNotNull);
      expect(weather.locations, [_sea]);

      await _advance(tester, clock, const Duration(minutes: 4, seconds: 59));
      expect(weather.locations, [_sea]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'weather and water failures cool down independently for five minutes',
    (tester) async {
      final clock = _Clock(DateTime.utc(2026, 11, 16, 10, 12));
      final weather = _Weather(clock)..failure = ExternalDataFailure.noData;
      final harness = await _open(tester, clock: clock, weather: weather);
      expect(_conditions(tester).weatherData, isNull);
      expect(_conditions(tester).waterTemperatureObservation, isNotNull);

      weather.failure = null;
      await _advance(tester, clock, const Duration(minutes: 4, seconds: 59));
      await _lifecycle(tester, AppLifecycleState.paused);
      await _lifecycle(tester, AppLifecycleState.resumed);
      expect(weather.locations, [_sea]);
      await _advance(tester, clock, const Duration(seconds: 1));
      expect(weather.locations, [_sea, _sea]);
      expect(harness.water.locations, [_sea]);
      expect(_conditions(tester).weatherData, isNotNull);

      harness.water.failure = WaterTemperatureFailure.noData;
      await _advance(tester, clock, const Duration(minutes: 5));
      expect(harness.water.locations, [_sea, _sea]);
      expect(weather.locations, [_sea, _sea]);
      expect(_conditions(tester).waterTemperatureObservation, isNull);
      expect(_conditions(tester).weatherData, isNotNull);

      harness.water.failure = null;
      await _advance(tester, clock, const Duration(minutes: 4, seconds: 59));
      expect(harness.water.locations, [_sea, _sea]);
      await _advance(tester, clock, const Duration(seconds: 1));
      expect(harness.water.locations, [_sea, _sea, _sea]);
      expect(weather.locations, [_sea, _sea, _sea]);
      expect(_conditions(tester).waterTemperatureObservation, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'configuration and authorization failures never retry automatically',
    (tester) async {
      final clock = _Clock(DateTime.utc(2026, 11, 16, 10, 12));
      final harness = await _open(
        tester,
        clock: clock,
        weather: _Weather(clock)..failure = ExternalDataFailure.configuration,
        water: _Water(clock)..failure = WaterTemperatureFailure.unauthorized,
      );

      await _advance(tester, clock, const Duration(hours: 1));
      await _lifecycle(tester, AppLifecycleState.paused);
      await _lifecycle(tester, AppLifecycleState.resumed);
      connectivity.setConnected(false);
      await _pump(tester);
      connectivity.setConnected(true);
      await _pump(tester);
      expect(harness.weather.locations, [_sea]);
      expect(harness.water.locations, [_sea]);
      expect(_conditions(tester).weatherData, isNull);
      expect(_conditions(tester).waterTemperatureObservation, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'retries share pending requests and disposal cancels refresh timers',
    (tester) async {
      final clock = _Clock(DateTime.utc(2026, 11, 16, 10, 12));
      final harness = await _open(
        tester,
        clock: clock,
        weather: _Weather(clock)..failure = ExternalDataFailure.noData,
        water: _Water(clock)..failure = WaterTemperatureFailure.noData,
      );
      final retryWeather = _conditions(tester).onRetryWeather!;
      final retryWater = _conditions(tester).onRetryWaterTemperature!;
      harness.weather
        ..failure = null
        ..deferred = true;
      harness.water
        ..failure = null
        ..deferred = true;
      retryWeather();
      retryWeather();
      retryWater();
      retryWater();
      await _pump(tester);
      expect(harness.weather.locations, [_sea, _sea]);
      expect(harness.water.locations, [_sea, _sea]);
      expect(harness.weather.pending, hasLength(1));
      expect(harness.water.pending, hasLength(1));
      expect(harness.weather.forceRefreshes.last, isTrue);
      expect(harness.water.forceRefreshes.last, isTrue);

      await _advance(tester, clock, const Duration(minutes: 15));
      expect(harness.weather.pending, hasLength(1));
      expect(harness.water.pending, hasLength(1));
      harness.weather.pending.single.complete(_weather(_sea, clock.now));
      harness.water.pending.single.complete(_observation(_sea, clock.now));
      await _pump(tester);
      expect(_conditions(tester).weatherData, isNotNull);
      expect(_conditions(tester).waterTemperatureObservation, isNotNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await _advance(tester, clock, const Duration(minutes: 20));
      expect(harness.weather.locations, [_sea, _sea]);
      expect(harness.water.locations, [_sea, _sea]);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<_Harness> _open(
  WidgetTester tester, {
  DateTime? now,
  _Clock? clock,
  _Weather? weather,
  _Water? water,
  bool isActive = true,
}) async {
  _setLifecycle(tester, AppLifecycleState.resumed);
  await NetworkStatusService.instance.initialize();
  tester.view.physicalSize = const Size(1000, 2600);
  tester.view.devicePixelRatio = 1;
  final harness = _Harness(
    clock ?? _Clock(now ?? DateTime.utc(2026, 11, 16, 10, 12)),
    weather: weather,
    water: water,
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    harness.controller.dispose();
    _setLifecycle(tester, AppLifecycleState.resumed);
    tester.view.reset();
  });
  await tester.pumpWidget(harness.page(isActive: isActive));
  await _pump(tester);
  return harness;
}

class _Harness {
  _Harness(this.clock, {_Weather? weather, _Water? water})
    : weather = weather ?? _Weather(clock),
      water = water ?? _Water(clock) {
    controller = MapSelectionController(
      locationGateway: gps,
      initialSelection: _sea,
    );
  }

  final _Clock clock;
  final _Weather weather;
  final _Water water;
  final gps = _NoGps();
  late final MapSelectionController controller;
  final catalog = TideStationCatalog(stations: [_tideStation]);
  late final tides = _Tides(clock);

  Widget page({bool isActive = true}) => MaterialApp(
    home: MapPage(
      key: const ValueKey('freshness-map'),
      controller: controller,
      isActive: isActive,
      clock: clock.read,
      waterAreaService: const FixedWaterAreaService(),
      externalDataService: weather,
      tideService: tides,
      tideStations: catalog,
      waterTemperatureService: water,
      mapBuilder: (_, _, _) => const SizedBox(),
    ),
  );
}

class _Clock {
  _Clock(this.now);

  DateTime now;
  DateTime read() => now;
}

class _Weather implements ExternalDataService {
  _Weather(this.clock);

  final _Clock clock;
  bool deferred = false;
  ExternalDataFailure? failure;
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
    final error = failure;
    if (error != null) return Future.error(ExternalDataException(error));
    return Future.value(_weather(location, clock.now));
  }
}

class _Water implements WaterTemperatureService {
  _Water(this.clock);

  final _Clock clock;
  bool deferred = false;
  WaterTemperatureFailure? failure;
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
    return Future.value(_observation(location, clock.now));
  }
}

class _Tides implements TideService {
  _Tides(this.clock);

  final _Clock clock;

  @override
  Future<TideForecast> fetchForecast({
    required TideStation station,
    required TideDay day,
    bool forceRefresh = false,
  }) async => TideForecast(
    station: station,
    day: day,
    fetchedAt: clock.now,
    events: [
      TideEvent(
        at: DateTime.utc(day.year, day.month, day.day, 1),
        heightCm: 609,
        kind: TideEventKind.high,
      ),
    ],
  );
}

class _NoGps implements CurrentLocationGateway {
  int requests = 0;

  @override
  Future<MapLocation> currentLocation({bool requestPermission = true}) async {
    requests++;
    throw const CurrentLocationException(CurrentLocationFailure.denied);
  }

  @override
  Future<bool> openAppSettings() async => true;

  @override
  Future<bool> openLocationSettings() async => true;
}

class _Connectivity implements ConnectivityGateway {
  final _changes = StreamController<List<ConnectivityResult>>.broadcast(
    sync: true,
  );
  bool connected = true;

  List<ConnectivityResult> get _results => [
    connected ? ConnectivityResult.wifi : ConnectivityResult.none,
  ];

  void setConnected(bool value) {
    connected = value;
    _changes.add(_results);
  }

  void reportUnknown() =>
      _changes.addError(StateError('Transport check failed'));

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => _results;

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => _changes.stream;

  Future<void> close() => _changes.close();
}

ExternalData _weather(MapLocation location, DateTime now) {
  final hour = DateTime.utc(now.year, now.month, now.day, now.hour);
  return ExternalData(
    locationName: location.name,
    latitude: location.latitude!,
    longitude: location.longitude!,
    weather: 'Clear',
    airTemperature: 20,
    gridX: 1,
    gridY: 1,
    issuedAt: hour.subtract(const Duration(minutes: 30)),
    validAt: hour,
    fetchedAt: now,
  );
}

WaterTemperatureObservation _observation(MapLocation location, DateTime now) =>
    WaterTemperatureObservation(
      location: location,
      station: _waterStation,
      temperatureCelsius: 16.2,
      observedAt: now.subtract(const Duration(minutes: 10)),
      fetchedAt: now,
    );

LocationConditionsCard _conditions(WidgetTester tester) =>
    tester.widget<LocationConditionsCard>(find.byType(LocationConditionsCard));

Future<void> _pump(WidgetTester tester) async {
  for (var frame = 0; frame < 5; frame++) {
    await tester.pump();
  }
}

Future<void> _advance(
  WidgetTester tester,
  _Clock clock,
  Duration duration,
) async {
  clock.now = clock.now.add(duration);
  await tester.pump(duration);
  await _pump(tester);
}

Future<void> _lifecycle(WidgetTester tester, AppLifecycleState state) async {
  _setLifecycle(tester, state);
  await _pump(tester);
}

void _setLifecycle(WidgetTester tester, AppLifecycleState state) {
  void change(AppLifecycleState next) =>
      tester.binding.handleAppLifecycleStateChanged(next);

  if (state == AppLifecycleState.paused) {
    if (tester.binding.lifecycleState == AppLifecycleState.resumed) {
      change(AppLifecycleState.inactive);
    }
    if (tester.binding.lifecycleState == AppLifecycleState.inactive) {
      change(AppLifecycleState.hidden);
    }
    if (tester.binding.lifecycleState == AppLifecycleState.hidden) {
      change(AppLifecycleState.paused);
    }
  } else if (state == AppLifecycleState.resumed) {
    if (tester.binding.lifecycleState == AppLifecycleState.paused) {
      change(AppLifecycleState.hidden);
    }
    if (tester.binding.lifecycleState == AppLifecycleState.hidden) {
      change(AppLifecycleState.inactive);
    }
    if (tester.binding.lifecycleState != AppLifecycleState.resumed) {
      change(AppLifecycleState.resumed);
    }
  } else {
    change(state);
  }
}
