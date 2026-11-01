import 'dart:io';

import 'package:fishing_build/data/local/app_database.dart';
import 'package:fishing_build/data/local/local_data_store.dart';
import 'package:fishing_build/data/models/conflict_item.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/outbox_item.dart';
import 'package:fishing_build/data/models/record_sync_metadata.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/test_database.dart';

void main() {
  const owner = 'member:coordinate-owner';
  const otherOwner = 'member:other-coordinate-owner';
  final store = LocalDataStore.instance;
  late Directory directory;

  setUp(() async {
    await resetTestDatabase();
    directory = await Directory.systemTemp.createTemp('coordinate-storage-');
  });

  tearDown(() async {
    await AppDatabase.instance.close();
    await directory.delete(recursive: true);
  });

  FishingRecord record(
    String id, {
    double? latitude,
    double? longitude,
    String species = 'Rockfish',
  }) => FishingRecord(
    id: id,
    location: 'Coordinate harbor',
    latitude: latitude,
    longitude: longitude,
    startAt: DateTime(2026, 10, 21, 18),
    endAt: DateTime(2026, 10, 22, 3),
    genreName: 'Lure',
    catches: [CatchRecord(speciesName: species, lengthCm: 33)],
    photos: const [
      RecordPhoto(id: 'original', localPath: 'C:/photos/original.jpg'),
    ],
    memo: 'Existing record contents',
  );

  Future<void> save(
    FishingRecord record, {
    String ownerKey = owner,
    bool replace = false,
  }) => AppDatabase.instance.transaction(
    (transaction) => store.insertRecord(
      transaction,
      ownerKey: ownerKey,
      record: record,
      replace: replace,
    ),
  );

  Future<Map<String, List<Map<String, Object?>>>> snapshot() async {
    final database = await AppDatabase.instance.database;
    return {
      for (final table in [
        AppDatabase.fishingRecordsTable,
        AppDatabase.recordCatchesTable,
        AppDatabase.recordPhotosTable,
        AppDatabase.recordPhotoArchivesTable,
        AppDatabase.outboxItemsTable,
        AppDatabase.recordSyncStatesTable,
        AppDatabase.recordConflictsTable,
        AppDatabase.localRecordChangesTable,
        AppDatabase.localMetadataTable,
      ])
        table: await database.query(table),
    };
  }

  Future<void> prepareV5Database() async {
    await AppDatabase.instance.configureForTesting(
      databaseFactory: databaseFactoryFfiNoIsolate,
      databasePath: path.join(directory.path, 'legacy-v5.db'),
    );
    final original = record('legacy');
    await save(original);
    await AppDatabase.instance.transaction((transaction) async {
      await store.insertOutboxItem(
        transaction,
        ownerKey: owner,
        item: OutboxItem(
          id: 'pending-v5',
          userId: 'coordinate-owner',
          recordId: original.id,
          operationType: OutboxOperationType.update,
          status: OutboxStatus.failed,
          createdAt: DateTime(2026, 10, 22),
          retryCount: 2,
          baseVersionNo: 3,
          payload: original.toJson(),
        ),
      );
      await store.writeRecordSyncMetadata(
        transaction,
        ownerKey: owner,
        metadata: RecordSyncMetadata(
          recordId: original.id,
          serverVersionNo: 3,
          optimisticVersionNo: 4,
          remoteStatus: RemoteRecordStatus.active,
        ),
      );
      await store.writeLocalRecordChange(
        transaction,
        ownerKey: owner,
        record: original,
        deleted: false,
      );
      await store.insertConflict(
        transaction,
        conflict: ConflictItem(
          id: 'v5-conflict',
          ownerKey: owner,
          recordId: original.id,
          outboxId: 'earlier-v5',
          localOperationType: OutboxOperationType.update,
          baseVersionNo: 2,
          remoteVersionNo: 3,
          remoteStatus: RemoteRecordStatus.active,
          localRecord: original,
          remoteRecord: original,
          occurredAt: DateTime(2026, 10, 22),
          status: ConflictStatus.unresolved,
        ),
      );
      await store.writeMetadata(
        transaction,
        key: 'existing-owner-checkpoint',
        value: 'existing-v5-progress',
      );
    });
    final database = await AppDatabase.instance.database;
    // Recreate the actual v5 table shape while preserving its original data,
    // indexes, child tables, metadata, and durable requests.
    await database.execute(
      'ALTER TABLE ${AppDatabase.fishingRecordsTable} DROP COLUMN longitude',
    );
    await database.execute(
      'ALTER TABLE ${AppDatabase.fishingRecordsTable} DROP COLUMN latitude',
    );
    await database.setVersion(5);
  }

  test(
    'v5 upgrade adds optional coordinates without rewriting durable data',
    () async {
      await prepareV5Database();
      final before = await snapshot();
      await AppDatabase.instance.close();

      final upgraded = await AppDatabase.instance.database;
      expect(await upgraded.getVersion(), AppDatabase.databaseVersion);
      final after = await snapshot();
      final updatedBodies = after[AppDatabase.fishingRecordsTable]!;
      for (final row in updatedBodies) {
        expect(row['latitude'], isNull);
        expect(row['longitude'], isNull);
      }
      after[AppDatabase.fishingRecordsTable] = updatedBodies
          .map(
            (row) => {
              for (final entry in row.entries)
                if (entry.key != 'latitude' && entry.key != 'longitude')
                  entry.key: entry.value,
            },
          )
          .toList();
      expect(after, before);
      final restored = (await store.readRecordForOwner(owner, 'legacy'))!;
      expect(restored.latitude, isNull);
      expect(restored.longitude, isNull);
      expect(restored.catches.single.speciesName, 'Rockfish');
      expect(restored.photos.single.localPath, 'C:/photos/original.jpg');
      expect(await upgraded.rawQuery('PRAGMA foreign_key_check'), isEmpty);

      await save(
        record('legacy', latitude: 35.0785, longitude: 129.0509),
        replace: true,
      );
      final positioned = (await store.readRecordForOwner(owner, 'legacy'))!;
      expect(positioned.latitude, 35.0785);
      expect(positioned.longitude, 129.0509);
    },
  );

  test(
    'coordinates survive reload, update and explicit removal per owner',
    () async {
      final first = record('same-id', latitude: 35.0785, longitude: 129.0509);
      final second = record('same-id', latitude: -33.8568, longitude: 151.2153);
      await save(first);
      await save(second, ownerKey: otherOwner);
      expect(
        (await store.readRecordsForOwner(owner)).single.toJson(),
        first.toJson(),
      );
      expect(
        (await store.readRecordForOwner(otherOwner, second.id))!.toJson(),
        second.toJson(),
      );
      final database = await AppDatabase.instance.database;
      final insertionOrder = (await database.query(
        AppDatabase.fishingRecordsTable,
        columns: ['insertion_order'],
        where: 'owner_key = ?',
        whereArgs: [owner],
      )).single['insertion_order'];

      final moved = record('same-id', latitude: 0, longitude: 0);
      await save(moved, replace: true);
      expect(
        (await store.readRecordForOwner(owner, first.id))!.toJson(),
        moved.toJson(),
      );
      final cleared = record('same-id');
      await save(cleared, replace: true);
      expect(
        (await store.readRecordForOwner(owner, first.id))!.toJson(),
        cleared.toJson(),
      );
      expect(
        (await store.readRecordForOwner(otherOwner, second.id))!.toJson(),
        second.toJson(),
      );
      expect(
        (await database.query(
          AppDatabase.fishingRecordsTable,
          columns: ['insertion_order'],
          where: 'owner_key = ?',
          whereArgs: [owner],
        )).single['insertion_order'],
        insertionOrder,
      );
      expect(
        (await store.readArchivedPhotosForRecord(owner, first.id)).single.id,
        'original',
      );
    },
  );

  for (final migrated in [false, true]) {
    test(
      'coordinate constraints match for ${migrated ? 'upgraded' : 'fresh'} databases',
      () async {
        if (migrated) {
          await prepareV5Database();
          await AppDatabase.instance.close();
          await AppDatabase.instance.database;
        }
        for (final (latitude, longitude) in [
          (-90.0, -180.0),
          (90.0, 180.0),
          (0.0, 0.0),
        ]) {
          final valid = record(
            'valid-$latitude',
            latitude: latitude,
            longitude: longitude,
          );
          await save(valid);
          expect(
            (await store.readRecordForOwner(owner, valid.id))!.toJson(),
            valid.toJson(),
          );
        }
        final invalid = <(double?, double?)>[
          (37, null),
          (null, 127),
          (90.000001, 127),
          (-90.000001, 127),
          (37, 180.000001),
          (37, -180.000001),
          (double.infinity, 127),
          (37, double.negativeInfinity),
          (double.nan, 127),
        ];
        for (var index = 0; index < invalid.length; index++) {
          final (latitude, longitude) = invalid[index];
          final id = 'invalid-$index';
          await expectLater(
            save(record(id, latitude: latitude, longitude: longitude)),
            throwsA(isA<DatabaseException>()),
          );
          expect(await store.readRecordForOwner(owner, id), isNull);
        }
      },
    );
  }

  test(
    'a child write failure rolls coordinates and original children back together',
    () async {
      final original = record(
        'rollback',
        latitude: 35.0785,
        longitude: 129.0509,
      );
      await save(original);
      final before = await snapshot();
      final database = await AppDatabase.instance.database;
      await database.execute('''
      CREATE TRIGGER reject_coordinate_replacement
      BEFORE INSERT ON ${AppDatabase.recordCatchesTable}
      WHEN NEW.species_name = 'Reject'
      BEGIN SELECT RAISE(ABORT, 'Injected child write failure'); END
    ''');

      await expectLater(
        save(
          record('rollback', latitude: 0, longitude: 0, species: 'Reject'),
          replace: true,
        ),
        throwsA(isA<DatabaseException>()),
      );

      expect(await snapshot(), before);
      expect(
        (await store.readRecordForOwner(owner, original.id))!.toJson(),
        original.toJson(),
      );
      expect(await database.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    },
  );
}
