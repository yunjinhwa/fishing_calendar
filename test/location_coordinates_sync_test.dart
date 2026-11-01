import 'package:fishing_build/data/local/app_database.dart';
import 'package:fishing_build/data/local/local_data_store.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/conflict_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/repositories/outbox_repository.dart';
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
  final store = LocalDataStore.instance;
  final outbox = OutboxRepository.instance;
  final mutations = RecordMutationService.instance;
  late RecordSyncService sync;
  late FakeRecordSyncGateway gateway;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await RecordSyncService.instance.resetForTesting();
    await resetTestDatabase();
    auth.resetAuthGatewayForTesting();
    records.clearCacheOnlyForTesting();
    outbox.clearCacheOnlyForTesting();
    ConflictRepository.instance.clearCacheOnlyForTesting();
    gateway = FakeRecordSyncGateway();
    sync = RecordSyncService()..configureGateway(gateway);
  });
  tearDown(() async {
    await sync.resetForTesting();
    sync.dispose();
    await RecordSyncService.instance.resetForTesting();
    await AppDatabase.instance.close();
  });

  Future<void> signIn(UserPlan plan) => auth.setSessionForTesting(
    plan: plan,
    email: 'coordinate-sync@example.com',
  );

  test(
    'paid create, reload and coordinate removal propagate together',
    () async {
      await signIn(UserPlan.paid);
      final original = _record('paid', latitude: 35.1796, longitude: 129.0756);
      await mutations.addRecord(original);
      expect(
        outbox.getAllItems().single.payload!['latitude'],
        original.latitude,
      );
      expect((await sync.syncNow()).isSuccess, isTrue);
      expect(
        gateway.record(auth.memberId!, original.id)!.longitude,
        original.longitude,
      );
      records.clearCacheOnlyForTesting();
      await records.loadRecords();
      expect(records.getRecordById(original.id)!.latitude, original.latitude);

      await mutations.updateRecord(_record(original.id));
      expect((await sync.syncNow()).isSuccess, isTrue);
      expect(gateway.record(auth.memberId!, original.id)!.latitude, isNull);
      expect(
        (await store.readRecordForOwner(
          auth.dataOwnerKey,
          original.id,
        ))!.longitude,
        isNull,
      );
    },
  );

  test(
    'an old coordinate record restores after body eviction at the same version',
    () async {
      await signIn(UserPlan.paid);
      final remote = _record(
        'restored',
        latitude: -33.8688,
        longitude: 151.2093,
      );
      gateway.seedActive(auth.memberId!, remote);
      expect((await sync.syncNow()).isSuccess, isTrue);
      await AppDatabase.instance.transaction(
        (transaction) => store.deleteRecord(
          transaction,
          ownerKey: auth.dataOwnerKey,
          recordId: remote.id,
          preservePhotos: true,
        ),
      );
      await records.reloadOwner(auth.dataOwnerKey);
      expect(records.getRecordById(remote.id), isNull);
      expect((await sync.syncNow()).isSuccess, isTrue);
      expect(records.getRecordById(remote.id)!.latitude, remote.latitude);
      expect(records.getRecordById(remote.id)!.longitude, remote.longitude);
    },
  );

  test(
    'free intent survives restart and migrates with its coordinate pair',
    () async {
      await signIn(UserPlan.free);
      final original = _record('free', latitude: 0, longitude: 0);
      await mutations.addRecord(original);
      expect(outbox.getAllItems(), isEmpty);
      expect(
        (await store.readLocalRecordChangesForOwner(
          auth.dataOwnerKey,
        )).single.payload['longitude'],
        0.0,
      );
      records.clearCacheOnlyForTesting();
      await records.loadRecords();
      expect(records.getRecordById(original.id)!.latitude, 0.0);
      await PlanPolicyService.instance.changePlan(UserPlan.paid);
      expect((await sync.syncNow()).isSuccess, isTrue);
      expect(gateway.record(auth.memberId!, original.id)!.latitude, 0.0);
      expect(gateway.record(auth.memberId!, original.id)!.longitude, 0.0);
      expect(
        await store.readLocalRecordChangesForOwner(auth.dataOwnerKey),
        isEmpty,
      );
    },
  );

  test(
    'invalid programmatic mutations leave body and queue untouched',
    () async {
      await signIn(UserPlan.paid);
      await expectLater(
        mutations.addRecord(_record('invalid', latitude: 35)),
        throwsArgumentError,
      );
      expect(await store.readRecordsForOwner(auth.dataOwnerKey), isEmpty);
      expect(await store.readOutboxItemsForOwner(auth.dataOwnerKey), isEmpty);
    },
  );
}

FishingRecord _record(String id, {double? latitude, double? longitude}) =>
    FishingRecord(
      id: id,
      location: 'Coordinate harbor',
      latitude: latitude,
      longitude: longitude,
      startAt: DateTime(2026, 8, 15, 8),
      endAt: DateTime(2026, 8, 15, 12),
      genreName: '루어',
    );
