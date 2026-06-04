import 'package:fishing_build/app.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/repositories/fishing_record_memory_repository.dart';
import 'package:fishing_build/presentation/calendar/calendar_page.dart';
import 'package:fishing_build/presentation/record/record_detail_page.dart';
import 'package:fishing_build/presentation/shell/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FishingRecordMemoryRepository.instance.clearMemoryOnlyForTesting();
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
    final repository = FishingRecordMemoryRepository.instance;
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
      FishingRecord(
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
    final repository = FishingRecordMemoryRepository.instance;
    final startAt = DateTime(2026, 5, 21, 12);

    await repository.addRecord(
      FishingRecord(
        id: 'persisted-record-test',
        location: 'Test Port',
        startAt: startAt,
        endAt: startAt.add(const Duration(hours: 1)),
        genreName: 'PersistedGenre',
      ),
    );

    repository.clearMemoryOnlyForTesting();

    expect(repository.getAllRecords(), isEmpty);

    await repository.loadRecords();

    final records = repository.getAllRecords();
    expect(records, hasLength(1));
    expect(records.single.genreName, 'PersistedGenre');
  });

  test('updated records replace the saved record', () async {
    final repository = FishingRecordMemoryRepository.instance;
    final startAt = DateTime(2026, 5, 21, 12);

    await repository.addRecord(
      FishingRecord(
        id: 'updated-record-test',
        location: 'Old Port',
        startAt: startAt,
        endAt: startAt.add(const Duration(hours: 1)),
        genreName: '루어',
      ),
    );

    await repository.updateRecord(
      FishingRecord(
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
    final repository = FishingRecordMemoryRepository.instance;
    final startAt = DateTime(2026, 5, 21, 12);
    final record = FishingRecord(
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

  testWidgets('record search stays scrollable while the keyboard is visible', (
    WidgetTester tester,
  ) async {
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
