import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fishing_build/data/history/historical_conditions.dart';
import 'package:fishing_build/data/history/historical_conditions_service.dart';
import 'package:fishing_build/data/maps/map_location.dart';
import 'package:fishing_build/data/maps/water_area.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/services/network_status_service.dart';
import 'package:fishing_build/data/water_temperature/water_temperature_models.dart';
import 'package:fishing_build/presentation/map/map_history_page.dart';
import 'package:fishing_build/presentation/map/weather_data_card.dart';
import 'package:fishing_build/presentation/record/record_form_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_database.dart';

final _now = DateTime.utc(2026, 11, 3, 12, 34);
final _target = DateTime.utc(2025, 7, 12, 15);
const _weatherStation = HistoricalWeatherStation(
  code: '159',
  name: '부산 기상관측소',
  latitude: 35.1,
  longitude: 129.1,
);
const _waterStation = WaterTemperatureStation(
  code: 'HISTORICAL',
  name: '부산 수온관측소',
  latitude: 35.01,
  longitude: 129.01,
);

void main() {
  final network = NetworkStatusService.instance;
  late _ConnectivityGateway connectivity;
  late _WeatherService weather;
  late _WaterService water;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await resetTestDatabase();
    AuthSessionRepository.instance.clearMemoryOnlyForTesting();
    FishingRecordRepository.instance.clearCacheOnlyForTesting();
    await AuthSessionRepository.instance.setSessionForTesting(
      plan: UserPlan.free,
      email: 'map-history@example.com',
    );
    connectivity = _ConnectivityGateway();
    await network.resetForTesting(gateway: connectivity);
    weather = _WeatherService();
    water = _WaterService();
  });

  tearDown(() async {
    await network.close();
    await connectivity.close();
  });

  Widget page({
    String name = '과거 조회 항구',
    double? latitude = 35,
    double? longitude = 129,
    WaterArea area = WaterArea.marine,
    DateTime? requestedAt,
    double textScale = 1,
  }) => MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: MapHistoryPage(
      selectedLocation: name,
      latitude: latitude,
      longitude: longitude,
      waterArea: area,
      weatherService: weather,
      waterTemperatureService: water,
      initialRequestedAt: requestedAt ?? _target,
      clock: () => _now,
    ),
  );

  Future<void> open(
    WidgetTester tester, {
    Widget? child,
    double width = 1000,
    double height = 1800,
  }) async {
    // Subscribe in the widget test's async zone so connectivity recovery futures
    // are advanced by tester.pump, just like requests started by the page.
    await network.initialize();
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(child ?? page());
    await tester.pump();
  }

  testWidgets('historical KST day and hour request the matching UTC instant', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('2025.07.13'), findsOneWidget);
    expect(_hour(tester).initialValue, 0);
    expect(weather.requests.single.requestedAt, _target);
    expect(water.requests.single.requestedAt, _target);
    expect(weather.requests.single.location.latitude, 35);
    expect(weather.requests.single.location.longitude, 129);
    expect(find.text('맑음'), findsOneWidget);
    expect(find.text('24.6℃'), findsOneWidget);
    expect(find.text('21.8℃'), findsOneWidget);
    expect(find.text('물때'), findsOneWidget);
    expect(find.textContaining('2025.07.13 00:00 관측'), findsNWidgets(2));
    expect(_card(tester).data, isNull);
    expect(_card(tester).waterTemperatureObservation, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'changing KST date and hour converts both requests across UTC day',
    (tester) async {
      await open(tester);
      await _chooseDate(tester, DateTime(2025, 7, 14));
      await _chooseHour(tester, 5);
      final expected = DateTime.utc(2025, 7, 13, 20);
      expect(weather.requests, hasLength(3));
      expect(water.requests, hasLength(3));
      expect(weather.requests.last.requestedAt, expected);
      expect(water.requests.last.requestedAt, expected);
      expect(find.text('2025.07.14'), findsOneWidget);
      expect(_hour(tester).initialValue, 5);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'today only offers completed KST hours and clamps a future target',
    (tester) async {
      await open(
        tester,
        child: page(requestedAt: _now.add(const Duration(days: 2))),
      );
      final latest = historicalHour(_now).subtract(const Duration(hours: 1));
      expect(weather.requests.single.requestedAt, latest);
      expect(water.requests.single.requestedAt, latest);
      expect(_hour(tester).initialValue, 20);
      expect(
        tester
            .widget<DropdownButton<int>>(find.byType(DropdownButton<int>))
            .items!
            .last
            .value,
        20,
      );
      expect(find.text('2026.11.03'), findsOneWidget);
    },
  );

  for (final weatherFails in [true, false]) {
    testWidgets(
      '${weatherFails ? 'weather' : 'water'} failure has an independent retry',
      (tester) async {
        weather.autoComplete = false;
        water.autoComplete = false;
        await open(tester);
        if (weatherFails) {
          weather.requests.single.fail(HistoricalDataFailure.noData);
          water.complete(0);
        } else {
          weather.complete(0);
          water.requests.single.fail(HistoricalDataFailure.timedOut);
        }
        await tester.pump();
        expect(
          _card(tester).historicalWeather,
          weatherFails ? isNull : isNotNull,
        );
        expect(
          _card(tester).historicalWaterTemperature,
          weatherFails ? isNotNull : isNull,
        );
        final unaffected = weatherFails
            ? _card(tester).historicalWaterTemperature
            : _card(tester).historicalWeather;
        final retry = find.widgetWithText(
          TextButton,
          weatherFails ? '날씨 다시 조회' : '수온 다시 조회',
        );
        expect(retry, findsOneWidget);
        expect(find.text(weatherFails ? '수온 다시 조회' : '날씨 다시 조회'), findsNothing);
        await tester.ensureVisible(retry);
        await tester.tap(retry);
        await tester.pump();
        if (weatherFails) {
          expect(weather.requests, hasLength(2));
          expect(water.requests, hasLength(1));
          expect(weather.requests.last.forceRefresh, isTrue);
          expect(_card(tester).historicalWaterTemperature, same(unaffected));
          weather.complete(1, sky: '비');
        } else {
          expect(weather.requests, hasLength(1));
          expect(water.requests, hasLength(2));
          expect(water.requests.last.forceRefresh, isTrue);
          expect(_card(tester).historicalWeather, same(unaffected));
          water.complete(1, temperature: 19.3);
        }
        await tester.pump();
        expect(_card(tester).historicalWeather, isNotNull);
        expect(_card(tester).historicalWaterTemperature, isNotNull);
        expect(find.text('날씨 다시 조회'), findsNothing);
        expect(find.text('수온 다시 조회'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final area in [
    WaterArea.freshwater,
    WaterArea.inland,
    WaterArea.unknown,
  ]) {
    testWidgets('$area requests weather without marine values', (tester) async {
      await open(tester, child: page(area: area));
      expect(weather.requests, hasLength(1));
      expect(water.requests, isEmpty);
      expect(find.text('맑음'), findsOneWidget);
      expect(find.text('수온'), findsNothing);
      expect(find.text('물때'), findsNothing);
      expect(_card(tester).historicalWaterTemperature, isNull);
      expect(_card(tester).tideName, isNull);
      expect(tester.takeException(), isNull);
    });
  }

  for (final changeDate in [false, true]) {
    testWidgets(
      'late results for the old ${changeDate ? 'date' : 'hour'} are ignored',
      (tester) async {
        weather.autoComplete = false;
        water.autoComplete = false;
        await open(tester);
        if (changeDate) {
          await _chooseDate(tester, DateTime(2025, 7, 14));
        } else {
          await _chooseHour(tester, 1);
        }
        expect(weather.requests, hasLength(2));
        expect(water.requests, hasLength(2));
        weather.complete(1, sky: '새로운 관측');
        water.complete(1, temperature: 19.4);
        await tester.pump();
        weather.complete(0, sky: '이전 관측');
        water.complete(0, temperature: 13.1);
        await tester.pump();
        expect(find.text('새로운 관측'), findsOneWidget);
        expect(find.text('이전 관측'), findsNothing);
        expect(find.text('19.4℃'), findsOneWidget);
        expect(find.text('13.1℃'), findsNothing);
        expect(
          _card(tester).historicalWeather!.requestedAt,
          weather.requests.last.requestedAt,
        );
        expect(
          _card(tester).historicalWaterTemperature!.requestedAt,
          water.requests.last.requestedAt,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('late old location results cannot replace the new location', (
    tester,
  ) async {
    weather.autoComplete = false;
    water.autoComplete = false;
    await open(tester);
    await tester.pumpWidget(page(name: '새로운 항구', latitude: 36, longitude: 128));
    await tester.pump();
    expect(weather.requests, hasLength(2));
    expect(water.requests, hasLength(2));
    weather.complete(1, sky: '새 위치 관측');
    water.complete(1, temperature: 19.5);
    await tester.pump();
    weather.complete(0, sky: '이전 위치 관측');
    water.complete(0, temperature: 13.2);
    await tester.pump();
    expect(find.text('새 위치 관측'), findsOneWidget);
    expect(find.text('이전 위치 관측'), findsNothing);
    expect(_card(tester).historicalWeather!.location.name, '새로운 항구');
    expect(_card(tester).historicalWaterTemperature!.location.longitude, 128);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late old failures cannot add retry buttons after new results', (
    tester,
  ) async {
    weather.autoComplete = false;
    water.autoComplete = false;
    await open(tester);
    await _chooseHour(tester, 1);
    weather.complete(1);
    water.complete(1);
    await tester.pump();
    weather.requests.first.fail(HistoricalDataFailure.network);
    water.requests.first.fail(HistoricalDataFailure.timedOut);
    await tester.pump();
    expect(find.text('날씨 다시 조회'), findsNothing);
    expect(find.text('수온 다시 조회'), findsNothing);
    expect(find.text('맑음'), findsOneWidget);
    expect(find.text('21.8℃'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'disposal ignores pending results and removes the network listener',
    (tester) async {
      weather.autoComplete = false;
      water.autoComplete = false;
      await open(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      weather.complete(0);
      water.requests.single.fail(HistoricalDataFailure.network);
      connectivity.emit(ConnectivityResult.none);
      connectivity.emit(ConnectivityResult.wifi);
      await tester.pumpAndSettle();
      expect(weather.requests, hasLength(1));
      expect(water.requests, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'offline starts no requests and recovery reloads both providers',
    (tester) async {
      connectivity.emit(ConnectivityResult.none);
      await open(tester);
      expect(weather.requests, isEmpty);
      expect(water.requests, isEmpty);
      final weatherRetry = find.widgetWithText(TextButton, '날씨 다시 조회');
      final waterRetry = find.widgetWithText(TextButton, '수온 다시 조회');
      expect(tester.widget<TextButton>(weatherRetry).onPressed, isNull);
      expect(tester.widget<TextButton>(waterRetry).onPressed, isNull);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      connectivity.emit(ConnectivityResult.wifi);
      await tester.pumpAndSettle();
      expect(weather.requests.single.forceRefresh, isTrue);
      expect(water.requests.single.forceRefresh, isTrue);
      expect(find.text('맑음'), findsOneWidget);
      expect(find.text('21.8℃'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('disconnect invalidates pending requests before recovery', (
    tester,
  ) async {
    weather.autoComplete = false;
    water.autoComplete = false;
    await open(tester);
    connectivity.emit(ConnectivityResult.none);
    await tester.pump();
    weather.complete(0, sky: '연결 끊기 전 결과');
    water.complete(0, temperature: 12.4);
    await tester.pump();
    expect(_card(tester).historicalWeather, isNull);
    expect(_card(tester).historicalWaterTemperature, isNull);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    connectivity.emit(ConnectivityResult.wifi);
    await tester.pump();
    expect(weather.requests, hasLength(2));
    expect(water.requests, hasLength(2));
    expect(weather.requests.last.forceRefresh, isTrue);
    expect(water.requests.last.forceRefresh, isTrue);
    weather.complete(1, sky: '연결 복구 후 결과');
    water.complete(1, temperature: 20.4);
    await tester.pump();
    await tester.pump();
    expect(weather.requests, hasLength(2));
    expect(water.requests, hasLength(2));
    expect(_card(tester).historicalWeather, isNotNull);
    expect(_card(tester).historicalWaterTemperature, isNotNull);
    expect(find.text('연결 복구 후 결과'), findsOneWidget);
    expect(find.text('연결 끊기 전 결과'), findsNothing);
    expect(find.text('20.4℃'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing coordinates explain the requirement without requests', (
    tester,
  ) async {
    await open(tester, child: page(latitude: null, longitude: null));
    expect(weather.requests, isEmpty);
    expect(water.requests, isEmpty);
    expect(find.text('지도에서 좌표가 있는 위치를 선택해 주세요.'), findsOneWidget);
    expect(find.text('날씨 다시 조회'), findsNothing);
    expect(find.text('수온 다시 조회'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('guests can read history but must sign in to create a record', (
    tester,
  ) async {
    AuthSessionRepository.instance.clearMemoryOnlyForTesting();
    await AuthSessionRepository.instance.setSessionForTesting(
      plan: UserPlan.guest,
    );
    await open(tester);
    expect(find.text('맑음'), findsOneWidget);
    final create = find.widgetWithText(FilledButton, '이 정보로 기록 작성');
    await tester.ensureVisible(create);
    await tester.tap(create);
    await tester.pumpAndSettle();
    expect(find.text('로그인이 필요합니다'), findsOneWidget);
    expect(find.text('조회한 과거 정보를 출조 기록으로 저장하려면 로그인이 필요합니다.'), findsOneWidget);
    expect(find.byType(RecordFormPage), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, '나중에'));
    await tester.pumpAndSettle();
    expect(find.byType(MapHistoryPage), findsOneWidget);
    expect(find.byType(RecordFormPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'record receives selected historical UTC time and observation references',
    (tester) async {
      await open(tester);
      await _chooseDate(tester, DateTime(2025, 7, 14));
      await _chooseHour(tester, 5);
      final selectedWeather = _card(tester).historicalWeather;
      final selectedWater = _card(tester).historicalWaterTemperature;
      final create = find.widgetWithText(FilledButton, '이 정보로 기록 작성');
      await tester.ensureVisible(create);
      await tester.tap(create);
      await tester.pumpAndSettle();
      final form = tester.widget<RecordFormPage>(find.byType(RecordFormPage));
      expect(form.initialStartAt, DateTime.utc(2025, 7, 13, 20));
      expect(form.initialLocation, '과거 조회 항구');
      expect(form.initialLatitude, 35);
      expect(form.initialLongitude, 129);
      expect(form.initialHistoricalWeather, same(selectedWeather));
      expect(form.initialHistoricalWaterTemperature, same(selectedWater));
      expect(form.initialExternalData, isNull);
      expect(form.initialWaterTemperatureObservation, isNull);
      expect(form.initialWeather, isNull);
      expect(form.initialAirTemperature, isNull);
      expect(form.initialWaterTemperature, isNull);
      expect(form.allowAutomaticTide, isTrue);
      expect(form.allowAutomaticWaterTemperature, isTrue);
      expect(_recordText(tester, 'record-weather'), '맑음');
      expect(_recordText(tester, 'record-water-temperature'), '21.8');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'nonmarine record receives weather while marine automatic fields stay disabled',
    (tester) async {
      await open(tester, child: page(area: WaterArea.freshwater));
      final create = find.widgetWithText(FilledButton, '이 정보로 기록 작성');
      await tester.ensureVisible(create);
      await tester.tap(create);
      await tester.pumpAndSettle();
      final form = tester.widget<RecordFormPage>(find.byType(RecordFormPage));
      expect(form.initialHistoricalWeather, isNotNull);
      expect(form.initialHistoricalWaterTemperature, isNull);
      expect(form.allowAutomaticTide, isFalse);
      expect(form.allowAutomaticWaterTemperature, isFalse);
      expect(_recordText(tester, 'record-weather'), '맑음');
      expect(_recordText(tester, 'record-tide'), isEmpty);
      expect(_recordText(tester, 'record-water-temperature'), isEmpty);
      expect(water.requests, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow screen at double text scale keeps observation details readable',
    (tester) async {
      await open(tester, child: page(textScale: 2), width: 320, height: 1000);
      await tester.pump();
      expect(find.text('맑음'), findsOneWidget);
      final waterDetail = find.text('부산 수온관측소 · 2025.07.13 00:00 관측');
      await tester.ensureVisible(waterDetail);
      await tester.pump();
      expect(waterDetail, findsOneWidget);
      final cardSize = tester.getSize(find.byType(WeatherDataCard));
      expect(cardSize.width, lessThanOrEqualTo(320));
      expect(tester.takeException(), isNull);
    },
  );
}

WeatherDataCard _card(WidgetTester tester) =>
    tester.widget<WeatherDataCard>(find.byType(WeatherDataCard));

DropdownButtonFormField<int> _hour(WidgetTester tester) =>
    tester.widget<DropdownButtonFormField<int>>(
      find.byType(DropdownButtonFormField<int>),
    );

Future<void> _chooseDate(WidgetTester tester, DateTime day) async {
  await tester.tap(find.byKey(const ValueKey('history-date')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  Navigator.of(tester.element(find.byType(DatePickerDialog))).pop(day);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _chooseHour(WidgetTester tester, int hour) async {
  await tester.tap(find.byType(DropdownButtonFormField<int>));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  final option = find.text('${hour.toString().padLeft(2, '0')}:00').last;
  await tester.ensureVisible(option);
  await tester.tap(option);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

String _recordText(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;

class _Request<T> {
  _Request(this.location, this.requestedAt, this.forceRefresh);

  final MapLocation location;
  final DateTime requestedAt;
  final bool forceRefresh;
  final completer = Completer<T>();

  void fail(HistoricalDataFailure reason) =>
      completer.completeError(HistoricalDataException(reason));
}

class _WeatherService implements HistoricalWeatherService {
  bool autoComplete = true;
  final requests = <_Request<HistoricalWeatherObservation>>[];

  @override
  Future<HistoricalWeatherObservation> fetchAt({
    required MapLocation location,
    required DateTime requestedAt,
    bool forceRefresh = false,
  }) {
    final request = _Request<HistoricalWeatherObservation>(
      location,
      requestedAt,
      forceRefresh,
    );
    requests.add(request);
    if (autoComplete) complete(requests.length - 1);
    return request.completer.future;
  }

  void complete(int index, {String sky = '맑음'}) {
    final request = requests[index];
    request.completer.complete(
      HistoricalWeatherObservation(
        location: request.location,
        station: _weatherStation,
        requestedAt: request.requestedAt,
        observedAt: historicalHour(request.requestedAt),
        fetchedAt: _now,
        weather: sky,
        airTemperature: 24.6,
      ),
    );
  }
}

class _WaterService implements HistoricalWaterTemperatureService {
  bool autoComplete = true;
  final requests = <_Request<HistoricalWaterTemperatureObservation>>[];

  @override
  Future<HistoricalWaterTemperatureObservation> fetchAt({
    required MapLocation location,
    required DateTime requestedAt,
    bool forceRefresh = false,
  }) {
    final request = _Request<HistoricalWaterTemperatureObservation>(
      location,
      requestedAt,
      forceRefresh,
    );
    requests.add(request);
    if (autoComplete) complete(requests.length - 1);
    return request.completer.future;
  }

  void complete(int index, {double temperature = 21.8}) {
    final request = requests[index];
    request.completer.complete(
      HistoricalWaterTemperatureObservation(
        location: request.location,
        station: _waterStation,
        requestedAt: request.requestedAt,
        observedAt: request.requestedAt,
        fetchedAt: _now,
        temperatureCelsius: temperature,
      ),
    );
  }
}

class _ConnectivityGateway implements ConnectivityGateway {
  ConnectivityResult current = ConnectivityResult.wifi;
  final _events = StreamController<List<ConnectivityResult>>.broadcast(
    sync: true,
  );

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => [current];

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => _events.stream;

  void emit(ConnectivityResult result) {
    current = result;
    _events.add([result]);
  }

  Future<void> close() => _events.close();
}
