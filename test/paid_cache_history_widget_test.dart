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
import 'package:fishing_build/presentation/personal_best/personal_best_page.dart';
import 'package:fishing_build/presentation/record/record_history_scope.dart';
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
  late _HistoryGateway gateway;
  late _ConnectivityGateway connectivity;
  late DateTime now;
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
      email: 'history-widget@example.com',
    );
    owner = auth.dataOwnerKey;
    now = DateTime.now();
    policy.reset(now: () => now);
    connectivity = _ConnectivityGateway();
    await network.resetForTesting(gateway: connectivity);
    await network.refresh();
    gateway = _HistoryGateway();
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

  FishingRecord record(String id, {double length = 60, bool recent = false}) {
    final start = recent
        ? now.subtract(const Duration(hours: 2))
        : DateTime(now.year - 1, 8, 2, 8);
    return FishingRecord(
      id: id,
      location: recent ? 'Recent harbor' : 'Historical harbor',
      startAt: start,
      endAt: start.add(const Duration(hours: 1)),
      genreName: 'Lure',
      catches: [CatchRecord(speciesName: 'Rockfish', lengthCm: length)],
    );
  }

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

  Widget history({bool isActive = true}) => MaterialApp(
    home: Scaffold(
      body: RecordHistoryScope(
        isActive: isActive,
        child: const Text('Saved records'),
      ),
    ),
  );

  testWidgets(
    'history loads only while visible and offers a failed-load retry',
    (tester) async {
      gateway.seedActive(auth.memberId!, record('older'));
      final gate = Completer<void>();
      gates.add(gate);
      gateway.fetchGate = gate.future;
      gateway.failFetch = true;

      await tester.pumpWidget(history(isActive: false));
      await tester.pump();
      expect(policy.holdsHistory(owner), isFalse);
      expect(gateway.fetchCount, 0);

      await tester.pumpWidget(history());
      await tester.pump();
      expect(policy.holdsHistory(owner), isTrue);
      expect(gateway.fetchCount, 1);
      expect(find.text('전체 기록을 불러오는 중입니다.'), findsOneWidget);
      gate.complete();
      await _flush(tester, cache);
      expect(find.textContaining('전체 기록을 불러오지 못했습니다.'), findsOneWidget);
      expect(find.text('다시 시도'), findsOneWidget);

      gateway.fetchGate = null;
      gateway.failFetch = false;
      await tester.tap(find.text('다시 시도'));
      await tester.pump();
      await _flush(tester, cache);
      expect(gateway.fetchCount, 2);
      expect(records.getRecordById('older'), isNotNull);
      expect(find.text('다시 시도'), findsNothing);

      await tester.pumpWidget(history(isActive: false));
      await _flush(tester, cache);
      expect(policy.holdsHistory(owner), isFalse);
      expect(records.getRecordById('older'), isNull);
      expect(gateway.fetchCount, 2);
      await _dispose(tester, cache);
    },
  );

  testWidgets(
    'personal best includes a larger catch outside the 31-day cache',
    (tester) async {
      final recent = record('recent', length: 30, recent: true);
      await tester.runAsync(() => seedLocal(recent));
      gateway.seedActive(auth.memberId!, recent);
      gateway.seedActive(auth.memberId!, record('old-largest'));
      final gate = Completer<void>();
      gates.add(gate);
      gateway.fetchGate = gate.future;

      await tester.pumpWidget(const MaterialApp(home: PersonalBestPage()));
      await tester.pump();
      expect(find.textContaining('30.0 cm'), findsOneWidget);
      expect(find.text('전체 기록을 불러오는 중입니다.'), findsOneWidget);
      gate.complete();
      await _flush(tester, cache);

      expect(gateway.fetchCount, 1);
      expect(find.textContaining('60.0 cm'), findsOneWidget);
      expect(find.textContaining('Historical harbor'), findsOneWidget);
      expect(records.getRecordById('old-largest'), isNotNull);
      await _dispose(tester, cache);
      expect(records.getRecordById('old-largest'), isNull);
      expect(records.getRecordById('recent'), isNotNull);
    },
  );

  testWidgets('offline history settles without retries and loads on recovery', (
    tester,
  ) async {
    connectivity.connected = false;
    await tester.runAsync(network.refresh);
    gateway.seedActive(auth.memberId!, record('recovered'));
    await tester.pumpWidget(history());
    await _flush(tester, cache);

    expect(find.textContaining('오프라인에서는'), findsOneWidget);
    expect(gateway.fetchCount, 0);
    await tester.pumpAndSettle(
      const Duration(milliseconds: 16),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 1),
    );
    for (var index = 0; index < 6; index++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(gateway.fetchCount, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);

    connectivity.connected = true;
    await tester.runAsync(network.refresh);
    await tester.pump();
    await _flush(tester, cache);
    expect(gateway.fetchCount, 1);
    expect(cache.historyState, CachedMonthState.ready);
    expect(records.getRecordById('recovered'), isNotNull);
    expect(find.textContaining('오프라인에서는'), findsNothing);
    await _dispose(tester, cache);
  });

  testWidgets(
    'offline historical calendar does not schedule a frame retry loop',
    (tester) async {
      connectivity.connected = false;
      await tester.runAsync(network.refresh);
      await tester.pumpWidget(const MaterialApp(home: CalendarPage()));
      await tester.pump();
      // Two months back is always before the rolling 31-day boundary.
      for (var index = 0; index < 2; index++) {
        await tester.tap(find.byIcon(Icons.chevron_left));
        await tester.pump();
      }
      await _flush(tester, cache);

      expect(find.text('과거 기록을 모두 보려면 인터넷에 연결해 주세요.'), findsOneWidget);
      await tester.pumpAndSettle(
        const Duration(milliseconds: 16),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 1),
      );
      for (var index = 0; index < 6; index++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(gateway.rangeFetchCount, 0);
      expect(gateway.fetchCount, 0);
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.takeException(), isNull);
      await _dispose(tester, cache);
    },
  );
}

Future<void> _flush(WidgetTester tester, PaidRecordCacheService cache) async {
  var completed = false;
  cache.flushPending().then((_) => completed = true);
  // SQLite uses the real event loop while widget continuations need the fake
  // clock pumped. Keep both moving without pumpAndSettle on a loading spinner.
  for (var iteration = 0; iteration < 200 && !completed; iteration++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
  expect(completed, isTrue, reason: 'Timed out waiting for the record cache.');
  await tester.pump();
}

Future<void> _dispose(WidgetTester tester, PaidRecordCacheService cache) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await _flush(tester, cache);
}

class _HistoryGateway extends FakeRecordSyncGateway
    implements RecordRangeQueryGateway {
  int rangeFetchCount = 0;

  @override
  Future<RemoteRecordRangePage> fetchRange({
    required String uid,
    required DateTime from,
    required DateTime to,
    RecordRangeCursor? after,
    int limit = 100,
  }) async {
    rangeFetchCount++;
    return RemoteRecordRangePage(
      revisions: const [],
      hasMore: false,
      nextCursor: null,
    );
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
