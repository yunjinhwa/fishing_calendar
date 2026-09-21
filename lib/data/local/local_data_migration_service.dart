import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../models/fishing_record.dart';
import '../models/outbox_item.dart';
import 'app_database.dart';
import 'local_data_store.dart';

class LocalDataMigrationService {
  LocalDataMigrationService._();

  static final LocalDataMigrationService instance =
      LocalDataMigrationService._();

  static const String scopedRecordsPreferencesKey =
      'fishing_records_by_account_v1';
  static const String scopedOutboxPreferencesKey = 'outbox_items_by_account_v1';
  static const String recordsMigrationBackupKey =
      'fishing_records_sqlite_migration_backup_v1';
  static const String outboxMigrationBackupKey =
      'outbox_items_sqlite_migration_backup_v1';

  final LocalDataStore _store = LocalDataStore.instance;
  Future<void>? _runningMigration;

  Future<void> migrateIfNeeded() {
    final runningMigration = _runningMigration;
    if (runningMigration != null) {
      return runningMigration;
    }

    final migration = _migrateIfNeeded();
    _runningMigration = migration;
    return migration.whenComplete(() {
      if (identical(_runningMigration, migration)) {
        _runningMigration = null;
      }
    });
  }

  Future<void> _migrateIfNeeded() async {
    final database = await AppDatabase.instance.database;
    final preferences = await SharedPreferences.getInstance();
    await _migrateRecords(database, preferences);
    await _migrateOutbox(database, preferences);
  }

  Future<void> _migrateRecords(
    Database database,
    SharedPreferences preferences,
  ) async {
    final migrationStatus = await _store.readMetadata(
      database,
      AppDatabase.legacyRecordsPreferencesMigrationKey,
    );
    if (migrationStatus == AppDatabase.migrationCompletedValue) {
      await preferences.remove(scopedRecordsPreferencesKey);
      return;
    }

    final source = preferences.getString(scopedRecordsPreferencesKey);
    final decoded = _decodeRecords(source);
    if (decoded == null ||
        !await _preserveInvalidSource(
          preferences,
          source: source,
          backupKey: recordsMigrationBackupKey,
          hasInvalidItems: decoded.hasInvalidItems,
        )) {
      return;
    }

    await database.transaction((transaction) async {
      for (final entry in decoded.itemsByOwner.entries) {
        for (final record in entry.value) {
          await _store.insertRecord(
            transaction,
            ownerKey: entry.key,
            record: record,
            replace: true,
          );
        }
      }
      await _store.writeMetadata(
        transaction,
        key: AppDatabase.legacyRecordsPreferencesMigrationKey,
        value: AppDatabase.migrationCompletedValue,
      );
    });
    await preferences.remove(scopedRecordsPreferencesKey);
  }

  Future<void> _migrateOutbox(
    Database database,
    SharedPreferences preferences,
  ) async {
    final migrationStatus = await _store.readMetadata(
      database,
      AppDatabase.legacyOutboxPreferencesMigrationKey,
    );
    if (migrationStatus == AppDatabase.migrationCompletedValue) {
      await preferences.remove(scopedOutboxPreferencesKey);
      return;
    }

    final source = preferences.getString(scopedOutboxPreferencesKey);
    final decoded = _decodeOutbox(source);
    if (decoded == null ||
        !await _preserveInvalidSource(
          preferences,
          source: source,
          backupKey: outboxMigrationBackupKey,
          hasInvalidItems: decoded.hasInvalidItems,
        )) {
      return;
    }

    await database.transaction((transaction) async {
      for (final entry in decoded.itemsByOwner.entries) {
        for (final item in entry.value) {
          await _store.insertOutboxItem(
            transaction,
            ownerKey: entry.key,
            item: item,
            replace: true,
          );
        }
      }
      await _store.writeMetadata(
        transaction,
        key: AppDatabase.legacyOutboxPreferencesMigrationKey,
        value: AppDatabase.migrationCompletedValue,
      );
    });
    await preferences.remove(scopedOutboxPreferencesKey);
  }

  Future<bool> _preserveInvalidSource(
    SharedPreferences preferences, {
    required String? source,
    required String backupKey,
    required bool hasInvalidItems,
  }) async {
    if (!hasInvalidItems || source == null || source.isEmpty) {
      return true;
    }
    if (preferences.getString(backupKey) != null) {
      return true;
    }
    return preferences.setString(backupKey, source);
  }

  _DecodedItems<FishingRecord>? _decodeRecords(String? value) {
    if (value == null || value.isEmpty) {
      return const _DecodedItems<FishingRecord>(
        itemsByOwner: <String, List<FishingRecord>>{},
      );
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(value);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) {
      return null;
    }

    var hasInvalidItems = false;
    final recordsByOwner = <String, List<FishingRecord>>{};
    for (final entry in decoded.entries) {
      final values = entry.value;
      if (values is! List) {
        hasInvalidItems = true;
        continue;
      }

      final records = <FishingRecord>[];
      for (final value in values) {
        try {
          records.add(
            FishingRecord.fromJson(Map<String, dynamic>.from(value as Map)),
          );
        } on FormatException {
          hasInvalidItems = true;
        } on TypeError {
          hasInvalidItems = true;
        }
      }
      recordsByOwner[entry.key.toString()] = records;
    }

    return _DecodedItems<FishingRecord>(
      itemsByOwner: recordsByOwner,
      hasInvalidItems: hasInvalidItems,
    );
  }

  _DecodedItems<OutboxItem>? _decodeOutbox(String? value) {
    if (value == null || value.isEmpty) {
      return const _DecodedItems<OutboxItem>(
        itemsByOwner: <String, List<OutboxItem>>{},
      );
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(value);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) {
      return null;
    }

    var hasInvalidItems = false;
    final outboxByOwner = <String, List<OutboxItem>>{};
    for (final entry in decoded.entries) {
      final values = entry.value;
      if (values is! List) {
        hasInvalidItems = true;
        continue;
      }

      final items = <OutboxItem>[];
      for (final value in values) {
        try {
          items.add(
            OutboxItem.fromJson(Map<String, dynamic>.from(value as Map)),
          );
        } on FormatException {
          hasInvalidItems = true;
        } on ArgumentError {
          hasInvalidItems = true;
        } on TypeError {
          hasInvalidItems = true;
        }
      }
      outboxByOwner[entry.key.toString()] = items;
    }

    return _DecodedItems<OutboxItem>(
      itemsByOwner: outboxByOwner,
      hasInvalidItems: hasInvalidItems,
    );
  }
}

class _DecodedItems<T> {
  final Map<String, List<T>> itemsByOwner;
  final bool hasInvalidItems;

  const _DecodedItems({
    required this.itemsByOwner,
    this.hasInvalidItems = false,
  });
}
