import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fishing_build/data/local/app_database.dart';
import 'package:fishing_build/data/local/local_data_store.dart';
import 'package:fishing_build/data/models/conflict_item.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/outbox_item.dart';
import 'package:fishing_build/data/models/record_sync_metadata.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/photos/record_photo_file_store.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/services/account_deletion_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'support/test_database.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AuthSessionRepository.instance.resetAuthGatewayForTesting();
    await resetTestDatabase();
  });

  tearDown(() async {
    await AppDatabase.instance.close();
  });

  test('deleteOwnerData removes only the selected owner data', () async {
    const deletedOwner = 'member:uid:deleted-user';
    const retainedOwner = 'member:uid:retained-user';
    final store = LocalDataStore.instance;

    await _seedOwner(store, ownerKey: deletedOwner, suffix: 'deleted');
    await _seedOwner(store, ownerKey: retainedOwner, suffix: 'retained');
    await AppDatabase.instance.transaction(
      (transaction) => store.writeMetadata(
        transaction,
        key: 'global-migration-marker',
        value: 'preserve-me',
      ),
    );

    await AppDatabase.instance.transaction(
      (transaction) =>
          store.deleteOwnerData(transaction, ownerKey: deletedOwner),
    );
    // Account deletion can be retried after an interrupted attempt.
    await AppDatabase.instance.transaction(
      (transaction) =>
          store.deleteOwnerData(transaction, ownerKey: deletedOwner),
    );

    expect(await store.readRecordsForOwner(deletedOwner), isEmpty);
    expect(await store.readOutboxItemsForOwner(deletedOwner), isEmpty);
    expect(
      await store.readRecordSyncMetadata(deletedOwner, 'record-deleted'),
      isNull,
    );
    expect(await store.readConflictsForOwner(deletedOwner), isEmpty);

    expect(
      (await store.readRecordsForOwner(retainedOwner)).single.id,
      'record-retained',
    );
    expect(
      (await store.readOutboxItemsForOwner(retainedOwner)).single.id,
      'outbox-retained',
    );
    expect(
      await store.readRecordSyncMetadata(retainedOwner, 'record-retained'),
      isNotNull,
    );
    expect(
      (await store.readConflictsForOwner(retainedOwner)).single.id,
      'conflict-retained',
    );

    final database = await AppDatabase.instance.database;
    expect(
      await _ownerRowCount(
        database,
        AppDatabase.recordCatchesTable,
        deletedOwner,
      ),
      0,
    );
    expect(
      await _ownerRowCount(
        database,
        AppDatabase.recordPhotosTable,
        deletedOwner,
      ),
      0,
    );
    expect(
      await _ownerRowCount(
        database,
        AppDatabase.recordCatchesTable,
        retainedOwner,
      ),
      1,
    );
    expect(
      await _ownerRowCount(
        database,
        AppDatabase.recordPhotosTable,
        retainedOwner,
      ),
      1,
    );
    expect(
      await store.readMetadata(database, 'global-migration-marker'),
      'preserve-me',
    );
  });

  test('startup resumes an interrupted local account cleanup', () async {
    const ownerKey = 'member:uid:pending-user';
    const email = 'pending@example.com';
    final store = LocalDataStore.instance;
    await _seedOwner(store, ownerKey: ownerKey, suffix: 'pending');

    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'account-deletion-cleanup-',
    );
    addTearDown(() async {
      if (temporaryDirectory.existsSync()) {
        await temporaryDirectory.delete(recursive: true);
      }
    });
    final photoStore = RecordPhotoFileStore(
      supportPathProvider: () async => temporaryDirectory.path,
    );
    final photo = await photoStore.persistSelection(
      ownerId: ownerKey,
      recordId: 'record-pending',
      photoId: 'photo-pending',
      bytes: Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 0xd9]),
      contentType: 'image/jpeg',
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'account_deletion_local_cleanup_v1',
      jsonEncode(<String, Object>{
        'version': 1,
        'ownerKey': ownerKey,
        'email': email,
        'firebaseUid': 'pending-user',
      }),
    );

    final service = AccountDeletionService(photoFileStore: photoStore);
    await service.resumePendingLocalCleanup();

    expect(await store.readRecordsForOwner(ownerKey), isEmpty);
    await expectLater(
      photoStore.readBytes(photo.path),
      throwsA(isA<RecordPhotoFileNotFoundException>()),
    );
    expect(prefs.getString('account_deletion_local_cleanup_v1'), isNull);
  });

  test(
    'a remote deletion tombstone purges this device and clears its session',
    () async {
      const ownerKey = 'member:uid:remote-deleted-user';
      const retainedOwner = 'member:uid:retained-user';
      const email = 'remote-deleted@example.com';
      const firebaseUid = 'remote-deleted-user';
      final store = LocalDataStore.instance;
      await _seedOwner(store, ownerKey: ownerKey, suffix: 'remote');
      await _seedOwner(store, ownerKey: retainedOwner, suffix: 'retained');

      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'remote-account-deletion-cleanup-',
      );
      addTearDown(() async {
        if (temporaryDirectory.existsSync()) {
          await temporaryDirectory.delete(recursive: true);
        }
      });
      final photoStore = RecordPhotoFileStore(
        supportPathProvider: () async => temporaryDirectory.path,
      );
      final photo = await photoStore.persistSelection(
        ownerId: ownerKey,
        recordId: 'record-remote',
        photoId: 'photo-remote',
        bytes: Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 0xd9]),
        contentType: 'image/jpeg',
      );

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('auth_has_active_session', true);
      await prefs.setString('auth_plan', 'paid');
      await prefs.setString('auth_email', email);
      await prefs.setString('auth_member_id', firebaseUid);
      await prefs.setString(
        'auth_firebase_nicknames_v1',
        jsonEncode(<String, String>{firebaseUid: '삭제대상'}),
      );

      final service = AccountDeletionService(photoFileStore: photoStore);
      await Future.wait(<Future<void>>[
        service.handleRemoteAccountDeletion(
          ownerKey: ownerKey,
          email: email,
          firebaseUid: firebaseUid,
        ),
        service.handleRemoteAccountDeletion(
          ownerKey: ownerKey,
          email: email,
          firebaseUid: firebaseUid,
        ),
      ]);

      expect(await store.readRecordsForOwner(ownerKey), isEmpty);
      expect(await store.readOutboxItemsForOwner(ownerKey), isEmpty);
      expect(await store.readRecordsForOwner(retainedOwner), isNotEmpty);
      await expectLater(
        photoStore.readBytes(photo.path),
        throwsA(isA<RecordPhotoFileNotFoundException>()),
      );
      expect(prefs.getString('auth_member_id'), isNull);
      expect(prefs.getString('auth_email'), isNull);
      expect(prefs.getString('auth_firebase_nicknames_v1'), isNull);
      expect(prefs.getString('account_deletion_local_cleanup_v1'), isNull);
    },
  );

  test(
    'startup does not restore a local account after cleanup was interrupted',
    () async {
      const email = 'interrupted@example.com';
      const password = 'Password1';
      final authSession = AuthSessionRepository.instance;
      await authSession.setSessionForTesting(
        plan: UserPlan.free,
        email: email,
        nickname: 'interrupted-user',
        password: password,
      );
      final ownerKey = authSession.dataOwnerKey;
      final store = LocalDataStore.instance;
      await _seedOwner(store, ownerKey: ownerKey, suffix: 'interrupted');

      // Reproduce a process termination after local rows were purged but
      // before AuthSessionRepository removed account and session preferences.
      await AppDatabase.instance.transaction(
        (transaction) => store.deleteOwnerData(transaction, ownerKey: ownerKey),
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'account_deletion_local_cleanup_v1',
        jsonEncode(<String, Object>{
          'version': 1,
          'ownerKey': ownerKey,
          'email': email,
        }),
      );
      authSession.clearMemoryOnlyForTesting();

      final service = AccountDeletionService(
        authSession: authSession,
        photoFileStore: _NoOpPhotoFileStore(),
      );
      await service.resumePendingLocalCleanup();
      await authSession.loadSession();

      expect(authSession.hasActiveSession, isFalse);
      expect(authSession.isMember, isFalse);
      expect(
        await authSession.signIn(email: email, password: password),
        AuthSignInResult.accountNotFound,
      );
      expect(prefs.getString('account_deletion_local_cleanup_v1'), isNull);
    },
  );

  test('malformed pending cleanup does not block startup', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'account_deletion_local_cleanup_v1',
      '{malformed-json',
    );

    await expectLater(
      AccountDeletionService().resumePendingLocalCleanup(),
      completes,
    );
    await AuthSessionRepository.instance.loadSession();

    expect(AuthSessionRepository.instance.hasActiveSession, isFalse);
    expect(prefs.getString('account_deletion_local_cleanup_v1'), isNull);
  });

  test(
    'failed pending cleanup keeps its retry marker without blocking startup',
    () async {
      const email = 'retry@example.com';
      const password = 'Password1';
      final authSession = AuthSessionRepository.instance;
      await authSession.setSessionForTesting(
        plan: UserPlan.free,
        email: email,
        nickname: 'retry-user',
        password: password,
      );
      final ownerKey = authSession.dataOwnerKey;
      await _seedOwner(
        LocalDataStore.instance,
        ownerKey: ownerKey,
        suffix: 'retry',
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'account_deletion_local_cleanup_v1',
        jsonEncode(<String, Object>{
          'version': 1,
          'ownerKey': ownerKey,
          'email': email,
        }),
      );
      authSession.clearMemoryOnlyForTesting();

      final service = AccountDeletionService(
        authSession: authSession,
        photoFileStore: _FailingPhotoFileStore(),
      );
      await expectLater(service.resumePendingLocalCleanup(), completes);
      await authSession.loadSession();

      expect(authSession.hasActiveSession, isFalse);
      expect(authSession.isMember, isFalse);
      expect(prefs.getString('account_deletion_local_cleanup_v1'), isNotNull);
      expect(
        await LocalDataStore.instance.readRecordsForOwner(ownerKey),
        isNotEmpty,
      );
    },
  );
}

