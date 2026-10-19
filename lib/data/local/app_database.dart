import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart' as sqflite;

import 'database_factory.dart';

class AppDatabase {
  AppDatabase._();

  static final AppDatabase instance = AppDatabase._();

  static const String databaseName = 'fishing_calendar.db';
  static const int databaseVersion = 4;

  static const String localMetadataTable = 'local_metadata';
  static const String fishingRecordsTable = 'fishing_records';
  static const String recordCatchesTable = 'record_catches';
  static const String recordPhotosTable = 'record_photos';
  static const String outboxItemsTable = 'outbox_items';
  static const String recordSyncStatesTable = 'record_sync_states';
  static const String recordConflictsTable = 'record_conflicts';
  static const String localRecordChangesTable = 'local_record_changes';

  static const String legacyRecordsPreferencesMigrationKey =
      'records_shared_preferences_to_sqlite_v1';
  static const String legacyOutboxPreferencesMigrationKey =
      'outbox_shared_preferences_to_sqlite_v1';
  static const String migrationPendingValue = 'pending';
  static const String migrationCompletedValue = 'completed';

  sqflite.Database? _database;
  Future<sqflite.Database>? _openingDatabase;
  sqflite.DatabaseFactory? _databaseFactoryOverride;
  String? _databasePathOverride;

  Future<sqflite.Database> get database async {
    final openDatabase = _database;
    if (openDatabase != null && openDatabase.isOpen) {
      return openDatabase;
    }

    final pendingOpen = _openingDatabase;
    if (pendingOpen != null) {
      return pendingOpen;
    }

    final openFuture = _openDatabase();
    _openingDatabase = openFuture;

    try {
      final database = await openFuture;
      _database = database;
      return database;
    } finally {
      _openingDatabase = null;
    }
  }

  Future<T> transaction<T>(
    Future<T> Function(sqflite.Transaction transaction) action, {
    bool? exclusive,
  }) async {
    final database = await this.database;
    return database.transaction(action, exclusive: exclusive);
  }

