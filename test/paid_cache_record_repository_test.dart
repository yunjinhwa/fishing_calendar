import 'package:fishing_build/data/local/app_database.dart';
import 'package:fishing_build/data/local/local_data_store.dart';
import 'package:fishing_build/data/models/conflict_item.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/outbox_item.dart';
import 'package:fishing_build/data/models/record_sync_metadata.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/remote/record_sync_gateway.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_database.dart';

void main() {
  final auth = AuthSessionRepository.instance;
  final records = FishingRecordRepository.instance;
  final store = LocalDataStore.instance;
  late String owner;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await resetTestDatabase();
    auth.clearMemoryOnlyForTesting();
    records.clearCacheOnlyForTesting();
    await auth.setSessionForTesting(
      plan: UserPlan.paid,
      email: 'paid-cache-repository@example.com',
    );
    owner = auth.dataOwnerKey;
  });

  tearDown(() async {
    await AppDatabase.instance.close();
  });

  Future<void> seed(
    FishingRecord record, {
    int version = 1,
    String? ownerKey,
  }) async {
    final targetOwner = ownerKey ?? owner;
    await AppDatabase.instance.transaction((transaction) async {
      await store.insertRecord(
        transaction,
        ownerKey: targetOwner,
        record: record,
      );
      await store.writeRecordSyncMetadata(
        transaction,
        ownerKey: targetOwner,
        metadata: RecordSyncMetadata(
          recordId: record.id,
          serverVersionNo: version,
          optimisticVersionNo: version,
          remoteStatus: RemoteRecordStatus.active,
        ),
      );
    });
    await records.reloadOwner(targetOwner);
  }

  Future<void> evict(String recordId, {String? ownerKey}) async {
    final targetOwner = ownerKey ?? owner;
    await AppDatabase.instance.transaction(
      (transaction) => store.deleteRecord(
        transaction,
        ownerKey: targetOwner,
        recordId: recordId,
        preservePhotos: true,
      ),
    );
    await records.reloadOwner(targetOwner);
  }

  Future<RecordPageApplyResult> page(
    List<RemoteRecordRevision> revisions, {
    int position = 2,
    bool Function(FishingRecord)? retainRecord,
    bool Function()? isCurrentSession,
  }) => records.applyRemotePage(
    ownerKey: owner,
    revisions: revisions,
    checkpoint: _checkpoint(position),
    isCurrentSession: isCurrentSession ?? () => true,
    retainRecord: retainRecord,
  );

  Future<RecordPageApplyResult> range(List<RemoteRecordRevision> revisions) =>
      records.applyRemoteRange(
        ownerKey: owner,
        revisions: revisions,
        isCurrentSession: () => true,
      );

  test('excluded old bodies still commit versions and pull progress', () async {
    final old = _record('old', startAt: DateTime(2025, 1, 1));
    final recent = _record('recent');
    final cutoff = DateTime(2026, 10, 1);
    bool retain(FishingRecord record) => !record.endAt.isBefore(cutoff);

    final result = await page(
      [_active(old, version: 3), _active(recent, version: 4)],
      position: 7,
      retainRecord: retain,
    );

    expect(result.applied, isTrue);
    expect(result.changedCount, 1);
    expect(records.getAllRecords().map((record) => record.id), ['recent']);
    expect(await store.readRecordForOwner(owner, old.id), isNull);
    final oldMetadata = (await store.readRecordSyncMetadata(owner, old.id))!;
    expect(oldMetadata.serverVersionNo, 3);
    expect(oldMetadata.optimisticVersionNo, 3);
    expect(oldMetadata.remoteStatus, RemoteRecordStatus.active);
    expect((await records.readSyncCheckpoint(owner))!.cursor.seconds, 7);

    // Replaying a page cannot hydrate an excluded body from its metadata.
    final replay = await page(
      [_active(old, version: 3)],
      position: 7,
      retainRecord: retain,
    );
    expect(replay.changedCount, 0);
    expect(await store.readRecordForOwner(owner, old.id), isNull);
  });

  test(
    'evicting an existing body preserves originals and publishes once',
    () async {
      final original = _record('evicted', withPhoto: true);
      await seed(original);
      var notifications = 0;
      void listener() => notifications++;
      records.addListener(listener);
      addTearDown(() => records.removeListener(listener));

      final revision = _active(
        _record(original.id, location: 'Updated on server'),
        version: 2,
      );
      final result = await page([revision], retainRecord: (_) => false);

      expect(result.applied, isTrue);
      expect(result.changedCount, 1);
      expect(records.getRecordById(original.id), isNull);
      expect(await store.readRecordForOwner(owner, original.id), isNull);
      final database = await AppDatabase.instance.database;
      for (final table in [
        AppDatabase.recordCatchesTable,
        AppDatabase.recordPhotosTable,
      ]) {
        expect(
          await database.query(
            table,
            where: 'owner_key = ? AND record_id = ?',
            whereArgs: [owner, original.id],
          ),
          isEmpty,
        );
      }
      expect(
        (await store.readArchivedPhotosForRecord(
          owner,
          original.id,
        )).single.toJson(),
        original.photos.single.toJson(),
      );
      expect(
        (await store.readRecordSyncMetadata(
          owner,
          original.id,
        ))!.serverVersionNo,
        2,
      );
      expect(notifications, 1);
      expect(
        (await page([revision], retainRecord: (_) => false)).changedCount,
        0,
      );
      expect(notifications, 1);
    },
  );

  test(
    'range restores equal-version bodies and photos without moving cursor',
    () async {
      final archived = _record('archived', withPhoto: true);
      await seed(archived, version: 3);
      await evict(archived.id);
      await seed(_record('outside-range'));
      await page([], position: 9);

      final result = await range([
        _active(_record(archived.id, location: 'Historical'), version: 3),
      ]);

      expect(result.applied, isTrue);
      expect(result.changedCount, 1);
      final restored = records.getRecordById(archived.id)!;
      expect(restored.location, 'Historical');
      expect(restored.photos.single.toJson(), archived.photos.single.toJson());
      expect(
        (await store.readRecordForOwner(
          owner,
          archived.id,
        ))!.photos.single.toJson(),
        archived.photos.single.toJson(),
      );
      expect(records.getRecordById('outside-range'), isNotNull);
      expect((await records.readSyncCheckpoint(owner))!.cursor.seconds, 9);
      expect(
        (await store.readRecordSyncMetadata(
          owner,
          archived.id,
        ))!.serverVersionNo,
        3,
      );
    },
  );

  test(
    'stale range bodies and tombstones cannot replace a newer archive',
    () async {
      final archived = _record('newer', withPhoto: true);
      await seed(archived, version: 4);
      await evict(archived.id);

      final result = await range([
        _active(_record(archived.id, location: 'Stale'), version: 3),
        _deleted(archived.id, version: 2),
      ]);

      expect(result.applied, isTrue);
      expect(result.changedCount, 0);
      expect(await store.readRecordForOwner(owner, archived.id), isNull);
      expect(
        await store.readArchivedPhotosForRecord(owner, archived.id),
        hasLength(1),
      );
      final metadata = (await store.readRecordSyncMetadata(
        owner,
        archived.id,
      ))!;
      expect(metadata.serverVersionNo, 4);
      expect(metadata.remoteStatus, RemoteRecordStatus.active);
      expect(await records.readSyncCheckpoint(owner), isNull);
    },
  );

  test(
    'tombstone clears archive-only photos and keeps deleted version',
    () async {
      final archived = _record('deleted', withPhoto: true);
      await seed(archived);
      await evict(archived.id);

      final result = await page([_deleted(archived.id, version: 2)]);

      expect(result.applied, isTrue);
      expect(result.changedCount, 0);
      expect(
        await store.readArchivedPhotosForRecord(owner, archived.id),
        isEmpty,
      );
      final metadata = (await store.readRecordSyncMetadata(
        owner,
        archived.id,
      ))!;
      expect(metadata.serverVersionNo, 2);
      expect(metadata.remoteStatus, RemoteRecordStatus.deleted);
      expect((await records.readSyncCheckpoint(owner))!.cursor.seconds, 2);
    },
  );

  test(
    'full snapshot removes missing archives only for the selected owner',
    () async {
      await seed(_record('missing', withPhoto: true));
      await seed(_record('known', withPhoto: true));
      await evict('missing');
      await evict('known');
      const otherOwner = 'user:other-cache-owner';
      await seed(_record('missing', withPhoto: true), ownerKey: otherOwner);
      await evict('missing', ownerKey: otherOwner);

      final applied = await records.replaceWithRemoteSnapshot(
        RemoteRecordSnapshot(revisions: [_active(_record('known'))]),
        ownerKey: owner,
        checkpoint: _checkpoint(5),
        retainRecord: (_) => false,
      );

      expect(applied, isTrue);
      expect(
        await store.readArchivedPhotosForRecord(owner, 'missing'),
        isEmpty,
      );
      expect(await store.readRecordSyncMetadata(owner, 'missing'), isNull);
      expect(
        await store.readArchivedPhotosForRecord(owner, 'known'),
        hasLength(1),
      );
      expect(await store.readRecordForOwner(owner, 'known'), isNull);
      expect(
        await store.readArchivedPhotosForRecord(otherOwner, 'missing'),
        hasLength(1),
      );
      expect(
        await store.readRecordSyncMetadata(otherOwner, 'missing'),
        isNotNull,
      );
    },
  );

  for (final guard in ['outbox', 'conflict', 'free journal']) {
    test(
      'range skips $guard ID while applying unrelated historical data',
      () async {
        final protected = _record('protected', withPhoto: true);
        await seed(protected);
        final safe = _record('safe', withPhoto: true);
        await seed(safe);
        await evict(safe.id);
        await page([], position: 8);
        await AppDatabase.instance.transaction((transaction) async {
          switch (guard) {
            case 'outbox':
              await store.insertOutboxItem(
                transaction,
                ownerKey: owner,
                item: OutboxItem(
                  id: 'pending',
                  recordId: protected.id,
                  operationType: OutboxOperationType.update,
                  status: OutboxStatus.pending,
                  createdAt: DateTime(2026, 10, 26),
                  payload: protected.toJson(),
                ),
              );
            case 'conflict':
              await store.insertConflict(
                transaction,
                conflict: ConflictItem(
                  id: 'unresolved',
                  ownerKey: owner,
                  recordId: protected.id,
                  outboxId: 'previous',
                  localOperationType: OutboxOperationType.update,
                  baseVersionNo: 0,
                  remoteVersionNo: 1,
                  remoteStatus: RemoteRecordStatus.active,
                  localRecord: protected,
                  remoteRecord: protected,
                  occurredAt: DateTime(2026, 10, 26),
                  status: ConflictStatus.unresolved,
                ),
              );
            case 'free journal':
              await store.writeLocalRecordChange(
                transaction,
                ownerKey: owner,
                record: protected,
                deleted: false,
              );
          }
        });
        final revisions = [
          _active(
            _record(protected.id, location: 'Must not replace'),
            version: 2,
          ),
          _active(
            _record(safe.id, location: 'Historical server body'),
            version: 2,
          ),
        ];

        // Incremental pulls retain their existing all-or-nothing intent guard.
        expect((await page(revisions, position: 9)).applied, isFalse);
        final result = await range(revisions);

        expect(result.applied, isTrue);
        expect(result.changedCount, 1);
        expect(
          records.getRecordById(protected.id)!.toJson(),
          protected.toJson(),
        );
        expect(
          (await store.readRecordSyncMetadata(
            owner,
            protected.id,
          ))!.serverVersionNo,
          1,
        );
        final hydrated = records.getRecordById(safe.id)!;
        expect(hydrated.location, 'Historical server body');
        expect(hydrated.photos.single.toJson(), safe.photos.single.toJson());
        expect(
          (await store.readRecordSyncMetadata(owner, safe.id))!.serverVersionNo,
          2,
        );
        expect((await records.readSyncCheckpoint(owner))!.cursor.seconds, 8);
      },
    );
  }

  final rangeFrom = DateTime(2026, 10);
  final rangeTo = DateTime(2026, 11);
  Future<Map<String, int>> capture() => records.captureRemoteRangeVersions(
    ownerKey: owner,
    from: rangeFrom,
    to: rangeTo,
    isCurrentSession: () => true,
  );
  Future<RecordPageApplyResult> reconcile(
    Map<String, int> expected, {
    Set<String> known = const {},
    bool Function()? isCurrentSession,
  }) => records.reconcileRemoteRange(
    ownerKey: owner,
    from: rangeFrom,
    to: rangeTo,
    expectedVersions: expected,
    knownRecordIds: known,
    isCurrentSession: isCurrentSession ?? () => true,
  );

  test(
    'range capture uses durable owner versions and exact overlap bounds',
    () async {
      await seed(_record('inside'), version: 3);
      await seed(
        _record(
          'spanning',
          startAt: DateTime(2026, 9, 29),
          endAt: DateTime(2026, 11, 2),
        ),
        version: 4,
      );
      await seed(
        _record(
          'midnight',
          startAt: DateTime(2026, 9, 30, 18),
          endAt: rangeFrom,
        ),
      );
      await seed(_record('next-month', startAt: rangeTo));
      await seed(_record('unsynced'), version: 0);
      await seed(_record('other-owner'), ownerKey: 'user:other-range-owner');
      await AppDatabase.instance.transaction(
        (transaction) => store.insertRecord(
          transaction,
          ownerKey: owner,
          record: _record('unversioned'),
        ),
      );
      records.clearCacheOnlyForTesting();

      expect(await capture(), {'inside': 3, 'spanning': 4});
      expect(
        await records.captureRemoteRangeVersions(
          ownerKey: owner,
          from: rangeFrom,
          to: rangeTo,
          isCurrentSession: () => false,
        ),
        isEmpty,
      );
    },
  );

  test(
    'missing range bodies are evicted without changing archives or progress',
    () async {
      await seed(_record('missing', withPhoto: true), version: 2);
      await seed(_record('known', withPhoto: true));
      await seed(_record('outside', startAt: DateTime(2026, 11, 2)));
      const otherOwner = 'user:other-range-owner';
      await seed(_record('missing', withPhoto: true), ownerKey: otherOwner);
      await page([], position: 9);
      final expected = await capture();
      final beforeMetadata = await _persistentTable(
        AppDatabase.recordSyncStatesTable,
      );
      final beforeProgress = await _persistentTable(
        AppDatabase.localMetadataTable,
      );
      final beforePhotos = await _persistentTable(
        AppDatabase.recordPhotoArchivesTable,
      );
      var notifications = 0;
      void listener() => notifications++;
      records.addListener(listener);
      addTearDown(() => records.removeListener(listener));

      final result = await reconcile(expected, known: {'known'});

      expect(result.applied, isTrue);
      expect(result.changedCount, 1);
      expect(records.getRecordById('missing'), isNull);
      expect(records.getRecordById('known'), isNotNull);
      expect(records.getRecordById('outside'), isNotNull);
      expect(await store.readRecordForOwner(otherOwner, 'missing'), isNotNull);
      expect(
        await _persistentTable(AppDatabase.recordSyncStatesTable),
        beforeMetadata,
      );
      expect(
        await _persistentTable(AppDatabase.localMetadataTable),
        beforeProgress,
      );
      expect(
        await _persistentTable(AppDatabase.recordPhotoArchivesTable),
        beforePhotos,
      );
      expect(notifications, 1);
      expect((await reconcile(expected, known: {'known'})).changedCount, 0);
      expect(notifications, 1);
    },
  );

  test(
    'range reconciliation protects bodies added or updated after capture',
    () async {
      await seed(_record('updated'), version: 1);
      await seed(_record('unchanged'), version: 1);
      final expected = await capture();
      await range([
        _active(_record('updated', location: 'New server version'), version: 2),
      ]);
      await range([_active(_record('new-during-query'), version: 1)]);

      final result = await reconcile(expected);

      expect(result.changedCount, 1);
      expect(records.getRecordById('unchanged'), isNull);
      expect(records.getRecordById('updated')!.location, 'New server version');
      expect(records.getRecordById('new-during-query'), isNotNull);
      expect(
        (await store.readRecordSyncMetadata(owner, 'updated'))!.serverVersionNo,
        2,
      );
    },
  );

  test(
    'range reconciliation preserves pending intent and unsafe metadata',
    () async {
      for (final id in [
        'outbox',
        'conflict',
        'journal',
        'ahead',
        'zero',
        'deleted',
        'safe',
      ]) {
        await seed(_record(id), version: id == 'zero' ? 0 : 1);
      }
      await AppDatabase.instance.transaction((transaction) async {
        await store.insertRecord(
          transaction,
          ownerKey: owner,
          record: _record('no-metadata'),
        );
        await store.insertOutboxItem(
          transaction,
          ownerKey: owner,
          item: OutboxItem(
            id: 'pending-range',
            recordId: 'outbox',
            operationType: OutboxOperationType.update,
            status: OutboxStatus.pending,
            createdAt: DateTime(2026, 10, 26),
            payload: _record('outbox').toJson(),
          ),
        );
        await store.insertConflict(
          transaction,
          conflict: ConflictItem(
            id: 'range-conflict',
            ownerKey: owner,
            recordId: 'conflict',
            outboxId: 'previous',
            localOperationType: OutboxOperationType.update,
            baseVersionNo: 0,
            remoteVersionNo: 1,
            remoteStatus: RemoteRecordStatus.active,
            localRecord: _record('conflict'),
            remoteRecord: _record('conflict'),
            occurredAt: DateTime(2026, 10, 26),
            status: ConflictStatus.unresolved,
          ),
        );
        await store.writeLocalRecordChange(
          transaction,
          ownerKey: owner,
          record: _record('journal'),
          deleted: false,
        );
        await store.writeRecordSyncMetadata(
          transaction,
          ownerKey: owner,
          metadata: const RecordSyncMetadata(
            recordId: 'ahead',
            serverVersionNo: 1,
            optimisticVersionNo: 2,
            remoteStatus: RemoteRecordStatus.active,
          ),
          resetOptimisticVersion: true,
        );
        await store.writeRecordSyncMetadata(
          transaction,
          ownerKey: owner,
          metadata: const RecordSyncMetadata(
            recordId: 'deleted',
            serverVersionNo: 1,
            optimisticVersionNo: 1,
            remoteStatus: RemoteRecordStatus.deleted,
          ),
          resetOptimisticVersion: true,
        );
      });
      await records.reloadOwner(owner);

      final result = await reconcile({
        ...await capture(),
        'zero': 0,
        'no-metadata': 1,
      });

      expect(result.changedCount, 1);
      expect(records.getRecordById('safe'), isNull);
      expect(records.getAllRecords().map((record) => record.id).toSet(), {
        'outbox',
        'conflict',
        'journal',
        'ahead',
        'zero',
        'deleted',
        'no-metadata',
      });
    },
  );

  test(
    'range reconciliation cancellation rolls back a completed body delete',
    () async {
      await seed(_record('cancelled', withPhoto: true));
      final expected = await capture();
      final before = await _persistentState();
      var checks = 0;

      final result = await reconcile(
        expected,
        isCurrentSession: () => ++checks < 5,
      );

      expect(checks, 5);
      expect(result.applied, isFalse);
      expect(result.changedCount, 0);
      expect(await _persistentState(), before);
      expect(records.getRecordById('cancelled'), isNotNull);
    },
  );

  test(
    'range reconciliation publishes remaining durable bodies for a cold owner',
    () async {
      await seed(_record('missing'));
      await seed(_record('retained'));
      final expected = await capture();
      records.clearCacheOnlyForTesting();

      final result = await reconcile(expected, known: {'retained'});

      expect(result.changedCount, 1);
      expect(records.getAllRecords().map((record) => record.id), ['retained']);
      expect(await store.readRecordForOwner(owner, 'missing'), isNull);
    },
  );

  test(
    'session generation change rolls back eviction, versions and cursor',
    () async {
      final original = _record('rollback', withPhoto: true);
      await seed(original);
      await page([], position: 1);
      final before = await _persistentState();
      var generation = 1;
      final capturedGeneration = generation;

      final result = await page(
        [_active(_record(original.id, location: 'Wrong session'), version: 2)],
        retainRecord: (_) {
          // Even an A -> B -> A transition must invalidate the captured session.
          generation += 2;
          return false;
        },
        isCurrentSession: () => generation == capturedGeneration,
      );

      expect(result.applied, isFalse);
      expect(result.changedCount, 0);
      expect(await _persistentState(), before);
      expect(records.getRecordById(original.id)!.toJson(), original.toJson());
    },
  );
}

