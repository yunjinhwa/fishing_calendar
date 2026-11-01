import 'package:fishing_build/data/local/app_database.dart';
import 'package:fishing_build/data/local/local_data_store.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/record_cache_policy.dart';
import 'package:fishing_build/data/models/record_sync_metadata.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/remote/record_sync_gateway.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/conflict_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/repositories/outbox_repository.dart';
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
  final policy = RecordCachePolicy.instance;
  late IncrementalFakeRecordSyncGateway gateway;
  late RecordSyncService sync;
  late String owner;
  late String uid;
  final now = DateTime(2026, 10, 26, 12);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PaidRecordCacheService.instance.resetForTesting();
    await RecordSyncService.instance.resetForTesting();
    policy.reset(now: () => now);
    policy.enabled = true;
    await resetTestDatabase();
    auth.resetAuthGatewayForTesting();
    records.clearCacheOnlyForTesting();
    OutboxRepository.instance.clearCacheOnlyForTesting();
    ConflictRepository.instance.clearCacheOnlyForTesting();
    await auth.setSessionForTesting(
      plan: UserPlan.paid,
      email: 'paid-cache-sync@example.com',
    );
    owner = auth.dataOwnerKey;
    uid = auth.memberId!;
    gateway = IncrementalFakeRecordSyncGateway(pageSize: 2);
    sync = RecordSyncService(now: () => now)..configureGateway(gateway);
  });

  tearDown(() async {
    gateway.releaseChangePage();
    await sync.resetForTesting();
    sync.dispose();
    await RecordSyncService.instance.resetForTesting();
    policy.reset();
    await AppDatabase.instance.close();
  });

  Future<RecordSyncCheckpoint> checkpoint() async =>
      (await records.readSyncCheckpoint(owner))!;

  test(
    'bootstrap excludes old bodies while committing every remote version',
    () async {
      final boundary = DateTime(2026, 9, 26);
      gateway.seedActive(
        uid,
        _record('old'),
        versionNo: 3,
        cursor: _cursor('old', 10),
      );
      gateway.seedActive(
        uid,
        _record('ends-at-boundary', endAt: boundary),
        cursor: _cursor('ends-at-boundary', 20),
      );
      gateway.seedActive(
        uid,
        _record(
          'overlaps-boundary',
          endAt: boundary.add(const Duration(microseconds: 1)),
        ),
        cursor: _cursor('overlaps-boundary', 30),
      );
      gateway.seedActive(
        uid,
        _record(
          'recent',
          startAt: DateTime(2026, 10, 22),
          endAt: DateTime(2026, 10, 23),
        ),
        cursor: _cursor('recent', 40),
      );
      gateway.seedActive(
        uid,
        _record(
          'future',
          startAt: DateTime(2026, 12, 1),
          endAt: DateTime(2026, 12, 2),
        ),
        cursor: _cursor('future', 50),
      );

      final result = await sync.syncNow();

      expect(result.isSuccess, isTrue);
      expect(result.pushedCount, 0);
      expect(gateway.pushedOutboxIds, isEmpty);
      expect(
        records.getAllRecords().map((record) => record.id),
        unorderedEquals(['overlaps-boundary', 'recent', 'future']),
      );
      expect(await store.readRecordForOwner(owner, 'old'), isNull);
      expect(await store.readRecordForOwner(owner, 'ends-at-boundary'), isNull);
      final oldMetadata = (await store.readRecordSyncMetadata(owner, 'old'))!;
      expect(oldMetadata.serverVersionNo, 3);
      expect(oldMetadata.optimisticVersionNo, 3);
      expect(oldMetadata.remoteStatus, RemoteRecordStatus.active);
      expect(
        (await store.readRecordSyncMetadata(
          owner,
          'ends-at-boundary',
        ))!.serverVersionNo,
        1,
      );
      expect(
        (await checkpoint()).cursor.toJson(),
        _cursor('future', 50).toJson(),
      );
      expect((await checkpoint()).lastFullSyncAt, now.toUtc());
    },
  );

  test(
    'incremental pages advance excluded versions without restoring old bodies',
    () async {
      gateway.seedActive(
        uid,
        _record('old'),
        versionNo: 3,
        cursor: _cursor('old', 10),
      );
      gateway.seedActive(
        uid,
        _record(
          'recent',
          startAt: DateTime(2026, 10, 20),
          endAt: DateTime(2026, 10, 21),
        ),
        cursor: _cursor('recent', 20),
      );
      expect((await sync.syncNow()).isSuccess, isTrue);
      final baselineFetches = gateway.fetchCount;
      final fullSyncAt = (await checkpoint()).lastFullSyncAt;
      gateway.seedActive(
        uid,
        _record('old', location: 'Old updated remotely'),
        versionNo: 4,
        cursor: _cursor('old', 30),
      );
      gateway.seedActive(
        uid,
        _record(
          'recent',
          location: 'Recent updated remotely',
          startAt: DateTime(2026, 10, 20),
          endAt: DateTime(2026, 10, 21),
        ),
        versionNo: 2,
        cursor: _cursor('recent', 40),
      );
      gateway.seedActive(
        uid,
        _record('new-old'),
        cursor: _cursor('new-old', 50),
      );

      final result = await sync.syncNow();

      expect(result.isSuccess, isTrue);
      expect(gateway.fetchCount, baselineFetches);
      expect(gateway.changeRequests, hasLength(2));
      expect(
        records.getRecordById('recent')!.location,
        'Recent updated remotely',
      );
      expect(records.getRecordById('old'), isNull);
      expect(records.getRecordById('new-old'), isNull);
      expect(
        (await store.readRecordSyncMetadata(owner, 'old'))!.serverVersionNo,
        4,
      );
      expect(
        (await store.readRecordSyncMetadata(owner, 'new-old'))!.serverVersionNo,
        1,
      );
      expect(
        (await checkpoint()).cursor.toJson(),
        _cursor('new-old', 50).toJson(),
      );
      expect((await checkpoint()).lastFullSyncAt, fullSyncAt);
      expect((await sync.syncNow()).isSuccess, isTrue);
      expect(records.getRecordById('new-old'), isNull);
    },
  );

  test('month and history pins restore old bodies only while held', () async {
    gateway.seedActive(
      uid,
      _record('old'),
      versionNo: 2,
      cursor: _cursor('old', 10),
    );
    expect((await sync.syncNow()).isSuccess, isTrue);
    expect(records.getRecordById('old'), isNull);

    for (final pin in ['month', 'history']) {
      final release = pin == 'month'
          ? policy.holdMonth(owner, DateTime(2026, 8))
          : policy.holdHistory(owner);
      expect((await sync.syncNow(forceFullRefresh: true)).isSuccess, isTrue);
      expect(records.getRecordById('old'), isNotNull, reason: pin);
      expect(
        (await store.readRecordSyncMetadata(owner, 'old'))!.serverVersionNo,
        2,
      );

      release();
      expect((await sync.syncNow(forceFullRefresh: true)).isSuccess, isTrue);
      expect(records.getRecordById('old'), isNull, reason: pin);
      expect(await store.readRecordForOwner(owner, 'old'), isNull);
      expect(
        (await store.readRecordSyncMetadata(owner, 'old'))!.serverVersionNo,
        2,
      );
      expect((await checkpoint()).cursor.toJson(), _cursor('old', 10).toJson());
    }
  });

  test(
    'old tombstones clear archived originals after the body was evicted',
    () async {
      final original = _record('old-photo', withPhoto: true);
      await records.addRecord(original);
      gateway.seedActive(uid, original, cursor: _cursor(original.id, 10));
      final release = policy.holdHistory(owner);
      expect((await sync.syncNow()).isSuccess, isTrue);
      expect(
        records.getRecordById(original.id)!.photos.single.toJson(),
        original.photos.single.toJson(),
      );
      release();
      expect((await sync.syncNow(forceFullRefresh: true)).isSuccess, isTrue);
      expect(await store.readRecordForOwner(owner, original.id), isNull);
      expect(
        await store.readArchivedPhotosForRecord(owner, original.id),
        hasLength(1),
      );
      final fullFetches = gateway.fetchCount;
      gateway.seedDeleted(
        uid,
        original.id,
        versionNo: 2,
        cursor: _cursor(original.id, 20),
      );

      final result = await sync.syncNow();

      expect(result.isSuccess, isTrue);
      expect(gateway.fetchCount, fullFetches);
      expect(records.getRecordById(original.id), isNull);
      expect(
        await store.readArchivedPhotosForRecord(owner, original.id),
        isEmpty,
      );
      final metadata = (await store.readRecordSyncMetadata(
        owner,
        original.id,
      ))!;
      expect(metadata.serverVersionNo, 2);
      expect(metadata.remoteStatus, RemoteRecordStatus.deleted);
      expect(
        (await checkpoint()).cursor.toJson(),
        _cursor(original.id, 20).toJson(),
      );
      expect(gateway.pushedOutboxIds, isEmpty);
    },
  );
}

RecordSyncCursor _cursor(String id, int seconds) =>
    RecordSyncCursor(seconds: seconds, nanoseconds: 500, recordId: id);

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
      const RecordPhoto(
        id: 'original',
        localPath: 'C:/photos/local-original.jpg',
      ),
  ],
);
