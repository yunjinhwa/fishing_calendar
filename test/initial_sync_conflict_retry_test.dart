import 'dart:async';

import 'package:fishing_build/data/local/app_database.dart';
import 'package:fishing_build/data/local/local_data_store.dart';
import 'package:fishing_build/data/models/conflict_item.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/outbox_item.dart';
import 'package:fishing_build/data/models/record_sync_metadata.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/remote/record_sync_gateway.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/conflict_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/repositories/outbox_repository.dart';
import 'package:fishing_build/data/services/conflict_resolution_service.dart';
import 'package:fishing_build/data/services/plan_policy_service.dart';
import 'package:fishing_build/data/services/record_mutation_service.dart';
import 'package:fishing_build/data/services/record_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_record_sync_gateway.dart';
import 'support/test_database.dart';

void main() {
  final auth = AuthSessionRepository.instance;
  final records = FishingRecordRepository.instance;
  final outbox = OutboxRepository.instance;
  final conflicts = ConflictRepository.instance;
  final sync = RecordSyncService.instance;
  final mutations = RecordMutationService.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await sync.resetForTesting();
    await resetTestDatabase();
    auth.resetAuthGatewayForTesting();
    records.clearCacheOnlyForTesting();
    outbox.clearCacheOnlyForTesting();
    conflicts.clearCacheOnlyForTesting();
  });

  tearDown(() async {
    await sync.resetForTesting();
    auth.resetAuthGatewayForTesting();
    await AppDatabase.instance.close();
  });

  test(
    'migration completion publishes repaired terminal state to the cache',
    () async {
      final fixture = await _migrationConflict('cache-repair');
      await ConflictResolutionService.instance.useTheirs(fixture.conflict);
      final source = outbox.getAllItems().single;
      await outbox.replaceItem(source.copyWith(status: OutboxStatus.sending));
      await auth.changeMemberPlan(
        UserPlan.paid,
        migrationStatus: PlanMigrationStatus.localToCloudPending,
      );
      expect(outbox.hasUnfinishedItems, isTrue);

      await PlanPolicyService.instance.completeMigrationIfPossible();

      expect(auth.isPlanMigrationPending, isFalse);
      expect(outbox.hasUnfinishedItems, isFalse);
      expect(outbox.getAllItems().single.status, OutboxStatus.succeeded);
      expect(records.getRecordById(fixture.record.id)?.location, 'Server port');
    },
  );

  for (final replaceGateway in [false, true]) {
    final caseId = replaceGateway ? 'gateway-change' : 'session-cycle';
    test('server adoption stops after $caseId during revision fetch', () async {
      final fixture = await _migrationConflict(caseId);
      final uid = auth.memberId!;
      final gateway = _DelayedRevisionGateway()
        ..seedActive(uid, _record(fixture.record.id, location: 'Server port'));
      sync.configureGateway(gateway);
      final choice = expectLater(
        ConflictResolutionService.instance.useTheirs(fixture.conflict),
        throwsStateError,
      );
      await gateway.started.future;
      try {
        if (replaceGateway) {
          sync.configureGateway(FakeRecordSyncGateway());
        } else {
          await auth.setSessionForTesting(
            plan: UserPlan.paid,
            email: 'other@example.com',
          );
          await auth.setSessionForTesting(
            plan: UserPlan.paid,
            email: '$caseId@example.com',
          );
          expect(auth.memberId, uid);
        }
      } finally {
        gateway.release.complete();
      }
      await choice;
      expect(records.getRecordById(fixture.record.id)?.location, 'Local port');
      expect(conflicts.getPendingItems().single.id, fixture.conflict.id);
    });
  }

  test(
    'initial migration server choice survives retry and later uploads',
    () async {
      final fixture = await _migrationConflict('retry');
      final sourceId = fixture.conflict.outboxId;
      final uid = auth.memberId!;

      await ConflictResolutionService.instance.useTheirs(fixture.conflict);

      expect(auth.isPlanMigrationPending, isFalse);
      expect(auth.canUseCloudSync, isTrue);
      expect(records.getRecordById(fixture.record.id)?.location, 'Server port');
      expect(
        records.getRecordById(fixture.record.id)?.photoPaths,
        fixture.record.photoPaths,
      );
      fixture.gateway.pushedOutboxIds.clear();

      final retry = await sync.syncNow();

      expect(retry.isSuccess, isTrue);
      expect(retry.pushedCount, 0);
      expect(fixture.gateway.pushedOutboxIds, isEmpty);
      expect(conflicts.getPendingItems(), isEmpty);
      expect(fixture.gateway.version(uid, fixture.record.id), 1);

      await _reloadSession(fixture.gateway);
      expect((await sync.syncNow()).isSuccess, isTrue);
      expect(fixture.gateway.pushedOutboxIds, isEmpty);

      // A completed first sync must leave unrelated new mutations uploadable.
      sync.configureGateway(null);
      final later = _record('later-record', location: 'Later port');
      await mutations.addRecord(later);
      await sync.syncNow();
      final laterId = outbox.getAllItems().last.id;
      sync.configureGateway(fixture.gateway);

      expect((await sync.syncNow()).isSuccess, isTrue);
      expect(fixture.gateway.pushedOutboxIds, <String>[laterId]);
      expect(fixture.gateway.pushedOutboxIds, isNot(contains(sourceId)));
      expect(fixture.gateway.record(uid, later.id)?.location, later.location);
      expect(records.getRecordById(fixture.record.id)?.location, 'Server port');
      expect(conflicts.getPendingItems(), isEmpty);
    },
  );

  test(
    'initial migration server choice survives reload before retry',
    () async {
      final fixture = await _migrationConflict('reload');
      await ConflictResolutionService.instance.useTheirs(fixture.conflict);
      fixture.gateway.pushedOutboxIds.clear();

      // Keep the memory SQLite database while discarding every session/cache.
      await _reloadSession(fixture.gateway);

      expect(auth.isPlanMigrationPending, isFalse);
      expect(conflicts.getAllItems().single.status, ConflictStatus.resolved);
      expect(
        conflicts.getAllItems().single.resolutionType,
        ConflictResolutionType.useTheirs,
      );
      expect((await sync.syncNow()).isSuccess, isTrue);
      expect(fixture.gateway.pushedOutboxIds, isEmpty);
      expect(records.getRecordById(fixture.record.id)?.location, 'Server port');
      expect(conflicts.getPendingItems(), isEmpty);
    },
  );

  test('server choice finishes a conflicted migration deletion', () async {
    await auth.setSessionForTesting(
      plan: UserPlan.free,
      email: 'migration-delete@example.com',
    );
    final record = _record('migration-delete', location: 'Old local port');
    await mutations.addRecord(record);
    await AppDatabase.instance.transaction((transaction) {
      return LocalDataStore.instance.writeRecordSyncMetadata(
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
    await mutations.deleteRecord(record.id);
    await PlanPolicyService.instance.changePlan(UserPlan.paid);
    final source = outbox.getAllItems().single;
    expect(source.operationType, OutboxOperationType.delete);
    expect(source.isMigration, isTrue);
    expect(source.baseVersionNo, 1);
    final uid = auth.memberId!;
    final gateway = FakeRecordSyncGateway()
      ..seedActive(
        uid,
        _record(record.id, location: 'Restored server port'),
        versionNo: 2,
      );
    sync.configureGateway(gateway);
    expect((await sync.syncNow()).isSuccess, isFalse);

    await ConflictResolutionService.instance.useTheirs(
      conflicts.getPendingItems().single,
    );

    expect(auth.isPlanMigrationPending, isFalse);
    expect(records.getRecordById(record.id)?.location, 'Restored server port');
    expect(outbox.getAllItems().single.id, source.id);
    expect(
      outbox.getAllItems().single.operationType,
      OutboxOperationType.delete,
    );
    gateway.pushedOutboxIds.clear();
    expect((await sync.syncNow()).isSuccess, isTrue);
    expect(gateway.pushedOutboxIds, isEmpty);
    expect(gateway.version(uid, record.id), 2);
    expect(gateway.record(uid, record.id)?.location, 'Restored server port');
    expect(outbox.getAllItems(), hasLength(1));
    expect(conflicts.getPendingItems(), isEmpty);
  });

  test(
    'resolved source evidence is isolated by owner for identical IDs',
    () async {
      final fixture = await _migrationConflict('owner-a');
      final uidA = auth.memberId!;
      await ConflictResolutionService.instance.useTheirs(fixture.conflict);
      final sourceId = fixture.conflict.outboxId;
      sync.configureGateway(null);
      await auth.setSessionForTesting(
        plan: UserPlan.paid,
        email: 'owner-b@example.com',
      );
      final uidB = auth.memberId!;
      final ownerBRecord = _record(fixture.record.id, location: 'Owner B port');
      await AppDatabase.instance.transaction((transaction) async {
        await LocalDataStore.instance.insertRecord(
          transaction,
          ownerKey: auth.dataOwnerKey,
          record: ownerBRecord,
        );
        await LocalDataStore.instance.insertOutboxItem(
          transaction,
          ownerKey: auth.dataOwnerKey,
          item: OutboxItem(
            id: sourceId,
            userId: uidB,
            recordId: ownerBRecord.id,
            operationType: OutboxOperationType.create,
            status: OutboxStatus.succeeded,
            createdAt: DateTime(2026, 9, 22),
            isMigration: true,
            baseVersionNo: 0,
            payload: ownerBRecord.toJson(),
          ),
        );
      });
      await records.loadRecords();
      await outbox.loadItems();
      await conflicts.loadItems();
      fixture.gateway.pushedOutboxIds.clear();
      sync.configureGateway(fixture.gateway);

      final result = await sync.syncNow();

      expect(result.isSuccess, isTrue);
      expect(result.pushedCount, 1);
      expect(fixture.gateway.pushedOutboxIds, <String>[sourceId]);
      expect(
        fixture.gateway.record(uidB, ownerBRecord.id)?.location,
        ownerBRecord.location,
      );
      expect(fixture.gateway.version(uidB, ownerBRecord.id), 1);
      expect(
        fixture.gateway.record(uidA, fixture.record.id)?.location,
        'Server port',
      );
      expect(fixture.gateway.version(uidA, fixture.record.id), 1);
      expect(conflicts.getAllItems(), isEmpty);
    },
  );

  for (final remoteStatus in <RemoteRecordStatus>[
    RemoteRecordStatus.deleted,
    RemoteRecordStatus.missing,
  ]) {
    test(
      'initial migration adopts remote ${remoteStatus.name} without resurrection',
      () async {
        final fixture = await _migrationConflict(remoteStatus.name);
        final uid = auth.memberId!;
        final gateway = remoteStatus == RemoteRecordStatus.missing
            ? FakeRecordSyncGateway()
            : fixture.gateway;
        if (remoteStatus == RemoteRecordStatus.deleted) {
          gateway.seedDeleted(uid, fixture.record.id);
        }
        sync.configureGateway(gateway);

        await ConflictResolutionService.instance.useTheirs(fixture.conflict);
        gateway.pushedOutboxIds.clear();

        expect(auth.isPlanMigrationPending, isFalse);
        expect(records.getRecordById(fixture.record.id), isNull);
        expect((await sync.syncNow()).isSuccess, isTrue);
        expect(gateway.pushedOutboxIds, isEmpty);
        expect(gateway.record(uid, fixture.record.id), isNull);
        expect(
          gateway.status(uid, fixture.record.id),
          remoteStatus == RemoteRecordStatus.missing ? isNull : remoteStatus,
        );

        await _reloadSession(gateway);

        expect((await sync.syncNow()).isSuccess, isTrue);
        expect(records.getRecordById(fixture.record.id), isNull);
        expect(gateway.pushedOutboxIds, isEmpty);
        expect(conflicts.getPendingItems(), isEmpty);
      },
    );
  }

  for (final legacyStatus in <OutboxStatus>[
    OutboxStatus.sending,
    OutboxStatus.failed,
  ]) {
    for (final deleteLater in <bool>[false, true]) {
      final intent = deleteLater ? 'deletion' : 'edit';
      test(
        'resolved migration recovers legacy ${legacyStatus.name} and keeps later $intent',
        () async {
          final fixture = await _migrationConflict(
            'legacy-${legacyStatus.name}-$intent',
          );
          final uid = auth.memberId!;
          await ConflictResolutionService.instance.useTheirs(fixture.conflict);
          final source = outbox.getAllItems().single;
          final adopted = records.getRecordById(fixture.record.id)!;

          sync.configureGateway(null);
          if (deleteLater) {
            await mutations.deleteRecord(fixture.record.id);
          } else {
            await mutations.updateRecord(
              _record(fixture.record.id, location: 'Later local edit'),
            );
          }
          await sync.syncNow();
          final later = outbox.getAllItems().last;
          expect(later.id, isNot(source.id));
          expect(later.baseVersionNo, 1);

          // Older builds persisted a resolved conflict alongside a retried
          // migration request whose base/payload could no longer be replayed.
          await outbox.replaceItem(
            source.copyWith(
              status: legacyStatus,
              baseVersionNo: 0,
              payload: adopted.toJson(),
              errorMessage: legacyStatus == OutboxStatus.failed
                  ? 'Interrupted retry'
                  : null,
            ),
          );
          await _reloadSession(fixture.gateway);
          fixture.gateway.pushedOutboxIds.clear();

          final result = await sync.syncNow();

          expect(result.isSuccess, isTrue);
          expect(result.pushedCount, 1);
          expect(fixture.gateway.pushedOutboxIds, <String>[later.id]);
          expect(
            outbox.getAllItems().any(
              (item) =>
                  item.id == source.id && item.status != OutboxStatus.succeeded,
            ),
            isFalse,
          );
          expect(conflicts.getPendingItems(), isEmpty);
          expect(fixture.gateway.version(uid, fixture.record.id), 2);
          if (deleteLater) {
            expect(records.getRecordById(fixture.record.id), isNull);
            expect(fixture.gateway.record(uid, fixture.record.id), isNull);
            expect(
              fixture.gateway.status(uid, fixture.record.id),
              RemoteRecordStatus.deleted,
            );
          } else {
            expect(
              records.getRecordById(fixture.record.id)?.location,
              'Later local edit',
            );
            expect(
              fixture.gateway.record(uid, fixture.record.id)?.location,
              'Later local edit',
            );
          }

          fixture.gateway.pushedOutboxIds.clear();
          await _reloadSession(fixture.gateway);
          expect((await sync.syncNow()).isSuccess, isTrue);
          expect(fixture.gateway.pushedOutboxIds, isEmpty);
          expect(conflicts.getPendingItems(), isEmpty);
        },
      );
    }
  }
}

Future<
  ({FishingRecord record, ConflictItem conflict, FakeRecordSyncGateway gateway})
>
_migrationConflict(String caseId) async {
  final auth = AuthSessionRepository.instance;
  await auth.setSessionForTesting(
    plan: UserPlan.free,
    email: '$caseId@example.com',
  );
  final record = _record(
    'migration-$caseId',
    location: 'Local port',
    photoPaths: const <String>['C:/device/migration.jpg'],
  );
  await RecordMutationService.instance.addRecord(record);
  await PlanPolicyService.instance.changePlan(UserPlan.paid);
  expect(auth.isPlanMigrationPending, isTrue);
  final migration = OutboxRepository.instance.getAllItems().single;
  expect(migration.isMigration, isTrue);
  expect(migration.baseVersionNo, 0);

  final gateway = FakeRecordSyncGateway()
    ..seedActive(auth.memberId!, _record(record.id, location: 'Server port'));
  RecordSyncService.instance.configureGateway(gateway);
  expect((await RecordSyncService.instance.syncNow()).isSuccess, isFalse);
  final conflict = ConflictRepository.instance.getPendingItems().single;
  expect(conflict.outboxId, migration.id);
  return (record: record, conflict: conflict, gateway: gateway);
}

Future<void> _reloadSession(FakeRecordSyncGateway gateway) async {
  final sync = RecordSyncService.instance;
  final auth = AuthSessionRepository.instance;
  await sync.resetForTesting();
  auth.clearMemoryOnlyForTesting();
  FishingRecordRepository.instance.clearCacheOnlyForTesting();
  OutboxRepository.instance.clearCacheOnlyForTesting();
  ConflictRepository.instance.clearCacheOnlyForTesting();
  await auth.loadSession();
  await FishingRecordRepository.instance.loadRecords();
  await OutboxRepository.instance.loadItems();
  await ConflictRepository.instance.loadItems();
  await RecordMutationService.instance.reconcileOutboxWithLocalRecords();
  await PlanPolicyService.instance.resumePendingMigration();
  sync.configureGateway(gateway);
}

FishingRecord _record(
  String id, {
  String location = 'Test port',
  List<String> photoPaths = const <String>[],
}) => FishingRecord(
  id: id,
  location: location,
  startAt: DateTime(2026, 9, 22, 8),
  endAt: DateTime(2026, 9, 22, 10),
  genreName: 'Sea fishing',
  catches: const <CatchRecord>[
    CatchRecord(speciesName: 'Rockfish', lengthCm: 31, weightG: 820),
  ],
  photoPaths: photoPaths,
);

class _DelayedRevisionGateway extends FakeRecordSyncGateway {
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<RemoteRecordRevision?> fetchRecordRevision({
    required String uid,
    required String recordId,
  }) async {
    started.complete();
    await release.future;
    return super.fetchRecordRevision(uid: uid, recordId: recordId);
  }
}
