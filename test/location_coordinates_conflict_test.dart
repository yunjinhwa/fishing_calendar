import 'dart:convert';

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
import 'package:fishing_build/data/services/record_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_record_sync_gateway.dart';
import 'support/test_database.dart';

void main() {
  final auth = AuthSessionRepository.instance;
  final records = FishingRecordRepository.instance;
  final store = LocalDataStore.instance;
  final conflicts = ConflictRepository.instance;
  final outbox = OutboxRepository.instance;
  final sync = RecordSyncService.instance;
  late String owner;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await sync.resetForTesting();
    await resetTestDatabase();
    auth.clearMemoryOnlyForTesting();
    records.clearCacheOnlyForTesting();
    conflicts.clearCacheOnlyForTesting();
    outbox.clearCacheOnlyForTesting();
    await auth.setSessionForTesting(
      plan: UserPlan.paid,
      email: 'coordinate-conflict@example.com',
    );
    owner = auth.dataOwnerKey;
  });

  tearDown(() async {
    await sync.resetForTesting();
    await AppDatabase.instance.close();
  });

  Future<void> seed(FishingRecord record) async {
    await AppDatabase.instance.transaction((transaction) async {
      await store.insertRecord(transaction, ownerKey: owner, record: record);
      await store.writeRecordSyncMetadata(
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

  test(
    'same place name with different precise coordinates is a location conflict',
    () {
      final mine = _record(latitude: 35.00000001, longitude: 129.00000001);
      final theirs = _record(latitude: 35.00000002, longitude: 129.00000002);
      final conflict = _conflict(owner, mine, theirs);

      expect(conflict.fields, hasLength(1));
      final field = conflict.fields.single;
      expect(field.key, ConflictFieldKey.location);
      expect(field.mineValue, contains('35.00000001'));
      expect(field.theirsValue, contains('35.00000002'));
      expect(field.mineValue, isNot(field.theirsValue));
    },
  );

  test('merging another field preserves the entire local location', () {
    final mine = _record(location: '부산', memo: '내 메모');
    final theirs = _record(
      location: '인천',
      latitude: 37.5,
      longitude: 126.6,
      memo: '상대 메모',
    );
    final merged = _conflict(
      owner,
      mine,
      theirs,
    ).buildMergedRecord({ConflictFieldKey.memo});

    expect(merged.location, mine.location);
    expect(merged.latitude, mine.latitude);
    expect(merged.longitude, mine.longitude);
    expect(merged.memo, theirs.memo);
  });

  test(
    'remote location selection takes its name and coordinate pair together',
    () {
      final mine = _record(location: '부산', photos: [_photo]);
      final theirs = _record(location: '인천', latitude: 37.5, longitude: 126.6);
      final merged = _conflict(
        owner,
        mine,
        theirs,
      ).buildMergedRecord({ConflictFieldKey.location});

      expect(merged.location, theirs.location);
      expect(merged.latitude, theirs.latitude);
      expect(merged.longitude, theirs.longitude);
      expect(merged.photos.single.toJson(), _photo.toJson());
    },
  );

  test('selecting a legacy remote location clears both local coordinates', () {
    final mine = _record();
    final theirs = _record(
      location: '수동 입력 위치',
      latitude: null,
      longitude: null,
    );
    final conflict = _conflict(owner, mine, theirs);
    final merged = conflict.buildMergedRecord({ConflictFieldKey.location});

    expect(merged.location, theirs.location);
    expect(merged.latitude, isNull);
    expect(merged.longitude, isNull);
    expect(conflict.fields.single.theirsValue, theirs.location);
  });

  test(
    'conflict payload snapshots retain coordinate presence and legacy absence',
    () {
      final conflict = _conflict(
        owner,
        _record(),
        _record(latitude: null, longitude: null),
      );
      final local = FishingRecord.fromJson(
        jsonDecode(conflict.localPayloadJson!),
      );
      final remote = FishingRecord.fromJson(
        jsonDecode(conflict.remotePayloadJson!),
      );

      expect(local.latitude, 35.1);
      expect(local.longitude, 129.1);
      expect(remote.latitude, isNull);
      expect(remote.longitude, isNull);
    },
  );

  for (final archived in [false, true]) {
    test(
      'remote range restores coordinates with ${archived ? 'archived' : 'current'} local photos',
      () async {
        final local = _record(photos: [_photo]);
        await seed(local);
        if (archived) {
          await AppDatabase.instance.transaction(
            (transaction) => store.deleteRecord(
              transaction,
              ownerKey: owner,
              recordId: local.id,
              preservePhotos: true,
            ),
          );
          await records.reloadOwner(owner);
        }
        final remote = _record(latitude: 37.5, longitude: 126.6);

        final result = await records.applyRemoteRange(
          ownerKey: owner,
          revisions: [
            RemoteRecordRevision(
              recordId: remote.id,
              versionNo: 2,
              status: RemoteRecordStatus.active,
              record: remote,
            ),
          ],
          isCurrentSession: () => true,
        );

        expect(result.applied, isTrue);
        final restored = records.getRecordById(local.id)!;
        expect(restored.latitude, remote.latitude);
        expect(restored.longitude, remote.longitude);
        expect(restored.photos.single.toJson(), _photo.toJson());
        final durable = (await store.readRecordForOwner(owner, local.id))!;
        expect(durable.latitude, remote.latitude);
        expect(durable.longitude, remote.longitude);
      },
    );
  }

  for (final hasRemoteCoordinates in [false, true]) {
    test(
      'useTheirs preserves local photos and ${hasRemoteCoordinates ? 'adopts' : 'clears'} coordinates',
      () async {
        final local = _record(photos: [_photo]);
        final remote = _record(
          location: '상대 위치',
          latitude: hasRemoteCoordinates ? 37.5 : null,
          longitude: hasRemoteCoordinates ? 126.6 : null,
        );
        await seed(local);
        final gateway = FakeRecordSyncGateway();
        gateway.seedActive(auth.memberId!, remote, versionNo: 2);
        sync.configureGateway(gateway);
        final conflict = _conflict(owner, local, remote);
        await conflicts.recordDetectedConflict(conflict);

        await ConflictResolutionService.instance.useTheirs(conflict);

        final resolved = records.getRecordById(local.id)!;
        expect(resolved.location, remote.location);
        expect(resolved.latitude, remote.latitude);
        expect(resolved.longitude, remote.longitude);
        expect(resolved.photos.single.toJson(), _photo.toJson());
        expect(
          conflicts.findById(conflict.id)!.status,
          ConflictStatus.resolved,
        );
      },
    );
  }

  test(
    'manual location merge persists the chosen pair in its new Outbox payload',
    () async {
      final local = _record(photos: [_photo]);
      final remote = _record(location: '인천', latitude: 37.5, longitude: 126.6);
      await seed(local);
      final conflict = _conflict(owner, local, remote);
      await conflicts.recordDetectedConflict(conflict);
      final merged = conflict.buildMergedRecord({ConflictFieldKey.location});

      await ConflictResolutionService.instance.useMerged(conflict, merged);

      final payload = outbox.getAllItems().single.payload!;
      final queued = FishingRecord.fromJson(payload);
      expect(queued.location, remote.location);
      expect(queued.latitude, remote.latitude);
      expect(queued.longitude, remote.longitude);
      expect(queued.photos.single.toJson(), _photo.toJson());
      expect(conflicts.findById(conflict.id)!.status, ConflictStatus.resolving);
    },
  );
}

const _photo = RecordPhoto(
  id: 'local-photo',
  localPath: 'C:/photos/coordinate-local.jpg',
);

FishingRecord _record({
  String location = '부산',
  double? latitude = 35.1,
  double? longitude = 129.1,
  String? memo,
  List<RecordPhoto> photos = const [],
}) => FishingRecord(
  id: 'coordinate-record',
  location: location,
  latitude: latitude,
  longitude: longitude,
  startAt: DateTime(2026, 11, 1, 8),
  endAt: DateTime(2026, 11, 1, 12),
  genreName: '루어',
  tide: '3물',
  weather: '맑음',
  photos: photos,
  memo: memo,
);

ConflictItem _conflict(
  String owner,
  FishingRecord mine,
  FishingRecord theirs,
) => ConflictItem(
  id: 'coordinate-conflict',
  ownerKey: owner,
  recordId: mine.id,
  outboxId: 'coordinate-outbox',
  localOperationType: OutboxOperationType.update,
  baseVersionNo: 1,
  remoteVersionNo: 2,
  remoteStatus: RemoteRecordStatus.active,
  localRecord: mine,
  remoteRecord: theirs,
  occurredAt: DateTime(2026, 11, 1),
  status: ConflictStatus.unresolved,
);
