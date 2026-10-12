import 'dart:convert';
import 'dart:io';

import 'package:fishing_build/data/local/app_database.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/outbox_item.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/repositories/outbox_repository.dart';
import 'package:fishing_build/data/services/record_mutation_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/test_database.dart';

void main() {
  final authSession = AuthSessionRepository.instance;
  final recordRepository = FishingRecordRepository.instance;
  final outboxRepository = OutboxRepository.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await resetTestDatabase();
    authSession.clearMemoryOnlyForTesting();
    recordRepository.clearCacheOnlyForTesting();
    outboxRepository.clearCacheOnlyForTesting();
  });

  test('record fields and ordered children survive a SQLite reload', () async {
    await authSession.setSessionForTesting(
      plan: UserPlan.free,
      email: 'sqlite@example.com',
    );
    final original = _record(
      id: 'sqlite-record',
      catches: const <CatchRecord>[
        CatchRecord(speciesName: '농어', lengthCm: 42.5, weightG: 1300),
        CatchRecord(speciesName: '광어', lengthCm: 51, weightG: 2200),
      ],
      photoPaths: const <String>['first.jpg', 'second.jpg'],
    );

    await recordRepository.addRecord(original);
    recordRepository.clearCacheOnlyForTesting();
    await recordRepository.loadRecords();

    final restored = recordRepository.getAllRecords().single;
    expect(restored.id, original.id);
    expect(restored.location, original.location);
    expect(restored.startAt, original.startAt);
    expect(restored.endAt, original.endAt);
    expect(restored.genreName, original.genreName);
    expect(restored.tide, original.tide);
    expect(restored.weather, original.weather);
    expect(restored.airTemperature, original.airTemperature);
    expect(restored.waterTemperature, original.waterTemperature);
    expect(restored.memo, original.memo);
    expect(restored.catches.map((item) => item.speciesName), <String>[
      '농어',
      '광어',
    ]);
    expect(restored.photoPaths, <String>['first.jpg', 'second.jpg']);

    final updated = _record(
      id: original.id,
      catches: const <CatchRecord>[
        CatchRecord(speciesName: '참돔', lengthCm: 38, weightG: 900),
      ],
      photoPaths: const <String>['updated.jpg'],
    );
    await recordRepository.updateRecord(updated);

    final database = await AppDatabase.instance.database;
    expect(
      Sqflite.firstIntValue(
        await database.rawQuery(
          'SELECT COUNT(*) FROM ${AppDatabase.recordCatchesTable}',
        ),
      ),
      1,
    );
    expect(
      Sqflite.firstIntValue(
        await database.rawQuery(
          'SELECT COUNT(*) FROM ${AppDatabase.recordPhotosTable}',
        ),
      ),
      1,
    );

    await recordRepository.deleteRecord(original.id);
    expect(
      Sqflite.firstIntValue(
        await database.rawQuery(
          'SELECT COUNT(*) FROM ${AppDatabase.recordCatchesTable}',
        ),
      ),
      0,
    );
    expect(
      Sqflite.firstIntValue(
        await database.rawQuery(
          'SELECT COUNT(*) FROM ${AppDatabase.recordPhotosTable}',
        ),
      ),
      0,
    );
  });

  test('local photo metadata survives a SQLite reload', () async {
    await authSession.setSessionForTesting(
      plan: UserPlan.free,
      email: 'photo-metadata@example.com',
    );
    final original = _record(
      id: 'photo-metadata-record',
      photos: const <RecordPhoto>[
        RecordPhoto(
          id: 'local-photo',
          localPath: 'local.jpg',
          contentType: 'image/jpeg',
          sizeBytes: 1234,
          checksum: 'local-checksum',
        ),
        RecordPhoto(
          id: 'second-local-photo',
          localPath: 'second-local.png',
          contentType: 'image/png',
          sizeBytes: 5678,
          checksum: 'cloud-checksum',
        ),
      ],
    );

    await recordRepository.addRecord(original);
    recordRepository.clearCacheOnlyForTesting();
    await recordRepository.loadRecords();

    final restored = recordRepository.getAllRecords().single;
    expect(restored.photos, hasLength(2));
    expect(restored.photos.first.id, 'local-photo');
    expect(restored.photos.first.localPath, 'local.jpg');
    expect(restored.photos.first.contentType, 'image/jpeg');
    expect(restored.photos.first.sizeBytes, 1234);
    expect(restored.photos.first.checksum, 'local-checksum');
    expect(restored.photos.last.id, 'second-local-photo');
    expect(restored.photos.last.localPath, 'second-local.png');
    expect(restored.photoPaths, <String>['local.jpg', 'second-local.png']);
  });

  test('legacy photoPaths JSON receives deterministic photo IDs', () {
    final json = _record(id: 'legacy-json').toJson()
      ..remove('photos')
      ..['photoPaths'] = <String>['first.jpg', 'second.jpg'];

    final restored = FishingRecord.fromJson(json);

    expect(restored.photos.map((photo) => photo.id), <String>[
      'legacy-0',
      'legacy-1',
    ]);
    expect(restored.photoPaths, <String>['first.jpg', 'second.jpg']);
    expect(
      FishingRecord.fromJson(restored.toJson()).photos.first.id,
      'legacy-0',
    );
  });

  test('photo metadata survives a record JSON round trip', () {
    final original = _record(
      id: 'photo-json',
      photos: const <RecordPhoto>[
        RecordPhoto(
          id: 'photo-id',
          localPath: 'photo.jpg',
          contentType: 'image/jpeg',
          sizeBytes: 4321,
          checksum: 'sha256-checksum',
        ),
      ],
    );

    final encoded = original.toJson();
    final restored = FishingRecord.fromJson(encoded);

    expect(encoded, contains('photos'));
    expect(encoded, isNot(contains('photoPaths')));
    expect(restored.photos.single.id, 'photo-id');
    expect(restored.photos.single.localPath, 'photo.jpg');
    expect(restored.photos.single.contentType, 'image/jpeg');
    expect(restored.photos.single.sizeBytes, 4321);
    expect(restored.photos.single.checksum, 'sha256-checksum');
  });

  test('scoped SharedPreferences data migrates once into SQLite', () async {
    final recordA = _record(id: 'legacy-a');
    final recordB = _record(id: 'legacy-b');
    final outboxItem = OutboxItem(
      id: 'legacy-outbox',
      userId: 'a@example.com',
      recordId: recordA.id,
      operationType: OutboxOperationType.create,
      status: OutboxStatus.pending,
      createdAt: DateTime(2026, 9, 21, 10),
      payload: recordA.toJson(),
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      'fishing_records_by_account_v1': jsonEncode(<String, Object>{
        'member:a@example.com': <Object>[recordA.toJson()],
        'member:b@example.com': <Object>[recordB.toJson()],
      }),
      'outbox_items_by_account_v1': jsonEncode(<String, Object>{
        'member:a@example.com': <Object>[outboxItem.toJson()],
      }),
    });
    await authSession.setSessionForTesting(
      plan: UserPlan.paid,
      email: 'a@example.com',
    );

    await recordRepository.loadRecords();
    await outboxRepository.loadItems();

    expect(recordRepository.getAllRecords().single.id, recordA.id);
    expect(outboxRepository.getAllItems().single.id, outboxItem.id);

    await authSession.setSessionForTesting(
      plan: UserPlan.free,
      email: 'b@example.com',
    );
    await recordRepository.loadRecords();
    await outboxRepository.loadItems();
    expect(recordRepository.getAllRecords().single.id, recordB.id);
    expect(outboxRepository.getAllItems(), isEmpty);

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('fishing_records_by_account_v1'), isNull);
    expect(preferences.getString('outbox_items_by_account_v1'), isNull);

    await recordRepository.loadRecords();
    final database = await AppDatabase.instance.database;
    expect(
      Sqflite.firstIntValue(
        await database.rawQuery(
          'SELECT COUNT(*) FROM ${AppDatabase.fishingRecordsTable}',
        ),
      ),
      2,
    );
  });

  test(
    'valid legacy records migrate while damaged data is preserved',
    () async {
      final validRecord = _record(id: 'valid-legacy-record');
      final recordsSource = jsonEncode(<String, Object>{
        'member:recover@example.com': <Object>[
          validRecord.toJson(),
          <String, Object>{'broken': true},
        ],
      });
      SharedPreferences.setMockInitialValues(<String, Object>{
        'fishing_records_by_account_v1': recordsSource,
        'outbox_items_by_account_v1': 'not-json',
      });
      await authSession.setSessionForTesting(
        plan: UserPlan.free,
        email: 'recover@example.com',
      );

      await recordRepository.loadRecords();

      expect(recordRepository.getAllRecords().single.id, validRecord.id);
      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getString('fishing_records_sqlite_migration_backup_v1'),
        recordsSource,
      );
      expect(preferences.getString('fishing_records_by_account_v1'), isNull);
      expect(preferences.getString('outbox_items_by_account_v1'), 'not-json');
    },
  );

  test('paid record and outbox writes are atomic', () async {
    await authSession.setSessionForTesting(
      plan: UserPlan.paid,
      email: 'atomic@example.com',
    );
    final record = _record(id: 'atomic-record');
    final database = await AppDatabase.instance.database;
    await database.execute('''
      CREATE TEMP TRIGGER force_outbox_failure
      BEFORE INSERT ON ${AppDatabase.outboxItemsTable}
      WHEN NEW.record_id = '${record.id}'
      BEGIN
        SELECT RAISE(ABORT, 'forced outbox failure');
      END
    ''');

    await expectLater(
      RecordMutationService.instance.addRecord(record),
      throwsA(isA<DatabaseException>()),
    );

    recordRepository.clearCacheOnlyForTesting();
    outboxRepository.clearCacheOnlyForTesting();
    await recordRepository.loadRecords();
    await outboxRepository.loadItems();

    expect(recordRepository.getAllRecords(), isEmpty);
    expect(outboxRepository.getAllItems(), isEmpty);
  });

  test('foreign keys are enabled for every database connection', () async {
    final database = await AppDatabase.instance.database;
    final result = await database.rawQuery('PRAGMA foreign_keys');
    expect(Sqflite.firstIntValue(result), 1);
  });

  test('database v1 photo paths migrate losslessly to database v2', () async {
    sqfliteFfiInit();
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'fishing-calendar-v1-',
    );
    final databasePath = path.join(
      temporaryDirectory.path,
      'migration-test.db',
    );
    addTearDown(() async {
      await AppDatabase.instance.resetForTesting();
      if (temporaryDirectory.existsSync()) {
        await temporaryDirectory.delete(recursive: true);
      }
    });

    final legacyDatabase = await databaseFactoryFfiNoIsolate.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (database, version) async {
          await database.execute('''
            CREATE TABLE ${AppDatabase.fishingRecordsTable} (
              insertion_order INTEGER PRIMARY KEY AUTOINCREMENT,
              owner_key TEXT NOT NULL,
              record_id TEXT NOT NULL,
              UNIQUE (owner_key, record_id)
            )
          ''');
          await database.execute('''
            CREATE TABLE ${AppDatabase.recordPhotosTable} (
              owner_key TEXT NOT NULL,
              record_id TEXT NOT NULL,
              display_order INTEGER NOT NULL,
              photo_path TEXT NOT NULL,
              PRIMARY KEY (owner_key, record_id, display_order),
              FOREIGN KEY (owner_key, record_id)
                REFERENCES ${AppDatabase.fishingRecordsTable}
                  (owner_key, record_id)
                ON UPDATE CASCADE
                ON DELETE CASCADE
            )
          ''');
        },
      ),
    );
    await legacyDatabase.insert(
      AppDatabase.fishingRecordsTable,
      <String, Object>{
        'owner_key': 'member:legacy',
        'record_id': 'legacy-record',
      },
    );
    await legacyDatabase.insert(AppDatabase.recordPhotosTable, <String, Object>{
      'owner_key': 'member:legacy',
      'record_id': 'legacy-record',
      'display_order': 0,
      'photo_path': 'legacy-photo.jpg',
    });
    await legacyDatabase.close();

    await AppDatabase.instance.configureForTesting(
      databaseFactory: databaseFactoryFfiNoIsolate,
      databasePath: databasePath,
    );
    final upgradedDatabase = await AppDatabase.instance.database;
    final rows = await upgradedDatabase.query(AppDatabase.recordPhotosTable);
    final columns = await upgradedDatabase.rawQuery(
      'PRAGMA table_info(${AppDatabase.recordPhotosTable})',
    );

    expect(
      Sqflite.firstIntValue(
        await upgradedDatabase.rawQuery('PRAGMA user_version'),
      ),
      AppDatabase.databaseVersion,
    );
    expect(rows, hasLength(1));
    expect(rows.single['photo_id'], 'legacy-0');
    expect(rows.single['local_path'], 'legacy-photo.jpg');
    expect(rows.single['storage_path'], isNull);
    expect(rows.single['display_order'], 0);
    expect(columns.map((column) => column['name']), contains('local_path'));
    expect(
      columns.map((column) => column['name']),
      isNot(contains('photo_path')),
    );
  });

  test('database v2 outbox migrates to conflict-aware schema', () async {
    sqfliteFfiInit();
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'fishing-calendar-v2-',
    );
    final databasePath = path.join(
      temporaryDirectory.path,
      'outbox-migration-test.db',
    );
    addTearDown(() async {
      await AppDatabase.instance.resetForTesting();
      if (temporaryDirectory.existsSync()) {
        await temporaryDirectory.delete(recursive: true);
      }
    });

    final legacyDatabase = await databaseFactoryFfiNoIsolate.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: (database, version) async {
          await database.execute('''
            CREATE TABLE ${AppDatabase.outboxItemsTable} (
              insertion_order INTEGER PRIMARY KEY AUTOINCREMENT,
              owner_key TEXT NOT NULL,
              outbox_id TEXT NOT NULL,
              user_id TEXT,
              record_id TEXT NOT NULL,
              operation_type TEXT NOT NULL,
              status TEXT NOT NULL,
              created_at TEXT NOT NULL,
              last_tried_at TEXT,
              error_message TEXT,
              retry_count INTEGER NOT NULL DEFAULT 0,
              is_migration INTEGER NOT NULL DEFAULT 0,
              payload_json TEXT,
              UNIQUE (owner_key, outbox_id)
            )
          ''');
        },
      ),
    );
    await legacyDatabase.insert(AppDatabase.outboxItemsTable, <String, Object?>{
      'owner_key': 'member:legacy-v2',
      'outbox_id': 'legacy-outbox',
      'user_id': 'legacy-v2',
      'record_id': 'legacy-record',
      'operation_type': 'update',
      'status': 'pending',
      'created_at': DateTime(2026, 9, 1).toIso8601String(),
      'retry_count': 2,
      'is_migration': 0,
      'payload_json': jsonEncode(<String, Object?>{'id': 'legacy-record'}),
    });
    await legacyDatabase.close();

    await AppDatabase.instance.configureForTesting(
      databaseFactory: databaseFactoryFfiNoIsolate,
      databasePath: databasePath,
    );
    final upgradedDatabase = await AppDatabase.instance.database;
    final rows = await upgradedDatabase.query(AppDatabase.outboxItemsTable);
    final outboxColumns = await upgradedDatabase.rawQuery(
      'PRAGMA table_info(${AppDatabase.outboxItemsTable})',
    );
    final tables = await upgradedDatabase.rawQuery('''
      SELECT name
      FROM sqlite_master
      WHERE type = 'table'
      ''');

    expect(rows, hasLength(1));
    expect(rows.single['outbox_id'], 'legacy-outbox');
    expect(rows.single['retry_count'], 2);
    expect(rows.single['base_version_no'], isNull);
    expect(
      outboxColumns.map((column) => column['name']),
      contains('base_version_no'),
    );
    expect(
      tables.map((table) => table['name']),
      containsAll(<String>[
        AppDatabase.recordSyncStatesTable,
        AppDatabase.recordConflictsTable,
      ]),
    );

    await upgradedDatabase
        .insert(AppDatabase.outboxItemsTable, <String, Object?>{
          'owner_key': 'member:legacy-v2',
          'outbox_id': 'conflicted-outbox',
          'record_id': 'legacy-record',
          'operation_type': 'update',
          'status': 'conflicted',
          'created_at': DateTime(2026, 9, 2).toIso8601String(),
          'retry_count': 0,
          'is_migration': 0,
          'base_version_no': 4,
        });
  });
}

FishingRecord _record({
  required String id,
  List<CatchRecord> catches = const <CatchRecord>[],
  List<RecordPhoto> photos = const <RecordPhoto>[],
  List<String> photoPaths = const <String>[],
}) {
  return FishingRecord(
    id: id,
    location: '테스트 방파제',
    startAt: DateTime(2026, 9, 21, 6, 30),
    endAt: DateTime(2026, 9, 21, 9, 45),
    genreName: '루어',
    tide: '7물',
    weather: '맑음',
    airTemperature: 22.5,
    waterTemperature: 19.2,
    catches: catches,
    photos: photos,
    photoPaths: photoPaths,
    memo: 'SQLite 왕복 테스트',
  );
}
