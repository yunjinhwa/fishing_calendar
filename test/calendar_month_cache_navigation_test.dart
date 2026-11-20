import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fishing_build/data/local/app_database.dart';
import 'package:fishing_build/data/local/local_data_store.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/record_cache_policy.dart';
import 'package:fishing_build/data/models/record_sync_metadata.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/remote/record_sync_gateway.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/services/network_status_service.dart';
import 'package:fishing_build/data/services/paid_record_cache_service.dart';
import 'package:fishing_build/data/services/record_sync_service.dart';
import 'package:fishing_build/presentation/calendar/calendar_page.dart';
import 'package:fishing_build/presentation/calendar/calendar_today_summary.dart';
import 'package:fishing_build/presentation/calendar/daily_record_list_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_record_sync_gateway.dart';
import 'support/test_database.dart';

void main() {
  final auth = AuthSessionRepository.instance;
  final records = FishingRecordRepository.instance;
  final cache = PaidRecordCacheService.instance;
  final policy = RecordCachePolicy.instance;
  final network = NetworkStatusService.instance;
  final sync = RecordSyncService.instance;
  final gates = <Completer<void>>[];
  final currentMonth = DateTime(2026, 11);
  final targetMonth = DateTime(2021, 4);
  late _CalendarGateway gateway;
  late _ConnectivityGateway connectivity;
  late String owner;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await cache.resetForTesting();
    await sync.resetForTesting();
    await resetTestDatabase();
    auth.resetAuthGatewayForTesting();
    records.clearCacheOnlyForTesting();
    await auth.setSessionForTesting(
      plan: UserPlan.paid,
      email: 'calendar-navigation@example.com',
    );
    owner = auth.dataOwnerKey;
    policy.reset(now: () => DateTime(2026, 11, 16, 13));
    connectivity = _ConnectivityGateway();
    await network.resetForTesting(gateway: connectivity);
    await network.refresh();
    gateway = _CalendarGateway();
    sync.configureGateway(gateway);
    gates.clear();
    cache.initialize();
    await cache.flushPending();
  });

  tearDown(() async {
    for (final gate in gates) {
      if (!gate.isCompleted) gate.complete();
    }
    await cache.resetForTesting();
    await sync.resetForTesting();
    await network.close();
    await connectivity.close();
    await AppDatabase.instance.close();
  });

  Widget calendar({bool isActive = true, DateTime? initialMonth}) =>
      MaterialApp(
        home: CalendarPage(
          initialMonth: initialMonth ?? currentMonth,
          isActive: isActive,
        ),
      );

  Future<void> seedLocal(FishingRecord record) async {
    await AppDatabase.instance.transaction((transaction) async {
      await LocalDataStore.instance.insertRecord(
        transaction,
        ownerKey: owner,
        record: record,
      );
      await LocalDataStore.instance.writeRecordSyncMetadata(
        transaction,
        ownerKey: owner,
        metadata: RecordSyncMetadata(
          recordId: record.id,
          serverVersionNo: 1,
          optimisticVersionNo: 1,
          remoteStatus: RemoteRecordStatus.active,
        ),
      );
    });
    await records.reloadOwner(owner);
  }

  testWidgets(
    'paid picker queries only the selected month and reselecting it is a no-op',
    (tester) async {
      final record = _record('selected-month', targetMonth);
      gateway.onRange = (_) async => _page([_active(record)]);
      await tester.pumpWidget(calendar());
      await _flush(tester, cache);
      expect(gateway.requests, isEmpty);

      await _selectMonth(tester, targetMonth);
      await _flush(tester, cache);

      expect(gateway.requests, hasLength(1));
      expect(gateway.requests.single.from, targetMonth);
      expect(gateway.requests.single.to, DateTime(2021, 5));
      expect(gateway.requests.single.after, isNull);
      expect(gateway.fetchCount, 0);
      expect(policy.holdsMonth(owner, targetMonth), isTrue);
      expect(policy.holdsMonth(owner, currentMonth), isFalse);
      expect(find.text(record.summaryTitle), findsOneWidget);
      expect(cache.stateFor(targetMonth), CachedMonthState.ready);

      await _selectMonth(tester, targetMonth);
      await _flush(tester, cache);

      expect(gateway.requests, hasLength(1));
      expect(cache.stateFor(targetMonth), CachedMonthState.ready);
      expect(find.text(record.summaryTitle), findsOneWidget);
      await _dispose(tester, cache);
    },
  );

  testWidgets(
    'today summary keeps recent records while an older month uses its own cache',
    (tester) async {
      final today = DateTime(2026, 11, 16, 13);
      final todayRecord = FishingRecord(
        id: 'today-summary-recent',
        location: 'Today harbor',
        startAt: DateTime(2026, 11, 16, 8),
        endAt: DateTime(2026, 11, 16, 11),
        genreName: '루어',
      );
      final pastRecord = _record('today-summary-past', targetMonth);
      await tester.runAsync(() => seedLocal(todayRecord));
      gateway.onRange = (_) async => _page([_active(pastRecord)]);

      await tester.pumpWidget(
        MaterialApp(
          home: CalendarPage(initialMonth: targetMonth, now: () => today),
        ),
      );
      await _flush(tester, cache);

      final summary = find.byType(CalendarTodaySummary);
      expect(summary, findsOneWidget);
      expect(find.textContaining(todayRecord.location), findsNothing);
      expect(find.text('2021년 4월'), findsOneWidget);
      expect(
        find.descendant(
          of: _grid,
          matching: find.text(pastRecord.summaryTitle),
        ),
        findsOneWidget,
      );
      expect(gateway.requests, hasLength(1));
      expect(gateway.requests.single.from, targetMonth);
      expect(gateway.requests.single.to, DateTime(2021, 5));
      expect(gateway.fetchCount, 0);
      expect(policy.holdsMonth(owner, targetMonth), isTrue);
      expect(policy.holdsMonth(owner, currentMonth), isFalse);
      expect(policy.holdsHistory(owner), isFalse);

      await tester.tap(find.byKey(const ValueKey('calendar-today-open')));
      await tester.pumpAndSettle();
      final details = tester.widget<DailyRecordListPage>(
        find.byType(DailyRecordListPage),
      );
      expect(details.selectedDate, DateTime(2026, 11, 16));
      expect(details.isTodaySummary, isTrue);
      expect(find.text('오늘의 요약'), findsOneWidget);
      expect(find.text('11월 16일 · 출조 1건'), findsOneWidget);
      expect(find.textContaining(todayRecord.location), findsOneWidget);
      expect(find.textContaining('08:00'), findsOneWidget);

      expect(await tester.runAsync(cache.trimNow), 0);
      await _flush(tester, cache);
      expect(records.getRecordById(todayRecord.id), isNotNull);
      expect(
        await tester.runAsync(
          () =>
              LocalDataStore.instance.readRecordForOwner(owner, todayRecord.id),
        ),
        isNotNull,
      );
      expect(find.textContaining(todayRecord.location), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await _flush(tester, cache);
      expect(find.byType(DailyRecordListPage), findsNothing);
      expect(summary, findsOneWidget);
      expect(find.text('2021년 4월'), findsOneWidget);
      expect(
        find.descendant(
          of: _grid,
          matching: find.text(pastRecord.summaryTitle),
        ),
        findsOneWidget,
      );
      expect(gateway.requests, hasLength(1));
      expect(gateway.fetchCount, 0);
      expect(policy.holdsMonth(owner, currentMonth), isFalse);
      expect(policy.holdsHistory(owner), isFalse);
      await _dispose(tester, cache);
    },
  );

  testWidgets(
    'free picker and swipes keep local records without remote reads',
    (tester) async {
      await tester.runAsync(
        () => auth.setSessionForTesting(
          plan: UserPlan.free,
          email: 'calendar-navigation@example.com',
        ),
      );
      owner = auth.dataOwnerKey;
      final record = _record('free-local-month', targetMonth);
      await tester.runAsync(() => seedLocal(record));
      await tester.pumpWidget(calendar());
      await _selectMonth(tester, targetMonth);
      await _flush(tester, cache);
      expect(find.text(record.summaryTitle), findsOneWidget);

      await tester.fling(_grid, const Offset(-350, 0), 1000);
      await tester.pumpAndSettle();
      expect(find.text('2021년 5월'), findsOneWidget);
      await tester.fling(_grid, const Offset(350, 0), 1000);
      await tester.pumpAndSettle();
      await _flush(tester, cache);

      expect(find.text(record.summaryTitle), findsOneWidget);
      expect(records.getRecordById(record.id), isNotNull);
      expect(gateway.requests, isEmpty);
      expect(gateway.fetchCount, 0);
      expect(cache.stateFor(targetMonth), CachedMonthState.local);
      await _dispose(tester, cache);
    },
  );

  testWidgets(
    'offline paid picker retains cached records and shows the notice',
    (tester) async {
      connectivity.connected = false;
      await tester.runAsync(network.refresh);
      // Keep an existing cached body alive while navigating to its month.
      final releaseFixture = cache.holdMonth(targetMonth);
      final record = _record('offline-cached-month', targetMonth);
      await tester.runAsync(() => seedLocal(record));
      await tester.pumpWidget(calendar());
      await _selectMonth(tester, targetMonth);
      releaseFixture();
      await _flush(tester, cache);

      expect(find.text(record.summaryTitle), findsOneWidget);
      expect(find.text('과거 기록을 모두 보려면 인터넷에 연결해 주세요.'), findsOneWidget);
      expect(cache.stateFor(targetMonth), CachedMonthState.offline);
      expect(await tester.runAsync(cache.trimNow), 0);
      expect(records.getRecordById(record.id), isNotNull);
      expect(gateway.requests, isEmpty);
      expect(gateway.fetchCount, 0);
      await tester.pumpAndSettle(
        const Duration(milliseconds: 16),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 1),
      );
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.takeException(), isNull);
      await _dispose(tester, cache);
    },
  );

  testWidgets(
    'a swipe rejects the previous month response after it completes',
    (tester) async {
      final nextMonth = DateTime(2021, 5);
      final oldRecord = _record('late-previous-month', targetMonth);
      final nextRecord = _record('current-selected-month', nextMonth);
      final gate = Completer<void>();
      gates.add(gate);
      gateway.onRange = (request) async {
        if (request.from == targetMonth) {
          await gate.future;
          return _page([_active(oldRecord)]);
        }
        return _page([_active(nextRecord)]);
      };
      await tester.pumpWidget(calendar());
      await _selectMonth(tester, targetMonth);
      await _waitUntil(tester, () => gateway.requests.length == 1);

      try {
        await tester.fling(_grid, const Offset(-350, 0), 1000);
        await tester.pump();
        await _waitUntil(
          tester,
          () => cache.stateFor(nextMonth) == CachedMonthState.ready,
        );
        expect(gateway.requests.map((request) => request.from), [
          targetMonth,
          nextMonth,
        ]);
        expect(policy.holdsMonth(owner, targetMonth), isFalse);
        expect(policy.holdsMonth(owner, nextMonth), isTrue);
        expect(records.getRecordById(nextRecord.id), isNotNull);
        expect(find.text(nextRecord.summaryTitle), findsOneWidget);
      } finally {
        if (!gate.isCompleted) gate.complete();
        await _flush(tester, cache);
      }

      expect(find.text('2021년 5월'), findsOneWidget);
      expect(find.text(nextRecord.summaryTitle), findsOneWidget);
      expect(records.getRecordById(oldRecord.id), isNull);
      expect(
        await tester.runAsync(
          () => LocalDataStore.instance.readRecordForOwner(owner, oldRecord.id),
        ),
        isNull,
      );
      expect(cache.stateFor(nextMonth), CachedMonthState.ready);
      expect(gateway.fetchCount, 0);
      await _dispose(tester, cache);
    },
  );

  testWidgets('an inactive calendar defers its month read until active', (
    tester,
  ) async {
    await tester.pumpWidget(
      calendar(isActive: false, initialMonth: targetMonth),
    );
    await _flush(tester, cache);
    expect(gateway.requests, isEmpty);
    expect(policy.holdsMonth(owner, targetMonth), isFalse);

    await tester.pumpWidget(calendar(initialMonth: targetMonth));
    await _flush(tester, cache);

    expect(gateway.requests, hasLength(1));
    expect(gateway.requests.single.from, targetMonth);
    expect(gateway.fetchCount, 0);
    expect(policy.holdsMonth(owner, targetMonth), isTrue);
    await _dispose(tester, cache);
  });
}

