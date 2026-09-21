import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart' as sqflite;

import 'database_factory.dart';

class AppDatabase {
  AppDatabase._();

  static final AppDatabase instance = AppDatabase._();

  static const String databaseName = 'fishing_calendar.db';
  static const int databaseVersion = 1;

  static const String localMetadataTable = 'local_metadata';
  static const String fishingRecordsTable = 'fishing_records';
  static const String recordCatchesTable = 'record_catches';
  static const String recordPhotosTable = 'record_photos';
  static const String outboxItemsTable = 'outbox_items';

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

    batch.execute('''
      CREATE TABLE $recordPhotosTable (
        owner_key TEXT NOT NULL,
        record_id TEXT NOT NULL,
        display_order INTEGER NOT NULL,
        photo_path TEXT NOT NULL,
        PRIMARY KEY (owner_key, record_id, display_order),
        FOREIGN KEY (owner_key, record_id)
          REFERENCES $fishingRecordsTable (owner_key, record_id)
          ON UPDATE CASCADE
          ON DELETE CASCADE
      )
    ''');

    batch.execute('''
      CREATE TABLE $outboxItemsTable (
        insertion_order INTEGER PRIMARY KEY AUTOINCREMENT,
        owner_key TEXT NOT NULL,
        outbox_id TEXT NOT NULL,
        user_id TEXT,
        record_id TEXT NOT NULL,
        operation_type TEXT NOT NULL
          CHECK (operation_type IN ('create', 'update', 'delete')),
        status TEXT NOT NULL
          CHECK (status IN ('pending', 'sending', 'succeeded', 'failed')),
        created_at TEXT NOT NULL,
        last_tried_at TEXT,
        error_message TEXT,
        retry_count INTEGER NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
        is_migration INTEGER NOT NULL DEFAULT 0
          CHECK (is_migration IN (0, 1)),
        payload_json TEXT,
        UNIQUE (owner_key, outbox_id)
      )
    ''');

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
