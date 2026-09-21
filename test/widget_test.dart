import 'package:fishing_build/app.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/presentation/calendar/calendar_page.dart';
import 'package:fishing_build/presentation/record/record_detail_page.dart';
import 'package:fishing_build/presentation/record/record_form_page.dart';
import 'package:fishing_build/presentation/shell/app_shell.dart';
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
  });

  testWidgets('app starts on the login choice page', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const FishingBuildApp());

    expect(find.byIcon(Icons.phishing), findsOneWidget);
  });

  testWidgets('calendar refreshes when records change', (
    WidgetTester tester,
  ) async {
    final repository = FishingRecordRepository.instance;
    await repository.clear();

    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await repository.clear();
    });

    await tester.pumpWidget(const MaterialApp(home: CalendarPage()));

    const genreName = 'AutoRefreshGenre';
    expect(find.text(genreName), findsNothing);

    final now = DateTime.now();
    final startAt = DateTime(now.year, now.month, 1, 12);
    await repository.addRecord(
      _createRecord(
        id: 'calendar-refresh-test',
        location: 'Test Port',
        startAt: startAt,
        endAt: startAt.add(const Duration(hours: 1)),
        genreName: genreName,
      ),
    );

    await tester.pump();

    expect(find.text(genreName), findsOneWidget);
  });

  testWidgets('calendar returns to the current month', (
    WidgetTester tester,
  ) async {
    final today = DateTime.now();
    final previousMonth = DateTime(today.year, today.month - 1);

    await tester.pumpWidget(const MaterialApp(home: CalendarPage()));

    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pump();

    expect(
      find.text('${previousMonth.year}년 ${previousMonth.month}월'),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('이번 달로 이동'));
    await tester.pump();

    expect(find.text('${today.year}년 ${today.month}월'), findsOneWidget);
  });

  testWidgets('saved records reload from local storage', (
    WidgetTester tester,
  ) async {
    final repository = FishingRecordRepository.instance;
    final startAt = DateTime(2026, 5, 21, 12);

    await repository.addRecord(
      _createRecord(
        id: 'persisted-record-test',
        location: 'Test Port',
        startAt: startAt,
        endAt: startAt.add(const Duration(hours: 1)),
        genreName: 'PersistedGenre',
      ),
    );

    repository.clearCacheOnlyForTesting();

    expect(repository.getAllRecords(), isEmpty);

    await repository.loadRecords();

    final records = repository.getAllRecords();
    expect(records, hasLength(1));
    expect(records.single.genreName, 'PersistedGenre');
  });

  test('updated records replace the saved record', () async {
    final repository = FishingRecordRepository.instance;
    final startAt = DateTime(2026, 5, 21, 12);

    await repository.addRecord(
      _createRecord(
        id: 'updated-record-test',
        location: 'Old Port',
        startAt: startAt,
        endAt: startAt.add(const Duration(hours: 1)),
        genreName: '루어',
      ),
    );

    await repository.updateRecord(
      _createRecord(
        id: 'updated-record-test',
        location: 'New Port',
        startAt: startAt,
        endAt: startAt.add(const Duration(hours: 2)),
        genreName: '선상',
      ),
    );

    final records = repository.getAllRecords();
    expect(records, hasLength(1));
    expect(records.single.location, 'New Port');
    expect(records.single.genreName, '선상');
  });

  testWidgets('record detail edit button updates the saved record', (
    WidgetTester tester,
  ) async {
    await AuthSessionRepository.instance.setSessionForTesting(
      plan: UserPlan.free,
      email: 'tester@example.com',
    );

    final repository = FishingRecordRepository.instance;
    final startAt = DateTime(2026, 5, 21, 12);
    final record = _createRecord(
      id: 'detail-edit-test',
      location: 'Old Port',
      startAt: startAt,
      endAt: startAt.add(const Duration(hours: 1)),
      genreName: '루어',
    );

    await repository.addRecord(record);
    await tester.pumpWidget(
      MaterialApp(home: RecordDetailPage(record: record)),
    );

    await tester.tap(find.byTooltip('수정'));
    await tester.pumpAndSettle();

    expect(find.text('출조 기록 수정'), findsOneWidget);

    final locationField = tester.widget<TextField>(
      find.byType(TextField).first,
    );
    expect(locationField.controller?.text, 'Old Port');

    await tester.enterText(find.byType(TextField).first, 'New Port');

    final saveButton = find.widgetWithText(FilledButton, '저장');
    await tester.scrollUntilVisible(
      saveButton,
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    final records = repository.getAllRecords();
    expect(records, hasLength(1));
    expect(records.single.id, 'detail-edit-test');
    expect(records.single.location, 'New Port');
    expect(find.text('New Port'), findsOneWidget);
  });

  testWidgets('guest is prompted to log in when opening member tabs', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const FishingBuildApp());
    await tester.tap(find.text('비회원으로 시작하기'));
    await tester.pumpAndSettle();

    expect(find.text('지도'), findsWidgets);

    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();

    expect(find.text('로그인이 필요합니다'), findsOneWidget);
    expect(find.text('출조 기록과 내 정보 관리는 로그인 후 사용할 수 있습니다.'), findsOneWidget);
  });

  testWidgets('record form requires external data before saving', (
    WidgetTester tester,
  ) async {
    await AuthSessionRepository.instance.setSessionForTesting(
      plan: UserPlan.free,
      email: 'tester@example.com',
    );

    await tester.pumpWidget(const MaterialApp(home: RecordFormPage()));

    await tester.enterText(find.byType(TextField).first, 'Test Port');
    await tester.tap(find.text('루어'));
    await tester.pump();

    final saveButton = find.widgetWithText(FilledButton, '저장');
    await tester.scrollUntilVisible(
      saveButton,
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(saveButton);
    await tester.pump();

    expect(find.text('물때를 입력하세요.'), findsOneWidget);
    expect(FishingRecordRepository.instance.getAllRecords(), isEmpty);
  });

  testWidgets('record search stays scrollable while the keyboard is visible', (
    WidgetTester tester,
  ) async {
    await AuthSessionRepository.instance.setSessionForTesting(
      plan: UserPlan.free,
      email: 'tester@example.com',
    );

    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(390, 640);
    tester.view.devicePixelRatio = 1;

    await tester.pumpWidget(const MaterialApp(home: AppShell()));
    await tester.tap(find.text('기록'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField).first);

    tester.view.viewInsets = const FakeViewPadding(bottom: 360);
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

FishingRecord _createRecord({
  required String id,
  required String location,
  required DateTime startAt,
  required DateTime endAt,
  required String genreName,
}) {
  return FishingRecord(
    id: id,
    location: location,
    startAt: startAt,
    endAt: endAt,
    genreName: genreName,
    tide: '7물',
    weather: '맑음',
    airTemperature: 18,
    waterTemperature: 16.2,
  );
}
