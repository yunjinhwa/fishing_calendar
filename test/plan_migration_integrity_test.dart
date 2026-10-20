import 'dart:async';

import 'package:fishing_build/data/local/app_database.dart';
import 'package:fishing_build/data/local/local_data_store.dart';
import 'package:fishing_build/data/local/local_identity_migration_service.dart';
import 'package:fishing_build/data/local/data_owner_key.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/outbox_item.dart';
import 'package:fishing_build/data/models/record_sync_metadata.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/conflict_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/repositories/outbox_repository.dart';
import 'package:fishing_build/data/services/plan_policy_service.dart';
import 'package:fishing_build/data/services/conflict_resolution_service.dart';
import 'package:fishing_build/data/services/record_mutation_service.dart';
import 'package:fishing_build/data/services/record_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_auth_test.dart' show FakeAuthGateway;
import 'support/fake_record_sync_gateway.dart';
import 'support/test_database.dart';

void main() {
  final auth = AuthSessionRepository.instance;
  final records = FishingRecordRepository.instance;
  final outbox = OutboxRepository.instance;
  final plans = PlanPolicyService.instance;
  final mutations = RecordMutationService.instance;
  final sync = RecordSyncService.instance;
  final store = LocalDataStore.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await sync.resetForTesting();
    await resetTestDatabase();
    auth.resetAuthGatewayForTesting();
    records.clearCacheOnlyForTesting();
    outbox.clearCacheOnlyForTesting();
    ConflictRepository.instance.clearCacheOnlyForTesting();
  });

  tearDown(() async {
    await sync.resetForTesting();
    auth.resetAuthGatewayForTesting();
  });

  Future<FakeAuthGateway> paidMember() async {
    final gateway = FakeAuthGateway()
      ..seedEntitlement(uid: 'uid-1', plan: UserPlan.paid);
    auth.configureAuthGateway(gateway);
    await auth.registerAsFree(
      email: 'integrity@example.com',
      password: 'Password1',
      nickname: 'Integrity',
    );
    await records.loadRecords();
    await outbox.loadItems();
    await plans.resumePendingMigration();
    return gateway;
  }

  Future<void> restart() async {
    await sync.resetForTesting();
    auth.clearMemoryOnlyForTesting();
    records.clearCacheOnlyForTesting();
    outbox.clearCacheOnlyForTesting();
    await auth.loadSession();
    await records.loadRecords();
    await outbox.loadItems();
    await mutations.reconcileOutboxWithLocalRecords();
    await plans.resumePendingMigration();
  }

  test(
    'cold paid restoration preserves latest free edit and immutable predecessor',
    () async {
      final gateway = await paidMember();
      await mutations.addRecord(_record('restart', 'paid edit'));
      final original = outbox.getAllItems().single;
      gateway.seedEntitlement(uid: 'uid-1', plan: UserPlan.free);
      await plans.refreshServerPlan();
      await mutations.updateRecord(_record('restart', 'latest free edit'));

      gateway.seedEntitlement(uid: 'uid-1', plan: UserPlan.paid);
      await restart();

      expect(records.getRecordById('restart')!.location, 'latest free edit');
      final items = outbox.getAllItems();
      expect(items, hasLength(2));
      expect(items.first.id, original.id);
      expect(items.first.payload, original.payload);
      expect(items.map((item) => item.baseVersionNo), [0, 1]);
      expect(items.last.payload!['location'], 'latest free edit');
      await restart();
      expect(
        outbox.getAllItems().map((item) => item.id),
        items.map((item) => item.id),
      );

      final server = FakeRecordSyncGateway();
      sync.configureGateway(server);
      expect((await sync.syncNow()).isSuccess, isTrue);
      expect(server.record('uid-1', 'restart')!.location, 'latest free edit');
      expect(auth.isPlanMigrationPending, isFalse);
    },
  );

  test(
    'lost acknowledgement recovers original receipt before sending successor',
    () async {
      final gateway = await paidMember();
      await mutations.addRecord(_record('lost-ack', 'committed edit'));
      final original = outbox.getAllItems().single;
      final server = FakeRecordSyncGateway();
      await outbox.updateItemStatus(
        itemId: original.id,
        status: OutboxStatus.sending,
      );
      // The server commit succeeds; the local client never records its response.
      await server.pushOutboxItem(uid: 'uid-1', item: original);
      gateway.seedEntitlement(uid: 'uid-1', plan: UserPlan.free);
      await plans.refreshServerPlan();
      await mutations.updateRecord(_record('lost-ack', 'new free edit'));
      gateway.seedEntitlement(uid: 'uid-1', plan: UserPlan.paid);
      await restart();
      final items = outbox.getAllItems();
      expect(items.first.id, original.id);
      expect(items.first.payload, original.payload);
      expect(items.first.status, OutboxStatus.sending);
      expect(items.last.id, isNot(original.id));
      expect(items.last.baseVersionNo, 1);
      sync.configureGateway(server);
      expect((await sync.syncNow()).isSuccess, isTrue);
      expect(server.version('uid-1', 'lost-ack'), 2);
      expect(server.record('uid-1', 'lost-ack')!.location, 'new free edit');
    },
  );

  test(
    'free deletion survives restart and propagates only after reupgrade',
    () async {
      final gateway = await paidMember();
      await mutations.addRecord(_record('deleted', 'cloud copy'));
      await sync.syncNow();
      final server = FakeRecordSyncGateway();
      sync.configureGateway(server);
      expect((await sync.syncNow()).isSuccess, isTrue);
      gateway.seedEntitlement(uid: 'uid-1', plan: UserPlan.free);
      await plans.refreshServerPlan();
      final pushCount = server.pushedOutboxIds.length;
      await mutations.deleteRecord('deleted');
      await restart();
      expect(auth.isFree, isTrue);
      expect(records.getRecordById('deleted'), isNull);
      expect(server.status('uid-1', 'deleted'), RemoteRecordStatus.active);
      expect(server.pushedOutboxIds, hasLength(pushCount));
      expect(
        (await store.readLocalRecordChangesForOwner(
          auth.dataOwnerKey,
        )).single.operationType,
        OutboxOperationType.delete,
      );

      gateway.seedEntitlement(uid: 'uid-1', plan: UserPlan.paid);
      await restart();
      expect(records.getRecordById('deleted'), isNull);
      expect(
        outbox.getAllItems().last.operationType,
        OutboxOperationType.delete,
      );
      sync.configureGateway(server);
      expect((await sync.syncNow()).isSuccess, isTrue);
      expect(server.status('uid-1', 'deleted'), RemoteRecordStatus.deleted);
      expect(records.getRecordById('deleted'), isNull);
      expect(
        await store.readLocalRecordChangesForOwner(auth.dataOwnerKey),
        isEmpty,
      );
    },
  );

  test(
    'a request already rewritten by an older build can be resolved with a new ID',
    () async {
      await paidMember();
      await mutations.addRecord(_record('rewritten', 'original server value'));
      await sync.syncNow();
      final original = outbox.getAllItems().single;
      final server = FakeRecordSyncGateway();
      await server.pushOutboxItem(uid: 'uid-1', item: original);
      final desired = _record('rewritten', 'latest local value');
      await records.updateRecord(desired);
      // Simulate persisted data from the old implementation, not a new write.
      await outbox.replaceItem(original.copyWith(payload: desired.toJson()));
      sync.configureGateway(server);
      expect((await sync.syncNow()).failedCount, 1);
      expect(outbox.getAllItems().single.status, OutboxStatus.conflicted);
      final conflict = ConflictRepository.instance.getPendingItems().single;
      expect(conflict.localRecord!.location, 'latest local value');
      expect(conflict.remoteRecord!.location, 'original server value');
      await ConflictResolutionService.instance.useMine(conflict);
      expect((await sync.syncNow()).isSuccess, isTrue);
      expect(outbox.getAllItems().last.id, isNot(original.id));
      expect(
        server.record('uid-1', 'rewritten')!.location,
        'latest local value',
      );
      expect(server.version('uid-1', 'rewritten'), 2);
    },
  );

  test('free-only create then delete needs no cloud mutation', () async {
    await auth.setSessionForTesting(
      plan: UserPlan.free,
      email: 'free@example.com',
    );
    await mutations.addRecord(_record('never-cloud', 'local'));
    await mutations.deleteRecord('never-cloud');
    await plans.changePlan(UserPlan.paid);
    expect(outbox.getAllItems(), isEmpty);
    expect(auth.isPlanMigrationPending, isFalse);
    expect(
      await store.readLocalRecordChangesForOwner(auth.dataOwnerKey),
      isEmpty,
    );
  });

  test(
    'local journal protects a free edit even without a migration status flag',
    () async {
      await auth.setSessionForTesting(
        plan: UserPlan.paid,
        email: 'journal@example.com',
      );
      await mutations.addRecord(_record('journal-record', 'old queued edit'));
      await auth.setSessionForTesting(
        plan: UserPlan.free,
        email: 'journal@example.com',
      );
      await mutations.updateRecord(
        _record('journal-record', 'latest local edit'),
      );
      await auth.setSessionForTesting(
        plan: UserPlan.paid,
        email: 'journal@example.com',
      );
      expect(auth.isPlanMigrationPending, isFalse);
      await mutations.reconcileOutboxWithLocalRecords();
      expect(
        records.getRecordById('journal-record')!.location,
        'latest local edit',
      );
      await plans.resumePendingMigration();
      expect(outbox.getAllItems(), hasLength(2));
      expect(
        outbox.getAllItems().last.payload!['location'],
        'latest local edit',
      );
    },
  );

  for (final keepMine in [true, false]) {
    test(
      'free deletion during an existing conflict respects ${keepMine ? 'mine' : 'server'} resolution',
      () async {
        final gateway = await paidMember();
        await mutations.addRecord(_record('conflict-delete', 'initial'));
        await sync.syncNow();
        final server = FakeRecordSyncGateway();
        sync.configureGateway(server);
        expect((await sync.syncNow()).isSuccess, isTrue);
        sync.configureGateway(null);
        server.seedActive('uid-1', _record('conflict-delete', 'remote newer'));
        await mutations.updateRecord(
          _record('conflict-delete', 'old local edit'),
        );
        await sync.syncNow();
        sync.configureGateway(server);
        expect((await sync.syncNow()).failedCount, 1);
        expect(ConflictRepository.instance.getPendingItems(), hasLength(1));
        gateway.seedEntitlement(uid: 'uid-1', plan: UserPlan.free);
        await plans.refreshServerPlan();
        await mutations.deleteRecord('conflict-delete');
        gateway.seedEntitlement(uid: 'uid-1', plan: UserPlan.paid);
        await plans.refreshServerPlan();
        final conflict = ConflictRepository.instance.getPendingItems().single;
        expect(
          outbox.getAllItems().last.operationType,
          OutboxOperationType.delete,
        );
        expect(
          await store.readLocalRecordChangesForOwner(auth.dataOwnerKey),
          isEmpty,
        );
        if (keepMine) {
          await ConflictResolutionService.instance.useMine(conflict);
        } else {
          await ConflictResolutionService.instance.useTheirs(conflict);
        }
        expect((await sync.syncNow()).isSuccess, isTrue);
        expect(
          server.status('uid-1', 'conflict-delete'),
          keepMine ? RemoteRecordStatus.deleted : RemoteRecordStatus.active,
        );
        expect(
          records.getRecordById('conflict-delete')?.location,
          keepMine ? isNull : 'remote newer',
        );
        expect(auth.isPlanMigrationPending, isFalse);
      },
    );
  }

  test(
    'concurrent migration calls share one transaction and enqueue once',
    () async {
      await auth.setSessionForTesting(
        plan: UserPlan.free,
        email: 'single@example.com',
      );
      await mutations.addRecord(_record('single', 'local'));
      await auth.changeMemberPlan(
        UserPlan.paid,
        migrationStatus: PlanMigrationStatus.localToCloudPending,
      );
      final first = plans.resumePendingMigration();
      final second = plans.resumePendingMigration();
      expect(identical(first, second), isTrue);
      await Future.wait([first, second]);
      await plans.resumePendingMigration();
      expect(outbox.getAllItems(), hasLength(1));
    },
  );

  for (final returnToA in [false, true]) {
    test(
      'queued migration cancels across ${returnToA ? 'A-B-A' : 'A-B'} session switch',
      () async {
        await auth.setSessionForTesting(
          plan: UserPlan.free,
          email: 'a@example.com',
        );
        await mutations.addRecord(_record('a-first', 'A first'));
        await mutations.addRecord(_record('a-second', 'A second'));
        final ownerA = auth.dataOwnerKey;
        await auth.changeMemberPlan(
          UserPlan.paid,
          migrationStatus: PlanMigrationStatus.localToCloudPending,
        );
        final locked = Completer<void>();
        final release = Completer<void>();
        final blocker = AppDatabase.instance.transaction((transaction) async {
          locked.complete();
          await release.future;
        });
        await locked.future;
        final migration = plans.resumePendingMigration();
        await Future<void>.delayed(Duration.zero);
        await auth.setSessionForTesting(
          plan: UserPlan.free,
          email: 'b@example.com',
        );
        final ownerB = auth.dataOwnerKey;
        if (returnToA) {
          await auth.setSessionForTesting(
            plan: UserPlan.paid,
            email: 'a@example.com',
            migrationStatus: PlanMigrationStatus.localToCloudPending,
          );
        }
        release.complete();
        await blocker;
        await migration;
        expect(await store.readOutboxItemsForOwner(ownerA), isEmpty);
        expect(await store.readOutboxItemsForOwner(ownerB), isEmpty);
        expect(auth.email, returnToA ? 'a@example.com' : 'b@example.com');
        expect(auth.isPlanMigrationPending, returnToA);
        if (returnToA) {
          await plans.resumePendingMigration();
          expect(outbox.getAllItems(), hasLength(2));
          expect(
            outbox.getAllItems().every(
              (item) => item.userId == 'a@example.com',
            ),
            isTrue,
          );
        }
      },
    );
  }

  test(
    'account cleanup also removes free change journal for that owner only',
    () async {
      await auth.setSessionForTesting(
        plan: UserPlan.free,
        email: 'cleanup-a@example.com',
      );
      await mutations.addRecord(_record('cleanup-a', 'A'));
      final ownerA = auth.dataOwnerKey;
      await auth.setSessionForTesting(
        plan: UserPlan.free,
        email: 'cleanup-b@example.com',
      );
      await mutations.addRecord(_record('cleanup-b', 'B'));
      final ownerB = auth.dataOwnerKey;
      await AppDatabase.instance.transaction(
        (transaction) => store.deleteOwnerData(transaction, ownerKey: ownerA),
      );
      expect(await store.readLocalRecordChangesForOwner(ownerA), isEmpty);
      expect(await store.readLocalRecordChangesForOwner(ownerB), hasLength(1));
    },
  );

  test('legacy UID migration moves local deletion intent atomically', () async {
    await auth.setSessionForTesting(
      plan: UserPlan.free,
      email: 'legacy-delete@example.com',
    );
    await mutations.addRecord(_record('legacy-delete', 'local'));
    await mutations.deleteRecord('legacy-delete');
    final source = auth.dataOwnerKey;
    final target = DataOwnerKey.firebaseUid('legacy-uid');
    final result = await LocalIdentityMigrationService.instance
        .claimLegacyMemberData(
          firebaseUid: 'legacy-uid',
          authenticatedEmail: 'legacy-delete@example.com',
          allowInitialClaim: true,
        );
    expect(result.migratedLocalChangeCount, 1);
    expect(await store.readLocalRecordChangesForOwner(source), isEmpty);
    expect(
      (await store.readLocalRecordChangesForOwner(target)).single.operationType,
      OutboxOperationType.delete,
    );
  });

  test(
    'legacy deletion intent cannot collide with another UID record',
    () async {
      await auth.setSessionForTesting(
        plan: UserPlan.free,
        email: 'collision@example.com',
      );
      await mutations.addRecord(_record('same-id', 'source'));
      await mutations.deleteRecord('same-id');
      final source = auth.dataOwnerKey;
      final target = DataOwnerKey.firebaseUid('collision-uid');
      await AppDatabase.instance.transaction(
        (transaction) => store.insertRecord(
          transaction,
          ownerKey: target,
          record: _record('same-id', 'target'),
        ),
      );
      await expectLater(
        LocalIdentityMigrationService.instance.claimLegacyMemberData(
          firebaseUid: 'collision-uid',
          authenticatedEmail: 'collision@example.com',
          allowInitialClaim: true,
        ),
        throwsA(isA<LocalIdentityDataConflict>()),
      );
      expect(await store.readLocalRecordChangesForOwner(source), hasLength(1));
      expect(
        (await store.readRecordsForOwner(target)).single.location,
        'target',
      );
    },
  );
}

FishingRecord _record(String id, String location) => FishingRecord(
  id: id,
  location: location,
  startAt: DateTime(2026, 10, 11, 6),
  endAt: DateTime(2026, 10, 11, 8),
  genreName: '루어',
  tide: '조금',
  weather: '맑음',
  airTemperature: 20,
  waterTemperature: 18,
  catches: const [CatchRecord(speciesName: '광어')],
);
