import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/conflict_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/repositories/outbox_repository.dart';
import 'package:fishing_build/data/services/record_sync_service.dart';
import 'package:fishing_build/presentation/calendar/calendar_page.dart';
import 'package:fishing_build/presentation/calendar/daily_record_list_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_database.dart';

void main() {
  final records = FishingRecordRepository.instance;
  final sync = RecordSyncService.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await sync.resetForTesting();
    await resetTestDatabase();
    AuthSessionRepository.instance.clearMemoryOnlyForTesting();
    records.clearCacheOnlyForTesting();
    OutboxRepository.instance.clearCacheOnlyForTesting();
    ConflictRepository.instance.clearCacheOnlyForTesting();
    await AuthSessionRepository.instance.setSessionForTesting(
      plan: UserPlan.free,
      email: 'calendar-range@example.com',
    );
  });

  tearDown(() async {
    await sync.resetForTesting();
  });

  testWidgets('an overnight record connects the two date cells with one bar', (
    tester,
  ) async {
    final first = _sameWeekDate();
    final second = _nextDate(first);
    final record = _record('overnight', first, second);
    await records.addRecord(record);
    await _pumpCalendar(tester);

    final bar = _segment(record.id, _weekIndex(first));
    expect(bar, findsOneWidget);
    expect(_segments(record.id), findsOneWidget);
    final rect = tester.getRect(bar);
    final firstCenter = tester.getCenter(_day(first));
    final secondCenter = tester.getCenter(_day(second));
    expect(rect.left, lessThan(firstCenter.dx));
    expect(rect.right, greaterThan(secondCenter.dx));
    expect(find.text(record.summaryTitle), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'tapping each end of a bar opens that date rather than its start',
    (tester) async {
      final first = _sameWeekDate();
      final second = _nextDate(first);
      final record = _record('bar-hit-testing', first, second);
      await records.addRecord(record);
      await _pumpCalendar(tester);

      for (final date in <DateTime>[first, second]) {
        final barCenter = tester.getCenter(
          _segment(record.id, _weekIndex(first)),
        );
        final dayCenter = tester.getCenter(_day(date));
        await tester.tapAt(Offset(dayCenter.dx, barCenter.dy));
        await tester.pumpAndSettle();

        final page = tester.widget<DailyRecordListPage>(
          find.byType(DailyRecordListPage),
        );
        expect(page.selectedDate, date);
        expect(find.text(record.summaryTitle), findsOneWidget);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
      }

      expect(find.byType(CalendarPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a Saturday to Monday record continues on the next week row', (
    tester,
  ) async {
    final now = DateTime.now();
    var saturday = DateTime(now.year, now.month, 1);
    while (saturday.weekday != DateTime.saturday) {
      saturday = _nextDate(saturday);
    }
    final sunday = _nextDate(saturday);
    final monday = _nextDate(sunday);
    final record = _record('week-boundary', saturday, monday);
    await records.addRecord(record);
    await _pumpCalendar(tester);

    final firstBar = tester.getRect(_segment(record.id, _weekIndex(saturday)));
    final secondBar = tester.getRect(_segment(record.id, _weekIndex(monday)));
    expect(_segments(record.id), findsNWidgets(2));
    expect(firstBar.left, lessThan(tester.getCenter(_day(saturday)).dx));
    expect(firstBar.right, greaterThan(tester.getCenter(_day(sunday)).dx));
    expect(secondBar.left, lessThan(tester.getCenter(_day(monday)).dx));
    expect(secondBar.right, greaterThan(tester.getCenter(_day(monday)).dx));
    expect(secondBar.top, greaterThan(firstBar.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'overlapping ranges use separate lanes and more opens all records',
    (tester) async {
      final first = _sameWeekDate();
      final second = _nextDate(first);
      final entries = <FishingRecord>[
        for (final id in <String>['lane-a', 'lane-b', 'lane-c'])
          _record(id, first, second),
      ];
      for (final record in entries) {
        await records.addRecord(record);
      }
      await _pumpCalendar(tester);

      final firstBar = tester.getRect(
        _segment(entries[0].id, _weekIndex(first)),
      );
      final secondBar = tester.getRect(
        _segment(entries[1].id, _weekIndex(first)),
      );
      expect(firstBar.overlaps(secondBar), isFalse);
      expect(firstBar.center.dy, isNot(secondBar.center.dy));
      expect(_segments(entries[2].id), findsNothing);
      for (final date in <DateTime>[first, second]) {
        final overflow = _overflow(date);
        expect(overflow, findsOneWidget);
        expect(tester.widget<Text>(overflow).data, '+1');
      }

      await tester.tap(_overflow(second));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DailyRecordListPage>(find.byType(DailyRecordListPage))
            .selectedDate,
        second,
      );
      for (final record in entries) {
        expect(find.text(record.summaryTitle), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an end at midnight does not extend the bar into the next date', (
    tester,
  ) async {
    final first = _sameWeekDate();
    final second = _nextDate(first);
    final record = _record('midnight-end', first, second, endHour: 0);
    await records.addRecord(record);
    await _pumpCalendar(tester);

    final rect = tester.getRect(_segment(record.id, _weekIndex(first)));
    expect(rect.left, lessThan(tester.getCenter(_day(first)).dx));
    expect(rect.right, greaterThan(tester.getCenter(_day(first)).dx));
    expect(rect.right, lessThan(tester.getCenter(_day(second)).dx));
    await tester.tap(_day(second));
    await tester.pumpAndSettle();
    expect(find.byType(DailyRecordListPage), findsOneWidget);
    expect(find.text(record.summaryTitle), findsNothing);
    expect(find.text('저장된 출조 기록이 없습니다.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'month navigation clips a continuous record to each visible month',
    (tester) async {
      final now = DateTime.now();
      final last = DateTime(now.year, now.month + 1, 0);
      final firstNext = DateTime(now.year, now.month + 1, 1);
      final secondNext = _nextDate(firstNext);
      final record = _record('month-boundary', last, secondNext);
      await records.addRecord(record);
      await _pumpCalendar(tester);

      expect(_day(firstNext), findsNothing);
      final lastBar = tester.getRect(_segment(record.id, _weekIndex(last)));
      final lastCell = tester.getRect(_day(last));
      expect(lastBar.center.dx, closeTo(lastCell.center.dx, 1));
      expect(lastBar.width, lessThanOrEqualTo(lastCell.width));
      await tester.tap(find.widgetWithIcon(IconButton, Icons.chevron_right));
      await tester.pumpAndSettle();

      expect(_day(last), findsNothing);
      expect(_day(firstNext), findsOneWidget);
      expect(_day(secondNext), findsOneWidget);
      final expectedSegments = firstNext.weekday == DateTime.sunday ? 2 : 1;
      expect(_segments(record.id), findsNWidgets(expectedSegments));
      final firstBar = tester.getRect(
        _segment(record.id, _weekIndex(firstNext)),
      );
      expect(firstBar.left, lessThan(tester.getCenter(_day(firstNext)).dx));
      if (expectedSegments == 1) {
        expect(
          firstBar.right,
          greaterThan(tester.getCenter(_day(secondNext)).dx),
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'repository changes add, resize, and remove a range immediately',
    (tester) async {
      final first = _sameWeekDate();
      final second = _nextDate(first);
      const id = 'range-refresh';
      await _pumpCalendar(tester);
      expect(_segments(id), findsNothing);

      await records.addRecord(_record(id, first, second));
      await tester.pumpAndSettle();
      final bar = _segment(id, _weekIndex(first));
      final overnightWidth = tester.getSize(bar).width;
      expect(
        tester.getRect(bar).right,
        greaterThan(tester.getCenter(_day(second)).dx),
      );

      await records.updateRecord(_record(id, first, first, endHour: 21));
      await tester.pumpAndSettle();
      expect(tester.getSize(bar).width, lessThan(overnightWidth));
      expect(
        tester.getRect(bar).right,
        lessThan(tester.getCenter(_day(second)).dx),
      );

      await records.deleteRecord(id);
      await tester.pumpAndSettle();
      expect(_segments(id), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow screens and large text keep ranges and overflow tappable',
    (tester) async {
      final first = _sameWeekDate();
      final second = _nextDate(first);
      for (var index = 0; index < 3; index++) {
        await records.addRecord(
          _record(
            'narrow-$index',
            first,
            second,
            genre: '아주 긴 출조 기록 제목 $index',
          ),
        );
      }
      await _pumpCalendar(
        tester,
        size: const Size(320, 640),
        textScaler: const TextScaler.linear(2),
      );
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        _overflow(second),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.tap(_overflow(second));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DailyRecordListPage>(find.byType(DailyRecordListPage))
            .selectedDate,
        second,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pumpCalendar(
  WidgetTester tester, {
  Size size = const Size(800, 1600),
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  addTearDown(tester.view.reset);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
  });
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: child!,
      ),
      home: const CalendarPage(),
    ),
  );
  await tester.pumpAndSettle();
}

DateTime _sameWeekDate() {
  final now = DateTime.now();
  final day21 = DateTime(now.year, now.month, 21);
  return day21.weekday == DateTime.sunday
      ? DateTime(now.year, now.month, 20)
      : day21;
}

DateTime _nextDate(DateTime date) =>
    DateTime(date.year, date.month, date.day + 1);

int _weekIndex(DateTime date) =>
    (DateTime(date.year, date.month, 1).weekday - 1 + date.day - 1) ~/ 7;

String _dateKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

Finder _day(DateTime date) =>
    find.byKey(ValueKey('calendar-day-${_dateKey(date)}'));

Finder _overflow(DateTime date) =>
    find.byKey(ValueKey('calendar-overflow-${_dateKey(date)}'));

Finder _segment(String recordId, int weekIndex) =>
    find.byKey(ValueKey('calendar-range-$recordId-$weekIndex'));

Finder _segments(String recordId) => find.byWidgetPredicate((widget) {
  final key = widget.key;
  return key is ValueKey<String> &&
      key.value.startsWith('calendar-range-$recordId-');
});

FishingRecord _record(
  String id,
  DateTime startDate,
  DateTime endDate, {
  int endHour = 3,
  String? genre,
}) => FishingRecord(
  id: id,
  location: 'Range test harbor',
  startAt: DateTime(startDate.year, startDate.month, startDate.day, 18),
  endAt: DateTime(endDate.year, endDate.month, endDate.day, endHour),
  genreName: genre ?? 'Range $id',
  tide: '3물',
  weather: '맑음',
  airTemperature: 24,
  waterTemperature: 20,
);
