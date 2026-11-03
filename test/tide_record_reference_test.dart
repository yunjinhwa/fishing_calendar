import 'package:fishing_build/data/maps/map_location.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/tides/tide_models.dart';
import 'package:fishing_build/presentation/map/tide_data_card.dart';
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
      email: 'tide-reference@example.com',
    );
  });

  testWidgets('tide name is calculated separately from high and low events', (
    tester,
  ) async {
    await _open(tester, _reference(day: TideDay(2026, 11, 2)));
    await _pickDateTime(tester, '시작 시간 *', DateTime(2026, 11, 2));
    expect(find.byType(TideDataCard), findsOneWidget);
    expect(find.text('간조'), findsOneWidget);
    expect(find.text('03:00'), findsOneWidget);
    expect(find.text('-12.5 cm'), findsOneWidget);
    expect(find.text('만조'), findsOneWidget);
    expect(find.text('09:00'), findsOneWidget);
    expect(find.text('483 cm'), findsOneWidget);
    expect(_text(tester, '물때 *'), '조금');
    expect(_text(tester, '수온 *'), isEmpty);
  });

  testWidgets(
    'changing the date refreshes the automatic name without old events',
    (tester) async {
      await _open(tester, _reference(day: TideDay(2026, 11, 2)));
      await _pickDateTime(tester, '시작 시간 *', DateTime(2026, 11, 2));
      expect(_text(tester, '물때 *'), '조금');

      await _pickDateTime(tester, '시작 시간 *', DateTime(2026, 11, 3));

      expect(_text(tester, '물때 *'), '무시');
      expect(find.byType(TideDataCard), findsNothing);
      expect(find.text('간조'), findsNothing);
      expect(find.text('03:00'), findsNothing);
      expect(find.text('-12.5 cm'), findsNothing);
      expect(find.text('만조'), findsNothing);
      expect(find.text('09:00'), findsNothing);
      expect(find.text('483 cm'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a changed place hides the reference and preserves manual fields',
    (tester) async {
      await _open(tester, _reference());
      await tester.enterText(_field('물때 *'), '7물');
      await tester.enterText(_field('수온 *'), '16.5');
      await tester.enterText(_field('위치 *'), '다른 출조 장소');
      await tester.pump();
      expect(find.byType(TideDataCard), findsNothing);
      expect(_text(tester, '물때 *'), '7물');
      expect(_text(tester, '수온 *'), '16.5');
    },
  );

  testWidgets(
    'a changed start date hides the old forecast and preserves a manual name',
    (tester) async {
      await _open(tester, _reference(day: TideDay(2026, 11, 2)));
      await _pickDateTime(tester, '시작 시간 *', DateTime(2026, 11, 2));
      await tester.enterText(_field('물때 *'), '직접 확인한 7물');
      await _pickDateTime(tester, '시작 시간 *', DateTime(2026, 11, 3));
      expect(find.byType(TideDataCard), findsNothing);
      expect(_text(tester, '물때 *'), '직접 확인한 7물');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a manually cleared tide stays empty when the date changes', (
    tester,
  ) async {
    await _open(tester, _reference(day: TideDay(2026, 11, 2)));
    await _pickDateTime(tester, '시작 시간 *', DateTime(2026, 11, 2));
    expect(_text(tester, '물때 *'), '조금');
    await tester.enterText(_field('물때 *'), '');

    await _pickDateTime(tester, '시작 시간 *', DateTime(2026, 11, 3));

    expect(_text(tester, '물때 *'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'invalid coordinates clear automatic tide and retain manual tide',
    (tester) async {
      await _open(tester, _reference(day: TideDay(2026, 11, 2)));
      await _pickDateTime(tester, '시작 시간 *', DateTime(2026, 11, 2));
      expect(_text(tester, '물때 *'), '조금');

      await tester.ensureVisible(_field('위도'));
      await tester.enterText(_field('위도'), '91');
      await tester.pump();
      expect(_text(tester, '물때 *'), isEmpty);
      expect(find.byType(TideDataCard), findsNothing);

      await tester.enterText(_field('위도'), '35.9756');
      await tester.pump();
      expect(_text(tester, '물때 *'), '조금');
      await tester.enterText(_field('물때 *'), '7물');
      await tester.ensureVisible(_field('위도'));
      await tester.enterText(_field('위도'), '91');
      await tester.pump();
      expect(_text(tester, '물때 *'), '7물');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'coordinates calculate a tide without an API forecast reference',
    (tester) async {
      await _open(tester, null);
      await _pickDateTime(tester, '시작 시간 *', DateTime(2026, 11, 2));

      expect(_text(tester, '물때 *'), '조금');
      expect(find.byType(TideDataCard), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'freshwater scope keeps known coordinates manual without reference',
    (tester) async {
      await _open(
        tester,
        _reference(day: TideDay(2026, 11, 2)),
        allowAutomaticTide: false,
      );
      await _pickDateTime(tester, '시작 시간 *', DateTime(2026, 11, 2));

      expect(_text(tester, '위도'), '35.9756');
      expect(_text(tester, '경도'), '126.5631');
      expect(_text(tester, '물때 *'), isEmpty);
      expect(find.byType(TideDataCard), findsNothing);
      expect(find.text('03:00'), findsNothing);
      expect(find.text('09:00'), findsNothing);

      await tester.enterText(_field('물때 *'), '직접 확인한 7물');
      await _pickDateTime(tester, '시작 시간 *', DateTime(2026, 11, 3));

      expect(_text(tester, '물때 *'), '직접 확인한 7물');
      expect(find.byType(TideDataCard), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an initial tide remains unchanged after automatic date refresh',
    (tester) async {
      await _open(
        tester,
        _reference(day: TideDay(2026, 11, 2)),
        initialTide: '기존 입력 5물',
      );
      expect(_text(tester, '물때 *'), '기존 입력 5물');
      await _pickDateTime(tester, '시작 시간 *', DateTime(2026, 11, 2));
      await _pickDateTime(tester, '시작 시간 *', DateTime(2026, 11, 3));

      expect(_text(tester, '물때 *'), '기존 입력 5물');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('saving persists the automatic tide name', (tester) async {
    await _open(tester, null);
    await _pickDateTime(tester, '시작 시간 *', DateTime(2026, 11, 2));
    await _pickDateTime(tester, '종료 시간 *', DateTime(2026, 11, 2), hour: 14);
    expect(_text(tester, '물때 *'), '조금');
    await tester.enterText(_field('날씨 *'), '흐림');
    await tester.enterText(_field('기온 *'), '11');
    await tester.enterText(_field('수온 *'), '16.5');
    final genre = find.widgetWithText(ChoiceChip, '루어');
    await tester.ensureVisible(genre);
    await tester.tap(genre);
    final save = find.widgetWithText(FilledButton, '저장');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    final saved = FishingRecordRepository.instance.getAllRecords().single;
    expect(saved.tide, '조금');
    expect(saved.latitude, 35.9756);
    expect(saved.longitude, 126.5631);
    expect(tester.takeException(), isNull);
  });

  testWidgets('saving keeps the user tide name rather than the event summary', (
    tester,
  ) async {
    await _open(tester, _reference());
    await tester.enterText(_field('물때 *'), '7물');
    await tester.enterText(_field('날씨 *'), '흐림');
    await tester.enterText(_field('기온 *'), '11');
    await tester.enterText(_field('수온 *'), '16.5');
    final genre = find.widgetWithText(ChoiceChip, '루어');
    await tester.ensureVisible(genre);
    await tester.tap(genre);
    final save = find.widgetWithText(FilledButton, '저장');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    final saved = FishingRecordRepository.instance.getAllRecords().single;
    expect(saved.tide, '7물');
    expect(saved.waterTemperature, 16.5);
    expect(tester.takeException(), isNull);
  });
}

TideRecordReference _reference({TideDay? day}) {
  final forecastDay = day ?? TideDay.fromInstant(DateTime.now());
  DateTime at(int hour) => DateTime.utc(
    forecastDay.year,
    forecastDay.month,
    forecastDay.day,
    hour,
  ).subtract(const Duration(hours: 9));
  return TideRecordReference(
    location: MapLocation(
      name: '조석 테스트 항구',
      latitude: 35.9756,
      longitude: 126.5631,
    ),
    forecast: TideForecast(
      station: const TideStation(
        code: 'DT_0018',
        name: '군산',
        latitude: 35.97555,
        longitude: 126.56305,
      ),
      day: forecastDay,
      events: [
        TideEvent(at: at(3), heightCm: -12.5, kind: TideEventKind.low),
        TideEvent(at: at(9), heightCm: 483, kind: TideEventKind.high),
      ],
      fetchedAt: DateTime.now().toUtc(),
    ),
  );
}

Future<void> _open(
  WidgetTester tester,
  TideRecordReference? reference, {
  String? initialTide,
  bool allowAutomaticTide = true,
}) async {
  tester.view.physicalSize = const Size(1000, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
  await tester.pumpWidget(
    MaterialApp(
      home: RecordFormPage(
        initialLocation: reference?.location.name ?? '조석 테스트 항구',
        initialLatitude: reference?.location.latitude ?? 35.9756,
        initialLongitude: reference?.location.longitude ?? 126.5631,
        initialTide: initialTide,
        initialTideReference: reference,
        allowAutomaticTide: allowAutomaticTide,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pickDateTime(
  WidgetTester tester,
  String label,
  DateTime date, {
  int hour = 12,
}) async {
  final field = find
      .ancestor(of: find.text(label), matching: find.byType(InkWell))
      .first;
  await tester.ensureVisible(field);
  await tester.tap(field);
  await tester.pumpAndSettle();
  Navigator.of(tester.element(find.byType(DatePickerDialog))).pop(date);
  await tester.pumpAndSettle();
  Navigator.of(
    tester.element(find.byType(TimePickerDialog)),
  ).pop(TimeOfDay(hour: hour, minute: 0));
  await tester.pumpAndSettle();
}

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);
String _text(WidgetTester tester, String label) =>
    tester.widget<TextField>(_field(label)).controller!.text;
