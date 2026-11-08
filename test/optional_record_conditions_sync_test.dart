import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fishing_build/data/local/app_database.dart';
import 'package:fishing_build/data/local/local_data_store.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/remote/firestore_record_sync_gateway.dart';
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
  final outbox = OutboxRepository.instance;
  final sync = RecordSyncService.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await sync.resetForTesting();
    await resetTestDatabase();
    auth.clearMemoryOnlyForTesting();
    records.clearCacheOnlyForTesting();
    outbox.clearCacheOnlyForTesting();
    ConflictRepository.instance.clearCacheOnlyForTesting();
    await auth.setSessionForTesting(
      plan: UserPlan.paid,
      email: 'optional-conditions-sync@example.com',
    );
  });

  tearDown(() async {
    await sync.resetForTesting();
    await AppDatabase.instance.close();
  });

  test(
    'cleared optional values survive Outbox, Firestore codec, sync and reload',
    () async {
      final gateway = FakeRecordSyncGateway();
      sync.configureGateway(gateway);
      final original = _record(tide: '3물', waterTemperature: 0);
      await mutations.addRecord(original);
      expect((await sync.syncNow()).isSuccess, isTrue);
      expect(gateway.record(auth.memberId!, original.id)!.waterTemperature, 0);

      await mutations.updateRecord(_record());
      final item = outbox.getAllItems().last;
      expect(item.payload!['tide'], isNull);
      expect(item.payload!['waterTemperature'], isNull);

      final encoded = FirestoreRecordSyncGateway.encodeActiveRecordForTesting(
        uid: auth.memberId!,
        item: item,
        record: FishingRecord.fromJson(item.payload!),
        versionNo: 2,
        createdAt: Timestamp.fromDate(original.startAt),
      );
      expect(encoded['tide'], isNull);
      expect(encoded['waterTemperature'], isNull);
      final decoded = FirestoreRecordSyncGateway.decodeCloudRecordForTesting(
        Map<String, dynamic>.from(encoded),
      );
      expect(decoded.tide, isNull);
      expect(decoded.waterTemperature, isNull);

      expect((await sync.syncNow()).isSuccess, isTrue);
      final remote = gateway.record(auth.memberId!, original.id)!;
      expect(remote.tide, isNull);
      expect(remote.waterTemperature, isNull);
      records.clearCacheOnlyForTesting();
      await records.loadRecords();
      final restored = records.getRecordById(original.id)!;
      expect(restored.tide, isNull);
      expect(restored.waterTemperature, isNull);
      final durable = (await LocalDataStore.instance.readRecordForOwner(
        auth.dataOwnerKey,
        original.id,
      ))!;
      expect(durable.tide, isNull);
      expect(durable.waterTemperature, isNull);
    },
  );
}

FishingRecord _record({String? tide, double? waterTemperature}) =>
    FishingRecord(
      id: 'optional-conditions-sync',
      location: '부산',
      startAt: DateTime(2026, 11, 9, 8),
      endAt: DateTime(2026, 11, 9, 10),
      genreName: '루어',
      tide: tide,
      weather: '맑음',
      airTemperature: 20,
      waterTemperature: waterTemperature,
    );