RecordSyncCheckpoint _checkpoint(int seconds) => RecordSyncCheckpoint(
  cursor: RecordSyncCursor(seconds: seconds, nanoseconds: 50, recordId: 'last'),
  lastFullSyncAt: DateTime.utc(2026, 10, 26),
);

RemoteRecordRevision _active(FishingRecord record, {int version = 1}) =>
    RemoteRecordRevision(
      recordId: record.id,
      versionNo: version,
      status: RemoteRecordStatus.active,
      record: record,
    );

RemoteRecordRevision _deleted(String id, {int version = 1}) =>
    RemoteRecordRevision(
      recordId: id,
      versionNo: version,
      status: RemoteRecordStatus.deleted,
      record: null,
    );

FishingRecord _record(
  String id, {
  String location = 'Original',
  DateTime? startAt,
  DateTime? endAt,
  bool withPhoto = false,
}) {
  final start = startAt ?? DateTime(2026, 10, 21, 18);
  return FishingRecord(
    id: id,
    location: location,
    startAt: start,
    endAt: endAt ?? start.add(const Duration(hours: 9)),
    genreName: 'Lure',
    catches: const [CatchRecord(speciesName: 'Rockfish', lengthCm: 31)],
    photos: [
      if (withPhoto)
        const RecordPhoto(
          id: 'local-photo',
          localPath: 'C:/device/original.jpg',
          contentType: 'image/jpeg',
          sizeBytes: 1200,
          checksum: 'local-original',
        ),
    ],
  );
}

Future<Map<String, List<Map<String, Object?>>>> _persistentState() async {
  final database = await AppDatabase.instance.database;
  return {
    for (final table in [
      AppDatabase.fishingRecordsTable,
      AppDatabase.recordCatchesTable,
      AppDatabase.recordPhotosTable,
      AppDatabase.recordPhotoArchivesTable,
      AppDatabase.recordSyncStatesTable,
      AppDatabase.localMetadataTable,
    ])
      table: await database.query(table, orderBy: 'rowid'),
  };
}

Future<List<Map<String, Object?>>> _persistentTable(String table) async {
  final database = await AppDatabase.instance.database;
  return database.query(table, orderBy: 'rowid');
}
