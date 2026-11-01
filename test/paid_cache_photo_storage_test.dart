import 'dart:io';
import 'dart:typed_data';

import 'package:fishing_build/data/local/app_database.dart';
import 'package:fishing_build/data/local/local_data_store.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/photos/record_photo_file_store.dart';
import 'package:fishing_build/data/services/record_photo_cleanup_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/test_database.dart';

void main() {
  const owner = 'member:cache-photo-owner';
  const otherOwner = 'member:other-cache-photo-owner';
  final store = LocalDataStore.instance;
  late Directory directory;
  late RecordPhotoFileStore files;
  late RecordPhotoCleanupService cleanup;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await resetTestDatabase();
    directory = await Directory.systemTemp.createTemp('paid-cache-photos-');
    files = RecordPhotoFileStore(
      supportPathProvider: () async => directory.path,
    );
    cleanup = RecordPhotoCleanupService(fileStore: files);
  });

  tearDown(() async {
    await cleanup.flushPending();
    await AppDatabase.instance.close();
    await directory.delete(recursive: true);
  });

  FishingRecord record({
    String id = 'record',
    List<RecordPhoto> photos = const [],
    String location = 'Port',
  }) => FishingRecord(
    id: id,
    location: location,
    startAt: DateTime(2026, 8, 1, 18),
    endAt: DateTime(2026, 8, 2, 3),
    genreName: 'Fishing',
    catches: const [CatchRecord(speciesName: 'Fish', lengthCm: 32)],
    photos: photos,
  );

  Future<void> save(
    FishingRecord record, {
    String ownerKey = owner,
    bool replace = false,
  }) => AppDatabase.instance.transaction((transaction) {
    return store.insertRecord(
      transaction,
      ownerKey: ownerKey,
      record: record,
      replace: replace,
    );
  });

  Future<void> remove(
    String recordId, {
    String ownerKey = owner,
    bool preservePhotos = false,
  }) => AppDatabase.instance.transaction((transaction) {
    return store.deleteRecord(
      transaction,
      ownerKey: ownerKey,
      recordId: recordId,
      preservePhotos: preservePhotos,
    );
  });

  Future<RecordPhoto> photo(String id) async {
    final stored = await files.persistSelection(
      ownerId: owner,
      recordId: 'record',
      photoId: id,
      bytes: Uint8List.fromList([0xff, 0xd8, id.length, 0xd9]),
      contentType: 'image/jpeg',
    );
    return RecordPhoto(
      id: id,
      localPath: stored.path,
      contentType: 'image/jpeg',
      sizeBytes: 4,
      checksum: 'checksum-$id',
    );
  }

  Future<String> prepareV4Database(FishingRecord existing) async {
    final databasePath = path.join(directory.path, 'v4.db');
    await AppDatabase.instance.configureForTesting(
      databaseFactory: databaseFactoryFfiNoIsolate,
      databasePath: databasePath,
    );
    await save(existing);
    final database = await AppDatabase.instance.database;
    // The prior schema is the current schema without the independent archive.
    await database.execute(
      'DROP TABLE ${AppDatabase.recordPhotoArchivesTable}',
    );
    await database.setVersion(4);
    return databasePath;
  }

  test(
    'v4 upgrade copies ordered photo metadata without a body dependency',
    () async {
      final first = await photo('first');
      final second = await photo('second');
      await prepareV4Database(record(photos: [second, first]));
      await AppDatabase.instance.close();

      final upgraded = await AppDatabase.instance.database;
      expect(await upgraded.getVersion(), AppDatabase.databaseVersion);
      expect(
        (await store.readArchivedPhotosForRecord(
          owner,
          'record',
        )).map((item) => item.toJson()),
        [second.toJson(), first.toJson()],
      );
      expect(
        await upgraded.rawQuery(
          'PRAGMA foreign_key_list(${AppDatabase.recordPhotoArchivesTable})',
        ),
        isEmpty,
      );

      await remove('record', preservePhotos: true);
      expect(await store.readRecordForOwner(owner, 'record'), isNull);
      expect(await store.readArchivedRecordIdsForOwner(owner), {'record'});
      expect(await cleanup.collectOwner(owner), 0);
      expect(await File(first.localPath!).exists(), isTrue);
      expect(await File(second.localPath!).exists(), isTrue);
    },
  );

  test(
    'failed v4 photo copy leaves the version and original rows unchanged',
    () async {
      final first = await photo('first');
      final second = await photo('second');
      final databasePath = await prepareV4Database(
        record(photos: [first, second]),
      );
      final database = await AppDatabase.instance.database;
      await database.execute('''
      CREATE TABLE ${AppDatabase.recordPhotoArchivesTable}
      AS SELECT * FROM ${AppDatabase.recordPhotosTable} WHERE 0
    ''');
      await database.execute('''
      CREATE TRIGGER reject_archive_copy
      BEFORE INSERT ON ${AppDatabase.recordPhotoArchivesTable}
      WHEN NEW.photo_id = 'second'
      BEGIN SELECT RAISE(ABORT, 'Injected archive copy failure'); END
    ''');
      await AppDatabase.instance.close();

      await expectLater(
        AppDatabase.instance.database,
        throwsA(isA<DatabaseException>()),
      );
      final unchanged = await databaseFactoryFfiNoIsolate.openDatabase(
        databasePath,
      );
      try {
        expect(await unchanged.getVersion(), 4);
        expect(
          await unchanged.query(AppDatabase.recordPhotoArchivesTable),
          isEmpty,
        );
        expect(
          (await unchanged.query(AppDatabase.recordPhotosTable)).length,
          2,
        );
      } finally {
        await unchanged.close();
      }
    },
  );

  test(
    'body eviction retains the original while removing unrelated files',
    () async {
      final original = await photo('original');
      final orphan = await photo('orphan');
      await save(record(photos: [original]));

      await remove('record', preservePhotos: true);
      final database = await AppDatabase.instance.database;
      expect(await database.query(AppDatabase.fishingRecordsTable), isEmpty);
      expect(await database.query(AppDatabase.recordPhotosTable), isEmpty);
      expect(await database.query(AppDatabase.recordCatchesTable), isEmpty);
      expect(await cleanup.collectOwner(owner), 1);
      expect(await File(original.localPath!).exists(), isTrue);
      expect(await File(orphan.localPath!).exists(), isFalse);
      expect(
        (await store.readArchivedPhotosForRecord(
          owner,
          'record',
        )).single.toJson(),
        original.toJson(),
      );
    },
  );

  test(
    'explicit photo removal releases the archive after restoring a body',
    () async {
      final original = await photo('original');
      await save(record(photos: [original]));
      await remove('record', preservePhotos: true);
      final archived = await store.readArchivedPhotosForRecord(owner, 'record');
      await save(record(photos: archived));

      await save(record(location: 'Edited port'), replace: true);
      expect(
        (await store.readRecordForOwner(owner, 'record'))!.photos,
        isEmpty,
      );
      expect(await store.readArchivedPhotosForRecord(owner, 'record'), isEmpty);
      expect(await store.readArchivedRecordIdsForOwner(owner), isEmpty);
      expect(await cleanup.collectOwner(owner), 1);
      expect(await File(original.localPath!).exists(), isFalse);
    },
  );

  test(
    'archive write failure rolls back the whole record replacement',
    () async {
      final original = await photo('original');
      final rejected = await photo('rejected');
      final before = record(photos: [original]);
      await save(before);
      final database = await AppDatabase.instance.database;
      await database.execute('''
      CREATE TRIGGER reject_archive_save
      BEFORE INSERT ON ${AppDatabase.recordPhotoArchivesTable}
      WHEN NEW.photo_id = 'rejected'
      BEGIN SELECT RAISE(ABORT, 'Injected archive save failure'); END
    ''');

      await expectLater(
        save(record(location: 'Changed', photos: [rejected]), replace: true),
        throwsA(isA<DatabaseException>()),
      );
      expect(
        (await store.readRecordForOwner(owner, 'record'))!.toJson(),
        before.toJson(),
      );
      expect(
        (await store.readArchivedPhotosForRecord(
          owner,
          'record',
        )).single.toJson(),
        original.toJson(),
      );
      expect(await cleanup.collectOwner(owner), 1);
      expect(await File(original.localPath!).exists(), isTrue);
      expect(await File(rejected.localPath!).exists(), isFalse);
    },
  );

  test('real deletion clears both cached and archive-only records', () async {
    final cached = await photo('cached');
    final evicted = await photo('evicted');
    await save(record(id: 'cached', photos: [cached]));
    await save(record(id: 'evicted', photos: [evicted]));
    await remove('evicted', preservePhotos: true);

    await remove('cached');
    await remove('evicted');
    await remove('evicted');
    expect(await store.readRecordsForOwner(owner), isEmpty);
    expect(await store.readArchivedRecordIdsForOwner(owner), isEmpty);
    expect(await cleanup.collectOwner(owner), 2);
    expect(await File(cached.localPath!).exists(), isFalse);
    expect(await File(evicted.localPath!).exists(), isFalse);
  });

  test(
    'owner purge and full record clear isolate other owners and shared paths',
    () async {
      final shared = await photo('shared');
      await save(record(photos: [shared]));
      await save(record(photos: [shared]), ownerKey: otherOwner);
      await remove('record', preservePhotos: true);
      await remove('record', ownerKey: otherOwner, preservePhotos: true);

      await AppDatabase.instance.transaction((transaction) {
        return store.deleteOwnerData(transaction, ownerKey: owner);
      });
      expect(await store.readArchivedRecordIdsForOwner(owner), isEmpty);
      expect(await store.readArchivedRecordIdsForOwner(otherOwner), {'record'});
      // A surviving owner's archive can refer to a file in the purged owner's
      // directory after importing records on the same device.
      expect(await cleanup.collectOwner(owner), 0);
      expect(await File(shared.localPath!).exists(), isTrue);

      await AppDatabase.instance.transaction((transaction) {
        return store.deleteAllRecords(transaction, ownerKey: otherOwner);
      });
      expect(await store.readArchivedRecordIdsForOwner(otherOwner), isEmpty);
      expect(await cleanup.collectOwner(owner), 1);
      expect(await File(shared.localPath!).exists(), isFalse);
    },
  );

  test('archive-only deletion is scoped to one owner and one record', () async {
    const original = RecordPhoto(id: 'photo', localPath: 'original.jpg');
    for (final ownerKey in [owner, otherOwner]) {
      for (final id in ['first', 'second']) {
        await save(
          record(id: id, photos: [original]),
          ownerKey: ownerKey,
        );
        await remove(id, ownerKey: ownerKey, preservePhotos: true);
      }
    }

    await AppDatabase.instance.transaction((transaction) async {
      await store.deleteArchivedPhotosForRecord(
        transaction,
        ownerKey: owner,
        recordId: 'first',
      );
      expect(
        await store.readArchivedRecordIdsForOwner(owner, executor: transaction),
        {'second'},
      );
      expect(
        (await store.readArchivedPhotosForRecord(
          otherOwner,
          'first',
          executor: transaction,
        )).single.toJson(),
        original.toJson(),
      );
    });
    expect(await store.readArchivedRecordIdsForOwner(otherOwner), {
      'first',
      'second',
    });
  });

  test(
    'a corrupt archived path aborts cleanup before any file is removed',
    () async {
      final original = await photo('original');
      final orphan = await photo('orphan');
      await save(record(photos: [original]));
      await remove('record', preservePhotos: true);
      final database = await AppDatabase.instance.database;
      // SQLite permits a BLOB in a TEXT column; fail closed on malformed data.
      await database.update(
        AppDatabase.recordPhotoArchivesTable,
        {
          'local_path': Uint8List.fromList([1, 2, 3]),
        },
        where: 'owner_key = ? AND record_id = ?',
        whereArgs: [owner, 'record'],
      );

      await expectLater(
        cleanup.collectOwner(owner),
        throwsA(isA<FormatException>()),
      );
      expect(await File(original.localPath!).exists(), isTrue);
      expect(await File(orphan.localPath!).exists(), isTrue);
    },
  );
}
