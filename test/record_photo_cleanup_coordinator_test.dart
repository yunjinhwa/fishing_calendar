import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/photos/record_photo_file_store.dart';
import 'package:fishing_build/data/photos/record_photo_file_store_stub.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/conflict_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/repositories/outbox_repository.dart';
import 'package:fishing_build/data/services/record_mutation_service.dart';
import 'package:fishing_build/data/services/record_photo_cleanup_coordinator.dart';
import 'package:fishing_build/data/services/record_photo_cleanup_service.dart';
import 'package:fishing_build/data/services/record_sync_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final auth = AuthSessionRepository.instance;
  final records = FishingRecordRepository.instance;
  late RecordPhotoFileStore files;
  late RecordPhotoCleanupService cleanup;
  late RecordPhotoCleanupCoordinator coordinator;
  late String owner;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await RecordSyncService.instance.resetForTesting();
    await resetTestDatabase();
    auth.clearMemoryOnlyForTesting();
    records.clearCacheOnlyForTesting();
    OutboxRepository.instance.clearCacheOnlyForTesting();
    ConflictRepository.instance.clearCacheOnlyForTesting();
    await auth.setSessionForTesting(
      plan: UserPlan.free,
      email: 'photo-cleanup-coordinator@example.com',
    );
    owner = auth.dataOwnerKey;
    files = RecordPhotoFileStore.withBackend(
      MemoryRecordPhotoFileStoreBackend(),
    );
    await files.deleteOwnerFiles(owner);
    cleanup = RecordPhotoCleanupService(
      fileStore: files,
      automaticCleanup: false,
    );
    coordinator = RecordPhotoCleanupCoordinator(cleanup: cleanup);
  });

  tearDown(() async {
    coordinator.dispose();
    await cleanup.flushPending();
    await RecordSyncService.instance.resetForTesting();
    await files.deleteOwnerFiles(owner);
  });

  Future<StoredRecordPhotoFile> persist(String id) => files.persistSelection(
    ownerId: owner,
    recordId: 'record',
    photoId: id,
    bytes: Uint8List.fromList([1, 2, 3]),
  );

  test(
    'initialization collects abandoned selections and preserves saved photos',
    () async {
      final saved = await persist('saved');
      final orphan = await persist('abandoned-before-restart');
      await records.addRecord(_record(saved.path));

      coordinator.initialize();
      coordinator.initialize();
      await cleanup.flushPending();

      expect(await files.readBytes(saved.path), [1, 2, 3]);
      await expectLater(
        files.readBytes(orphan.path),
        throwsA(isA<RecordPhotoFileNotFoundException>()),
      );
      expect(cleanup.lastError, isNull);
    },
  );

  test(
    'a committed free deletion releases its managed photo automatically',
    () async {
      final saved = await persist('deleted');
      await records.addRecord(_record(saved.path));
      coordinator.initialize();
      await cleanup.flushPending();

      await RecordMutationService.instance.deleteRecord('record');
      await cleanup.flushPending();

      expect(records.getAllRecords(), isEmpty);
      await expectLater(
        files.readBytes(saved.path),
        throwsA(isA<RecordPhotoFileNotFoundException>()),
      );
      expect(cleanup.lastError, isNull);
    },
  );

  test(
    'disposing removes observers and reinitialization resumes cleanup',
    () async {
      coordinator.initialize();
      await cleanup.flushPending();
      coordinator.dispose();
      coordinator.dispose();
      final orphan = await persist('after-dispose');

      await records.addRecord(_record(null));
      await cleanup.flushPending();
      expect(await files.readBytes(orphan.path), [1, 2, 3]);

      coordinator.initialize();
      await cleanup.flushPending();
      await expectLater(
        files.readBytes(orphan.path),
        throwsA(isA<RecordPhotoFileNotFoundException>()),
      );
    },
  );
}

FishingRecord _record(String? photoPath) => FishingRecord(
  id: 'record',
  location: '테스트 방파제',
  startAt: DateTime(2026, 10, 21, 18),
  endAt: DateTime(2026, 10, 22, 3),
  genreName: '루어',
  photos: [
    if (photoPath != null) RecordPhoto(id: 'photo', localPath: photoPath),
  ],
);
