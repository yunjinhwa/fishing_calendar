import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fishing_build/data/local/app_database.dart';
import 'package:fishing_build/data/local/local_data_store.dart';
import 'package:fishing_build/data/models/conflict_item.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/outbox_item.dart';
import 'package:fishing_build/data/models/record_cache_policy.dart';
import 'package:fishing_build/data/models/record_sync_metadata.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/remote/record_sync_gateway.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/services/network_status_service.dart';
import 'package:fishing_build/data/services/paid_record_cache_service.dart';
import 'package:fishing_build/data/services/record_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_record_sync_gateway.dart';
import 'support/test_database.dart';

void main() {
  final auth = AuthSessionRepository.instance;
  final records = FishingRecordRepository.instance;
  final store = LocalDataStore.instance;
  final sync = RecordSyncService.instance;
  final network = NetworkStatusService.instance;
  final gates = <Completer<void>>[];
  late RecordCachePolicy policy;
  late PaidRecordCacheService cache;
  late _RangeGateway gateway;
  late _ConnectivityGateway connectivity;
  late String owner;
  final now = DateTime(2026, 10, 26, 13);
  final historicalMonth = DateTime(2026, 8);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PaidRecordCacheService.instance.resetForTesting();
    await sync.resetForTesting();
    await resetTestDatabase();
    auth.resetAuthGatewayForTesting();
    records.clearCacheOnlyForTesting();
    await auth.setSessionForTesting(
      plan: UserPlan.paid,
      email: 'cache-service@example.com',
    );
    owner = auth.dataOwnerKey;
    connectivity = _ConnectivityGateway();
    await network.resetForTesting(gateway: connectivity);
    await network.refresh();
    gateway = _RangeGateway();
    sync.configureGateway(gateway);
    policy = RecordCachePolicy(now: () => now)..enabled = true;
    cache = PaidRecordCacheService(policy: policy);
    gates.clear();
  });

  tearDown(() async {
    for (final gate in gates) {
      if (!gate.isCompleted) gate.complete();
    }
    await cache.resetForTesting();
    cache.dispose();
    await sync.resetForTesting();
    await network.close();
    await connectivity.close();
    await AppDatabase.instance.close();
  });

  Future<void> seed(
    FishingRecord record, {
    bool hasMetadata = true,
    int serverVersion = 1,
    int? optimisticVersion,
    RemoteRecordStatus status = RemoteRecordStatus.active,
    String? ownerKey,
  }) async {
    final targetOwner = ownerKey ?? owner;
    await AppDatabase.instance.transaction((transaction) async {
      await store.insertRecord(
        transaction,
        ownerKey: targetOwner,
        record: record,
      );
      if (hasMetadata) {
        await store.writeRecordSyncMetadata(
          transaction,
          ownerKey: targetOwner,
          metadata: RecordSyncMetadata(
            recordId: record.id,
            serverVersionNo: serverVersion,
            optimisticVersionNo: optimisticVersion ?? serverVersion,
            remoteStatus: status,
          ),
        );
      }
    });
    await records.reloadOwner(targetOwner);
  }

  Future<void> saveCheckpoint() => AppDatabase.instance.transaction(
    (transaction) => store.writeMetadata(
      transaction,
      key: RecordSyncCheckpoint.metadataKey(owner),
      value: _checkpoint.encode(),
    ),
  );

  Future<void> setConnected(bool connected) async {
    connectivity.connected = connected;
    await network.refresh();
  }

  test(
    'initialize trims only bodies before the 31-day overlap boundary',
    () async {
      final boundary = DateTime(2026, 9, 26);
      final expired = _record('expired', withPhoto: true);
      await seed(expired);
      await seed(_record('ends-at-boundary', endAt: boundary));
      await seed(
        _record(
          'overlaps-boundary',
          endAt: boundary.add(const Duration(microseconds: 1)),
        ),
      );
      await seed(
        _record(
          'ongoing',
          startAt: DateTime(2026, 9, 1),
          endAt: now.add(const Duration(hours: 1)),
        ),
      );
      await seed(
        _record(
          'future',
          startAt: DateTime(2026, 12, 1),
          endAt: DateTime(2026, 12, 2),
        ),
      );
      await saveCheckpoint();
      var notifications = 0;
      void listener() => notifications++;
      records.addListener(listener);
      addTearDown(() => records.removeListener(listener));

      cache.initialize();
      await cache.flushPending();

      expect(cache.lastTrimError, isNull);
      expect(
        records.getAllRecords().map((record) => record.id),
        unorderedEquals(['overlaps-boundary', 'ongoing', 'future']),
      );
      expect(await store.readRecordForOwner(owner, expired.id), isNull);
      expect(
        (await store.readArchivedPhotosForRecord(
          owner,
          expired.id,
        )).single.toJson(),
        expired.photos.single.toJson(),
      );
      final metadata = (await store.readRecordSyncMetadata(owner, expired.id))!;
      expect(metadata.serverVersionNo, 1);
      expect(metadata.optimisticVersionNo, 1);
      expect(metadata.remoteStatus, RemoteRecordStatus.active);
      expect(
        (await records.readSyncCheckpoint(owner))!.encode(),
        _checkpoint.encode(),
      );
      expect(await store.readOutboxItemsForOwner(owner), isEmpty);
      expect(await store.readLocalRecordChangesForOwner(owner), isEmpty);
      expect(notifications, 1);
    },
  );

  test(
    'trim protects every unsent status, unresolved conflict and free journal',
    () async {
      final protectedIds = <String>[];
      for (final status in OutboxStatus.values) {
        final record = _record('outbox-${status.name}');
        await seed(record);
        if (status != OutboxStatus.succeeded) protectedIds.add(record.id);
        await AppDatabase.instance.transaction(
          (transaction) => store.insertOutboxItem(
            transaction,
            ownerKey: owner,
            item: OutboxItem(
              id: record.id,
              recordId: record.id,
              operationType: OutboxOperationType.update,
              status: status,
              createdAt: now,
              payload: record.toJson(),
            ),
          ),
        );
      }
      for (final status in ConflictStatus.values) {
        final record = _record('conflict-${status.name}');
        await seed(record);
        if (status != ConflictStatus.resolved) protectedIds.add(record.id);
        await AppDatabase.instance.transaction(
          (transaction) => store.insertConflict(
            transaction,
            conflict: ConflictItem(
              id: record.id,
              ownerKey: owner,
              recordId: record.id,
              outboxId: 'previous-${record.id}',
              localOperationType: OutboxOperationType.update,
              baseVersionNo: 0,
              remoteVersionNo: 1,
              remoteStatus: RemoteRecordStatus.active,
              localRecord: record,
              remoteRecord: record,
              occurredAt: now,
              status: status,
            ),
          ),
        );
      }
      final journal = _record('free-journal');
      await seed(journal);
      protectedIds.add(journal.id);
      await AppDatabase.instance.transaction(
        (transaction) => store.writeLocalRecordChange(
          transaction,
          ownerKey: owner,
          record: journal,
          deleted: false,
        ),
      );
      await seed(_record('fully-synced'));

      expect(await cache.trimNow(), 3);
      expect(
        records.getAllRecords().map((record) => record.id),
        unorderedEquals(protectedIds),
      );
      expect(
        (await store.readLocalRecordChangesForOwner(owner)).single.recordId,
        journal.id,
      );
    },
  );

  test(
    'trim requires a confirmed active version and leaves other owners untouched',
    () async {
      await seed(_record('no-metadata'), hasMetadata: false);
      await seed(_record('not-uploaded'), serverVersion: 0);
      await seed(_record('optimistic'), serverVersion: 2, optimisticVersion: 3);
      await seed(_record('remote-deleted'), status: RemoteRecordStatus.deleted);
      await seed(_record('confirmed'), serverVersion: 4);
      const otherOwner = 'user:other-cache-account';
      await seed(_record('confirmed'), ownerKey: otherOwner);

      expect(await cache.trimNow(), 1);
      expect(
        records.getAllRecords().map((record) => record.id),
        unorderedEquals([
          'no-metadata',
          'not-uploaded',
          'optimistic',
          'remote-deleted',
        ]),
      );
      expect(
        await store.readRecordForOwner(otherOwner, 'confirmed'),
        isNotNull,
      );
      expect(
        (await store.readRecordSyncMetadata(
          owner,
          'confirmed',
        ))!.serverVersionNo,
        4,
      );
    },
  );

  for (final lockedPlan in ['free', 'paid-migration']) {
    test('$lockedPlan does not evict previously cached bodies', () async {
      final record = _record('retained', withPhoto: true);
      await seed(record);
      await auth.setSessionForTesting(
        plan: lockedPlan == 'free' ? UserPlan.free : UserPlan.paid,
        email: auth.email,
        migrationStatus: lockedPlan == 'free'
            ? PlanMigrationStatus.none
            : PlanMigrationStatus.localToCloudPending,
      );

      expect(await cache.trimNow(), 0);
      expect(
        (await store.readRecordForOwner(owner, record.id))!.toJson(),
        record.toJson(),
      );
      expect(cache.stateFor(historicalMonth), CachedMonthState.local);
      await cache.loadMonth(historicalMonth);
      expect(gateway.requests, isEmpty);
    });
  }

  test(
    'month and detail leases retain old bodies until their last release',
    () async {
      final monthRecord = _record('month');
      final detailRecord = _record(
        'detail',
        startAt: DateTime(2026, 7, 2),
        endAt: DateTime(2026, 7, 3),
      );
      await seed(monthRecord);
      await seed(detailRecord);
      final releaseMonth = cache.holdMonth(historicalMonth);
      final releaseDetail = policy.holdRecord(owner, detailRecord.id);

      expect(await cache.trimNow(), 0);
      releaseMonth();
      expect(await cache.trimNow(), 1);
      expect(records.getRecordById(monthRecord.id), isNull);
      expect(records.getRecordById(detailRecord.id), isNotNull);
      releaseDetail();
      expect(await cache.trimNow(), 1);
      expect(records.getAllRecords(), isEmpty);
    },
  );

  test('unheld and recent months do not query the server', () async {
    await cache.loadMonth(historicalMonth);
    final recentMonth = DateTime(2026, 10);
    final release = cache.holdMonth(recentMonth);
    addTearDown(release);

    await cache.loadMonth(recentMonth, force: true);

    expect(gateway.requests, isEmpty);
    expect(cache.stateFor(historicalMonth), CachedMonthState.local);
    expect(cache.stateFor(recentMonth), CachedMonthState.local);
  });

  test(
    'offline month makes no request and can retry without moving sync progress',
    () async {
      await saveCheckpoint();
      final release = cache.holdMonth(historicalMonth);
      addTearDown(release);
      gateway.page = _page([_active(_record('historical'))]);
      await setConnected(false);

      await cache.loadMonth(historicalMonth);

      expect(cache.stateFor(historicalMonth), CachedMonthState.offline);
      expect(gateway.requests, isEmpty);
      await setConnected(true);
      await cache.loadMonth(historicalMonth);
      expect(cache.stateFor(historicalMonth), CachedMonthState.ready);
      expect(gateway.requests, hasLength(1));
      expect(records.getRecordById('historical'), isNotNull);
      expect(
        (await records.readSyncCheckpoint(owner))!.encode(),
        _checkpoint.encode(),
      );
    },
  );

  test(
    'month failure is retryable and concurrent loads share one request',
    () async {
      final release = cache.holdMonth(historicalMonth);
      addTearDown(release);
      gateway.onRange = (_) async => throw const RecordSyncGatewayException(
        code: 'unavailable',
        message: 'Unavailable',
      );
      await cache.loadMonth(historicalMonth);
      expect(cache.stateFor(historicalMonth), CachedMonthState.failed);

      final started = Completer<void>();
      final gate = Completer<void>();
      gates.add(gate);
      gateway.onRange = (_) async {
        started.complete();
        await gate.future;
        return _page([_active(_record('retried'))]);
      };
      final first = cache.loadMonth(historicalMonth);
      await started.future;
      final second = cache.loadMonth(DateTime(2026, 8, 19));
      expect(identical(first, second), isTrue);
      expect(cache.stateFor(historicalMonth), CachedMonthState.loading);
      expect(gateway.requests, hasLength(2));
      gate.complete();
      await Future.wait([first, second]);
      expect(cache.stateFor(historicalMonth), CachedMonthState.ready);
      expect(records.getRecordById('retried'), isNotNull);
      await cache.loadMonth(historicalMonth);
      expect(gateway.requests, hasLength(2));
      gateway.onRange = (_) async => _page([_active(_record('retried'))]);
      await cache.loadMonth(historicalMonth, force: true);
      expect(gateway.requests, hasLength(3));
    },
  );

  test(
    'month pagination uses range cursors and preserves unrelated records',
    () async {
      await seed(
        _record(
          'outside',
          startAt: DateTime(2026, 10, 20),
          endAt: DateTime(2026, 10, 21),
        ),
      );
      await saveCheckpoint();
      final release = cache.holdMonth(historicalMonth);
      addTearDown(release);
      final cursor = _rangeCursor('first', 2);
      gateway.onRange = (request) async => request.after == null
          ? _page([_active(_record('first'))], hasMore: true, cursor: cursor)
          : _page([_active(_record('second'))]);

      await cache.loadMonth(DateTime(2026, 8, 15, 17));

      expect(cache.stateFor(historicalMonth), CachedMonthState.ready);
      expect(gateway.requests, hasLength(2));
      expect(gateway.requests.first.from, historicalMonth);
      expect(gateway.requests.first.to, DateTime(2026, 9));
      expect(gateway.requests.last.after!.toJson(), cursor.toJson());
      expect(
        records.getAllRecords().map((record) => record.id),
        unorderedEquals(['outside', 'first', 'second']),
      );
      expect(
        (await records.readSyncCheckpoint(owner))!.encode(),
        _checkpoint.encode(),
      );
    },
  );

  test(
    'non-advancing month pages fail without dropping cached records',
    () async {
      await seed(_record('existing'));
      final release = cache.holdMonth(historicalMonth);
      addTearDown(release);
      final cursor = _rangeCursor('first', 2);
      gateway.onRange = (request) async => _page(
        [_active(_record(request.after == null ? 'first' : 'invalid-second'))],
        hasMore: true,
        cursor: cursor,
      );

      await cache.loadMonth(historicalMonth);

      expect(cache.stateFor(historicalMonth), CachedMonthState.failed);
      expect(gateway.requests, hasLength(2));
      expect(records.getRecordById('existing'), isNotNull);
      expect(records.getRecordById('first'), isNotNull);
      expect(records.getRecordById('invalid-second'), isNull);
      expect(await records.readSyncCheckpoint(owner), isNull);
    },
  );

  test(
    'old A to B to A response is ignored and a fresh load can complete',
    () async {
      cache.initialize();
      await cache.flushPending();
      final release = cache.holdMonth(historicalMonth);
      addTearDown(release);
      final started = Completer<void>();
      final gate = Completer<void>();
      gates.add(gate);
      gateway.onRange = (_) async {
        started.complete();
        await gate.future;
        return _page([_active(_record('stale-session'))]);
      };
      final loading = cache.loadMonth(historicalMonth);
      await started.future;
      await auth.setSessionForTesting(
        plan: UserPlan.paid,
        email: 'other@example.com',
      );
      await auth.setSessionForTesting(
        plan: UserPlan.paid,
        email: 'cache-service@example.com',
      );
      gate.complete();
      await loading;

      expect(auth.dataOwnerKey, owner);
      expect(await store.readRecordForOwner(owner, 'stale-session'), isNull);
      expect(cache.stateFor(historicalMonth), isNot(CachedMonthState.loading));
      gateway.onRange = (_) async => _page([_active(_record('fresh-session'))]);
      await cache.loadMonth(historicalMonth);
      expect(cache.stateFor(historicalMonth), CachedMonthState.ready);
      expect(records.getRecordById('fresh-session'), isNotNull);
      expect(gateway.requests, hasLength(2));
    },
  );

  test(
    'releasing a month invalidates a request before it can restore bodies',
    () async {
      final release = cache.holdMonth(historicalMonth);
      final started = Completer<void>();
      final gate = Completer<void>();
      gates.add(gate);
      gateway.onRange = (_) async {
        started.complete();
        await gate.future;
        return _page([_active(_record('released'))]);
      };
      final loading = cache.loadMonth(historicalMonth);
      await started.future;

      release();
      gate.complete();
      await loading;

      expect(await store.readRecordForOwner(owner, 'released'), isNull);
      expect(cache.stateFor(historicalMonth), CachedMonthState.local);
    },
  );

  test(
    'history restores originals while held and trims after release',
    () async {
      final original = _record('archived-history', withPhoto: true);
      await seed(original);
      expect(await cache.trimNow(), 1);
      final pending = _record('pending-history', withPhoto: true);
      await seed(pending);
      await AppDatabase.instance.transaction(
        (transaction) => store.insertOutboxItem(
          transaction,
          ownerKey: owner,
          item: OutboxItem(
            id: 'pending-history-update',
            recordId: pending.id,
            operationType: OutboxOperationType.update,
            status: OutboxStatus.pending,
            createdAt: now,
            payload: pending.toJson(),
          ),
        ),
      );
      await seed(_record('local-only'), hasMetadata: false);
      await saveCheckpoint();
      gateway.seedActive(auth.memberId!, _record(original.id), versionNo: 1);
      gateway.seedActive(
        auth.memberId!,
        _record(pending.id, location: 'Must not replace local intent'),
        versionNo: 2,
      );
      cache.initialize();
      final release = cache.holdHistory();

      await cache.loadHistory();
      await cache.flushPending();

      expect(cache.historyState, CachedMonthState.ready);
      expect(gateway.fetchCount, 1);
      expect(gateway.requests, isEmpty);
      expect(
        records.getRecordById(original.id)!.photos.single.toJson(),
        original.photos.single.toJson(),
      );
      expect(records.getRecordById(pending.id)!.toJson(), pending.toJson());
      expect(records.getRecordById('local-only'), isNotNull);
      expect(
        (await store.readRecordSyncMetadata(
          owner,
          pending.id,
        ))!.serverVersionNo,
        1,
      );
      expect(
        (await records.readSyncCheckpoint(owner))!.encode(),
        _checkpoint.encode(),
      );
      expect(await cache.trimNow(), 0);

      release();
      await cache.flushPending();
      expect(records.getRecordById(original.id), isNull);
      expect(
        await store.readArchivedPhotosForRecord(owner, original.id),
        hasLength(1),
      );
      expect(records.getRecordById(pending.id), isNotNull);
      expect(records.getRecordById('local-only'), isNotNull);
      expect(cache.historyState, CachedMonthState.local);
    },
  );

  test(
    'history offline and failures retry with shared in-flight requests',
    () async {
      final release = cache.holdHistory();
      addTearDown(release);
      await setConnected(false);

      await cache.loadHistory();
      expect(cache.historyState, CachedMonthState.offline);
      expect(gateway.fetchCount, 0);
      await setConnected(true);
      gateway.failFetch = true;
      await cache.loadHistory();
      expect(cache.historyState, CachedMonthState.failed);
      expect(gateway.fetchCount, 1);

      gateway.failFetch = false;
      gateway.seedActive(auth.memberId!, _record('retried-history'));
      final gate = Completer<void>();
      gates.add(gate);
      gateway.fetchGate = gate.future;
      gateway.fetchStarted = Completer<void>();
      final first = cache.loadHistory();
      await gateway.fetchStarted!.future;
      final second = cache.loadHistory();
      expect(identical(first, second), isTrue);
      expect(cache.historyState, CachedMonthState.loading);
      expect(gateway.fetchCount, 2);
      gate.complete();
      await Future.wait([first, second]);
      expect(cache.historyState, CachedMonthState.ready);
      expect(records.getRecordById('retried-history'), isNotNull);
      gateway.fetchGate = null;
      gateway.fetchStarted = null;
      await cache.loadHistory();
      expect(gateway.fetchCount, 2);
      await cache.loadHistory(force: true);
      expect(gateway.fetchCount, 3);
    },
  );

  test('history requires an active lease and a paid entitlement', () async {
    await cache.loadHistory();
    expect(gateway.fetchCount, 0);
    await auth.setSessionForTesting(plan: UserPlan.free, email: auth.email);
    final release = cache.holdHistory();
    addTearDown(release);

    await cache.loadHistory(force: true);

    expect(gateway.fetchCount, 0);
    expect(cache.historyState, CachedMonthState.local);
  });

  for (final transition in ['account', 'paid-free-paid']) {
    test(
      'history rejects a stale response after $transition transition',
      () async {
        cache.initialize();
        await cache.flushPending();
        final release = cache.holdHistory();
        addTearDown(release);
        gateway.seedActive(auth.memberId!, _record('stale-history'));
        final gate = Completer<void>();
        gates.add(gate);
        gateway.fetchGate = gate.future;
        gateway.fetchStarted = Completer<void>();
        final loading = cache.loadHistory();
        await gateway.fetchStarted!.future;

        if (transition == 'account') {
          await auth.setSessionForTesting(
            plan: UserPlan.paid,
            email: 'other-history@example.com',
          );
        } else {
          await auth.setSessionForTesting(
            plan: UserPlan.free,
            email: 'cache-service@example.com',
          );
        }
        await auth.setSessionForTesting(
          plan: UserPlan.paid,
          email: 'cache-service@example.com',
        );
        gate.complete();
        await loading;

        expect(auth.dataOwnerKey, owner);
        expect(await store.readRecordForOwner(owner, 'stale-history'), isNull);
        expect(cache.historyState, isNot(CachedMonthState.loading));
        gateway.fetchGate = null;
        gateway.fetchStarted = null;
        gateway.seedActive(auth.memberId!, _record('fresh-history'));
        await cache.loadHistory();
        expect(cache.historyState, CachedMonthState.ready);
        expect(records.getRecordById('fresh-history'), isNotNull);
        expect(gateway.fetchCount, 2);
      },
    );
  }

  test('releasing history invalidates its pending response', () async {
    final release = cache.holdHistory();
    gateway.seedActive(auth.memberId!, _record('released-history'));
    final gate = Completer<void>();
    gates.add(gate);
    gateway.fetchGate = gate.future;
    gateway.fetchStarted = Completer<void>();
    final loading = cache.loadHistory();
    await gateway.fetchStarted!.future;

    release();
    gate.complete();
    await loading;

    expect(await store.readRecordForOwner(owner, 'released-history'), isNull);
    expect(cache.historyState, CachedMonthState.local);
  });
}

