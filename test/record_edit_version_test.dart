import 'package:fishing_build/data/local/app_database.dart';
import 'package:fishing_build/data/local/local_data_store.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/outbox_item.dart';
import 'package:fishing_build/data/models/record_edit_snapshot.dart';
import 'package:fishing_build/data/models/record_sync_metadata.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/conflict_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/repositories/outbox_repository.dart';
import 'package:fishing_build/data/services/record_mutation_service.dart';
import 'package:fishing_build/data/services/record_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_record_sync_gateway.dart';
import 'support/test_database.dart';

void main() {
  final auth = AuthSessionRepository.instance;
  final records = FishingRecordRepository.instance;
  final mutations = RecordMutationService.instance;
  final sync = RecordSyncService.instance;
  final store = LocalDataStore.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await sync.resetForTesting();
    await resetTestDatabase();
    auth.clearMemoryOnlyForTesting();
    records.clearCacheOnlyForTesting();
    OutboxRepository.instance.clearCacheOnlyForTesting();
    ConflictRepository.instance.clearCacheOnlyForTesting();
  });

  tearDown(() async {
    await sync.resetForTesting();
  });

  Future<FakeRecordSyncGateway> pullOriginal(FishingRecord original) async {
    await auth.setSessionForTesting(
      plan: UserPlan.paid,
      email: 'editor@example.com',
    );
    await records.addRecord(original);
    final gateway = FakeRecordSyncGateway()
      ..seedActive(auth.memberId!, original, versionNo: 1);
    sync.configureGateway(gateway);
    expect((await sync.syncNow()).isSuccess, isTrue);
    expect(records.getRecordById(original.id)?.location, original.location);
    return gateway;
  }

  Future<void> expectAtomicRejection(
    FishingRecord edited,
    RecordEditSnapshot snapshot,
    RecordEditConflictReason reason,
  ) async {
    final before = await _persistentState(auth.dataOwnerKey);
    await expectLater(
      mutations.updateRecord(edited, expectedSnapshot: snapshot),
      throwsA(
        isA<RecordEditConflictException>().having(
          (error) => error.reason,
          'reason',
          reason,
        ),
      ),
    );
    expect(await _persistentState(auth.dataOwnerKey), before);
  }

  test(
    'a pulled remote edit cannot be overwritten by the old editor',
    () async {
      final original = _record('remote-edit');
      final gateway = await pullOriginal(original);
      final snapshot = await mutations.beginEditingRecord(original);

      gateway.seedActive(
        auth.memberId!,
        _record(original.id, location: 'Other device'),
      );
      expect((await sync.syncNow()).isSuccess, isTrue);

      await expectAtomicRejection(
        _record(original.id, location: 'Stale editor'),
        snapshot,
        RecordEditConflictReason.changed,
      );
      expect(records.getRecordById(original.id)?.location, 'Other device');
      expect(gateway.version(auth.memberId!, original.id), 2);
    },
  );

  test('a newer revision with the same body invalidates the editor', () async {
    final original = _record('same-body');
    final gateway = await pullOriginal(original);
    final snapshot = await mutations.beginEditingRecord(original);

    gateway.seedActive(auth.memberId!, original);
    expect((await sync.syncNow()).isSuccess, isTrue);
    expect(records.getRecordById(original.id)!.toJson(), original.toJson());

    await expectAtomicRejection(
      _record(original.id, location: 'Stale editor'),
      snapshot,
      RecordEditConflictReason.changed,
    );
  });

  test(
    'opening a stale displayed record cannot capture the new revision',
    () async {
      final original = _record('stale-display');
      final gateway = await pullOriginal(original);
      gateway.seedActive(
        auth.memberId!,
        _record(original.id, location: 'Newer before editor opens'),
      );
      expect((await sync.syncNow()).isSuccess, isTrue);
      final before = await _persistentState(auth.dataOwnerKey);

      await expectLater(
        mutations.beginEditingRecord(original),
        throwsA(
          isA<RecordEditConflictException>().having(
            (error) => error.reason,
            'reason',
            RecordEditConflictReason.changed,
          ),
        ),
      );

      expect(await _persistentState(auth.dataOwnerKey), before);
    },
  );

  test('a pulled tombstone cannot be resurrected by the editor', () async {
    final original = _record('remote-delete');
    final gateway = await pullOriginal(original);
    final snapshot = await mutations.beginEditingRecord(original);

    gateway.seedDeleted(auth.memberId!, original.id);
    expect((await sync.syncNow()).isSuccess, isTrue);
    expect(records.getRecordById(original.id), isNull);

    await expectAtomicRejection(
      _record(original.id, location: 'Stale editor'),
      snapshot,
      RecordEditConflictReason.deleted,
    );
    expect(records.getRecordById(original.id), isNull);
    expect(
      gateway.status(auth.memberId!, original.id),
      RemoteRecordStatus.deleted,
    );
  });

  test(
    'a free member local edit invalidates another editor atomically',
    () async {
      await auth.setSessionForTesting(
        plan: UserPlan.free,
        email: 'local-editor@example.com',
      );
      final original = _record('local-edit');
      await mutations.addRecord(original);
      final firstEditor = await mutations.beginEditingRecord(original);
      final secondEditor = await mutations.beginEditingRecord(original);

      await mutations.updateRecord(
        _record(original.id, location: 'First editor saved'),
        expectedSnapshot: firstEditor,
      );

      await expectAtomicRejection(
        _record(original.id, location: 'Second editor stale'),
        secondEditor,
        RecordEditConflictReason.changed,
      );
      expect(
        records.getRecordById(original.id)?.location,
        'First editor saved',
      );
      final changes = await store.readLocalRecordChangesForOwner(
        auth.dataOwnerKey,
      );
      expect(changes.single.payload['location'], 'First editor saved');
    },
  );

  for (final changedTable in <String>[
    AppDatabase.recordCatchesTable,
    AppDatabase.recordPhotosTable,
  ]) {
    test(
      'persistent $changedTable changes are checked despite a stale cache',
      () async {
        await auth.setSessionForTesting(
          plan: UserPlan.paid,
          email: 'persistent-editor@example.com',
        );
        final original = _record('persistent-change');
        await records.addRecord(original);
        final snapshot = await mutations.beginEditingRecord(original);
        final database = await AppDatabase.instance.database;
        await database.update(
          changedTable,
          changedTable == AppDatabase.recordCatchesTable
              ? <String, Object?>{'length_cm': 99.0}
              : <String, Object?>{
                  'checksum':
                      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
                },
          where: 'owner_key = ? AND record_id = ?',
          whereArgs: <Object?>[auth.dataOwnerKey, original.id],
        );
        expect(records.getRecordById(original.id)!.toJson(), original.toJson());

        await expectAtomicRejection(
          _record(original.id, location: 'Stale editor'),
          snapshot,
          RecordEditConflictReason.changed,
        );
      },
    );
  }

  test('switching from A to B and back invalidates the A editor', () async {
    await auth.setSessionForTesting(
      plan: UserPlan.paid,
      email: 'a@example.com',
    );
    final original = _record('shared-id');
    await records.addRecord(original);
    final snapshot = await mutations.beginEditingRecord(original);
    final ownerA = auth.dataOwnerKey;

    await auth.setSessionForTesting(
      plan: UserPlan.paid,
      email: 'b@example.com',
    );
    await records.addRecord(_record(original.id, location: 'Account B'));
    final ownerB = auth.dataOwnerKey;
    final stateB = await _persistentState(ownerB);
    await auth.setSessionForTesting(
      plan: UserPlan.paid,
      email: 'a@example.com',
    );
    expect(auth.dataOwnerKey, ownerA);
    expect(auth.sessionGeneration, isNot(snapshot.sessionGeneration));

    await expectAtomicRejection(
      _record(original.id, location: 'Stale A editor'),
      snapshot,
      RecordEditConflictReason.sessionChanged,
    );
    expect(await _persistentState(ownerB), stateB);
    expect(records.getRecordById(original.id)!.toJson(), original.toJson());
  });

  test('an ordinary acknowledgement keeps an open editor valid', () async {
    await auth.setSessionForTesting(
      plan: UserPlan.paid,
      email: 'ack-editor@example.com',
    );
    final original = _record('ack-edit');
    await mutations.addRecord(original);
    await sync.syncNow();
    final snapshot = await mutations.beginEditingRecord(original);
    final beforeAck = (await store.readRecordSyncMetadata(
      auth.dataOwnerKey,
      original.id,
    ))!;
    expect(beforeAck.serverVersionNo, 0);
    expect(beforeAck.optimisticVersionNo, 1);

    final gateway = FakeRecordSyncGateway();
    sync.configureGateway(gateway);
    expect((await sync.syncNow()).isSuccess, isTrue);
    final afterAck = (await store.readRecordSyncMetadata(
      auth.dataOwnerKey,
      original.id,
    ))!;
    expect(afterAck.serverVersionNo, 1);
    expect(afterAck.optimisticVersionNo, beforeAck.optimisticVersionNo);
    sync.configureGateway(null);

    final edited = _record(
      original.id,
      location: 'Saved after acknowledgement',
    );
    await mutations.updateRecord(edited, expectedSnapshot: snapshot);
    await sync.syncNow();

    expect(records.getRecordById(original.id)!.toJson(), edited.toJson());
    final pending = OutboxRepository.instance.getAllItems().where(
      (item) => item.status == OutboxStatus.pending,
    );
    expect(pending, hasLength(1));
    expect(pending.single.baseVersionNo, 1);
    expect(pending.single.operationType, OutboxOperationType.update);
  });
}

