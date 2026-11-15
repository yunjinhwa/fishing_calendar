import 'dart:io';

import 'package:fishing_build/data/local/app_database.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/services/app_startup_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  final appDatabase = AppDatabase.instance;
  late Directory directory;
  late File databaseFile;
  late _FailOnceFactory factory;
  late _DatabaseSnapshot originalRows;

  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('startup-db-recovery-');
    databaseFile = File(path.join(directory.path, 'records.db'));
    factory = _FailOnceFactory();
    await appDatabase.configureForTesting(
      databaseFactory: factory,
      databasePath: databaseFile.path,
    );
    final database = await appDatabase.database;
    await _seedDurableData(database);
    originalRows = await _rows(database);
    await appDatabase.close();
    factory.openCalls = 0;
  });

  tearDown(() async {
    await appDatabase.close();
    await appDatabase.configureForTesting(
      databaseFactory: databaseFactoryFfiNoIsolate,
    );
    expect(
      path.isWithin(
        Directory.systemTemp.resolveSymbolicLinksSync(),
        directory.resolveSymbolicLinksSync(),
      ),
      isTrue,
    );
    await directory.delete(recursive: true);
  });

  test('file database open failure preserves bytes and permits retry', () async {
    final originalBytes = await databaseFile.readAsBytes();
    factory.failConfigureOnce = true;

    await expectLater(appDatabase.database, throwsA(isA<DatabaseException>()));

    expect(factory.openCalls, 1);
    expect(factory.deleteCalls, 0);
    expect(databaseFile.existsSync(), isTrue);
    expect(await databaseFile.readAsBytes(), originalBytes);

    // Retry the same getter without closing, resetting, or replacing the file.
    final recovered = await appDatabase.database;
    expect(factory.openCalls, 2);
    expect(await recovered.getVersion(), AppDatabase.databaseVersion);
    expect(await _rows(recovered), originalRows);
    expect(await appDatabase.database, same(recovered));
    expect(factory.openCalls, 2);
    expect(factory.deleteCalls, 0);
  });

  test(
    'production startup stops before auth when opening SQLite fails',
    () async {
      factory.failConfigureOnce = true;
      final generation = AuthSessionRepository.instance.sessionGeneration;
      final controller = AppStartupController.production();
      addTearDown(controller.dispose);

      await controller.start();

      expect(controller.state, AppStartupState.failed);
      expect(controller.stage, AppStartupStage.storage);
      expect(controller.lastError, isA<DatabaseException>());
      expect(AuthSessionRepository.instance.sessionGeneration, generation);
      expect(factory.deleteCalls, 0);
    },
  );

  test('failed v5 upgrade rolls back durable data and permits retry', () async {
    final database = await appDatabase.database;
    // Match the existing v5 fixture without rebuilding records or child tables.
    await database.execute(
      'ALTER TABLE ${AppDatabase.fishingRecordsTable} DROP COLUMN longitude',
    );
    await database.execute(
      'ALTER TABLE ${AppDatabase.fishingRecordsTable} DROP COLUMN latitude',
    );
    await database.setVersion(5);
    final originalV5 = await _snapshot(database);
    await appDatabase.close();
    factory.openCalls = 0;
    factory.failUpgradeOnce = true;

    await expectLater(appDatabase.database, throwsA(isA<DatabaseException>()));

    expect(factory.openCalls, 1);
    expect(factory.sawBothCoordinatesBeforeFailure, isTrue);
    expect(factory.deleteCalls, 0);
    expect(databaseFile.existsSync(), isTrue);

    // Inspect the file independently, without triggering another upgrade.
    final preserved = await databaseFactoryFfiNoIsolate.openDatabase(
      databaseFile.path,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
    try {
      expect(await preserved.getVersion(), 5);
      expect(await _snapshot(preserved), originalV5);
      expect(
        (await preserved.rawQuery(
          'PRAGMA table_info(${AppDatabase.fishingRecordsTable})',
        )).map((column) => column['name']),
        isNot(anyOf(contains('latitude'), contains('longitude'))),
      );
      expect(await preserved.rawQuery('PRAGMA foreign_key_check'), isEmpty);
      expect(await preserved.rawQuery('PRAGMA integrity_check'), [
        {'integrity_check': 'ok'},
      ]);
    } finally {
      await preserved.close();
    }

    // The failed future must not remain cached after the rollback.
    final recovered = await appDatabase.database;
    expect(factory.openCalls, 2);
    expect(await recovered.getVersion(), AppDatabase.databaseVersion);
    expect(await _rows(recovered), originalRows);
    expect(await recovered.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    expect(factory.deleteCalls, 0);
  });
}

typedef _DatabaseSnapshot = Map<String, List<Map<String, Object?>>>;

Future<_DatabaseSnapshot> _rows(Database database) async => {
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
    table: await database.query(table, orderBy: 'rowid'),
};

Future<_DatabaseSnapshot> _snapshot(Database database) async => {
  ...await _rows(database),
  'sqlite_master': await database.rawQuery(
    'SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name',
  ),
};

Future<void> _seedDurableData(Database database) async {
  const owner = 'member:recovery@example.com';
  const record = 'original-record';
  const timestamp = '2026-11-01T06:00:00.000Z';
  await database.transaction((transaction) async {
    await transaction.insert(AppDatabase.fishingRecordsTable, {
      'owner_key': owner,
      'record_id': record,
      'location': 'Original harbor',
      'start_at': timestamp,
      'end_at': '2026-11-01T09:00:00.000Z',
      'genre_name': 'Lure',
      'memo': 'Preserve this original record',
    });
    await transaction.insert(AppDatabase.recordCatchesTable, {
      'owner_key': owner,
      'record_id': record,
      'display_order': 0,
      'species_name': 'Rockfish',
      'length_cm': 33.5,
    });
    const photo = {
      'owner_key': owner,
      'record_id': record,
      'photo_id': 'original-photo',
      'local_path': 'original-photo.jpg',
      'display_order': 0,
      'file_size': 1234,
      'checksum': 'original-checksum',
    };
    await transaction.insert(AppDatabase.recordPhotosTable, photo);
    await transaction.insert(AppDatabase.recordPhotoArchivesTable, photo);
    await transaction.insert(AppDatabase.outboxItemsTable, {
      'owner_key': owner,
      'outbox_id': 'pending-update',
      'user_id': 'recovery@example.com',
      'record_id': record,
      'operation_type': 'update',
      'status': 'failed',
      'created_at': timestamp,
      'retry_count': 2,
      'base_version_no': 3,
      'payload_json': '{"id":"original-record"}',
    });
    await transaction.insert(AppDatabase.recordSyncStatesTable, {
      'owner_key': owner,
      'record_id': record,
      'server_version_no': 3,
      'optimistic_version_no': 4,
      'remote_status': 'active',
      'updated_at': timestamp,
    });
    await transaction.insert(AppDatabase.recordConflictsTable, {
      'owner_key': owner,
      'conflict_id': 'original-conflict',
      'record_id': record,
      'outbox_id': 'earlier-update',
      'operation_type': 'update',
      'base_version_no': 2,
      'remote_version_no': 3,
      'remote_status': 'active',
      'status': 'unresolved',
      'detected_at': timestamp,
    });
    await transaction.insert(AppDatabase.localRecordChangesTable, {
      'owner_key': owner,
      'record_id': record,
      'operation_type': 'update',
      'payload_json': '{"id":"original-record"}',
    });
    await transaction.insert(AppDatabase.localMetadataTable, {
      'metadata_key': 'original-owner-checkpoint',
      'metadata_value': 'preserve-migration-progress',
      'updated_at': timestamp,
    });
  });
}

class _FailOnceFactory implements DatabaseFactory {
  bool failConfigureOnce = false;
  bool failUpgradeOnce = false;
  bool sawBothCoordinatesBeforeFailure = false;
  int openCalls = 0;
  int deleteCalls = 0;

  @override
  Future<Database> openDatabase(
    String path, {
    OpenDatabaseOptions? options,
  }) async {
    openCalls++;
    if (failConfigureOnce) {
      failConfigureOnce = false;
      final configure = options!.onConfigure;
      options.onConfigure = (database) async {
        await configure?.call(database);
        await _failWithSqliteError(database);
      };
    }
    if (failUpgradeOnce) {
      failUpgradeOnce = false;
      final upgrade = options!.onUpgrade;
      options.onUpgrade = (database, oldVersion, newVersion) async {
        await upgrade!(database, oldVersion, newVersion);
        final names = (await database.rawQuery(
          'PRAGMA table_info(${AppDatabase.fishingRecordsTable})',
        )).map((column) => column['name']).toSet();
        sawBothCoordinatesBeforeFailure =
            names.contains('latitude') && names.contains('longitude');
        await _failWithSqliteError(database);
      };
    }
    return databaseFactoryFfiNoIsolate.openDatabase(path, options: options);
  }

  @override
  Future<void> deleteDatabase(String path) async {
    deleteCalls++;
    throw StateError('Recovery must not delete the existing database');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _failWithSqliteError(Database database) => database.execute(
  'INSERT INTO deliberately_missing_recovery_test_table VALUES (1)',
);
