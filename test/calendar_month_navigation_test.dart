import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/conflict_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/repositories/outbox_repository.dart';
import 'package:fishing_build/data/services/network_status_service.dart';
import 'package:fishing_build/data/services/paid_record_cache_service.dart';
import 'package:fishing_build/data/services/record_sync_service.dart';
import 'package:fishing_build/presentation/calendar/calendar_page.dart';
import 'package:fishing_build/presentation/calendar/daily_record_list_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_database.dart';

void main() {
  final auth = AuthSessionRepository.instance;
  final records = FishingRecordRepository.instance;
  final sync = RecordSyncService.instance;
  final cache = PaidRecordCacheService.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await cache.resetForTesting();
    await sync.resetForTesting();
    await NetworkStatusService.instance.resetForTesting();
    await resetTestDatabase();
    auth.resetAuthGatewayForTesting();
    records.clearCacheOnlyForTesting();
    OutboxRepository.instance.clearCacheOnlyForTesting();
    ConflictRepository.instance.clearCacheOnlyForTesting();
    await auth.setSessionForTesting(
      plan: UserPlan.free,
      email: 'month-navigation@example.com',
    );
  });

  tearDown(() async {
    await cache.resetForTesting();
    await sync.resetForTesting();
  });

  testWidgets(
    'swipes cross a year once and arrows and today remain available',
    (tester) async {
      await _open(tester, month: DateTime(2026, 12, 31));
      _expectMonth(2026, 12);
      await tester.drag(_grid, const Offset(-240, 0));
      await tester.pumpAndSettle();
      _expectMonth(2027, 1);
      expect(find.byType(DailyRecordListPage), findsNothing);
      await tester.drag(_grid, const Offset(240, 0));
      await tester.pumpAndSettle();
      _expectMonth(2026, 12);
      await tester.tap(find.byTooltip('이전 달'));
      await tester.pumpAndSettle();
      _expectMonth(2026, 11);
      await tester.tap(find.byTooltip('다음 달'));
      await tester.pumpAndSettle();
      _expectMonth(2026, 12);
      await tester.tap(find.byTooltip('이번 달로 이동'));
      await tester.pumpAndSettle();
      final today = DateTime.now();
      _expectMonth(today.year, today.month);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('short drags and vertical scrolling do not change the month', (
    tester,
  ) async {
    await _open(tester, month: DateTime(2026, 11), size: const Size(360, 640));
    await tester.drag(_grid, const Offset(30, 0));
    await tester.pumpAndSettle();
    _expectMonth(2026, 11);
    expect(find.byType(DailyRecordListPage), findsNothing);

    Finder scrollable() =>
        find.descendant(of: _grid, matching: find.byType(Scrollable)).first;
    await tester.drag(_grid, const Offset(0, -180));
    await tester.pumpAndSettle();
    _expectMonth(2026, 11);
    expect(
      tester.state<ScrollableState>(scrollable()).position.pixels,
      greaterThan(0),
    );
    await tester.drag(_grid, const Offset(-200, 0));
    await tester.pumpAndSettle();
    _expectMonth(2026, 12);
    expect(tester.state<ScrollableState>(scrollable()).position.pixels, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'swiping a range bar changes month while tapping still opens each date',
    (tester) async {
      final record = FishingRecord(
        id: 'month-swipe-overnight',
        location: 'Harbor',
        genreName: '루어',
        startAt: DateTime(2026, 11, 21, 18),
        endAt: DateTime(2026, 11, 22, 3),
      );
      await records.addRecord(record);
      await _open(tester, month: DateTime(2026, 11));
      final bar = find.byKey(
        const ValueKey('calendar-range-month-swipe-overnight-3'),
      );
      await tester.dragFrom(tester.getCenter(bar), const Offset(-240, 0));
      await tester.pumpAndSettle();
      _expectMonth(2026, 12);
      expect(find.byType(DailyRecordListPage), findsNothing);
      await tester.drag(_grid, const Offset(240, 0));
      await tester.pumpAndSettle();

      for (final day in [21, 22]) {
        final dayCell = find.byKey(ValueKey('calendar-day-2026-11-$day'));
        await tester.tapAt(
          Offset(tester.getCenter(dayCell).dx, tester.getCenter(bar).dy),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<DailyRecordListPage>(find.byType(DailyRecordListPage))
              .selectedDate,
          DateTime(2026, 11, day),
        );
        expect(find.text(record.summaryTitle), findsOneWidget);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'month selection supports boundaries and prevents moving outside them',
    (tester) async {
      await _open(tester, month: DateTime(1));
      _expectMonth(1, 1);
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.chevron_left),
            )
            .onPressed,
        isNull,
      );
      await tester.drag(_grid, const Offset(240, 0));
      await tester.pumpAndSettle();
      _expectMonth(1, 1);

      await _choose(tester, year: 9999, month: 12);
      _expectMonth(9999, 12);
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.chevron_right),
            )
            .onPressed,
        isNull,
      );
      await tester.drag(_grid, const Offset(-240, 0));
      await tester.pumpAndSettle();
      _expectMonth(9999, 12);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cancelled selection keeps the visible month', (tester) async {
    await _open(tester, month: DateTime(2026, 11));
    await _openPicker(tester);
    await tester.enterText(
      find.byKey(const ValueKey('calendar-picker-year')),
      '2001',
    );
    await tester.tap(find.byKey(const ValueKey('calendar-picker-month-2')));
    await tester.tap(find.byKey(const ValueKey('calendar-picker-cancel')));
    await tester.pumpAndSettle();
    _expectMonth(2026, 11);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an account change while choosing a month cannot apply the old selection',
    (tester) async {
      await _open(tester, month: DateTime(2026, 11));
      await _openPicker(tester);
      await tester.enterText(
        find.byKey(const ValueKey('calendar-picker-year')),
        '2020',
      );
      await auth.setSessionForTesting(
        plan: UserPlan.free,
        email: 'another-month-owner@example.com',
      );
      await tester.tap(find.byKey(const ValueKey('calendar-picker-confirm')));
      await tester.pumpAndSettle();
      _expectMonth(2026, 11);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('narrow calendar header and picker support large text', (
    tester,
  ) async {
    await _open(
      tester,
      month: DateTime(2026, 11),
      size: const Size(320, 640),
      textScale: 2,
    );
    expect(
      find.byKey(const ValueKey('calendar-month-picker')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await _openPicker(tester);
    expect(find.text('연·월 선택'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('calendar-picker-cancel')));
    await tester.pumpAndSettle();
    _expectMonth(2026, 11);
  });
}

Finder get _grid => find.byKey(const ValueKey('calendar-month-grid'));

void _expectMonth(int year, int month) {
  expect(find.text('$year년 $month월'), findsOneWidget);
  expect(find.byKey(ValueKey('calendar-grid-$year-$month')), findsOneWidget);
}

Future<void> _open(
  WidgetTester tester, {
  required DateTime month,
  Size size = const Size(1000, 2200),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: CalendarPage(initialMonth: month),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openPicker(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('calendar-month-picker')));
  await tester.pumpAndSettle();
}

Future<void> _choose(
  WidgetTester tester, {
  required int year,
  required int month,
}) async {
  await _openPicker(tester);
  await tester.enterText(
    find.byKey(const ValueKey('calendar-picker-year')),
    '$year',
  );
  final target = find.byKey(ValueKey('calendar-picker-month-$month'));
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.tap(find.byKey(const ValueKey('calendar-picker-confirm')));
  await tester.pumpAndSettle();
}
