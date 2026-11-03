import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fishing_build/data/maps/current_location_gateway.dart';
import 'package:fishing_build/data/maps/map_location.dart';
import 'package:fishing_build/data/maps/water_area.dart';
import 'package:fishing_build/data/models/external_data.dart';
import 'package:fishing_build/data/services/external_data_service.dart';
import 'package:fishing_build/data/services/network_status_service.dart';
import 'package:fishing_build/data/tides/tide_models.dart';
import 'package:fishing_build/data/tides/tide_service.dart';
import 'package:fishing_build/data/tides/tide_station_catalog.dart';
import 'package:fishing_build/presentation/map/map_detail_page.dart';
import 'package:fishing_build/presentation/map/map_page.dart';
import 'package:fishing_build/presentation/map/map_selection_controller.dart';
import 'package:fishing_build/presentation/map/location_conditions_card.dart';
import 'package:fishing_build/presentation/map/tide_data_card.dart';
import 'package:fishing_build/presentation/map/tide_panel.dart';
import 'package:fishing_build/presentation/map/weather_data_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixed_water_area_service.dart';

const _first = TideStation(
  code: 'DT_0018',
  name: '첫 예보항',
  latitude: 35,
  longitude: 129,
);
const _second = TideStation(
  code: 'DT_0063',
  name: '둘째 예보항',
  latitude: 35.1,
  longitude: 129,
);
final _catalog = TideStationCatalog(stations: [_first, _second]);
final _location = MapLocation(name: '낚시 위치', latitude: 35, longitude: 129);
final _today = TideDay(2026, 11, 3);

