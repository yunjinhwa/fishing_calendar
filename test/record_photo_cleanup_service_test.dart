import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fishing_build/data/local/app_database.dart';
import 'package:fishing_build/data/local/local_data_store.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/photos/record_photo_file_store.dart';
import 'package:fishing_build/data/services/record_photo_cleanup_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_database.dart';

void main() {
  const owner = 'member:photo-owner';
  const otherOwner = 'member:other-owner';
  late Directory directory;
  late RecordPhotoFileStore files;
  late _ControlledBackend backend;
  late RecordPhotoCleanupService cleanup;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await resetTestDatabase();
    directory = await Directory.systemTemp.createTemp('photo-cleanup-service-');
    files = RecordPhotoFileStore(
      supportPathProvider: () async => directory.path,
    );
    backend = _ControlledBackend(files);
    cleanup = RecordPhotoCleanupService(
      fileStore: RecordPhotoFileStore.withBackend(backend),
    );
  });

  tearDown(() async {
    await cleanup.flushPending();
    await AppDatabase.instance.close();
    await directory.delete(recursive: true);
  });

  Future<StoredRecordPhotoFile> photo(String id, {String ownerKey = owner}) =>
      files.persistSelection(
        ownerId: ownerKey,
        recordId: 'record-$id',
        photoId: id,
        bytes: Uint8List.fromList([0xff, 0xd8, id.length, 0xd9]),
        contentType: 'image/jpeg',
      );

  Future<void> saveReference(String id, String path, String ownerKey) {
    return AppDatabase.instance.transaction((transaction) {
      return LocalDataStore.instance.insertRecord(
        transaction,
        ownerKey: ownerKey,
        record: FishingRecord(
          id: id,
          location: 'Port',
          startAt: DateTime(2026, 10, 21, 18),
          endAt: DateTime(2026, 10, 22, 3),
          genreName: 'Fishing',
          photos: [RecordPhoto(id: id, localPath: path)],
        ),
      );
    });
  }

  Future<void> outbox(
    String id,
    String status,
    Object payload, {
    String ownerKey = owner,
    bool rawPayload = false,
  }) async {
    final database = await AppDatabase.instance.database;
    await database.insert(AppDatabase.outboxItemsTable, {
      'owner_key': ownerKey,
      'outbox_id': id,
      'record_id': 'record-$id',
      'operation_type': 'update',
      'status': status,
      'created_at': DateTime.now().toIso8601String(),
      'payload_json': rawPayload ? payload : jsonEncode(payload),
    });
  }

  Future<void> conflict(
    String id,
    String status,
    Object local,
    Object remote,
  ) async {
    final database = await AppDatabase.instance.database;
    await database.insert(AppDatabase.recordConflictsTable, {
      'owner_key': owner,
      'conflict_id': id,
      'record_id': 'record-$id',
      'outbox_id': 'outbox-$id',
      'operation_type': 'update',
      'remote_version_no': 2,
      'remote_status': 'active',
      'local_payload_json': jsonEncode(local),
      'remote_payload_json': jsonEncode(remote),
      'status': status,
      'detected_at': DateTime.now().toIso8601String(),
    });
  }

  Map<String, Object> payload(String path) => {
    'photos': [
      {'id': 'photo', 'localPath': path},
    ],
  };

  test(
    'saved references from every owner protect shared managed files',
    () async {
      final saved = await photo('saved');
      final shared = await photo('shared');
      final orphan = await photo('orphan');
      final otherOrphan = await photo('other-orphan', ownerKey: otherOwner);
      await saveReference('saved-record', saved.path, owner);
      await saveReference('imported-record', shared.path, otherOwner);

      expect(await cleanup.collectOwner(owner), 1);
      expect(await File(saved.path).exists(), isTrue);
      expect(await File(shared.path).exists(), isTrue);
      expect(await File(orphan.path).exists(), isFalse);
      expect(await File(otherOrphan.path).exists(), isTrue);
    },
  );

  test(
    'quarantined legacy records retain both photo formats before import',
    () async {
      final modern = await photo('quarantined-modern');
      final legacy = await photo('quarantined-legacy');
      final orphan = await photo('unreferenced');
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        'fishing_records',
        jsonEncode([
          {
            ...payload(modern.path),
            'photoPaths': [legacy.path],
          },
        ]),
      );

      expect(await cleanup.collectOwner(owner), 1);
      expect(await File(modern.path).exists(), isTrue);
      expect(await File(legacy.path).exists(), isTrue);
      expect(await File(orphan.path).exists(), isFalse);
    },
  );

  test(
    'malformed quarantined legacy records abort before deleting any file',
    () async {
      final selected = await photo('legacy-read-failure');
      final preferences = await SharedPreferences.getInstance();
      for (final encoded in [
        '{',
        '{}',
        '[7]',
        '[{"photos":"wrong"}]',
        '[{"photoPaths":[7]}]',
      ]) {
        await preferences.setString('fishing_records', encoded);
        await expectLater(
          cleanup.collectOwner(owner),
          throwsA(isA<FormatException>()),
        );
        expect(await File(selected.path).exists(), isTrue);
      }
      expect(backend.sweepCalls, 0);
    },
  );

  test(
    'unfinished requests, both conflict sides and free edits retain photos',
    () async {
      final protectedPaths = <String>[];
      for (final status in ['pending', 'sending', 'failed', 'conflicted']) {
        final selected = await photo(status);
        protectedPaths.add(selected.path);
        await outbox(status, status, payload(selected.path));
      }
      final legacy = await photo('legacy');
      final modern = await photo('modern');
      protectedPaths.addAll([legacy.path, modern.path]);
      await outbox('both-formats', 'pending', {
        ...payload(modern.path),
        'photoPaths': [legacy.path],
      }, ownerKey: otherOwner);

      for (final status in ['unresolved', 'resolving']) {
        final local = await photo('$status-local');
        final remote = await photo('$status-remote');
        protectedPaths.addAll([local.path, remote.path]);
        await conflict(
          status,
          status,
          payload(local.path),
          payload(remote.path),
        );
      }
      final free = await photo('free-edit');
      protectedPaths.add(free.path);
      final database = await AppDatabase.instance.database;
      await database.insert(AppDatabase.localRecordChangesTable, {
        'owner_key': owner,
        'record_id': 'free-edit',
        'operation_type': 'update',
        'payload_json': jsonEncode(payload(free.path)),
      });
      final orphan = await photo('orphan');

      expect(await cleanup.collectOwner(owner), 1);
      for (final path in protectedPaths) {
        expect(await File(path).exists(), isTrue, reason: path);
      }
      expect(await File(orphan.path).exists(), isFalse);
    },
  );

  test(
    'unknown nonfinal conflict status protects its photo references',
    () async {
      final selected = await photo('future-conflict-status');
      final database = await AppDatabase.instance.database;
      // Simulate a newer app's nonfinal state rather than treating it as resolved.
      await database.execute('PRAGMA ignore_check_constraints = ON');
      try {
        await conflict(
          'future-status',
          'future-state',
          payload(selected.path),
          {},
        );
      } finally {
        await database.execute('PRAGMA ignore_check_constraints = OFF');
      }

      expect(await cleanup.collectOwner(owner), 0);
      expect(await File(selected.path).exists(), isTrue);
    },
  );

  test(
    'completed history and free deletion snapshots do not pin files',
    () async {
      final completed = await photo('completed');
      final resolved = await photo('resolved');
      final deleted = await photo('deleted');
      await outbox('completed', 'succeeded', payload(completed.path));
      await conflict('resolved', 'resolved', payload(resolved.path), {});
      final database = await AppDatabase.instance.database;
      await database.insert(AppDatabase.localRecordChangesTable, {
        'owner_key': owner,
        'record_id': 'free-deleted',
        'operation_type': 'delete',
        'payload_json': jsonEncode(payload(deleted.path)),
      });

      expect(await cleanup.collectOwner(owner), 3);
      expect(await File(completed.path).exists(), isFalse);
      expect(await File(resolved.path).exists(), isFalse);
      expect(await File(deleted.path).exists(), isFalse);
    },
  );

  test(
    'shared draft pins survive one editor release and current-path updates',
    () async {
      final selected = await photo('shared-draft');
      final removed = await photo('removed-draft');
      final first = cleanup.createDraft(
        ownerKey: owner,
        paths: [selected.path, removed.path],
      );
      final second = cleanup.createDraft(
        ownerKey: owner,
        paths: [selected.path],
      );
      first.updatePaths([selected.path]);
      await cleanup.flushPending();
      expect(await File(removed.path).exists(), isFalse);
      expect(await File(selected.path).exists(), isTrue);

      await first.release();
      await first.release();
      expect(await File(selected.path).exists(), isTrue);
      await second.release();
      expect(await File(selected.path).exists(), isFalse);
    },
  );

  test(
    'write accepted before release is pinned until the queued write finishes',
    () async {
      backend.writeStarted = Completer<void>();
      backend.allowWrite = Completer<void>();
      final draft = cleanup.createDraft(ownerKey: owner);
      final writing = draft.persistSelection(
        recordId: 'in-flight',
        photoId: 'selected',
        bytes: Uint8List.fromList([0xff, 0xd8, 0x01, 0xd9]),
        contentType: 'image/jpeg',
      );
      await backend.writeStarted!.future;
      final collecting = cleanup.collectOwner(owner);
      final releasing = draft.release();
      expect(
        () => draft.persistSelection(
          recordId: 'late',
          photoId: 'late',
          bytes: Uint8List.fromList([1]),
        ),
        throwsStateError,
      );
      backend.allowWrite!.complete();

      final stored = await writing;
      // The explicit sweep queued before release still sees the write's pin.
      expect(await collecting, 0);
      await releasing;
      expect(await File(stored.path).exists(), isFalse);
    },
  );

  test(
    'malformed JSON or photo structure aborts before any file sweep',
    () async {
      final selected = await photo('do-not-delete');
      await outbox('malformed', 'pending', '{', rawPayload: true);
      final database = await AppDatabase.instance.database;
      for (final encoded in [
        '{',
        '[]',
        '{"photos":"wrong"}',
        '{"photos":[7]}',
        '{"photos":[{"localPath":7}]}',
        '{"photoPaths":[7]}',
      ]) {
        await database.update(
          AppDatabase.outboxItemsTable,
          {'payload_json': encoded},
          where: 'outbox_id = ?',
          whereArgs: ['malformed'],
        );
        await expectLater(
          cleanup.collectOwner(owner),
          throwsA(isA<FormatException>()),
        );
        expect(await File(selected.path).exists(), isTrue);
      }
      expect(backend.sweepCalls, 0);
      await database.delete(AppDatabase.outboxItemsTable);
      expect(await cleanup.collectOwner(owner), 1);
    },
  );

  test('database read failure preserves every managed file', () async {
    final selected = await photo('read-failure');
    final database = await AppDatabase.instance.database;
    await database.execute('DROP TABLE ${AppDatabase.recordConflictsTable}');

    await expectLater(cleanup.collectOwner(owner), throwsA(isA<Exception>()));
    expect(backend.sweepCalls, 0);
    expect(await File(selected.path).exists(), isTrue);
  });

  test(
    'failed background sweep is harmless and a later request retries',
    () async {
      final selected = await photo('retry');
      backend.failSweeps = 1;
      cleanup.requestCleanup(owner);
      cleanup.requestCleanup(owner);
      await cleanup.flushPending();
      expect(backend.sweepCalls, 1);
      expect(cleanup.lastError, isA<FileSystemException>());
      expect(await File(selected.path).exists(), isTrue);

      cleanup.requestCleanup(owner);
      await cleanup.flushPending();
      expect(backend.sweepCalls, 2);
      expect(cleanup.lastError, isNull);
      expect(await File(selected.path).exists(), isFalse);
    },
  );

  test(
    'draft created during asynchronous sweep is checked at deletion time',
    () async {
      final selected = await photo('late-pin');
      backend.sweepStarted = Completer<void>();
      backend.allowSweep = Completer<void>();
      final collecting = cleanup.collectOwner(owner);
      await backend.sweepStarted!.future;
      final draft = cleanup.createDraft(
        ownerKey: owner,
        paths: [selected.path],
      );
      backend.allowSweep!.complete();

      expect(await collecting, 0);
      expect(await File(selected.path).exists(), isTrue);
      await draft.release();
      expect(await File(selected.path).exists(), isFalse);
    },
  );
}

