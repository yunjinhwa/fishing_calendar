import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fishing_build/data/local/app_database.dart';
import 'package:fishing_build/data/local/local_data_store.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/record_cache_policy.dart';
import 'package:fishing_build/data/models/record_sync_metadata.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/remote/firestore_record_sync_gateway.dart';
import 'package:fishing_build/data/remote/record_sync_gateway.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/conflict_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/repositories/outbox_repository.dart';
import 'package:fishing_build/data/services/network_status_service.dart';
import 'package:fishing_build/data/services/paid_record_cache_service.dart';
import 'package:fishing_build/data/services/record_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/incremental_fake_record_sync_gateway.dart';
import 'support/test_database.dart';

void main() {
  final auth = AuthSessionRepository.instance;
  final records = FishingRecordRepository.instance;
  final store = LocalDataStore.instance;
  final sync = RecordSyncService.instance;
  final network = NetworkStatusService.instance;
  late _CodecGateway gateway;
  late _ConnectedGateway connectivity;
  late PaidRecordCacheService cache;
  final month = DateTime(2026, 8);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PaidRecordCacheService.instance.resetForTesting();
    await sync.resetForTesting();
    await resetTestDatabase();
    auth.clearMemoryOnlyForTesting();
    records.clearCacheOnlyForTesting();
    OutboxRepository.instance.clearCacheOnlyForTesting();
    ConflictRepository.instance.clearCacheOnlyForTesting();
    await auth.setSessionForTesting(
      plan: UserPlan.paid,
      email: 'schema-read-safety@example.com',
    );
    connectivity = _ConnectedGateway();
    await network.resetForTesting(gateway: connectivity);
    await network.refresh();
    gateway = _CodecGateway();
    sync.configureGateway(gateway);
    cache = PaidRecordCacheService(
      policy: RecordCachePolicy(now: () => DateTime(2026, 11, 15))
        ..enabled = true,
    );
  });

  tearDown(() async {
    await cache.resetForTesting();
    cache.dispose();
    await sync.resetForTesting();
    await network.close();
    await connectivity.close();
    await AppDatabase.instance.close();
  });

  Future<void> seedLocal(FishingRecord record) async {
    await AppDatabase.instance.transaction((transaction) async {
      await store.insertRecord(
        transaction,
        ownerKey: auth.dataOwnerKey,
        record: record,
      );
      await store.writeRecordSyncMetadata(
        transaction,
        ownerKey: auth.dataOwnerKey,
        metadata: RecordSyncMetadata(
          recordId: record.id,
          serverVersionNo: 1,
          optimisticVersionNo: 1,
          remoteStatus: RemoteRecordStatus.active,
        ),
      );
    });
    await records.reloadOwner(auth.dataOwnerKey);
  }

  Future<String?> firstSyncMarker() async => store.readMetadata(
    await AppDatabase.instance.database,
    'firestore_record_sync_v2:${auth.memberId!}',
  );

  test(
    'malformed initial snapshot preserves records, photos and sync marker',
    () async {
      final local = _record('retained', withPhoto: true);
      await seedLocal(local);
      gateway.seedActive(
        auth.memberId!,
        _record(local.id, location: 'Remote change'),
      );
      gateway.seedActive(auth.memberId!, _record('broken'));
      gateway.corruptIds.add('broken');

      final result = await sync.syncNow();

      expect(result.isSuccess, isFalse);
      expect(await firstSyncMarker(), isNull);
      expect(await records.readSyncCheckpoint(auth.dataOwnerKey), isNull);
      expect(records.getRecordById(local.id)!.location, local.location);
      expect(records.getRecordById(local.id)!.photoPaths, local.photoPaths);
      expect(records.getRecordById('broken'), isNull);
      records.clearCacheOnlyForTesting();
      await records.reloadOwner(auth.dataOwnerKey);
      expect(records.getRecordById(local.id)!.photoPaths, local.photoPaths);

      gateway.corruptIds.clear();
      expect((await sync.syncNow()).isSuccess, isTrue);
      expect(await firstSyncMarker(), AppDatabase.migrationCompletedValue);
      expect(records.getRecordById(local.id)!.location, 'Remote change');
      expect(records.getRecordById(local.id)!.photoPaths, local.photoPaths);
      expect(records.getRecordById('broken'), isNotNull);
    },
  );

  test(
    'malformed second delta page keeps only the first committed checkpoint',
    () async {
      final uid = auth.memberId!;
      gateway.seedActive(
        uid,
        _record('baseline'),
        cursor: _cursor('baseline', 10),
      );
      expect((await sync.syncNow()).isSuccess, isTrue);
      gateway.seedActive(
        uid,
        _record('first-good'),
        cursor: _cursor('first-good', 20),
      );
      gateway.seedActive(
        uid,
        _record('failed-good'),
        cursor: _cursor('failed-good', 30),
      );
      gateway.seedActive(uid, _record('broken'), cursor: _cursor('broken', 40));
      gateway.corruptIds.add('broken');

      expect((await sync.syncNow()).isSuccess, isFalse);

      final checkpoint = (await records.readSyncCheckpoint(auth.dataOwnerKey))!;
      expect(checkpoint.cursor.recordId, 'first-good');
      expect(records.getRecordById('first-good'), isNotNull);
      expect(records.getRecordById('failed-good'), isNull);
      expect(records.getRecordById('broken'), isNull);
      expect(records.getRecordById('baseline'), isNotNull);

      gateway.corruptIds.clear();
      expect((await sync.syncNow()).isSuccess, isTrue);
      expect(records.getRecordById('failed-good'), isNotNull);
      expect(records.getRecordById('broken'), isNotNull);
      expect(
        (await records.readSyncCheckpoint(auth.dataOwnerKey))!.cursor.recordId,
        'broken',
      );
      expect(
        gateway.changeRequests[2].since.toJson(),
        checkpoint.cursor.toJson(),
      );
    },
  );

  test(
    'malformed later month page cannot reconcile away cached records',
    () async {
      final local = _record('preserved', day: 6, withPhoto: true);
      await seedLocal(local);
      gateway.seedActive(auth.memberId!, _record('first-good', day: 2));
      gateway.seedActive(auth.memberId!, _record('second-good', day: 3));
      gateway.seedActive(auth.memberId!, _record('failed-good', day: 4));
      gateway.seedActive(auth.memberId!, _record('broken', day: 5));
      gateway.corruptIds.add('broken');
      final release = cache.holdMonth(month);
      addTearDown(release);

      await cache.loadMonth(month);

      expect(cache.stateFor(month), CachedMonthState.failed);
      expect(cache.errorFor(month), contains('broken'));
      expect(records.getRecordById('first-good'), isNotNull);
      expect(records.getRecordById('failed-good'), isNull);
      expect(records.getRecordById(local.id)!.photoPaths, local.photoPaths);
      expect(
        await store.readRecordForOwner(auth.dataOwnerKey, local.id),
        isNotNull,
      );
      expect(await records.readSyncCheckpoint(auth.dataOwnerKey), isNull);

      release();
      expect(cache.errorFor(month), isNull);
      final releaseRetry = cache.holdMonth(month);
      addTearDown(releaseRetry);
      gateway.corruptIds.clear();
      await cache.loadMonth(month);
      expect(cache.stateFor(month), CachedMonthState.ready);
      expect(cache.errorFor(month), isNull);
      expect(records.getRecordById('failed-good'), isNotNull);
      expect(records.getRecordById('broken'), isNotNull);
      // Only a fully decoded authoritative range may reconcile missing records.
      expect(records.getRecordById(local.id), isNull);
      expect(await records.readSyncCheckpoint(auth.dataOwnerKey), isNull);
    },
  );

  test('malformed whole history never applies a partial snapshot', () async {
    final local = _record('preserved-history', withPhoto: true);
    await seedLocal(local);
    gateway.seedActive(auth.memberId!, _record('valid-history'));
    gateway.seedActive(auth.memberId!, _record('broken'));
    gateway.corruptIds.add('broken');
    final release = cache.holdHistory();
    addTearDown(release);

    await cache.loadHistory();

    expect(cache.historyState, CachedMonthState.failed);
    expect(cache.historyError, contains('broken'));
    expect(records.getRecordById('valid-history'), isNull);
    expect(records.getRecordById(local.id)!.photoPaths, local.photoPaths);
    expect(await records.readSyncCheckpoint(auth.dataOwnerKey), isNull);

    gateway.corruptIds.clear();
    await cache.loadHistory();
    expect(cache.historyState, CachedMonthState.ready);
    expect(cache.historyError, isNull);
    expect(records.getRecordById('valid-history'), isNotNull);
    expect(records.getRecordById('broken'), isNotNull);
    expect(records.getRecordById(local.id), isNull);
    expect(await records.readSyncCheckpoint(auth.dataOwnerKey), isNull);
  });
}