void main() {
  late _Connectivity connectivity;

  setUp(() async {
    connectivity = _Connectivity();
    await NetworkStatusService.instance.resetForTesting(gateway: connectivity);
    await NetworkStatusService.instance.initialize();
  });

  tearDown(() async {
    await NetworkStatusService.instance.close();
    await connectivity.events.close();
  });

  testWidgets(
    'only active coordinate selections fetch and remain alive in a list',
    (tester) async {
      final service = _Tides();
      Widget page({
        bool active = true,
        int results = 0,
        MapLocation? location,
      }) => MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              for (var i = 0; i < results; i++)
                SizedBox(height: 70, child: Text('검색 결과 $i')),
              TidePanel(
                key: const ValueKey('stable-tide-panel'),
                location: location ?? _location,
                waterArea: WaterArea.marine,
                isActive: active,
                service: service,
                catalog: _catalog,
                clock: () => DateTime.utc(2026, 11, 3),
              ),
              const SizedBox(height: 1500),
            ],
          ),
        ),
      );
      await tester.pumpWidget(page(active: false));
      await tester.pumpAndSettle();
      expect(service.requests, isEmpty);
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(service.requests, hasLength(1));
      await tester.pumpWidget(page(results: 20));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, -1700));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, -1200));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, 1200));
      await tester.pumpAndSettle();
      expect(service.requests, hasLength(1));
      await tester.drag(find.byType(ListView), const Offset(0, 4000));
      await tester.pumpAndSettle();
      await tester.pumpWidget(page(location: MapLocation(name: '이름만 있는 곳')));
      await tester.pumpAndSettle();
      expect(service.requests, hasLength(1));
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      expect(_metrics(tester).tideName, isNull);
      expect(find.text('제공되지 않음'), findsNWidgets(5));
      _expectForecastRows(visible: false);
      await tester.pumpWidget(
        page(location: MapLocation(name: '먼 곳', latitude: 37, longitude: 127)),
      );
      await tester.pumpAndSettle();
      expect(service.requests, hasLength(1));
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      expect(_metrics(tester).tideName, isNull);
      expect(find.text('제공되지 않음'), findsNWidgets(5));
      _expectForecastRows(visible: false);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('station and date choices fetch the chosen station and KST day', (
    tester,
  ) async {
    final service = _Tides();
    await tester.pumpWidget(_panel(service));
    await tester.pumpAndSettle();
    expect(service.requests.single.station.code, _first.code);
    expect(service.requests.single.day, _today);
    expect(find.text('무시'), findsOneWidget);
    expect(_metrics(tester).tideName!.convention.label, '7물때식');
    expect(find.textContaining('물때식'), findsNothing);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('둘째 예보항').last);
    await tester.pumpAndSettle();
    expect(service.requests.last.station.code, _second.code);
    expect(find.text('1물'), findsOneWidget);
    expect(_metrics(tester).tideName!.convention.label, '8물때식');
    expect(find.textContaining('물때식'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('tide-date')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('4').last);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(service.requests, hasLength(3));
    expect(service.requests.last.day, TideDay(2026, 11, 4));
    expect(service.requests.last.station.code, _second.code);
    expect(find.text('2026.11.04'), findsOneWidget);
    expect(_metrics(tester).tideName!.day, TideDay(2026, 11, 4));
    expect(find.text('2물'), findsOneWidget);
    _expectForecastRows();
    expect(find.byType(LocationConditionsCard), findsOneWidget);
    expect(find.byType(TideDataCard), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('point, date and station changes discard older responses', (
    tester,
  ) async {
    final service = _Tides(deferred: true);
    final references = <TideRecordReference?>[];
    await tester.pumpWidget(_panel(service, onReference: references.add));
    await tester.pump();
    final moved = MapLocation(name: '새 위치', latitude: 35.09, longitude: 129);
    await tester.pumpWidget(
      _panel(service, location: moved, onReference: references.add),
    );
    await tester.pump();
    expect(service.requests, hasLength(2));
    expect(service.requests.last.station.code, _second.code);
    service.complete(1);
    await tester.pumpAndSettle();
    expect(references.last!.location.name, '새 위치');
    service.complete(0);
    await tester.pumpAndSettle();
    expect(references.last!.location.name, '새 위치');
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('첫 예보항').last);
    await tester.pump();
    expect(references.last, isNull);
    await tester.tap(find.byKey(const ValueKey('tide-date')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('4').last);
    await tester.tap(find.text('OK'));
    await tester.pump();
    service.complete(3);
    await tester.pumpAndSettle();
    service.complete(2);
    await tester.pumpAndSettle();
    expect(references.last!.forecast.day, TideDay(2026, 11, 4));
    expect(references.last!.forecast.station.code, _first.code);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'offline and inactive panels do not fetch; late results are ignored',
    (tester) async {
      final service = _Tides(deferred: true);
      final references = <TideRecordReference?>[];
      connectivity.setConnected(false);
      await tester.pump();
      await tester.pumpWidget(_panel(service, onReference: references.add));
      await tester.pump();
      expect(service.requests, isEmpty);
      expect(find.text('무시'), findsOneWidget);
      expect(_metrics(tester).tideName!.convention.label, '7물때식');
      expect(find.text('제공되지 않음'), findsNWidgets(4));
      expect(find.text('만조·간조 다시 조회'), findsNothing);
      _expectForecastRows(visible: false);
      await tester.pumpWidget(
        _panel(service, active: false, onReference: references.add),
      );
      connectivity.setConnected(true);
      await tester.pump();
      expect(service.requests, isEmpty);
      await tester.pumpWidget(_panel(service, onReference: references.add));
      await tester.pump();
      expect(service.requests, hasLength(1));
      connectivity.setConnected(false);
      await tester.pump();
      service.complete(0);
      await tester.pumpAndSettle();
      expect(references.last, isNull);
      expect(find.byType(TideDataCard), findsNothing);
      expect(find.text('무시'), findsOneWidget);
      _expectForecastRows(visible: false);
      connectivity.setConnected(true);
      await tester.pump();
      expect(service.requests, hasLength(2));
      expect(service.requests.last.forceRefresh, isTrue);
      await tester.pumpWidget(
        _panel(service, active: false, onReference: references.add),
      );
      service.complete(1);
      await tester.pumpAndSettle();
      expect(references.last, isNull);
      await tester.pumpWidget(_panel(service));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      service.complete(2);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('weather failure leaves tide usable and forwards it to detail', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final service = _Tides();
    final weather = _FailedWeather();
    final controller = MapSelectionController(
      locationGateway: _NoGps(),
      initialSelection: _location,
    );
    addTearDown(controller.dispose);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(
        home: MapPage(
          waterAreaService: const FixedWaterAreaService(),
          controller: controller,
          tideService: service,
          tideStations: _catalog,
          externalDataService: weather,
          mapBuilder: (_, _, _) => const SizedBox(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_metrics(tester).data, isNull);
    expect(find.byType(LocationConditionsCard), findsOneWidget);
    expect(find.byType(TideDataCard), findsNothing);
    _expectForecastRows();
    expect(find.text('날씨 다시 조회'), findsOneWidget);
    expect(weather.calls, 1);
    final calls = service.requests.length;
    await tester.tap(find.text('날씨 다시 조회'));
    await tester.pumpAndSettle();
    expect(service.requests, hasLength(calls));
    expect(weather.calls, 2);
    await tester.ensureVisible(find.text('자세히 보기'));
    await tester.tap(find.text('자세히 보기'));
    await tester.pumpAndSettle();
    final detail = tester.widget<MapDetailPage>(find.byType(MapDetailPage));
    expect(detail.tideReference!.location.name, _location.name);
    expect(detail.tideReference!.forecast.station.code, _first.code);
    expect(detail.waterArea, WaterArea.marine);
    expect(find.byType(LocationConditionsCard), findsOneWidget);
    expect(find.byType(TideDataCard), findsNothing);
    expect(_metrics(tester).data, isNull);
    expect(
      find.descendant(
        of: find.byType(WeatherDataCard),
        matching: find.text('제공되지 않음'),
      ),
      findsNWidgets(3),
    );
    _expectForecastRows();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'weather tide follows the selected date and station without a forecast',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final weather = _SuccessfulWeather();
      final service = _Tides(failure: TideFailure.configuration);
      final controller = MapSelectionController(
        locationGateway: _NoGps(),
        initialSelection: _location,
      );
      addTearDown(controller.dispose);
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      await tester.pumpWidget(
        MaterialApp(
          home: MapPage(
            waterAreaService: const FixedWaterAreaService(),
            controller: controller,
            tideService: service,
            tideStations: _catalog,
            externalDataService: weather,
            mapBuilder: (_, _, _) => const SizedBox(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      WeatherDataCard card() =>
          tester.widget<WeatherDataCard>(find.byType(WeatherDataCard));
      expect(card().tideName, isNotNull);
      expect(find.text('물때'), findsOneWidget);
      expect(find.text('물때 명칭'), findsNothing);
      expect(find.text('조석 영역에서 확인'), findsNothing);

      Future<void> selectDay(DateTime day) async {
        await tester.ensureVisible(find.byKey(const ValueKey('tide-date')));
        await tester.tap(find.byKey(const ValueKey('tide-date')));
        await tester.pumpAndSettle();
        Navigator.of(tester.element(find.byType(DatePickerDialog))).pop(day);
        await tester.pumpAndSettle();
      }

      await selectDay(DateTime(2026, 11, 3));
      expect(card().tideName!.label, '무시');
      expect(card().tideName!.day, _today);
      expect(find.text('무시'), findsOneWidget);
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('둘째 예보항').last);
      await tester.pumpAndSettle();
      expect(card().tideName!.station.code, _second.code);
      expect(card().tideName!.label, '1물');
      expect(find.text('1물'), findsOneWidget);

      await selectDay(DateTime(2026, 11, 4));
      expect(card().tideName!.day, TideDay(2026, 11, 4));
      expect(card().tideName!.label, '2물');
      expect(find.text('2026.11.04'), findsOneWidget);
      expect(find.text('2물'), findsOneWidget);
      expect(find.textContaining('물때 기준:'), findsNothing);
      expect(find.textContaining('음력'), findsNothing);
      expect(find.textContaining('물때식'), findsNothing);
      expect(weather.calls, 1);

      connectivity.setConnected(false);
      await tester.pumpAndSettle();
      expect(card().tideName!.label, '2물');
      await tester.ensureVisible(find.text('자세히 보기'));
      await tester.tap(find.text('자세히 보기'));
      await tester.pumpAndSettle();
      final detail = tester.widget<MapDetailPage>(find.byType(MapDetailPage));
      expect(detail.tideReference, isNull);
      expect(detail.tideName!.label, '2물');
      expect(detail.waterArea, WaterArea.marine);
      expect(card().tideName!.label, '2물');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'configuration fallback keeps the tide name and missing weather tide is explicit',
    (tester) async {
      final service = _Tides(failure: TideFailure.configuration);
      await tester.pumpWidget(_panel(service));
      await tester.pumpAndSettle();
      expect(service.requests, hasLength(1));
      expect(find.text('만조·간조 다시 조회'), findsNothing);
      expect(find.text('제공되지 않음'), findsNWidgets(4));
      expect(find.text('무시'), findsOneWidget);
      _expectForecastRows(visible: false);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WeatherDataCard(
              waterArea: WaterArea.marine,
              data: ExternalData(
                locationName: _location.name,
                latitude: 35,
                longitude: 129,
                weather: '맑음',
                airTemperature: 20,
                gridX: 98,
                gridY: 74,
                issuedAt: DateTime.utc(2026, 11, 3),
                validAt: DateTime.utc(2026, 11, 3),
                fetchedAt: DateTime.utc(2026, 11, 3),
              ),
            ),
          ),
        ),
      );
      expect(find.text('물때'), findsOneWidget);
      expect(find.text('수온'), findsOneWidget);
      expect(find.text('제공되지 않음'), findsNWidgets(2));
      expect(find.text('맑음'), findsOneWidget);
      expect(find.text('20℃'), findsOneWidget);
      expect(find.text('조석 영역에서 확인'), findsNothing);
      expect(find.text('수동 입력'), findsNothing);
      expect(find.byType(TextField), findsNothing);
    },
  );

  testWidgets('forecast errors do not hide the selected lunar-day tide name', (
    tester,
  ) async {
    final service = _Tides(failure: TideFailure.network);
    await tester.pumpWidget(_panel(service));
    await tester.pumpAndSettle();
    expect(service.requests, hasLength(1));
    expect(find.text('무시'), findsOneWidget);
    expect(_metrics(tester).tideName!.convention.label, '7물때식');
    expect(find.text('제공되지 않음'), findsNWidgets(4));
    expect(find.byType(TideDataCard), findsNothing);
    _expectForecastRows(visible: false);
    expect(find.text('만조·간조 다시 조회'), findsOneWidget);
    await tester.ensureVisible(find.text('만조·간조 다시 조회'));
    await tester.tap(find.text('만조·간조 다시 조회'));
    await tester.pumpAndSettle();
    expect(service.requests, hasLength(2));
    expect(service.requests.last.forceRefresh, isTrue);
  });

  testWidgets(
    'unknown station conventions show missing tide with actual events',
    (tester) async {
      const unknown = TideStation(
        code: 'UNKNOWN',
        name: '미확인 지점',
        latitude: 35,
        longitude: 129,
      );
      await tester.pumpWidget(
        _panel(_Tides(), catalog: TideStationCatalog(stations: [unknown])),
      );
      await tester.pumpAndSettle();
      expect(_metrics(tester).tideName, isNull);
      expect(find.text('물때'), findsOneWidget);
      expect(find.text('제공되지 않음'), findsNWidgets(4));
      _expectForecastRows();
    },
  );

  testWidgets(
    'dates outside the lunar calendar range show missing tide with actual events',
    (tester) async {
      await tester.pumpWidget(
        _panel(_Tides(), clock: () => DateTime.utc(2036, 1, 1)),
      );
      await tester.pumpAndSettle();
      expect(_metrics(tester).tideName, isNull);
      expect(find.text('물때'), findsOneWidget);
      expect(find.text('제공되지 않음'), findsNWidgets(4));
      expect(find.text('2036.01.01'), findsOneWidget);
      _expectForecastRows();
    },
  );

  testWidgets(
    'forecast references show the tide name and events without metadata',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TideDataCard(
              reference: TideRecordReference(
                location: _location,
                forecast: _forecast(_second, _today),
              ),
            ),
          ),
        ),
      );
      expect(find.text('물때: 1물'), findsOneWidget);
      expect(find.text('2026.11.03 · 둘째 예보항'), findsOneWidget);
      expect(find.textContaining('음력'), findsNothing);
      expect(find.textContaining('물때식'), findsNothing);
      expect(find.textContaining('직선거리'), findsNothing);
      _expectForecastRows();
    },
  );
}

WeatherDataCard _metrics(WidgetTester tester) =>
    tester.widget<WeatherDataCard>(find.byType(WeatherDataCard));

void _expectForecastRows({bool visible = true}) {
  for (final value in ['만조', '09:30', '123 cm', '간조', '15:40', '45.5 cm']) {
    expect(find.text(value), visible ? findsOneWidget : findsNothing);
  }
}

Widget _panel(
  TideService service, {
  MapLocation? location,
  bool active = true,
  TideStationCatalog? catalog,
  DateTime Function()? clock,
  ValueChanged<TideRecordReference?>? onReference,
}) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: TidePanel(
        key: const ValueKey('test-tide-panel'),
        location: location ?? _location,
        waterArea: WaterArea.marine,
        isActive: active,
        service: service,
        catalog: catalog ?? _catalog,
        onReferenceChanged: onReference,
        clock: clock ?? () => DateTime.utc(2026, 11, 3),
      ),
    ),
  ),
);