final _grid = find.byKey(const ValueKey('calendar-month-grid'));

Future<void> _selectMonth(WidgetTester tester, DateTime month) async {
  await tester.tap(find.byKey(const ValueKey('calendar-month-picker')));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const ValueKey('calendar-picker-year')),
    '${month.year}',
  );
  await tester.tap(
    find.byKey(ValueKey('calendar-picker-month-${month.month}')),
  );
  await tester.tap(find.byKey(const ValueKey('calendar-picker-confirm')));
  await tester.pump();
  // A pending remote request can leave the calendar loading after dismissal.
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _waitUntil(WidgetTester tester, bool Function() condition) async {
  for (var iteration = 0; iteration < 200 && !condition(); iteration++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
  expect(condition(), isTrue, reason: 'Timed out waiting for the month read.');
  // The condition may become true before this helper enters its loop, while
  // the cache notification still has a calendar rebuild waiting for a frame.
  await tester.pump();
}

Future<void> _flush(WidgetTester tester, PaidRecordCacheService cache) async {
  var completed = false;
  unawaited(
    cache.flushPending().then<void>((_) {
      completed = true;
    }),
  );
  await _waitUntil(tester, () => completed);
  await tester.pump();
}

Future<void> _dispose(WidgetTester tester, PaidRecordCacheService cache) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await _flush(tester, cache);
}