FishingRecord _record(
  String id, {
  String location = 'Local harbor',
  int day = 2,
  bool withPhoto = false,
}) => FishingRecord(
  id: id,
  location: location,
  startAt: DateTime(2026, 8, day, 8),
  endAt: DateTime(2026, 8, day, 10),
  genreName: 'Lure',
  catches: const [CatchRecord(speciesName: 'Rockfish', lengthCm: 30)],
  photoPaths: withPhoto ? ['C:/photos/retained.jpg'] : const [],
);

RecordSyncCursor _cursor(String id, int seconds) =>
    RecordSyncCursor(seconds: seconds, nanoseconds: 0, recordId: id);

class _CodecGateway extends IncrementalFakeRecordSyncGateway
    implements RecordRangeQueryGateway {
  _CodecGateway() : super(pageSize: 2);
  final corruptIds = <String>{};

  Map<String, dynamic> _document(String uid, RemoteRecordRevision revision) {
    final record = revision.record!;
    return {
      'schemaVersion': 1,
      'ownerUid': uid,
      'recordId': record.id,
      'recordStatus': 'ACTIVE',
      'versionNo': revision.versionNo,
      'clientModifiedAt': Timestamp.fromDate(record.endAt),
      'createdAt': Timestamp.fromDate(record.startAt),
      'serverUpdatedAt': Timestamp(
        revision.cursor!.seconds,
        revision.cursor!.nanoseconds,
      ),
      'lastOutboxId': 'remote-${record.id}',
      'location': record.location,
      'startAt': Timestamp.fromDate(record.startAt),
      'endAt': Timestamp.fromDate(record.endAt),
      'genreName': record.genreName,
      'tide': null,
      'weather': null,
      'airTemperature': null,
      'waterTemperature': null,
      'catches': corruptIds.contains(record.id)
          ? [42]
          : record.catches.map((entry) => entry.toJson()).toList(),
      'memo': null,
      'photoUploadPending': false,
    };
  }

  @override
  Future<RemoteRecordSnapshot> fetchSnapshot({required String uid}) async {
    final snapshot = await super.fetchSnapshot(uid: uid);
    return FirestoreRecordSyncGateway.decodeSnapshotForTesting(
      uid: uid,
      documents: {
        for (final revision in snapshot.revisions)
          revision.recordId: _document(uid, revision),
      },
    );
  }

  @override
  Future<RemoteRecordChangePage> fetchChanges({
    required String uid,
    required RecordSyncCursor since,
    required RecordSyncCursor through,
    RecordSyncCursor? after,
    int limit = 100,
  }) async {
    final page = await super.fetchChanges(
      uid: uid,
      since: since,
      through: through,
      after: after,
      limit: limit,
    );
    final decoded = FirestoreRecordSyncGateway.decodeSnapshotForTesting(
      uid: uid,
      documents: {
        for (final revision in page.revisions)
          revision.recordId: _document(uid, revision),
      },
    );
    // Decode the entire page before exposing any revisions to the service.
    final byId = {
      for (final revision in decoded.revisions) revision.recordId: revision,
    };
    return RemoteRecordChangePage(
      revisions: [
        for (final revision in page.revisions) byId[revision.recordId]!,
      ],
      hasMore: page.hasMore,
    );
  }

  @override
  Future<RemoteRecordRangePage> fetchRange({
    required String uid,
    required DateTime from,
    required DateTime to,
    RecordRangeCursor? after,
    int limit = 100,
  }) async {
    final snapshot = await super.fetchSnapshot(uid: uid);
    final eligible =
        snapshot.revisions.where((revision) {
          final record = revision.record!;
          return record.startAt.isBefore(to) &&
              record.endAt.isAfter(from) &&
              (after == null || _rangeCursor(record).compareTo(after) > 0);
        }).toList()..sort(
          (left, right) =>
              _rangeCursor(left.record!).compareTo(_rangeCursor(right.record!)),
        );
    return FirestoreRecordSyncGateway.decodeRangePageForTesting(
      uid: uid,
      from: from,
      to: to,
      after: after,
      limit: 2,
      documents: {
        for (final revision in eligible.take(2))
          revision.recordId: _document(uid, revision),
      },
    );
  }
}

RecordRangeCursor _rangeCursor(FishingRecord record) => RecordRangeCursor(
  endSeconds: Timestamp.fromDate(record.endAt).seconds,
  endNanoseconds: 0,
  startSeconds: Timestamp.fromDate(record.startAt).seconds,
  startNanoseconds: 0,
  recordId: record.id,
);

class _ConnectedGateway implements ConnectivityGateway {
  final _changes = StreamController<List<ConnectivityResult>>.broadcast();
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => [
    ConnectivityResult.wifi,
  ];
  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => _changes.stream;
  Future<void> close() => _changes.close();
}
