import 'package:fishing_build/data/maps/map_location.dart';
import 'package:fishing_build/data/models/external_data.dart';
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

final _location = MapLocation(name: '수온 테스트 항구', latitude: 35, longitude: 129);
const _station = WaterTemperatureStation(
  code: 'TEST',
  name: '테스트 관측소',
  latitude: 35.01,
  longitude: 129.01,
);

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await resetTestDatabase();
    AuthSessionRepository.instance.clearMemoryOnlyForTesting();
    FishingRecordRepository.instance.clearCacheOnlyForTesting();
    await AuthSessionRepository.instance.setSessionForTesting(
      plan: UserPlan.free,
      email: 'water-temperature-prefill@example.com',
    );
  });

  testWidgets('matching observation fills water temperature without weather', (
    tester,
  ) async {
    await _open(tester);
    expect(_text(tester, '수온 (선택)'), '16.2');
    expect(_text(tester, '날씨 *'), isEmpty);
    expect(_text(tester, '기온 *'), isEmpty);
    expect(_text(tester, '물때 (선택)'), isNotEmpty);
    expect(find.textContaining('테스트 관측소 · 관측'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unusable weather does not prevent water-temperature prefill', (
    tester,
  ) async {
    await _open(tester, weather: _forecast(hoursAgo: 24));
    expect(_text(tester, '수온 (선택)'), '16.2');
    expect(_text(tester, '날씨 *'), isEmpty);
    expect(_text(tester, '기온 *'), isEmpty);
  });

  for (final age in [const Duration(hours: 3), const Duration(minutes: -5)]) {
    testWidgets('observation with age $age is never prefilled', (tester) async {
      await _open(tester, observation: _observation(age: age));
      expect(_text(tester, '수온 (선택)'), isEmpty);
      expect(find.textContaining('테스트 관측소 · 관측'), findsNothing);
    });
  }

  testWidgets('mismatched names and coordinates are never prefilled', (
    tester,
  ) async {
    await _open(tester, name: '다른 항구');
    expect(_text(tester, '수온 (선택)'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await _open(tester, longitude: 128);
    expect(_text(tester, '수온 (선택)'), isEmpty);
  });

  testWidgets(
    'changing location clears water only and matching again reapplies',
    (tester) async {
      await _open(tester, weather: _forecast());
      await tester.enterText(_field('날씨 *'), '직접 확인한 비');
      await tester.enterText(_field('기온 *'), '20');
      await tester.enterText(_field('물때 (선택)'), '3물');
      await tester.enterText(_field('위치 *'), '다른 항구');
      await tester.pump();
      expect(_text(tester, '수온 (선택)'), isEmpty);
      expect(_text(tester, '날씨 *'), '직접 확인한 비');
      expect(_text(tester, '기온 *'), '20');
      expect(_text(tester, '물때 (선택)'), '3물');
      await tester.enterText(_field('위치 *'), _location.name);
      await tester.pump();
      expect(_text(tester, '수온 (선택)'), '16.2');
      expect(tester.takeException(), isNull);
    },
  );

  for (final coordinate in ['record-latitude', 'record-longitude']) {
    testWidgets(
      'changing $coordinate clears only automatic water temperature',
      (tester) async {
        await _open(tester);
        final field = find.byKey(ValueKey(coordinate));
        final original = tester.widget<TextField>(field).controller!.text;
        await tester.enterText(field, '34');
        await tester.pump();
        expect(_text(tester, '수온 (선택)'), isEmpty);
        await tester.enterText(field, original);
        await tester.pump();
        expect(_text(tester, '수온 (선택)'), '16.2');
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final offset in [
    const Duration(days: -2),
    const Duration(days: 2),
    const Duration(hours: 2),
    const Duration(minutes: -30),
  ]) {
    testWidgets('record start offset $offset clears automatic observation', (
      tester,
    ) async {
      await _open(tester);
      await _chooseStart(tester, DateTime.now().add(offset));
      expect(_text(tester, '수온 (선택)'), isEmpty);
      expect(find.textContaining('테스트 관측소 · 관측'), findsNothing);
      await _chooseStart(tester, DateTime.now());
      expect(_text(tester, '수온 (선택)'), '16.2');
      expect(tester.takeException(), isNull);
    });
  }

  for (final manual in ['21.4', '']) {
    testWidgets('manual value "$manual" survives location and time changes', (
      tester,
    ) async {
      await _open(tester);
      await tester.enterText(_field('수온 (선택)'), manual);
      await tester.enterText(_field('위치 *'), '다른 항구');
      await tester.enterText(_field('위치 *'), _location.name);
      await _chooseStart(tester, DateTime.now().add(const Duration(days: 2)));
      await _chooseStart(tester, DateTime.now());
      expect(_text(tester, '수온 (선택)'), manual);
      expect(find.textContaining('테스트 관측소 · 관측'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('explicit initial water temperature remains manual', (
    tester,
  ) async {
    await _open(tester, initialWaterTemperature: 12.4);
    expect(_text(tester, '수온 (선택)'), '12.4');
    await tester.enterText(_field('위치 *'), '다른 항구');
    await _chooseStart(
      tester,
      DateTime.now().subtract(const Duration(days: 2)),
    );
    expect(_text(tester, '수온 (선택)'), '12.4');
    expect(find.textContaining('테스트 관측소 · 관측'), findsNothing);
  });

  for (final temperature in [13.4, null]) {
    testWidgets('editing stored water temperature $temperature preserves it', (
      tester,
    ) async {
      final now = DateTime.now();
      final record = FishingRecord(
        id: 'water-temperature-edit',
        location: _location.name,
        latitude: _location.latitude,
        longitude: _location.longitude,
        startAt: now,
        endAt: now.add(const Duration(hours: 2)),
        genreName: '루어',
        tide: '3물',
        weather: '흐림',
        airTemperature: 20,
        waterTemperature: temperature,
      );
      await FishingRecordRepository.instance.addRecord(record);
      await _open(tester, editingRecord: record);
      expect(_text(tester, '수온 (선택)'), temperature?.toString() ?? '');
      await tester.enterText(_field('위치 *'), '다른 항구');
      await tester.enterText(_field('위치 *'), _location.name);
      await _chooseStart(tester, DateTime.now());
      expect(_text(tester, '수온 (선택)'), temperature?.toString() ?? '');
      expect(find.textContaining('테스트 관측소 · 관측'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('nonmarine form never automatically fills water temperature', (
    tester,
  ) async {
    await _open(tester, allowAutomaticWaterTemperature: false);
    expect(_text(tester, '수온 (선택)'), isEmpty);
    await tester.enterText(_field('위치 *'), '다른 항구');
    await tester.enterText(_field('위치 *'), _location.name);
    expect(_text(tester, '수온 (선택)'), isEmpty);
    await tester.enterText(_field('수온 (선택)'), '18.3');
    await _chooseStart(
      tester,
      DateTime.now().subtract(const Duration(days: 2)),
    );
    expect(_text(tester, '수온 (선택)'), '18.3');
  });

  testWidgets('deliberate clear saves optional observed water as null', (
    tester,
  ) async {
    await _open(tester, weather: _forecast());
    await tester.enterText(_field('수온 (선택)'), '');
    final genre = find.widgetWithText(ChoiceChip, '루어');
    await tester.ensureVisible(genre);
    await tester.tap(genre);
    final save = find.widgetWithText(FilledButton, '저장');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(
      FishingRecordRepository.instance.getAllRecords().single.waterTemperature,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });
}

WaterTemperatureObservation _observation({
  Duration age = const Duration(minutes: 10),
}) {
  final now = DateTime.now().toUtc();
  return WaterTemperatureObservation(
    location: _location,
    station: _station,
    temperatureCelsius: 16.2,
    observedAt: now.subtract(age),
    fetchedAt: now,
  );
}

ExternalData _forecast({int hoursAgo = 0}) {
  final now = DateTime.now().toUtc();
  final hour = DateTime.utc(
    now.year,
    now.month,
    now.day,
    now.hour,
  ).subtract(Duration(hours: hoursAgo));
  return ExternalData(
    locationName: _location.name,
    latitude: _location.latitude!,
    longitude: _location.longitude!,
    weather: '흐림',
    airTemperature: 20,
    gridX: 98,
    gridY: 74,
    issuedAt: hour.subtract(const Duration(minutes: 30)),
    validAt: hour,
    fetchedAt: now,
  );
}

Future<void> _open(
  WidgetTester tester, {
  WaterTemperatureObservation? observation,
  ExternalData? weather,
  String name = '수온 테스트 항구',
  double longitude = 129,
  double? initialWaterTemperature,
  bool allowAutomaticWaterTemperature = true,
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
        initialLocation: name,
        initialLatitude: _location.latitude,
        initialLongitude: longitude,
        initialExternalData: weather,
        initialWaterTemperature: initialWaterTemperature,
        initialWaterTemperatureObservation: observation ?? _observation(),
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

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

String _text(WidgetTester tester, String label) =>
    tester.widget<TextField>(_field(label)).controller!.text;