class _Tides implements TideService {
  _Tides({this.deferred = false, this.failure});
  final bool deferred;
  final TideFailure? failure;
  final requests = <({TideStation station, TideDay day, bool forceRefresh})>[];
  final pending = <Completer<TideForecast>>[];

  @override
  Future<TideForecast> fetchForecast({
    required TideStation station,
    required TideDay day,
    bool forceRefresh = false,
  }) {
    requests.add((station: station, day: day, forceRefresh: forceRefresh));
    if (failure != null) return Future.error(TideException(failure!));
    if (!deferred) return Future.value(_forecast(station, day));
    final request = Completer<TideForecast>();
    pending.add(request);
    return request.future;
  }

  void complete(int index) => pending[index].complete(
    _forecast(requests[index].station, requests[index].day),
  );
}

TideForecast _forecast(TideStation station, TideDay day) => TideForecast(
  station: station,
  day: day,
  fetchedAt: DateTime.utc(2026, 11, 3),
  events: [
    TideEvent(
      at: DateTime.utc(day.year, day.month, day.day, 0, 30),
      heightCm: 123,
      kind: TideEventKind.high,
    ),
    TideEvent(
      at: DateTime.utc(day.year, day.month, day.day, 6, 40),
      heightCm: 45.5,
      kind: TideEventKind.low,
    ),
  ],
);

