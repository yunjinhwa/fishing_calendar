import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../models/fishing_record.dart';
import '../models/outbox_item.dart';
import 'app_database.dart';

class LocalDataStore {
  LocalDataStore._();

  static final LocalDataStore instance = LocalDataStore._();

  Future<List<FishingRecord>> readRecordsForOwner(String ownerKey) async {
    final database = await AppDatabase.instance.database;
    final recordRows = await database.query(
      AppDatabase.fishingRecordsTable,
      where: 'owner_key = ?',
      whereArgs: <Object?>[ownerKey],
      orderBy: 'insertion_order ASC',
    );
    final recordsByOwner = await _recordsFromRows(
      database,
      ownerKey,
      recordRows,
    );
    return recordsByOwner[ownerKey] ?? <FishingRecord>[];
  }

  Future<Map<String, List<FishingRecord>>> _recordsFromRows(
    DatabaseExecutor executor,
    String ownerKey,
    List<Map<String, Object?>> recordRows,
  ) async {
    if (recordRows.isEmpty) {
      return <String, List<FishingRecord>>{};
    }

    final catchRows = await executor.query(
      AppDatabase.recordCatchesTable,
      where: 'owner_key = ?',
      whereArgs: <Object?>[ownerKey],
      orderBy: 'record_id ASC, display_order ASC',
    );
    final photoRows = await executor.query(
      AppDatabase.recordPhotosTable,
      where: 'owner_key = ?',
      whereArgs: <Object?>[ownerKey],
      orderBy: 'record_id ASC, display_order ASC',
    );

    final catchesByRecord = <String, List<CatchRecord>>{};
    for (final row in catchRows) {
      final key = _recordKey(
        row['owner_key']! as String,
        row['record_id']! as String,
      );
      catchesByRecord
          .putIfAbsent(key, () => <CatchRecord>[])
          .add(
            CatchRecord(
              speciesName: row['species_name']! as String,
              lengthCm: (row['length_cm'] as num?)?.toDouble(),
              weightG: (row['weight_g'] as num?)?.toInt(),
            ),
          );
    }

    final photosByRecord = <String, List<String>>{};
    for (final row in photoRows) {
      final key = _recordKey(
        row['owner_key']! as String,
        row['record_id']! as String,
      );
      photosByRecord
          .putIfAbsent(key, () => <String>[])
          .add(row['photo_path']! as String);
    }

    final recordsByOwner = <String, List<FishingRecord>>{};
    for (final row in recordRows) {
      final rowOwnerKey = row['owner_key']! as String;
      final recordId = row['record_id']! as String;
      final key = _recordKey(rowOwnerKey, recordId);
      recordsByOwner
          .putIfAbsent(rowOwnerKey, () => <FishingRecord>[])
          .add(
            FishingRecord(
              id: recordId,
              location: row['location']! as String,
              startAt: DateTime.parse(row['start_at']! as String),
              endAt: DateTime.parse(row['end_at']! as String),
              genreName: row['genre_name']! as String,
              tide: row['tide'] as String?,
              weather: row['weather'] as String?,
              airTemperature: (row['air_temperature'] as num?)?.toDouble(),
              waterTemperature: (row['water_temperature'] as num?)?.toDouble(),
              catches: catchesByRecord[key] ?? const <CatchRecord>[],
              photoPaths: photosByRecord[key] ?? const <String>[],
              memo: row['memo'] as String?,
            ),
          );
    }

    return recordsByOwner;
  }

  Future<void> insertRecord(
    DatabaseExecutor executor, {
    required String ownerKey,
    required FishingRecord record,
    bool replace = false,
  }) async {
    int? insertionOrder;
    if (replace) {
      final existing = await executor.query(
        AppDatabase.fishingRecordsTable,
        columns: const <String>['insertion_order'],
        where: 'owner_key = ? AND record_id = ?',
        whereArgs: <Object?>[ownerKey, record.id],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        insertionOrder = (existing.single['insertion_order']! as num).toInt();
      }
    }

    final conflictAlgorithm = replace
        ? ConflictAlgorithm.replace
        : ConflictAlgorithm.abort;
    final recordRow = <String, Object?>{
      'owner_key': ownerKey,
      'record_id': record.id,
      'location': record.location,
      'start_at': record.startAt.toIso8601String(),
      'end_at': record.endAt.toIso8601String(),
      'genre_name': record.genreName,
      'tide': record.tide,
      'weather': record.weather,
      'air_temperature': record.airTemperature,
      'water_temperature': record.waterTemperature,
      'memo': record.memo,
    };
    if (insertionOrder != null) {
      recordRow['insertion_order'] = insertionOrder;
    }
    await executor.insert(
      AppDatabase.fishingRecordsTable,
      recordRow,
      conflictAlgorithm: conflictAlgorithm,
    );

    for (var index = 0; index < record.catches.length; index++) {
      final catchRecord = record.catches[index];
      await executor.insert(AppDatabase.recordCatchesTable, <String, Object?>{
        'owner_key': ownerKey,
        'record_id': record.id,
        'display_order': index,
        'species_name': catchRecord.speciesName,
        'length_cm': catchRecord.lengthCm,
        'weight_g': catchRecord.weightG,
      });
    }

    for (var index = 0; index < record.photoPaths.length; index++) {
      await executor.insert(AppDatabase.recordPhotosTable, <String, Object?>{
        'owner_key': ownerKey,
        'record_id': record.id,
        'display_order': index,
        'photo_path': record.photoPaths[index],
      });
    }
  }

