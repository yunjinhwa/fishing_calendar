import 'package:fishing_build/app.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/repositories/fishing_record_memory_repository.dart';
import 'package:fishing_build/presentation/calendar/calendar_page.dart';
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
}