Future<Map<String, List<Map<String, Object?>>>> _persistentState(
  String ownerKey,
) async {
  final database = await AppDatabase.instance.database;
  final result = <String, List<Map<String, Object?>>>{};
  for (final table in <String>[
    AppDatabase.fishingRecordsTable,
    AppDatabase.recordCatchesTable,
    AppDatabase.recordPhotosTable,
    AppDatabase.outboxItemsTable,
    AppDatabase.recordSyncStatesTable,
    AppDatabase.localRecordChangesTable,
  ]) {
    result[table] = await database.query(
      table,
      where: 'owner_key = ?',
      whereArgs: <Object?>[ownerKey],
      orderBy: 'rowid',
    );
  }
  return result;
}

FishingRecord _record(String id, {String location = 'Original harbor'}) {
  return FishingRecord(
    id: id,
    location: location,
    startAt: DateTime(2026, 9, 22, 8),
    endAt: DateTime(2026, 9, 22, 10),
    genreName: 'Sea fishing',
    tide: '3',
    weather: 'Clear',
    airTemperature: 24,
    waterTemperature: 20,
    catches: const <CatchRecord>[
      CatchRecord(speciesName: 'Rockfish', lengthCm: 31, weightG: 820),
    ],
    photos: const <RecordPhoto>[
      RecordPhoto(
        id: 'photo-1',
        localPath: 'C:/device/catch.jpg',
        contentType: 'image/jpeg',
        sizeBytes: 100,
        checksum:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      ),
    ],
    memo: 'Editor regression test',
  );
}