  Future<void> deleteRecord(
    DatabaseExecutor executor, {
    required String ownerKey,
    required String recordId,
  }) async {
    await executor.delete(
      AppDatabase.fishingRecordsTable,
      where: 'owner_key = ? AND record_id = ?',
      whereArgs: <Object?>[ownerKey, recordId],
    );
  }

  Future<void> deleteAllRecords(
    DatabaseExecutor executor, {
    required String ownerKey,
  }) async {
    await executor.delete(
      AppDatabase.fishingRecordsTable,
      where: 'owner_key = ?',
      whereArgs: <Object?>[ownerKey],
    );
  }

  Future<List<OutboxItem>> readOutboxItemsForOwner(String ownerKey) async {
    final database = await AppDatabase.instance.database;
    final rows = await database.query(
      AppDatabase.outboxItemsTable,
      where: 'owner_key = ?',
      whereArgs: <Object?>[ownerKey],
      orderBy: 'insertion_order ASC',
    );
    return _outboxItemsFromRows(rows)[ownerKey] ?? <OutboxItem>[];
  }

  Map<String, List<OutboxItem>> _outboxItemsFromRows(
    List<Map<String, Object?>> rows,
  ) {
    final itemsByOwner = <String, List<OutboxItem>>{};
    for (final row in rows) {
      final ownerKey = row['owner_key']! as String;
      final payloadJson = row['payload_json'] as String?;
      itemsByOwner
          .putIfAbsent(ownerKey, () => <OutboxItem>[])
          .add(
            OutboxItem(
              id: row['outbox_id']! as String,
              userId: row['user_id'] as String?,
              recordId: row['record_id']! as String,
              operationType: OutboxOperationType.values.byName(
                row['operation_type']! as String,
              ),
              status: OutboxStatus.values.byName(row['status']! as String),
              createdAt: DateTime.parse(row['created_at']! as String),
              lastTriedAt: row['last_tried_at'] == null
                  ? null
                  : DateTime.parse(row['last_tried_at']! as String),
              errorMessage: row['error_message'] as String?,
              retryCount: (row['retry_count']! as num).toInt(),
              isMigration: (row['is_migration']! as num).toInt() == 1,
              payload: payloadJson == null
                  ? null
                  : Map<String, dynamic>.from(jsonDecode(payloadJson) as Map),
            ),
          );
    }
    return itemsByOwner;
  }

  Future<void> insertOutboxItem(
    DatabaseExecutor executor, {
    required String ownerKey,
    required OutboxItem item,
    bool replace = false,
  }) async {
    int? insertionOrder;
    if (replace) {
      final existing = await executor.query(
        AppDatabase.outboxItemsTable,
        columns: const <String>['insertion_order'],
        where: 'owner_key = ? AND outbox_id = ?',
        whereArgs: <Object?>[ownerKey, item.id],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        insertionOrder = (existing.single['insertion_order']! as num).toInt();
      }
    }

    final outboxRow = <String, Object?>{
      'owner_key': ownerKey,
      'outbox_id': item.id,
      'user_id': item.userId,
      'record_id': item.recordId,
      'operation_type': item.operationType.name,
      'status': item.status.name,
      'created_at': item.createdAt.toIso8601String(),
      'last_tried_at': item.lastTriedAt?.toIso8601String(),
      'error_message': item.errorMessage,
      'retry_count': item.retryCount,
      'is_migration': item.isMigration ? 1 : 0,
      'payload_json': item.payload == null ? null : jsonEncode(item.payload),
    };
    if (insertionOrder != null) {
      outboxRow['insertion_order'] = insertionOrder;
    }

    await executor.insert(
      AppDatabase.outboxItemsTable,
      outboxRow,
      conflictAlgorithm: replace
          ? ConflictAlgorithm.replace
          : ConflictAlgorithm.abort,
    );
  }

  Future<void> deleteOutboxItems(
    DatabaseExecutor executor, {
    required String ownerKey,
    required String where,
    List<Object?> whereArgs = const <Object?>[],
  }) async {
    await executor.delete(
      AppDatabase.outboxItemsTable,
      where: 'owner_key = ? AND ($where)',
      whereArgs: <Object?>[ownerKey, ...whereArgs],
    );
  }

  Future<String?> readMetadata(DatabaseExecutor executor, String key) async {
    final rows = await executor.query(
      AppDatabase.localMetadataTable,
      columns: const <String>['metadata_value'],
      where: 'metadata_key = ?',
      whereArgs: <Object?>[key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single['metadata_value'] as String;
  }

  Future<void> writeMetadata(
    DatabaseExecutor executor, {
    required String key,
    required String value,
  }) async {
    await executor.insert(AppDatabase.localMetadataTable, <String, Object>{
      'metadata_key': key,
      'metadata_value': value,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  String _recordKey(String ownerKey, String recordId) =>
      '${ownerKey.length}:$ownerKey$recordId';
}
