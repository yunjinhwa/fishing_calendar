import 'package:fishing_build/app.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/repositories/fishing_record_memory_repository.dart';
import 'package:fishing_build/presentation/calendar/calendar_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
    repository.clear();

    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      repository.clear();
    });

    await tester.pumpWidget(const MaterialApp(home: CalendarPage()));

    const genreName = 'AutoRefreshGenre';
    expect(find.text(genreName), findsNothing);

    final now = DateTime.now();
    final startAt = DateTime(now.year, now.month, 1, 12);
    repository.addRecord(
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
}
