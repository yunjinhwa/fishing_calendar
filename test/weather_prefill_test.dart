import 'package:fishing_build/data/models/external_data.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/presentation/record/record_form_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_database.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await resetTestDatabase();
    AuthSessionRepository.instance.clearMemoryOnlyForTesting();
    FishingRecordRepository.instance.clearCacheOnlyForTesting();
    await AuthSessionRepository.instance.setSessionForTesting(
      plan: UserPlan.free,
      email: 'weather-prefill@example.com',
    );
  });

  testWidgets('matching forecast fills only weather and air temperature', (
    tester,
  ) async {
    await _open(tester, _forecast());
    expect(_text(tester, '날씨 *'), '흐림');
    expect(_text(tester, '기온 *'), '-2.5');
    expect(_text(tester, '물때 *'), isEmpty);
    expect(_text(tester, '수온 *'), isEmpty);
    expect(find.textContaining('기상청 초단기예보'), findsOneWidget);
  });

  testWidgets('old forecasts and mismatched coordinates are never prefilled', (
    tester,
  ) async {
    await _open(tester, _forecast(hoursAgo: 24));
    expect(_text(tester, '날씨 *'), isEmpty);
    expect(_text(tester, '기온 *'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await _open(tester, _forecast(), longitude: 128);
    expect(_text(tester, '날씨 *'), isEmpty);
    expect(_text(tester, '기온 *'), isEmpty);
  });

  testWidgets('changing the place clears only automatically filled values', (
    tester,
  ) async {
    await _open(tester, _forecast());
    await tester.enterText(_field('날씨 *'), '직접 확인한 비');
    await tester.enterText(_field('물때 *'), '3물');
    await tester.enterText(_field('수온 *'), '15');
    await tester.enterText(_field('위치 *'), '다른 항구');
    await tester.pump();
    expect(_text(tester, '날씨 *'), '직접 확인한 비');
    expect(_text(tester, '기온 *'), isEmpty);
    expect(_text(tester, '물때 *'), '3물');
    expect(_text(tester, '수온 *'), '15');
  });

  testWidgets(
    'moving the start date clears the forecast but preserves manual input',
    (tester) async {
      await _open(tester, _forecast());
      await tester.enterText(_field('기온 *'), '12.3');
      final start = find
          .ancestor(of: find.text('시작 시간 *'), matching: find.byType(InkWell))
          .first;
      await tester.ensureVisible(start);
      await tester.tap(start);
      await tester.pumpAndSettle();
      Navigator.of(
        tester.element(find.byType(DatePickerDialog)),
      ).pop(DateTime.now().subtract(const Duration(days: 2)));
      await tester.pumpAndSettle();
      Navigator.of(
        tester.element(find.byType(TimePickerDialog)),
      ).pop(const TimeOfDay(hour: 12, minute: 0));
      await tester.pumpAndSettle();
      expect(_text(tester, '날씨 *'), isEmpty);
      expect(_text(tester, '기온 *'), '12.3');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('partial forecast leaves missing fields ready for manual input', (
    tester,
  ) async {
    final forecast = _forecast();
    await _open(
      tester,
      ExternalData(
        locationName: forecast.locationName,
        latitude: forecast.latitude,
        longitude: forecast.longitude,
        airTemperature: 0,
        gridX: forecast.gridX,
        gridY: forecast.gridY,
        issuedAt: forecast.issuedAt,
        validAt: forecast.validAt,
        fetchedAt: forecast.fetchedAt,
      ),
    );
    expect(_text(tester, '날씨 *'), isEmpty);
    expect(_text(tester, '기온 *'), '0.0');
    expect(_text(tester, '물때 *'), isEmpty);
    expect(_text(tester, '수온 *'), isEmpty);
    expect(tester.takeException(), isNull);
  });
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
    locationName: '날씨 테스트 항구',
    latitude: 35,
    longitude: 129,
    weather: '흐림',
    airTemperature: -2.5,
    gridX: 98,
    gridY: 74,
    issuedAt: hour.subtract(const Duration(minutes: 30)),
    validAt: hour,
    fetchedAt: now,
  );
}

Future<void> _open(
  WidgetTester tester,
  ExternalData forecast, {
  double longitude = 129,
}) async {
  tester.view.physicalSize = const Size(1000, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
  await tester.pumpWidget(
    MaterialApp(
      home: RecordFormPage(
        initialLocation: forecast.locationName,
        initialLatitude: forecast.latitude,
        initialLongitude: longitude,
        initialExternalData: forecast,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

String _text(WidgetTester tester, String label) =>
    tester.widget<TextField>(_field(label)).controller!.text;