final class _FailingPhotoFileStore implements RecordPhotoFileStoreBackend {
  @override
  Future<void> deleteOwnerFiles(String ownerId) {
    throw const RecordPhotoFileStoreException('simulated cleanup failure');
  }

  @override
  Future<StoredRecordPhotoFile> persistSelection({
    required String ownerId,
    required String recordId,
    required String photoId,
    Uint8List? bytes,
    String? sourcePath,
    String? contentType,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<Uint8List> readBytes(String path) {
    throw UnimplementedError();
  }
}

final class _NoOpPhotoFileStore implements RecordPhotoFileStoreBackend {
  @override
  Future<void> deleteOwnerFiles(String ownerId) async {}

  @override
  Future<StoredRecordPhotoFile> persistSelection({
    required String ownerId,
    required String recordId,
    required String photoId,
    Uint8List? bytes,
    String? sourcePath,
    String? contentType,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<Uint8List> readBytes(String path) {
    throw UnimplementedError();
  }
}

Future<void> _seedOwner(
  LocalDataStore store, {
  required String ownerKey,
  required String suffix,
}) async {
  final record = FishingRecord(
    id: 'record-$suffix',
    location: 'location-$suffix',
    startAt: DateTime.utc(2026, 10, 18, 9),
    endAt: DateTime.utc(2026, 10, 18, 10),
    genreName: 'genre-$suffix',
    catches: <CatchRecord>[
      CatchRecord(speciesName: 'species-$suffix', lengthCm: 30),
    ],
    photos: <RecordPhoto>[
      RecordPhoto(
        id: 'photo-$suffix',
        localPath: 'photo-$suffix.jpg',
        contentType: 'image/jpeg',
        sizeBytes: 4,
        checksum: 'checksum-$suffix',
      ),
    ],
  );
  final outbox = OutboxItem(
    id: 'outbox-$suffix',
    userId: suffix,
    recordId: record.id,
    operationType: OutboxOperationType.update,
    status: OutboxStatus.pending,
    createdAt: DateTime.utc(2026, 10, 18, 11),
    baseVersionNo: 1,
    payload: record.toJson(),
  );

  await AppDatabase.instance.transaction((transaction) async {
    await store.insertRecord(transaction, ownerKey: ownerKey, record: record);
    await store.insertOutboxItem(transaction, ownerKey: ownerKey, item: outbox);
    await store.writeRecordSyncMetadata(
      transaction,
      ownerKey: ownerKey,
      metadata: RecordSyncMetadata(
        recordId: record.id,
        serverVersionNo: 2,
        optimisticVersionNo: 2,
        remoteStatus: RemoteRecordStatus.active,
      ),
    );
    await store.insertConflict(
      transaction,
      conflict: ConflictItem(
        id: 'conflict-$suffix',
        ownerKey: ownerKey,
        recordId: record.id,
        outboxId: outbox.id,
        localOperationType: OutboxOperationType.update,
        baseVersionNo: 1,
        remoteVersionNo: 2,
        remoteStatus: RemoteRecordStatus.active,
        localRecord: record,
        remoteRecord: record,
        occurredAt: DateTime.utc(2026, 10, 18, 12),
        status: ConflictStatus.unresolved,
      ),
    );
  });
}

Future<int> _ownerRowCount(
  Database database,
  String table,
  String ownerKey,
) async {
  return Sqflite.firstIntValue(
        await database.rawQuery(
          'SELECT COUNT(*) FROM $table WHERE owner_key = ?',
          <Object?>[ownerKey],
        ),
      ) ??
      0;
}