final class _ControlledBackend implements RecordPhotoFileStoreBackend {
  _ControlledBackend(this.delegate);

  final RecordPhotoFileStore delegate;
  Completer<void>? writeStarted;
  Completer<void>? allowWrite;
  Completer<void>? sweepStarted;
  Completer<void>? allowSweep;
  int sweepCalls = 0;
  int failSweeps = 0;

  @override
  Future<StoredRecordPhotoFile> persistSelection({
    required String ownerId,
    required String recordId,
    required String photoId,
    Uint8List? bytes,
    String? sourcePath,
    String? contentType,
  }) async {
    if (writeStarted?.isCompleted == false) writeStarted!.complete();
    await allowWrite?.future;
    return delegate.persistSelection(
      ownerId: ownerId,
      recordId: recordId,
      photoId: photoId,
      bytes: bytes,
      sourcePath: sourcePath,
      contentType: contentType,
    );
  }

  @override
  Future<int> deleteUnreferencedFiles({
    required String ownerId,
    required Set<String> retainedPaths,
    bool Function(String path)? isProtected,
  }) async {
    sweepCalls++;
    if (failSweeps > 0) {
      failSweeps--;
      throw const FileSystemException('Injected file-system failure');
    }
    if (sweepStarted?.isCompleted == false) sweepStarted!.complete();
    await allowSweep?.future;
    return delegate.deleteUnreferencedFiles(
      ownerId: ownerId,
      retainedPaths: retainedPaths,
      isProtected: isProtected,
    );
  }

  @override
  Future<Uint8List> readBytes(String path) => delegate.readBytes(path);

  @override
  Future<void> deleteOwnerFiles(String ownerId) =>
      delegate.deleteOwnerFiles(ownerId);
}