class _Connectivity implements ConnectivityGateway {
  final events = StreamController<List<ConnectivityResult>>.broadcast();
  var connected = true;

  void setConnected(bool value) {
    connected = value;
    events.add([value ? ConnectivityResult.wifi : ConnectivityResult.none]);
  }

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => [
    connected ? ConnectivityResult.wifi : ConnectivityResult.none,
  ];

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => events.stream;
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

class _FailedWeather implements ExternalDataService {
  int calls = 0;

  @override
  Future<ExternalData> fetchCurrentData({
    required MapLocation location,
    bool forceRefresh = false,
  }) async {
    calls++;
    throw const ExternalDataException(ExternalDataFailure.network);
  }
}

class _SuccessfulWeather implements ExternalDataService {
  int calls = 0;

  @override
  Future<ExternalData> fetchCurrentData({
    required MapLocation location,
    bool forceRefresh = false,
  }) async {
    calls++;
    return ExternalData(
      locationName: location.name,
      latitude: location.latitude!,
      longitude: location.longitude!,
      weather: '맑음',
      airTemperature: 20,
      gridX: 98,
      gridY: 74,
      issuedAt: DateTime.utc(2026, 11, 3),
      validAt: DateTime.utc(2026, 11, 3),
      fetchedAt: DateTime.utc(2026, 11, 3),
    );
  }
}
