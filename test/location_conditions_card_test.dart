import 'package:fishing_build/data/maps/map_location.dart';
import 'package:fishing_build/data/maps/water_area.dart';
import 'package:fishing_build/data/models/external_data.dart';
import 'package:fishing_build/data/tides/tide_models.dart';
import 'package:fishing_build/data/tides/tide_name.dart';
import 'package:fishing_build/data/water_temperature/water_temperature_models.dart';
import 'package:fishing_build/presentation/map/location_conditions_card.dart';
import 'package:fishing_build/presentation/map/weather_data_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _station = TideStation(
  code: 'DT_0018',
  name: '군산',
  latitude: 35.9755,
  longitude: 126.5631,
);
final _day = TideDay(2026, 11, 3);
final _name = TideName.calculate(day: _day, station: _station)!;

void main() {
  testWidgets('marine conditions combine four metrics and both tide events', (
    tester,
  ) async {
    await _pump(
      tester,
      LocationConditionsCard(
        waterArea: WaterArea.marine,
        weatherData: _weather(),
        tideName: _name,
        tideForecast: _forecast(),
        waterTemperatureObservation: _observation(),
      ),
    );

    for (final label in ['날씨', '기온', '물때', '수온']) {
      expect(find.text(label), findsOneWidget);
    }
    for (final value in ['맑음', '20℃', '무시', '17.5℃']) {
      expect(find.text(value), findsOneWidget);
    }
    expect(find.text('만조'), findsOneWidget);
    expect(find.text('09:30'), findsOneWidget);
    expect(find.text('123 cm'), findsOneWidget);
    expect(find.text('간조'), findsOneWidget);
    expect(find.text('15:40'), findsOneWidget);
    expect(find.text('-12.5 cm'), findsOneWidget);
    expect(find.byType(Card), findsOneWidget);
    expect(
      tester.widget<WeatherDataCard>(find.byType(WeatherDataCard)).embedded,
      isTrue,
    );
    expect(find.text('날씨·낚시 정보'), findsOneWidget);
    for (final metadata in ['기상청', '격자', '발표', '직선거리', '음력', '물때식']) {
      expect(find.textContaining(metadata), findsNothing);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'freshwater inland and unknown areas suppress stale marine values',
    (tester) async {
      for (final area in [
        WaterArea.freshwater,
        WaterArea.inland,
        WaterArea.unknown,
      ]) {
        await _pump(
          tester,
          LocationConditionsCard(
            waterArea: area,
            weatherData: _weather(),
            tideName: _name,
            tideForecast: _forecast(),
            waterTemperatureObservation: _observation(),
            waterTemperatureLoading: true,
            waterTemperatureError: '숨겨야 하는 수온 오류',
            onRetryWaterTemperature: () {},
            tideControls: const Text('예보 지점 선택'),
            tideError: '숨겨야 하는 조석 오류',
            onRetryTide: () {},
          ),
        );

        expect(find.text('맑음'), findsOneWidget, reason: area.name);
        expect(find.text('20℃'), findsOneWidget, reason: area.name);
        for (final marineText in [
          '물때',
          '수온',
          '무시',
          '17.5℃',
          '만조·간조',
          '09:30',
          '123 cm',
          '예보 지점 선택',
          '만조·간조 다시 조회',
          '수온 다시 조회',
        ]) {
          expect(find.text(marineText), findsNothing, reason: area.name);
        }
        expect(find.byType(Card), findsOneWidget);
        expect(
          find.byKey(const ValueKey('water-temperature-loading')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('unavailable marine data uses a consistent missing-value label', (
    tester,
  ) async {
    await _pump(
      tester,
      const LocationConditionsCard(waterArea: WaterArea.marine),
    );

    expect(find.text('제공되지 않음'), findsNWidgets(5));
    for (final obsoleteText in [
      '수동 입력',
      '직접 입력',
      '제공:',
      '격자',
      '발표',
      '음력',
      '물때식',
      '직선거리',
    ]) {
      expect(find.textContaining(obsoleteText), findsNothing);
    }
    expect(find.byType(Card), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('marine weather legacy water temperature is never displayed', (
    tester,
  ) async {
    await _pump(
      tester,
      LocationConditionsCard(
        waterArea: WaterArea.marine,
        weatherData: _weather(),
      ),
    );
    expect(find.text('맑음'), findsOneWidget);
    expect(find.text('20℃'), findsOneWidget);
    expect(find.text('수온'), findsOneWidget);
    expect(find.text('17.5℃'), findsNothing);
    expect(find.text('제공되지 않음'), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('water measurement time is independent of the future tide date', (
    tester,
  ) async {
    final observation = _observation();
    final futureDay = TideDay.fromInstant(
      DateTime.now().add(const Duration(days: 3)),
    );
    await _pump(
      tester,
      LocationConditionsCard(
        waterArea: WaterArea.marine,
        waterTemperatureObservation: observation,
        tideForecast: _forecast(day: futureDay),
      ),
    );
    expect(find.text('17.5℃'), findsOneWidget);
    expect(
      find.text(
        '군산 연안 수온 관측소 · ${formatWeatherTime(observation.observedAt)} 관측',
      ),
      findsOneWidget,
    );
    expect(find.text('${futureDay.label} · 군산'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final age in [const Duration(hours: 3), const Duration(minutes: -10)]) {
    testWidgets('unusable water observation age $age stays unavailable', (
      tester,
    ) async {
      await _pump(
        tester,
        LocationConditionsCard(
          waterArea: WaterArea.marine,
          weatherData: _weather(),
          waterTemperatureObservation: _observation(age: age),
        ),
      );
      expect(find.text('17.5℃'), findsNothing);
      expect(find.textContaining('수온 관측소 · '), findsNothing);
      expect(find.text('제공되지 않음'), findsNWidgets(3));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('section retries work without displaying raw service errors', (
    tester,
  ) async {
    var weatherRetries = 0;
    var tideRetries = 0;
    var waterRetries = 0;
    await _pump(
      tester,
      LocationConditionsCard(
        waterArea: WaterArea.marine,
        weatherError: '날씨 서비스의 내부 오류 내용',
        tideError: '조석 서비스의 내부 오류 내용',
        waterTemperatureError: '수온 서비스의 내부 오류 내용',
        onRetryWeather: () => weatherRetries++,
        onRetryTide: () => tideRetries++,
        onRetryWaterTemperature: () => waterRetries++,
      ),
    );

    expect(find.textContaining('내부 오류'), findsNothing);
    expect(find.text('제공되지 않음'), findsNWidgets(5));
    await tester.tap(find.text('날씨 다시 조회'));
    expect(weatherRetries, 1);
    expect(tideRetries, 0);
    expect(waterRetries, 0);
    await tester.ensureVisible(find.text('수온 다시 조회'));
    await tester.tap(find.text('수온 다시 조회'));
    expect(waterRetries, 1);
    expect(weatherRetries, 1);
    expect(tideRetries, 0);
    await tester.ensureVisible(find.text('만조·간조 다시 조회'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('만조·간조 다시 조회'));
    expect(tideRetries, 1);
    expect(weatherRetries, 1);
    expect(waterRetries, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a 320-pixel phone supports doubled text without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final observation = _observation();
    await _pump(
      tester,
      LocationConditionsCard(
        waterArea: WaterArea.marine,
        weatherData: _weather(weather: '흐리고 한때 비'),
        tideName: _name,
        tideForecast: _forecast(),
        waterTemperatureObservation: observation,
        waterAreaSelector: const Text('바다'),
        tideControls: const Text('군산 · 2026.11.03'),
      ),
      textScale: 2,
    );

    expect(find.text('흐리고 한때 비'), findsOneWidget);
    expect(find.text('무시'), findsOneWidget);
    expect(find.text('17.5℃'), findsOneWidget);
    expect(tester.getSize(find.byType(Card)).width, lessThanOrEqualTo(320));
    expect(tester.takeException(), isNull);
    final observedTime = find.text(
      '군산 연안 수온 관측소 · ${formatWeatherTime(observation.observedAt)} 관측',
    );
    await tester.ensureVisible(observedTime);
    await tester.pumpAndSettle();
    expect(observedTime.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('15:40'));
    await tester.pumpAndSettle();
    expect(find.text('-12.5 cm').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pump(
  WidgetTester tester,
  Widget card, {
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: card,
        ),
      ),
    ),
  );
}

ExternalData _weather({String weather = '맑음'}) => ExternalData(
  locationName: '군산항',
  latitude: _station.latitude,
  longitude: _station.longitude,
  weather: weather,
  airTemperature: 20,
  waterTemperature: 17.5,
  gridX: 55,
  gridY: 91,
  issuedAt: DateTime.utc(2026, 11, 3),
  validAt: DateTime.utc(2026, 11, 3, 1),
  fetchedAt: DateTime.utc(2026, 11, 3),
);

TideForecast _forecast({TideDay? day}) => TideForecast(
  station: _station,
  day: day ?? _day,
  fetchedAt: DateTime.utc(2026, 11, 3),
  events: [
    TideEvent(
      at: DateTime.utc(
        (day ?? _day).year,
        (day ?? _day).month,
        (day ?? _day).day,
        0,
        30,
      ),
      heightCm: 123,
      kind: TideEventKind.high,
    ),
    TideEvent(
      at: DateTime.utc(
        (day ?? _day).year,
        (day ?? _day).month,
        (day ?? _day).day,
        6,
        40,
      ),
      heightCm: -12.5,
      kind: TideEventKind.low,
    ),
  ],
);

WaterTemperatureObservation _observation({
  Duration age = const Duration(minutes: 10),
}) {
  final now = DateTime.now().toUtc();
  return WaterTemperatureObservation(
    location: MapLocation(
      name: '군산항',
      latitude: _station.latitude,
      longitude: _station.longitude,
    ),
    station: const WaterTemperatureStation(
      code: 'TEST_GUN',
      name: '군산 연안 수온 관측소',
      latitude: 35.9755,
      longitude: 126.5631,
    ),
    temperatureCelsius: 17.5,
    observedAt: now.subtract(age),
    fetchedAt: now,
  );
}