FishingRecord _record(String id, DateTime month) => FishingRecord(
  id: id,
  location: 'Cached harbor',
  startAt: DateTime(month.year, month.month, 8, 8),
  endAt: DateTime(month.year, month.month, 8, 11),
  genreName: id,
  catches: const [CatchRecord(speciesName: 'Rockfish', lengthCm: 30)],
);

RemoteRecordRevision _active(FishingRecord record) => RemoteRecordRevision(
  recordId: record.id,
  versionNo: 1,
  status: RemoteRecordStatus.active,
  record: record,
);

RemoteRecordRangePage _page(List<RemoteRecordRevision> revisions) =>
    RemoteRecordRangePage(
      revisions: revisions,
      nextCursor: null,
      hasMore: false,
    );

class _RangeRequest {
  final DateTime from;
  final DateTime to;
  final RecordRangeCursor? after;

  const _RangeRequest(this.from, this.to, this.after);
}

class _CalendarGateway extends FakeRecordSyncGateway
    implements RecordRangeQueryGateway {
  final requests = <_RangeRequest>[];
  Future<RemoteRecordRangePage> Function(_RangeRequest)? onRange;

  @override
  Future<RemoteRecordRangePage> fetchRange({
    required String uid,
    required DateTime from,
    required DateTime to,
    RecordRangeCursor? after,
    int limit = 100,
  }) async {
    final request = _RangeRequest(from, to, after);
    requests.add(request);
    return await onRange?.call(request) ?? _page([]);
  }
}

class _ConnectivityGateway implements ConnectivityGateway {
  bool connected = true;
  final _changes = StreamController<List<ConnectivityResult>>.broadcast();

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => [
    connected ? ConnectivityResult.wifi : ConnectivityResult.none,
  ];

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => _changes.stream;

  Future<void> close() => _changes.close();
}
