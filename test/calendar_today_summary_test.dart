import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/services/network_status_service.dart';
import 'package:fishing_build/data/services/paid_record_cache_service.dart';
import 'package:fishing_build/data/services/record_sync_service.dart';
import 'package:fishing_build/presentation/calendar/calendar_page.dart';
import 'package:fishing_build/presentation/calendar/calendar_today_summary.dart';
import 'package:fishing_build/presentation/calendar/daily_record_list_page.dart';
import 'package:fishing_build/presentation/record/record_form_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_database.dart';

void main() {
  final auth = AuthSessionRepository.instance;
  final records = FishingRecordRepository.instance;
  late DateTime clock;
  late DateTime Function() now;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PaidRecordCacheService.instance.resetForTesting();
    await RecordSyncService.instance.resetForTesting();
    await NetworkStatusService.instance.resetForTesting();
    await resetTestDatabase();
    auth.resetAuthGatewayForTesting();
    records.clearCacheOnlyForTesting();
    await auth.setSessionForTesting(
      plan: UserPlan.free,
      email: 'today@example.com',
    );
    clock = DateTime(2026, 12, 1, 12);
    now = () => clock;
  });

  tearDown(() async {
    await PaidRecordCacheService.instance.resetForTesting();
    await RecordSyncService.instance.resetForTesting();
  });

  Future<void> open(
    WidgetTester tester, {
    bool active = true,
    Size size = const Size(800, 1000),
    double scale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: CalendarPage(
          initialMonth: DateTime(2021, 4),
          now: now,
          isActive: active,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openSummary(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('calendar-today-open')));
    await tester.pumpAndSettle();
  }

  Future<void> back(WidgetTester tester) async {
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'calendar shows only the button and details list all today records in order',
    (tester) async {
      final today = _record(
        'Day port',
        DateTime(2026, 12, 1, 8),
        DateTime(2026, 12, 1, 11),
      );
      final overnight = _record(
        'Night port',
        DateTime(2026, 11, 30, 18),
        DateTime(2026, 12, 1, 3),
      );
      final afternoon = _record(
        'Afternoon port',
        DateTime(2026, 12, 1, 14),
        DateTime(2026, 12, 1, 17),
      );
      for (final record in [
        today,
        _record(
          'Ended at midnight',
          DateTime(2026, 11, 30, 18),
          DateTime(2026, 12, 1),
        ),
        _record(
          'Starts tomorrow',
          DateTime(2026, 12, 2),
          DateTime(2026, 12, 2, 3),
        ),
        afternoon,
        overnight,
      ]) {
        await records.addRecord(record);
      }
      await open(tester);
      expect(find.text('2021년 4월'), findsOneWidget);
      expect(find.byType(CalendarTodaySummary), findsOneWidget);
      expect(find.text('12월 1일 · 출조 3건'), findsNothing);
      expect(find.textContaining('Day port'), findsNothing);
      expect(find.textContaining('Night port'), findsNothing);
      await openSummary(tester);
      expect(find.text('오늘의 요약'), findsOneWidget);
      expect(find.text('12월 1일 · 출조 3건'), findsOneWidget);
      expect(find.textContaining('Night port'), findsOneWidget);
      expect(find.textContaining('11.30 18:00 ~ 12.01 03:00'), findsOneWidget);
      expect(find.textContaining('08:00 ~ 11:00'), findsOneWidget);
      expect(find.textContaining('Afternoon port'), findsOneWidget);
      expect(
        tester.getTopLeft(find.textContaining('Night port')).dy,
        lessThan(tester.getTopLeft(find.textContaining('Day port')).dy),
      );
      expect(
        tester.getTopLeft(find.textContaining('Day port')).dy,
        lessThan(tester.getTopLeft(find.textContaining('Afternoon port')).dy),
      );
      expect(find.textContaining('Ended at midnight'), findsNothing);
      expect(find.textContaining('Starts tomorrow'), findsNothing);

      await back(tester);
      await tester.tap(find.byTooltip('다음 달'));
      await tester.pumpAndSettle();
      expect(find.text('2021년 5월'), findsOneWidget);
      expect(find.text('12월 1일 · 출조 3건'), findsNothing);
      await openSummary(tester);
      expect(find.text('12월 1일 · 출조 3건'), findsOneWidget);
    },
  );

  testWidgets(
    'add, move, edit and delete immediately refresh summary details',
    (tester) async {
      await open(tester);
      await openSummary(tester);
      expect(find.text('12월 1일 · 출조 0건'), findsOneWidget);
      final record = _record(
        'Original port',
        DateTime(2026, 12, 1, 8),
        DateTime(2026, 12, 1, 11),
      );
      await records.addRecord(record);
      await tester.pump();
      expect(find.text('12월 1일 · 출조 1건'), findsOneWidget);
      expect(find.textContaining('Original port'), findsOneWidget);
      await records.updateRecord(
        _record(
          'Moved port',
          DateTime(2026, 12, 2, 8),
          DateTime(2026, 12, 2, 11),
          id: record.id,
        ),
      );
      await tester.pump();
      expect(find.text('12월 1일 · 출조 0건'), findsOneWidget);
      expect(find.textContaining('Moved port'), findsNothing);
      await records.updateRecord(
        _record(
          'Edited port',
          DateTime(2026, 12, 1, 9),
          DateTime(2026, 12, 1, 13),
          id: record.id,
        ),
      );
      await tester.pump();
      expect(find.textContaining('Edited port'), findsOneWidget);
      expect(find.textContaining('09:00 ~ 13:00'), findsOneWidget);
      await records.deleteRecord(record.id);
      await tester.pump();
      expect(find.text('12월 1일 · 출조 0건'), findsOneWidget);
      expect(find.textContaining('Edited port'), findsNothing);
    },
  );

  testWidgets(
    'summary opens today once and preserves the selected month after return',
    (tester) async {
      final record = _record(
        'Today port',
        DateTime(2026, 12, 1, 8),
        DateTime(2026, 12, 1, 11),
      );
      await records.addRecord(record);
      await open(tester);
      final onOpen = tester
          .widget<CalendarTodaySummary>(find.byType(CalendarTodaySummary))
          .onPressed!;
      onOpen();
      onOpen();
      await tester.pumpAndSettle();
      expect(find.byType(DailyRecordListPage), findsOneWidget);
      final details = tester.widget<DailyRecordListPage>(
        find.byType(DailyRecordListPage),
      );
      expect(details.selectedDate, DateTime(2026, 12, 1));
      expect(details.isTodaySummary, isTrue);
      expect(find.textContaining('Today port'), findsOneWidget);
      await records.deleteRecord(record.id);
      await tester.pump();
      expect(find.text('12월 1일 · 출조 0건'), findsOneWidget);
      await back(tester);
      expect(find.text('2021년 4월'), findsOneWidget);
      expect(find.byType(DailyRecordListPage), findsNothing);
      expect(find.text('12월 1일 · 출조 0건'), findsNothing);
      await openSummary(tester);
      expect(find.text('12월 1일 · 출조 0건'), findsOneWidget);
    },
  );

  testWidgets(
    'empty summary details start a draft at the current date and time',
    (tester) async {
      await open(tester);
      expect(find.byKey(const ValueKey('calendar-today-create')), findsNothing);
      await openSummary(tester);
      await tester.tap(find.byKey(const ValueKey('calendar-today-create')));
      await tester.pumpAndSettle();
      expect(find.byType(RecordFormPage), findsOneWidget);
      expect(
        tester
            .widget<RecordFormPage>(find.byType(RecordFormPage))
            .initialStartAt,
        clock,
      );
      expect(find.byType(DailyRecordListPage), findsNothing);
      await back(tester);
      expect(find.byType(DailyRecordListPage), findsOneWidget);
      expect(find.text('12월 1일 · 출조 0건'), findsOneWidget);
      await back(tester);
      expect(find.text('2021년 4월'), findsOneWidget);
    },
  );

  testWidgets(
    'midnight updates open summary details without changing the visible month',
    (tester) async {
      clock = DateTime(2026, 12, 31, 23, 59, 50);
      await records.addRecord(
        _record(
          'Year night',
          DateTime(2026, 12, 31, 18),
          DateTime(2027, 1, 1, 3),
        ),
      );
      await records.addRecord(
        _record(
          'Ended last year',
          DateTime(2026, 12, 31, 8),
          DateTime(2027, 1, 1),
        ),
      );
      await open(tester);
      await openSummary(tester);
      expect(find.text('12월 31일 · 출조 2건'), findsOneWidget);
      clock = DateTime(2027, 1, 1);
      await tester.pump(const Duration(seconds: 10));
      expect(find.text('1월 1일 · 출조 1건'), findsOneWidget);
      expect(find.textContaining('Year night'), findsOneWidget);
      expect(
        find.textContaining('2026.12.31 18:00 ~ 2027.01.01 03:00'),
        findsOneWidget,
      );
      expect(find.textContaining('Ended last year'), findsNothing);
      await back(tester);
      expect(find.text('2021년 4월'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('resume and tab reactivation catch up after the date changes', (
    tester,
  ) async {
    await open(tester);
    await openSummary(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    clock = DateTime(2026, 12, 3, 9);
    await tester.pump(const Duration(days: 2));
    expect(find.text('12월 1일 · 출조 0건'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('12월 3일 · 출조 0건'), findsOneWidget);
    await back(tester);
    await open(tester, active: false);
    expect(
      tester
          .widget<CalendarTodaySummary>(find.byType(CalendarTodaySummary))
          .onPressed,
      isNull,
    );
    clock = DateTime(2026, 12, 4, 9);
    await tester.pump(const Duration(days: 1));
    expect(find.byType(DailyRecordListPage), findsNothing);
    await open(tester);
    await openSummary(tester);
    expect(find.text('12월 4일 · 출조 0건'), findsOneWidget);
    await back(tester);
    expect(find.text('2021년 4월'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'old summary callbacks cannot bypass inactive or deleted-account access',
    (tester) async {
      await open(tester);
      final onOpen = tester
          .widget<CalendarTodaySummary>(find.byType(CalendarTodaySummary))
          .onPressed!;
      await open(tester, active: false);
      expect(
        tester
            .widget<CalendarTodaySummary>(find.byType(CalendarTodaySummary))
            .onPressed,
        isNull,
      );
      onOpen();
      await tester.pumpAndSettle();
      expect(find.byType(DailyRecordListPage), findsNothing);
      expect(find.byType(RecordFormPage), findsNothing);
      await open(tester);
      auth.setAccountDeletionStateForTesting(
        isPending: true,
        initiatedLocally: false,
      );
      onOpen();
      await tester.pumpAndSettle();
      expect(find.byType(CalendarTodaySummary), findsNothing);
      expect(find.byType(DailyRecordListPage), findsNothing);
      expect(find.byType(RecordFormPage), findsNothing);
    },
  );

  testWidgets('switching accounts never shows previous owner summary details', (
    tester,
  ) async {
    await records.addRecord(
      _record(
        'Private first port',
        DateTime(2026, 12, 1, 8),
        DateTime(2026, 12, 1, 11),
      ),
    );
    await open(tester);
    await openSummary(tester);
    expect(find.textContaining('Private first port'), findsOneWidget);
    await auth.setSessionForTesting(
      plan: UserPlan.free,
      email: 'second-today@example.com',
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Private first port'), findsNothing);
    expect(find.text('12월 1일 · 출조 0건'), findsOneWidget);
    await auth.setSessionForTesting(plan: UserPlan.guest);
    await tester.pumpAndSettle();
    expect(find.textContaining('Private first port'), findsNothing);
    expect(find.byKey(const ValueKey('calendar-today-create')), findsNothing);
    expect(find.text('12월 1일 · 출조 0건'), findsNothing);
    await back(tester);
    expect(find.byType(CalendarTodaySummary), findsNothing);
  });

  testWidgets(
    'narrow large-text calendar keeps a compact button and opens summary details',
    (tester) async {
      await open(tester, size: const Size(320, 640), scale: 2);
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('calendar-month-picker')).hitTestable(),
        findsOneWidget,
      );
      final button = find.byKey(const ValueKey('calendar-today-open'));
      expect(button.hitTestable(), findsOneWidget);
      expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
      expect(
        tester
            .getSize(find.byKey(const ValueKey('calendar-month-grid')))
            .height,
        greaterThan(100),
      );
      expect(find.byKey(const ValueKey('calendar-today-create')), findsNothing);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byType(DailyRecordListPage), findsOneWidget);
      expect(find.text('12월 1일 · 출조 0건'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final create = find.byKey(const ValueKey('calendar-today-create'));
      await tester.ensureVisible(create);
      await tester.tap(create);
      await tester.pumpAndSettle();
      expect(find.byType(RecordFormPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

FishingRecord _record(
  String location,
  DateTime start,
  DateTime end, {
  String? id,
}) => FishingRecord(
  id: id ?? location,
  location: location,
  startAt: start,
  endAt: end,
  genreName: '루어',
);
