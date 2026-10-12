import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../models/conflict_item.dart';
import '../models/fishing_record.dart';
import '../models/outbox_item.dart';
import '../models/record_sync_metadata.dart';
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

    final photosByRecord = <String, List<RecordPhoto>>{};
    for (final row in photoRows) {
      final key = _recordKey(
        row['owner_key']! as String,
        row['record_id']! as String,
      );
      photosByRecord
          .putIfAbsent(key, () => <RecordPhoto>[])
          .add(
            RecordPhoto(
              id: row['photo_id']! as String,
              localPath: row['local_path'] as String?,
              contentType: row['content_type'] as String?,
              sizeBytes: (row['file_size'] as num?)?.toInt(),
              checksum: row['checksum'] as String?,
            ),
          );
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
              photos: photosByRecord[key] ?? const <RecordPhoto>[],
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

    for (var index = 0; index < record.photos.length; index++) {
      final photo = record.photos[index];
      await executor.insert(AppDatabase.recordPhotosTable, <String, Object?>{
        'owner_key': ownerKey,
        'record_id': record.id,
        'photo_id': photo.id,
        'local_path': photo.localPath,
        'content_type': photo.contentType,
        'file_size': photo.sizeBytes,
        'checksum': photo.checksum,
        'display_order': index,
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
              baseVersionNo: (row['base_version_no'] as num?)?.toInt(),
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
      'base_version_no': item.baseVersionNo,
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

  Future<void> deleteUnfinishedOutboxItemsForRecord(
    DatabaseExecutor executor, {
    required String ownerKey,
    required String recordId,
  }) {
    return deleteOutboxItems(
      executor,
      ownerKey: ownerKey,
      where: 'record_id = ? AND status != ?',
      whereArgs: <Object?>[recordId, OutboxStatus.succeeded.name],
    );
  }

  Future<void> markOutboxItemsConflicted(
    DatabaseExecutor executor, {
    required String ownerKey,
    required String recordId,
    required DateTime triedAt,
    required String message,
  }) async {
    await executor.update(
      AppDatabase.outboxItemsTable,
      <String, Object?>{
        'status': OutboxStatus.conflicted.name,
        'last_tried_at': triedAt.toIso8601String(),
        'error_message': message,
      },
      where: 'owner_key = ? AND record_id = ? AND status != ?',
      whereArgs: <Object?>[ownerKey, recordId, OutboxStatus.succeeded.name],
    );
  }

  Future<RecordSyncMetadata?> readRecordSyncMetadata(
    String ownerKey,
    String recordId,
  ) async {
    final database = await AppDatabase.instance.database;
    final rows = await database.query(
      AppDatabase.recordSyncStatesTable,
      where: 'owner_key = ? AND record_id = ?',
      whereArgs: <Object?>[ownerKey, recordId],
      limit: 1,
    );
    return rows.isEmpty ? null : _syncMetadataFromRow(rows.single);
  }

  Future<int> reserveNextRecordVersion(
    DatabaseExecutor executor, {
    required String ownerKey,
    required String recordId,
  }) async {
    final rows = await executor.query(
      AppDatabase.recordSyncStatesTable,
      where: 'owner_key = ? AND record_id = ?',
      whereArgs: <Object?>[ownerKey, recordId],
      limit: 1,
    );
    final existing = rows.isEmpty ? null : _syncMetadataFromRow(rows.single);
    final baseVersionNo = existing?.optimisticVersionNo ?? 0;
    await writeRecordSyncMetadata(
      executor,
      ownerKey: ownerKey,
      metadata: RecordSyncMetadata(
        recordId: recordId,
        serverVersionNo: existing?.serverVersionNo ?? 0,
        optimisticVersionNo: baseVersionNo + 1,
        remoteStatus: existing?.remoteStatus ?? RemoteRecordStatus.missing,
      ),
      resetOptimisticVersion: true,
    );
    return baseVersionNo;
  }

  Future<void> writeRecordSyncMetadata(
    DatabaseExecutor executor, {
    required String ownerKey,
    required RecordSyncMetadata metadata,
    bool resetOptimisticVersion = false,
  }) async {
    var optimisticVersionNo = metadata.optimisticVersionNo;
    if (!resetOptimisticVersion) {
      final rows = await executor.query(
        AppDatabase.recordSyncStatesTable,
        columns: const <String>['optimistic_version_no'],
        where: 'owner_key = ? AND record_id = ?',
        whereArgs: <Object?>[ownerKey, metadata.recordId],
        limit: 1,
      );
      final existingOptimistic = rows.isEmpty
          ? 0
          : (rows.single['optimistic_version_no']! as num).toInt();
      if (existingOptimistic > optimisticVersionNo) {
        optimisticVersionNo = existingOptimistic;
      }
    }
    if (optimisticVersionNo < metadata.serverVersionNo) {
      optimisticVersionNo = metadata.serverVersionNo;
    }

    await executor.insert(
      AppDatabase.recordSyncStatesTable,
      <String, Object>{
        'owner_key': ownerKey,
        'record_id': metadata.recordId,
        'server_version_no': metadata.serverVersionNo,
        'optimistic_version_no': optimisticVersionNo,
        'remote_status': metadata.remoteStatus.name,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> replaceRecordSyncMetadata(
    DatabaseExecutor executor, {
    required String ownerKey,
    required Iterable<RecordSyncMetadata> items,
  }) async {
    await executor.delete(
      AppDatabase.recordSyncStatesTable,
      where: 'owner_key = ?',
      whereArgs: <Object?>[ownerKey],
    );
    for (final item in items) {
      await writeRecordSyncMetadata(
        executor,
        ownerKey: ownerKey,
        metadata: item,
        resetOptimisticVersion: true,
      );
    }
  }

  Future<List<ConflictItem>> readConflictsForOwner(String ownerKey) async {
    final database = await AppDatabase.instance.database;
    final rows = await database.query(
      AppDatabase.recordConflictsTable,
      where: 'owner_key = ?',
      whereArgs: <Object?>[ownerKey],
      orderBy: 'detected_at DESC',
    );
    return rows.map(_conflictFromRow).toList(growable: false);
  }

  Future<void> insertConflict(
    DatabaseExecutor executor, {
    required ConflictItem conflict,
    bool replace = false,
  }) async {
    await executor.insert(
      AppDatabase.recordConflictsTable,
      _conflictRow(conflict),
      conflictAlgorithm: replace
          ? ConflictAlgorithm.replace
          : ConflictAlgorithm.abort,
    );
  }

  Future<void> updateConflict(
    DatabaseExecutor executor, {
    required ConflictItem conflict,
  }) => insertConflict(executor, conflict: conflict, replace: true);

  Future<void> completeResolvingConflictForOutbox(
    DatabaseExecutor executor, {
    required String ownerKey,
    required String outboxId,
    required DateTime resolvedAt,
  }) async {
    await executor.update(
      AppDatabase.recordConflictsTable,
      <String, Object?>{
        'status': ConflictStatus.resolved.name,
        'resolved_at': resolvedAt.toIso8601String(),
      },
      where: 'owner_key = ? AND resolution_outbox_id = ? AND status = ?',
      whereArgs: <Object?>[ownerKey, outboxId, ConflictStatus.resolving.name],
    );
  }

  Future<void> deleteAllConflicts(
    DatabaseExecutor executor, {
    required String ownerKey,
  }) async {
    await executor.delete(
      AppDatabase.recordConflictsTable,
      where: 'owner_key = ?',
      whereArgs: <Object?>[ownerKey],
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

  RecordSyncMetadata _syncMetadataFromRow(Map<String, Object?> row) {
    return RecordSyncMetadata(
      recordId: row['record_id']! as String,
      serverVersionNo: (row['server_version_no']! as num).toInt(),
      optimisticVersionNo: (row['optimistic_version_no']! as num).toInt(),
      remoteStatus: RemoteRecordStatus.values.byName(
        row['remote_status']! as String,
      ),
    );
  }

  ConflictItem _conflictFromRow(Map<String, Object?> row) {
    final localPayload = row['local_payload_json'] as String?;
    final remotePayload = row['remote_payload_json'] as String?;
    return ConflictItem(
      id: row['conflict_id']! as String,
      ownerKey: row['owner_key']! as String,
      recordId: row['record_id']! as String,
      outboxId: row['outbox_id']! as String,
      localOperationType: OutboxOperationType.values.byName(
        row['operation_type']! as String,
      ),
      baseVersionNo: (row['base_version_no'] as num?)?.toInt(),
      remoteVersionNo: (row['remote_version_no']! as num).toInt(),
      remoteStatus: RemoteRecordStatus.values.byName(
        row['remote_status']! as String,
      ),
      localRecord: localPayload == null
          ? null
          : FishingRecord.fromJson(
              Map<String, dynamic>.from(jsonDecode(localPayload) as Map),
            ),
      remoteRecord: remotePayload == null
          ? null
          : FishingRecord.fromJson(
              Map<String, dynamic>.from(jsonDecode(remotePayload) as Map),
            ),
      occurredAt: DateTime.parse(row['detected_at']! as String),
      status: ConflictStatus.values.byName(row['status']! as String),
      resolutionType: row['resolution_type'] == null
          ? null
          : ConflictResolutionType.values.byName(
              row['resolution_type']! as String,
            ),
      resolutionOutboxId: row['resolution_outbox_id'] as String?,
      resolvedAt: row['resolved_at'] == null
          ? null
          : DateTime.parse(row['resolved_at']! as String),
    );
  }

  Map<String, Object?> _conflictRow(ConflictItem conflict) {
    return <String, Object?>{
      'owner_key': conflict.ownerKey,
      'conflict_id': conflict.id,
      'record_id': conflict.recordId,
      'outbox_id': conflict.outboxId,
      'operation_type': conflict.localOperationType.name,
      'base_version_no': conflict.baseVersionNo,
      'remote_version_no': conflict.remoteVersionNo,
      'remote_status': conflict.remoteStatus.name,
      'local_payload_json': conflict.localPayloadJson,
      'remote_payload_json': conflict.remotePayloadJson,
      'status': conflict.status.name,
      'resolution_type': conflict.resolutionType?.name,
      'resolution_outbox_id': conflict.resolutionOutboxId,
      'detected_at': conflict.occurredAt.toIso8601String(),
      'resolved_at': conflict.resolvedAt?.toIso8601String(),
    };
  }
}