final _checkpoint = RecordSyncCheckpoint(
  cursor: const RecordSyncCursor(
    seconds: 100,
    nanoseconds: 321,
    recordId: 'global',
  ),
  lastFullSyncAt: DateTime.utc(2026, 10, 26),
);

FishingRecord _record(
  String id, {
  String location = 'Test harbor',
  DateTime? startAt,
  DateTime? endAt,
  bool withPhoto = false,
}) => FishingRecord(
  id: id,
  location: location,
  startAt: startAt ?? DateTime(2026, 8, 2, 8),
  endAt: endAt ?? DateTime(2026, 8, 2, 11),
  genreName: 'Lure',
  catches: const [CatchRecord(speciesName: 'Rockfish', lengthCm: 30)],
  photos: [
    if (withPhoto)
      const RecordPhoto(id: 'original', localPath: 'C:/photos/original.jpg'),
  ],
);

RemoteRecordRevision _active(FishingRecord record) => RemoteRecordRevision(
  recordId: record.id,
  versionNo: 1,
  status: RemoteRecordStatus.active,
  record: record,
);

RemoteRecordRangePage _page(
  List<RemoteRecordRevision> revisions, {
  bool hasMore = false,
  RecordRangeCursor? cursor,
}) => RemoteRecordRangePage(
  revisions: revisions,
  hasMore: hasMore,
  nextCursor: cursor,
);

RecordRangeCursor _rangeCursor(String id, int seconds) => RecordRangeCursor(
  endSeconds: seconds,
  endNanoseconds: 0,
  startSeconds: seconds - 1,
  startNanoseconds: 0,
  recordId: id,
);

class _RangeRequest {
  final String uid;
  final DateTime from;
  final DateTime to;
  final RecordRangeCursor? after;
  _RangeRequest(this.uid, this.from, this.to, this.after);
}

class _RangeGateway extends FakeRecordSyncGateway
    implements RecordRangeQueryGateway {
  final requests = <_RangeRequest>[];
  Future<RemoteRecordRangePage> Function(_RangeRequest)? onRange;
  RemoteRecordRangePage page = _page([]);

  @override
  Future<RemoteRecordRangePage> fetchRange({
    required String uid,
    required DateTime from,
    required DateTime to,
    RecordRangeCursor? after,
    int limit = 100,
  }) async {
    final request = _RangeRequest(uid, from, to, after);
    requests.add(request);
    return await onRange?.call(request) ?? page;
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