  Future<sqflite.Database> _openDatabase() async {
    final factory = _databaseFactoryOverride ?? createLocalDatabaseFactory();
    final databasePath =
        _databasePathOverride ??
        path.join(await factory.getDatabasesPath(), databaseName);

    return factory.openDatabase(
      databasePath,
      options: sqflite.OpenDatabaseOptions(
        version: databaseVersion,
        onConfigure: (database) async {
          await database.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: _createSchema,
        onUpgrade: _upgradeSchema,
      ),
    );
  }

  Future<void> _createSchema(sqflite.Database database, int version) async {
    final batch = database.batch();

    batch.execute('''
      CREATE TABLE $localMetadataTable (
        metadata_key TEXT NOT NULL PRIMARY KEY,
        metadata_value TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    batch.execute('''
      CREATE TABLE $fishingRecordsTable (
        insertion_order INTEGER PRIMARY KEY AUTOINCREMENT,
        owner_key TEXT NOT NULL,
        record_id TEXT NOT NULL,
        location TEXT NOT NULL,
        start_at TEXT NOT NULL,
        end_at TEXT NOT NULL,
        genre_name TEXT NOT NULL,
        tide TEXT,
        weather TEXT,
        air_temperature REAL,
        water_temperature REAL,
        memo TEXT,
        UNIQUE (owner_key, record_id)
      )
    ''');

    batch.execute('''
      CREATE TABLE $recordCatchesTable (
        owner_key TEXT NOT NULL,
        record_id TEXT NOT NULL,
        display_order INTEGER NOT NULL,
        species_name TEXT NOT NULL,
        length_cm REAL,
        weight_g INTEGER,
        PRIMARY KEY (owner_key, record_id, display_order),
        FOREIGN KEY (owner_key, record_id)
          REFERENCES $fishingRecordsTable (owner_key, record_id)
          ON UPDATE CASCADE
          ON DELETE CASCADE
      )
    ''');

    batch.execute(_createRecordPhotosTableSql(recordPhotosTable));

    batch.execute(_createOutboxItemsTableSql(outboxItemsTable));
    batch.execute(_createRecordSyncStatesTableSql(recordSyncStatesTable));
    batch.execute(_createRecordConflictsTableSql(recordConflictsTable));
    batch.execute(_createLocalRecordChangesTableSql);

    batch.execute('''
      CREATE INDEX idx_fishing_records_owner_start
      ON $fishingRecordsTable (owner_key, start_at)
    ''');

    batch.execute('''
      CREATE INDEX idx_fishing_records_owner_end
      ON $fishingRecordsTable (owner_key, end_at)
    ''');

    batch.execute('''
      CREATE INDEX idx_outbox_owner_status_order
      ON $outboxItemsTable (owner_key, status, insertion_order)
    ''');

    batch.execute('''
      CREATE INDEX idx_outbox_owner_record
      ON $outboxItemsTable (owner_key, record_id)
    ''');

    batch.execute('''
      CREATE INDEX idx_conflicts_owner_status_detected
      ON $recordConflictsTable (owner_key, status, detected_at)
    ''');

    for (final migrationKey in <String>[
      legacyRecordsPreferencesMigrationKey,
      legacyOutboxPreferencesMigrationKey,
    ]) {
      batch.insert(localMetadataTable, <String, Object>{
        'metadata_key': migrationKey,
        'metadata_value': migrationPendingValue,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
    }

    await batch.commit(noResult: true);
  }

  Future<void> _upgradeSchema(
    sqflite.Database database,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      const legacyPhotosTable = '${recordPhotosTable}_v1';

      await database.execute(
        'ALTER TABLE $recordPhotosTable RENAME TO $legacyPhotosTable',
      );
      await database.execute(_createRecordPhotosTableSql(recordPhotosTable));
      await database.execute('''
        INSERT INTO $recordPhotosTable (
          owner_key,
          record_id,
          photo_id,
          local_path,
          content_type,
          file_size,
          checksum,
          display_order
        )
        SELECT
          owner_key,
          record_id,
          'legacy-' || CAST(display_order AS TEXT),
          photo_path,
          NULL,
          NULL,
          NULL,
          display_order
        FROM $legacyPhotosTable
      ''');
      await database.execute('DROP TABLE $legacyPhotosTable');
    }

    if (oldVersion < 3) {
      const legacyOutboxTable = '${outboxItemsTable}_v2';
      final outboxTableExists = (await database.rawQuery(
        '''
        SELECT name
        FROM sqlite_master
        WHERE type = 'table' AND name = ?
        LIMIT 1
        ''',
        <Object?>[outboxItemsTable],
      )).isNotEmpty;
      if (outboxTableExists) {
        await database.execute(
          'ALTER TABLE $outboxItemsTable RENAME TO $legacyOutboxTable',
        );
        await database.execute(_createOutboxItemsTableSql(outboxItemsTable));
        await database.execute('''
        INSERT INTO $outboxItemsTable (
          insertion_order,
          owner_key,
          outbox_id,
          user_id,
          record_id,
          operation_type,
          status,
          created_at,
          last_tried_at,
          error_message,
          retry_count,
          is_migration,
          base_version_no,
          payload_json
        )
        SELECT
          insertion_order,
          owner_key,
          outbox_id,
          user_id,
          record_id,
          operation_type,
          status,
          created_at,
          last_tried_at,
          error_message,
          retry_count,
          is_migration,
          NULL,
          payload_json
        FROM $legacyOutboxTable
      ''');
        await database.execute('DROP TABLE $legacyOutboxTable');
      } else {
        await database.execute(_createOutboxItemsTableSql(outboxItemsTable));
      }
      await database.execute('''
        CREATE INDEX idx_outbox_owner_status_order
        ON $outboxItemsTable (owner_key, status, insertion_order)
      ''');
      await database.execute('''
        CREATE INDEX idx_outbox_owner_record
        ON $outboxItemsTable (owner_key, record_id)
      ''');
      await database.execute(
        _createRecordSyncStatesTableSql(recordSyncStatesTable),
      );
      await database.execute(
        _createRecordConflictsTableSql(recordConflictsTable),
      );
      await database.execute('''
        CREATE INDEX idx_conflicts_owner_status_detected
        ON $recordConflictsTable (owner_key, status, detected_at)
      ''');
    }
    if (oldVersion < 4) {
      await database.execute(_createLocalRecordChangesTableSql);
    }
  }

  static const String _createLocalRecordChangesTableSql =
      '''
    CREATE TABLE $localRecordChangesTable (
      owner_key TEXT NOT NULL,
      record_id TEXT NOT NULL,
      operation_type TEXT NOT NULL CHECK (operation_type IN ('update', 'delete')),
      payload_json TEXT NOT NULL,
      PRIMARY KEY (owner_key, record_id)
    )
  ''';

  static String _createRecordPhotosTableSql(String tableName) =>
      '''
    CREATE TABLE $tableName (
      owner_key TEXT NOT NULL,
      record_id TEXT NOT NULL,
      photo_id TEXT NOT NULL,
      local_path TEXT NOT NULL,
      content_type TEXT,
      file_size INTEGER CHECK (file_size IS NULL OR file_size > 0),
      checksum TEXT,
      display_order INTEGER NOT NULL,
      PRIMARY KEY (owner_key, record_id, photo_id),
      UNIQUE (owner_key, record_id, display_order),
      FOREIGN KEY (owner_key, record_id)
        REFERENCES $fishingRecordsTable (owner_key, record_id)
        ON UPDATE CASCADE
        ON DELETE CASCADE
    )
  ''';

  static String _createOutboxItemsTableSql(String tableName) =>
      '''
    CREATE TABLE $tableName (
      insertion_order INTEGER PRIMARY KEY AUTOINCREMENT,
      owner_key TEXT NOT NULL,
      outbox_id TEXT NOT NULL,
      user_id TEXT,
      record_id TEXT NOT NULL,
      operation_type TEXT NOT NULL
        CHECK (operation_type IN ('create', 'update', 'delete')),
      status TEXT NOT NULL
        CHECK (status IN (
          'pending', 'sending', 'succeeded', 'failed', 'conflicted'
        )),
      created_at TEXT NOT NULL,
      last_tried_at TEXT,
      error_message TEXT,
      retry_count INTEGER NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
      is_migration INTEGER NOT NULL DEFAULT 0
        CHECK (is_migration IN (0, 1)),
      base_version_no INTEGER
        CHECK (base_version_no IS NULL OR base_version_no >= 0),
      payload_json TEXT,
      UNIQUE (owner_key, outbox_id)
    )
  ''';

  static String _createRecordSyncStatesTableSql(String tableName) =>
      '''
    CREATE TABLE $tableName (
      owner_key TEXT NOT NULL,
      record_id TEXT NOT NULL,
      server_version_no INTEGER NOT NULL CHECK (server_version_no >= 0),
      optimistic_version_no INTEGER NOT NULL
        CHECK (optimistic_version_no >= server_version_no),
      remote_status TEXT NOT NULL
        CHECK (remote_status IN ('missing', 'active', 'deleted')),
      updated_at TEXT NOT NULL,
      PRIMARY KEY (owner_key, record_id)
    )
  ''';

  static String _createRecordConflictsTableSql(String tableName) =>
      '''
    CREATE TABLE $tableName (
      owner_key TEXT NOT NULL,
      conflict_id TEXT NOT NULL,
      record_id TEXT NOT NULL,
      outbox_id TEXT NOT NULL,
      operation_type TEXT NOT NULL
        CHECK (operation_type IN ('create', 'update', 'delete')),
      base_version_no INTEGER
        CHECK (base_version_no IS NULL OR base_version_no >= 0),
      remote_version_no INTEGER NOT NULL CHECK (remote_version_no >= 0),
      remote_status TEXT NOT NULL
        CHECK (remote_status IN ('missing', 'active', 'deleted')),
      local_payload_json TEXT,
      remote_payload_json TEXT,
      status TEXT NOT NULL
        CHECK (status IN ('unresolved', 'resolving', 'resolved')),
      resolution_type TEXT
        CHECK (resolution_type IS NULL OR resolution_type IN (
          'useMine', 'useTheirs', 'manualMerge'
        )),
      resolution_outbox_id TEXT,
      detected_at TEXT NOT NULL,
      resolved_at TEXT,
      PRIMARY KEY (owner_key, conflict_id),
      UNIQUE (owner_key, outbox_id)
    )
  ''';

  @visibleForTesting
  Future<void> configureForTesting({
    required sqflite.DatabaseFactory databaseFactory,
    String databasePath = sqflite.inMemoryDatabasePath,
  }) async {
    await close();
    _databaseFactoryOverride = databaseFactory;
    _databasePathOverride = databasePath;
  }

  @visibleForTesting
  Future<void> resetForTesting() async {
    final factory = _databaseFactoryOverride;
    final databasePath = _databasePathOverride;

    await close();

    if (factory != null &&
        databasePath != null &&
        databasePath != sqflite.inMemoryDatabasePath) {
      await factory.deleteDatabase(databasePath);
    }
  }

  @visibleForTesting
  Future<void> close() async {
    final pendingOpen = _openingDatabase;
    if (pendingOpen != null) {
      try {
        await pendingOpen;
      } on Object {
        // An open failure leaves no database handle to close.
      }
    }

    final openDatabase = _database;
    _database = null;
    _openingDatabase = null;

    if (openDatabase != null && openDatabase.isOpen) {
      await openDatabase.close();
    }
  }
}
