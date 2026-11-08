import 'package:fishing_build/data/history/historical_conditions.dart';
import 'package:fishing_build/data/maps/map_location.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/water_temperature/water_temperature_models.dart';
import 'package:fishing_build/presentation/record/record_form_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_database.dart';

final _location = MapLocation(name: '과거 기록 항구', latitude: 35, longitude: 129);
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
final _target = DateTime.utc(2025, 7, 12, 15);

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await resetTestDatabase();
    AuthSessionRepository.instance.clearMemoryOnlyForTesting();
    FishingRecordRepository.instance.clearCacheOnlyForTesting();
    await AuthSessionRepository.instance.setSessionForTesting(
      plan: UserPlan.free,
      email: 'historical-prefill@example.com',
    );
  });

  testWidgets('UTC start is displayed locally and saved with a two hour end', (
    tester,
  ) async {
    await _open(tester);
    expect(_dateTimeText(tester, '시작 시간 *'), _format(_target.toLocal()));
    expect(
      _dateTimeText(tester, '종료 시간 *'),
      _format(_target.toLocal().add(const Duration(hours: 2))),
    );
    expect(_text(tester, '날씨 *'), '맑음');
    expect(_text(tester, '기온 *'), '24.6');
    expect(_text(tester, '수온 (선택)'), '21.8');
    expect(find.text('부산 기상관측소 · 과거 관측 2025.07.13 00:00 KST'), findsOneWidget);
    expect(find.text('부산 수온관측소 · 과거 관측 2025.07.13 00:00 KST'), findsOneWidget);
    await _selectGenreAndSave(tester);
    final saved = FishingRecordRepository.instance.getAllRecords().single;
    expect(saved.startAt.isAtSameMomentAs(_target), isTrue);
    expect(saved.endAt.difference(saved.startAt), const Duration(hours: 2));
    expect(saved.weather, '맑음');
    expect(saved.airTemperature, 24.6);
    expect(saved.waterTemperature, 21.8);
    expect(tester.takeException(), isNull);
  });

  for (final mismatch in ['name', 'latitude', 'longitude', 'hour']) {
    testWidgets('historical values require matching $mismatch', (tester) async {
      await _open(
        tester,
        name: mismatch == 'name' ? '다른 항구' : _location.name,
        latitude: mismatch == 'latitude' ? 34 : _location.latitude!,
        longitude: mismatch == 'longitude' ? 128 : _location.longitude!,
        startAt: mismatch == 'hour'
            ? _target.add(const Duration(hours: 1))
            : _target,
      );
      _expectValues(tester, weather: '', air: '', water: '');
      expect(
        find.byKey(const ValueKey('record-historical-weather-reference')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final coordinate in ['record-latitude', 'record-longitude']) {
    testWidgets(
      'changing $coordinate invalidates untouched historical fields',
      (tester) async {
        await _open(tester);
        final field = find.byKey(ValueKey(coordinate));
        final original = tester.widget<TextField>(field).controller!.text;
        await tester.enterText(field, '34');
        await tester.pump();
        _expectValues(tester, weather: '', air: '', water: '');
        await tester.enterText(field, original);
        await tester.pump();
        _expectValues(tester);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'location changes clear automatic values and restore matching ones',
    (tester) async {
      await _open(tester);
      await tester.enterText(_field('물때 (선택)'), '직접 확인한 물때');
      await tester.enterText(_field('위치 *'), '다른 항구');
      await tester.pump();
      _expectValues(tester, weather: '', air: '', water: '');
      expect(_text(tester, '물때 (선택)'), '직접 확인한 물때');
      await tester.enterText(_field('위치 *'), _location.name);
      await tester.pump();
      _expectValues(tester);
      expect(_text(tester, '물때 (선택)'), '직접 확인한 물때');
    },
  );

  for (final offset in [const Duration(hours: 1), const Duration(days: 1)]) {
    testWidgets('changing start by $offset clears and returning restores', (
      tester,
    ) async {
      await _open(tester);
      await _chooseStart(tester, _target.add(offset).toLocal());
      _expectValues(tester, weather: '', air: '', water: '');
      expect(
        find.byKey(const ValueKey('record-historical-weather-reference')),
        findsNothing,
      );
      await _chooseStart(tester, _target.toLocal());
      _expectValues(tester);
      expect(tester.takeException(), isNull);
    });
  }

  for (final clear in [false, true]) {
    testWidgets(
      'manual ${clear ? 'clears' : 'edits'} survive all reconciliations',
      (tester) async {
        await _open(tester);
        final weather = clear ? '' : '직접 확인한 비';
        final air = clear ? '' : '18.4';
        final water = clear ? '' : '19.2';
        await tester.enterText(_field('날씨 *'), weather);
        await tester.enterText(_field('기온 *'), air);
        await tester.enterText(_field('수온 (선택)'), water);
        await tester.enterText(_field('위치 *'), '다른 항구');
        await tester.enterText(_field('위치 *'), _location.name);
        await _chooseStart(
          tester,
          _target.add(const Duration(days: 1)).toLocal(),
        );
        await _chooseStart(tester, _target.toLocal());
        _expectValues(tester, weather: weather, air: air, water: water);
        expect(
          find.byKey(const ValueKey('record-historical-weather-reference')),
          findsNothing,
        );
        expect(find.textContaining('수온관측소 · 과거 관측'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('manual weather leaves other historical fields free to restore', (
    tester,
  ) async {
    await _open(tester);
    await tester.enterText(_field('날씨 *'), '직접 확인한 비');
    await tester.enterText(_field('위치 *'), '다른 항구');
    await tester.pump();
    _expectValues(tester, weather: '직접 확인한 비', air: '', water: '');
    await tester.enterText(_field('위치 *'), _location.name);
    await tester.pump();
    _expectValues(tester, weather: '직접 확인한 비');
  });

  testWidgets('explicit initial values preserve manual ownership', (
    tester,
  ) async {
    await _open(tester, weather: '직접 입력', air: 12.3, water: 14.5);
    await tester.enterText(_field('위치 *'), '다른 항구');
    await tester.enterText(_field('위치 *'), _location.name);
    await _chooseStart(tester, _target.add(const Duration(days: 1)).toLocal());
    await _chooseStart(tester, _target.toLocal());
    _expectValues(tester, weather: '직접 입력', air: '12.3', water: '14.5');
    expect(
      find.byKey(const ValueKey('record-historical-weather-reference')),
      findsNothing,
    );
  });

  for (final stored in [true, false]) {
    testWidgets(
      'editing ${stored ? 'stored' : 'empty'} fields preserves them',
      (tester) async {
        final storedStart = _target.subtract(const Duration(days: 2)).toLocal();
        final record = FishingRecord(
          id: 'historical-edit',
          location: _location.name,
          latitude: _location.latitude,
          longitude: _location.longitude,
          startAt: storedStart,
          endAt: storedStart.add(const Duration(hours: 2)),
          genreName: '루어',
          tide: '3물',
          weather: stored ? '기록한 비' : null,
          airTemperature: stored ? 18 : null,
          waterTemperature: stored ? 17 : null,
        );
        await FishingRecordRepository.instance.addRecord(record);
        await _open(tester, editingRecord: record);
        expect(_dateTimeText(tester, '시작 시간 *'), _format(record.startAt));
        await _chooseStart(tester, _target.toLocal());
        await tester.enterText(_field('위치 *'), '다른 항구');
        await tester.enterText(_field('위치 *'), _location.name);
        await tester.pump();
        _expectValues(
          tester,
          weather: stored ? '기록한 비' : '',
          air: stored ? '18.0' : '',
          water: stored ? '17.0' : '',
        );
        expect(
          find.byKey(const ValueKey('record-historical-weather-reference')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('nonmarine history fills weather and leaves water manual', (
    tester,
  ) async {
    await _open(tester, allowAutomaticWaterTemperature: false);
    _expectValues(tester, water: '');
    await tester.enterText(_field('위치 *'), '다른 항구');
    await tester.enterText(_field('위치 *'), _location.name);
    await tester.pump();
    _expectValues(tester, water: '');
    expect(find.textContaining('수온관측소 · 과거 관측'), findsNothing);
  });

  for (final airOnly in [true, false]) {
    testWidgets(
      'partial historical weather ${airOnly ? 'without sky' : 'with invalid air'} preserves independent fields',
      (tester) async {
        await _open(
          tester,
          historicalWeather: HistoricalWeatherObservation(
            location: _location,
            station: _weatherStation,
            requestedAt: _target,
            observedAt: _target,
            fetchedAt: DateTime.now().toUtc(),
            weather: airOnly ? null : '맑음',
            airTemperature: airOnly ? 0 : double.nan,
          ),
        );
        _expectValues(
          tester,
          weather: airOnly ? '' : '맑음',
          air: airOnly ? '0.0' : '',
        );
        await tester.enterText(_field('위치 *'), '다른 항구');
        await tester.enterText(_field('위치 *'), _location.name);
        await tester.pump();
        _expectValues(
          tester,
          weather: airOnly ? '' : '맑음',
          air: airOnly ? '0.0' : '',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('current observations cannot prefill a historical record', (
    tester,
  ) async {
    final now = DateTime.now().toUtc();
    await _open(
      tester,
      includeHistory: false,
      currentWater: WaterTemperatureObservation(
        location: _location,
        station: _waterStation,
        temperatureCelsius: 16.2,
        observedAt: now.subtract(const Duration(minutes: 10)),
        fetchedAt: now,
      ),
    );
    _expectValues(tester, weather: '', air: '', water: '');
    expect(tester.takeException(), isNull);
  });

  testWidgets('historical observation cannot bypass current freshness checks', (
    tester,
  ) async {
    await _open(
      tester,
      includeHistory: false,
      currentWater: WaterTemperatureObservation(
        location: _location,
        station: _waterStation,
        temperatureCelsius: 21.8,
        observedAt: _target,
        fetchedAt: DateTime.now().toUtc(),
      ),
    );
    expect(_text(tester, '수온 (선택)'), isEmpty);
  });

  for (final field in ['날씨 *', '기온 *']) {
    testWidgets('clearing historical $field preserves required validation', (
      tester,
    ) async {
      await _open(tester);
      await tester.enterText(_field(field), '');
      await _selectGenreAndSave(tester);
      expect(_text(tester, field), isEmpty);
      final message = field == '날씨 *' ? '날씨를 입력하세요.' : '기온을 입력하세요.';
      expect(find.text(message), findsOneWidget);
      expect(FishingRecordRepository.instance.getAllRecords(), isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('clearing historical water saves null without refilling', (
    tester,
  ) async {
    await _open(tester);
    await tester.enterText(_field('수온 (선택)'), '');
    await _selectGenreAndSave(tester);
    expect(
      FishingRecordRepository.instance.getAllRecords().single.waterTemperature,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });
}

HistoricalWeatherObservation _weather() => HistoricalWeatherObservation(
  location: _location,
  station: _weatherStation,
  requestedAt: _target,
  observedAt: _target,
  fetchedAt: DateTime.now().toUtc(),
  weather: '맑음',
  airTemperature: 24.6,
);

HistoricalWaterTemperatureObservation _water() =>
    HistoricalWaterTemperatureObservation(
      location: _location,
      station: _waterStation,
      requestedAt: _target,
      observedAt: _target,
      fetchedAt: DateTime.now().toUtc(),
      temperatureCelsius: 21.8,
    );

Future<void> _open(
  WidgetTester tester, {
  DateTime? startAt,
  String name = '과거 기록 항구',
  double latitude = 35,
  double longitude = 129,
  String? weather,
  double? air,
  double? water,
  bool includeHistory = true,
  bool allowAutomaticWaterTemperature = true,
  WaterTemperatureObservation? currentWater,
  HistoricalWeatherObservation? historicalWeather,
  FishingRecord? editingRecord,
}) async {
  tester.view.physicalSize = const Size(1000, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
  await tester.pumpWidget(
    MaterialApp(
      home: RecordFormPage(
        editingRecord: editingRecord,
        initialStartAt: startAt ?? _target,
        initialLocation: name,
        initialLatitude: latitude,
        initialLongitude: longitude,
        initialWeather: weather,
        initialAirTemperature: air,
        initialWaterTemperature: water,
        initialHistoricalWeather: includeHistory
            ? historicalWeather ?? _weather()
            : null,
        initialHistoricalWaterTemperature: includeHistory ? _water() : null,
        initialWaterTemperatureObservation: currentWater,
        allowAutomaticWaterTemperature: allowAutomaticWaterTemperature,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _chooseStart(WidgetTester tester, DateTime startAt) async {
  final field = find
      .ancestor(of: find.text('시작 시간 *'), matching: find.byType(InkWell))
      .first;
  await tester.ensureVisible(field);
  await tester.tap(field);
  await tester.pumpAndSettle();
  Navigator.of(tester.element(find.byType(DatePickerDialog))).pop(startAt);
  await tester.pumpAndSettle();
  Navigator.of(
    tester.element(find.byType(TimePickerDialog)),
  ).pop(TimeOfDay.fromDateTime(startAt));
  await tester.pumpAndSettle();
}

Future<void> _selectGenreAndSave(WidgetTester tester) async {
  final genre = find.widgetWithText(ChoiceChip, '루어');
  await tester.ensureVisible(genre);
  await tester.tap(genre);
  final save = find.widgetWithText(FilledButton, '저장');
  await tester.ensureVisible(save);
  await tester.tap(save);
  await tester.pumpAndSettle();
}

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

String _text(WidgetTester tester, String label) =>
    tester.widget<TextField>(_field(label)).controller!.text;

void _expectValues(
  WidgetTester tester, {
  String weather = '맑음',
  String air = '24.6',
  String water = '21.8',
}) {
  expect(_text(tester, '날씨 *'), weather);
  expect(_text(tester, '기온 *'), air);
  expect(_text(tester, '수온 (선택)'), water);
}

String _dateTimeText(WidgetTester tester, String label) => tester
    .widget<Text>(
      find
          .descendant(
            of: find
                .ancestor(of: find.text(label), matching: find.byType(InkWell))
                .first,
            matching: find.byType(Text),
          )
          .first,
    )
    .data!;

String _format(DateTime value) {
  String twoDigits(int value) => value.toString().padLeft(2, '0');
  return '${value.year}.${twoDigits(value.month)}.${twoDigits(value.day)} '
      '${twoDigits(value.hour)}:${twoDigits(value.minute)}';
}
