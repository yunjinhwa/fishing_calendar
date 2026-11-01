import 'package:fishing_build/data/local/app_database.dart';
import 'package:fishing_build/data/local/data_owner_key.dart';
import 'package:fishing_build/data/local/local_data_store.dart';
import 'package:fishing_build/data/local/local_identity_migration_service.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/test_database.dart';

void main() {
  const email = 'legacy-photos@example.com';
  const uid = 'photos-uid';
  final source = DataOwnerKey.legacyEmail(email);
  final target = DataOwnerKey.firebaseUid(uid);
  final store = LocalDataStore.instance;
  final migrations = LocalIdentityMigrationService.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await resetTestDatabase();
  });

  tearDown(() => AppDatabase.instance.close());

  FishingRecord record({String id = 'record', String label = 'source'}) =>
      FishingRecord(
        id: id,
        location: '$label port',
        startAt: DateTime(2026, 8, 1, 18),
        endAt: DateTime(2026, 8, 2, 3),
        genreName: 'Fishing',
        catches: const [CatchRecord(speciesName: 'Fish', lengthCm: 32)],
        photos: [
          RecordPhoto(
            id: '$label-first',
            localPath: '$label/first.jpg',
            contentType: 'image/jpeg',
            sizeBytes: 4,
            checksum: '$label-checksum',
          ),
          RecordPhoto(id: '$label-second', localPath: '$label/second.jpg'),
        ],
      );

  Future<void> save(
    String ownerKey,
    FishingRecord record, {
    bool evict = false,
  }) => AppDatabase.instance.transaction((transaction) async {
    await store.insertRecord(transaction, ownerKey: ownerKey, record: record);
    if (evict) {
      await store.deleteRecord(
        transaction,
        ownerKey: ownerKey,
        recordId: record.id,
        preservePhotos: true,
      );
    }
  });

  Future<LocalIdentityMigrationResult> claim({bool allowInitialClaim = true}) =>
      migrations.claimLegacyMemberData(
        firebaseUid: uid,
        authenticatedEmail: email,
        allowInitialClaim: allowInitialClaim,
      );

  Future<List<Map<String, Object?>>> claims() async {
    final database = await AppDatabase.instance.database;
    return database.query(
      AppDatabase.localMetadataTable,
      where: 'metadata_key LIKE ?',
      whereArgs: ['firebase_owner_claim_v1:%'],
    );
  }

  test(
    'identity claim moves cached children and independent photo originals',
    () async {
      final original = record();
      await save(source, original);

      final result = await claim();
      expect(result.status, LocalIdentityMigrationStatus.migrated);
      expect(result.migratedRecordCount, 1);
      expect(result.migratedPhotoArchiveCount, 2);
      expect(result.migratedItemCount, 3);
      expect(await store.readRecordsForOwner(source), isEmpty);
      expect(await store.readArchivedRecordIdsForOwner(source), isEmpty);
      expect(
        (await store.readRecordForOwner(target, 'record'))!.toJson(),
        original.toJson(),
      );
      expect(
        (await store.readArchivedPhotosForRecord(
          target,
          'record',
        )).map((photo) => photo.toJson()),
        original.photos.map((photo) => photo.toJson()),
      );
      final database = await AppDatabase.instance.database;
      for (final table in [
        AppDatabase.recordPhotosTable,
        AppDatabase.recordCatchesTable,
      ]) {
        expect(
          await database.query(
            table,
            where: 'owner_key = ?',
            whereArgs: [source],
          ),
          isEmpty,
        );
      }
    },
  );

  test(
    'archive-only claim reports migrated data and is safe to repeat',
    () async {
      final original = record();
      await save(source, original, evict: true);

      final result = await claim();
      expect(result.status, LocalIdentityMigrationStatus.migrated);
      expect(result.migratedRecordCount, 0);
      expect(result.migratedPhotoArchiveCount, 2);
      expect(result.migratedItemCount, 2);
      expect(await store.readRecordsForOwner(source), isEmpty);
      expect(await store.readRecordsForOwner(target), isEmpty);
      expect(await store.readArchivedRecordIdsForOwner(source), isEmpty);
      expect(await store.readArchivedRecordIdsForOwner(target), {'record'});
      expect(
        (await store.readArchivedPhotosForRecord(
          target,
          'record',
        )).map((photo) => photo.toJson()),
        original.photos.map((photo) => photo.toJson()),
      );

      final repeated = await claim(allowInitialClaim: false);
      expect(repeated.status, LocalIdentityMigrationStatus.alreadyMigrated);
      expect(repeated.migratedItemCount, 0);
      expect(repeated.migratedPhotoArchiveCount, 0);
    },
  );

  for (final scenario in [
    (sourceEvicted: true, targetEvicted: false),
    (sourceEvicted: false, targetEvicted: true),
    (sourceEvicted: true, targetEvicted: true),
  ]) {
    test(
      'archive identity collision blocks claim with source eviction '
      '${scenario.sourceEvicted} and target eviction ${scenario.targetEvicted}',
      () async {
        await save(source, record(), evict: scenario.sourceEvicted);
        await save(
          target,
          record(label: 'target'),
          evict: scenario.targetEvicted,
        );

        await expectLater(
          claim(),
          throwsA(
            isA<LocalIdentityDataConflict>().having(
              (error) => error.recordIds,
              'colliding record IDs are deduplicated',
              ['record'],
            ),
          ),
        );
        expect(await claims(), isEmpty);
        expect(
          (await store.readArchivedPhotosForRecord(source, 'record')).first.id,
          'source-first',
        );
        expect(
          (await store.readArchivedPhotosForRecord(target, 'record')).first.id,
          'target-first',
        );
        expect(
          await store.readRecordForOwner(source, 'record'),
          scenario.sourceEvicted ? isNull : isNotNull,
        );
        expect(
          await store.readRecordForOwner(target, 'record'),
          scenario.targetEvicted ? isNull : isNotNull,
        );
      },
    );
  }

  test(
    'archive-only ID cannot collide with a target local deletion intent',
    () async {
      await save(source, record(), evict: true);
      await AppDatabase.instance.transaction((transaction) {
        return store.writeLocalRecordChange(
          transaction,
          ownerKey: target,
          record: record(label: 'target'),
          deleted: true,
        );
      });

      await expectLater(claim(), throwsA(isA<LocalIdentityDataConflict>()));
      expect(await store.readArchivedRecordIdsForOwner(source), {'record'});
      expect(await store.readArchivedRecordIdsForOwner(target), isEmpty);
      expect(await store.readLocalRecordChangesForOwner(target), hasLength(1));
      expect(await claims(), isEmpty);
    },
  );

  test(
    'archive move failure rolls back bodies, child photos and the claim',
    () async {
      final original = record();
      await save(source, original);
      await save(source, record(id: 'evicted'), evict: true);
      final database = await AppDatabase.instance.database;
      await database.execute('''
      CREATE TRIGGER reject_archive_identity_move
      BEFORE UPDATE OF owner_key ON ${AppDatabase.recordPhotoArchivesTable}
      BEGIN SELECT RAISE(ABORT, 'Injected archive identity failure'); END
    ''');

      await expectLater(claim(), throwsA(isA<DatabaseException>()));
      expect(
        (await store.readRecordForOwner(source, 'record'))!.toJson(),
        original.toJson(),
      );
      expect(await store.readArchivedRecordIdsForOwner(source), {
        'record',
        'evicted',
      });
      expect(await store.readRecordsForOwner(target), isEmpty);
      expect(await store.readArchivedRecordIdsForOwner(target), isEmpty);
      expect(await claims(), isEmpty);

      await database.execute('DROP TRIGGER reject_archive_identity_move');
      final retried = await claim();
      expect(retried.status, LocalIdentityMigrationStatus.migrated);
      expect(retried.migratedRecordCount, 1);
      expect(retried.migratedPhotoArchiveCount, 4);
    },
  );

  test(
    'unverified claim leaves archive-only data under its original owner',
    () async {
      await save(source, record(), evict: true);

      final result = await claim(allowInitialClaim: false);
      expect(result.status, LocalIdentityMigrationStatus.skippedUnverified);
      expect(result.migratedItemCount, 0);
      expect(await store.readArchivedRecordIdsForOwner(source), {'record'});
      expect(await store.readArchivedRecordIdsForOwner(target), isEmpty);
      expect(await claims(), isEmpty);
    },
  );
}
