import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../local/app_database.dart';
import '../local/local_data_migration_service.dart';
import '../local/local_data_store.dart';
import '../models/fishing_record.dart';
import '../models/outbox_item.dart';
import '../models/record_sync_metadata.dart';
import '../remote/record_sync_gateway.dart';
import 'auth_session_repository.dart';

class FishingRecordRepository extends ChangeNotifier {
  FishingRecordRepository._();

  static final FishingRecordRepository instance = FishingRecordRepository._();

  static const String _legacyStorageKey = 'fishing_records';

  final LocalDataStore _store = LocalDataStore.instance;
  final Map<String, List<FishingRecord>> _recordsByOwner = {};
  final Set<String> _loadedOwners = {};
  List<FishingRecord>? _quarantinedLegacyRecords;
  bool _hasQuarantinedLegacyData = false;

  String get _ownerKey => AuthSessionRepository.instance.dataOwnerKey;

  List<FishingRecord> get _records =>
      _recordsByOwner.putIfAbsent(_ownerKey, () => <FishingRecord>[]);

  bool get hasQuarantinedLegacyData => _hasQuarantinedLegacyData;
  bool get canImportQuarantinedLegacyRecords =>
      _hasQuarantinedLegacyData && _quarantinedLegacyRecords != null;
  int? get quarantinedLegacyRecordCount => _quarantinedLegacyRecords?.length;

  Future<void> loadRecords() async {
    await LocalDataMigrationService.instance.migrateIfNeeded();
    final ownerKey = _ownerKey;
    _recordsByOwner[ownerKey] = await _store.readRecordsForOwner(ownerKey);
    _loadedOwners.add(ownerKey);
    await _loadQuarantinedLegacyRecords();
    notifyListeners();
  }

  Future<void> reloadOwner(String ownerKey) async {
    _recordsByOwner[ownerKey] = await _store.readRecordsForOwner(ownerKey);
    _loadedOwners.add(ownerKey);
    notifyListeners();
  }

  /// Publishes records already read and decoded inside a committed transaction.
  ///
  /// Call only after that transaction succeeds. This performs no database work;
  /// related caches must be published before listeners are notified here.
  void publishCommittedSnapshot({
    required String ownerKey,
    required List<FishingRecord> records,
  }) {
    _recordsByOwner[ownerKey] = List<FishingRecord>.unmodifiable(records);
    _loadedOwners.add(ownerKey);
    notifyListeners();
  }

  Future<void> _loadQuarantinedLegacyRecords() async {
    final preferences = await SharedPreferences.getInstance();
    final legacyJson = preferences.getString(_legacyStorageKey);
    _hasQuarantinedLegacyData =
        legacyJson != null && legacyJson.trim().isNotEmpty;
    _quarantinedLegacyRecords = _hasQuarantinedLegacyData
        ? _decodeLegacyRecords(legacyJson!)
        : <FishingRecord>[];
  }

  List<FishingRecord>? _decodeLegacyRecords(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is! List) {
        return null;
      }

      return decoded
          .map(
            (item) =>
                FishingRecord.fromJson(Map<String, dynamic>.from(item as Map)),
          )
          .toList();
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  List<FishingRecord> getAllRecords() => List.unmodifiable(_records);

  List<FishingRecord> getAllRecordsForOwner(String ownerKey) =>
      List.unmodifiable(
        _recordsByOwner.putIfAbsent(ownerKey, () => <FishingRecord>[]),
      );

  FishingRecord? getRecordById(String recordId) {
    for (final record in _records) {
      if (record.id == recordId) {
        return record;
      }
    }
    return null;
  }

  List<FishingRecord> getRecordsByDate(DateTime date) {
    return _records.where((record) => record.overlapsDate(date)).toList();
  }

  Future<void> addRecord(FishingRecord record) async {
    final ownerKey = _ownerKey;
    await AppDatabase.instance.transaction((transaction) async {
      await _store.insertRecord(
        transaction,
        ownerKey: ownerKey,
        record: record,
      );
    });
    await reloadOwner(ownerKey);
  }

  Future<void> updateRecord(FishingRecord record) async {
    if (getRecordById(record.id) == null) {
      throw StateError('Record not found: ${record.id}');
    }

    final ownerKey = _ownerKey;
    await AppDatabase.instance.transaction((transaction) async {
      await _store.insertRecord(
        transaction,
        ownerKey: ownerKey,
        record: record,
        replace: true,
      );
    });
    await reloadOwner(ownerKey);
  }

  Future<void> deleteRecord(String recordId) async {
    if (getRecordById(recordId) == null) {
      return;
    }

    final ownerKey = _ownerKey;
    await AppDatabase.instance.transaction((transaction) async {
      await _store.deleteRecord(
        transaction,
        ownerKey: ownerKey,
        recordId: recordId,
      );
    });
    await reloadOwner(ownerKey);
  }

  Future<RecordSyncCheckpoint?> readSyncCheckpoint(String ownerKey) async {
    final database = await AppDatabase.instance.database;
    try {
      final value = await _store.readMetadata(
        database,
        RecordSyncCheckpoint.metadataKey(ownerKey),
      );
      if (value == null) return null;
      return RecordSyncCheckpoint.decode(value);
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  /// Applies an authoritative full view without rewriting unchanged records.
  /// A checkpoint, when supplied, is committed with the records it describes.
  Future<bool> replaceWithRemoteSnapshot(
    RemoteRecordSnapshot snapshot, {
    String? ownerKey,
    RecordSyncCheckpoint? checkpoint,
    bool Function()? isCurrentSession,
    bool Function(FishingRecord)? retainRecord,
  }) async {
    final resolvedOwnerKey = ownerKey ?? _ownerKey;
    final result = await _applyRemoteChanges(
      ownerKey: resolvedOwnerKey,
      revisions: snapshot.revisions,
      checkpoint: checkpoint,
      isCurrentSession: isCurrentSession ?? () => true,
      fullSnapshot: true,
      retainRecord: retainRecord,
    );
    return result.applied;
  }

  /// Updates only IDs received in a delta page. Local intent and session guards
  /// are checked inside the transaction, before the page cursor can advance.
  Future<RecordPageApplyResult> applyRemotePage({
    required String ownerKey,
    required List<RemoteRecordRevision> revisions,
    required RecordSyncCheckpoint checkpoint,
    required bool Function() isCurrentSession,
    bool Function(FishingRecord)? retainRecord,
  }) => _applyRemoteChanges(
    ownerKey: ownerKey,
    revisions: revisions,
    checkpoint: checkpoint,
    isCurrentSession: isCurrentSession,
    fullSnapshot: false,
    retainRecord: retainRecord,
  );

  /// Hydrates an explicitly requested range without advancing global pull
  /// progress. Local intent is protected per ID so an unrelated pending record
  /// cannot prevent reading the rest of a historical month.
  Future<RecordPageApplyResult> applyRemoteRange({
    required String ownerKey,
    required List<RemoteRecordRevision> revisions,
    required bool Function() isCurrentSession,
  }) => _applyRemoteChanges(
    ownerKey: ownerKey,
    revisions: revisions,
    checkpoint: null,
    isCurrentSession: isCurrentSession,
    fullSnapshot: false,
    protectLocalsPerRecord: true,
  );

  /// Captures the bodies present before a range query. A later authoritative
  /// pull can change their versions, so reconciliation must compare this map
  /// with the current durable metadata before evicting a missing body.
  /// A cancelled session returns an empty, non-destructive snapshot.
  Future<Map<String, int>> captureRemoteRangeVersions({
    required String ownerKey,
    required DateTime from,
    required DateTime to,
    required bool Function() isCurrentSession,
  }) async {
    if (!from.isBefore(to)) throw ArgumentError('Invalid record query range.');
    try {
      return await AppDatabase.instance.transaction((transaction) async {
        if (!isCurrentSession()) throw const _RemotePullCancelled();
        final rows = await _readRangeBodyVersions(transaction, ownerKey);
        if (!isCurrentSession()) throw const _RemotePullCancelled();
        return Map<String, int>.unmodifiable({
          for (final row in rows)
            if (_rowOverlapsRange(row, from, to) &&
                (row['server_version_no']! as num) > 0)
              row['record_id']! as String: (row['server_version_no']! as num)
                  .toInt(),
        });
      });
    } on _RemotePullCancelled {
      return const <String, int>{};
    }
  }

  /// Removes only unchanged cached bodies missing from a completed range read.
  /// Absence cannot distinguish a deletion from a date change: originals,
  /// server versions, and the global pull checkpoint therefore remain intact.
  Future<RecordPageApplyResult> reconcileRemoteRange({
    required String ownerKey,
    required DateTime from,
    required DateTime to,
    required Set<String> knownRecordIds,
    required Map<String, int> expectedVersions,
    required bool Function() isCurrentSession,
  }) async {
    if (!from.isBefore(to)) throw ArgumentError('Invalid record query range.');
    final knownIds = Set<String>.of(knownRecordIds);
    final expected = Map<String, int>.of(expectedVersions);
    final evictedIds = <String>{};
    List<FishingRecord>? cacheBase;
    void ensureSession() {
      if (!isCurrentSession()) throw const _RemotePullCancelled();
    }

    try {
      await AppDatabase.instance.transaction((transaction) async {
        ensureSession();
        final rows = await _readRangeBodyVersions(transaction, ownerKey);
        ensureSession();
        final protectedIds = <String>{};
        for (final (table, condition) in [
          (AppDatabase.outboxItemsTable, "status != 'succeeded'"),
          (AppDatabase.recordConflictsTable, "status != 'resolved'"),
          (AppDatabase.localRecordChangesTable, '1 = 1'),
        ]) {
          final protectedRows = await transaction.query(
            table,
            columns: const ['record_id'],
            where: 'owner_key = ? AND ($condition)',
            whereArgs: [ownerKey],
          );
          protectedIds.addAll(
            protectedRows.map((row) => row['record_id']! as String),
          );
        }
        ensureSession();
        for (final row in rows) {
          ensureSession();
          final id = row['record_id']! as String;
          final version = (row['server_version_no']! as num).toInt();
          if (knownIds.contains(id) ||
              protectedIds.contains(id) ||
              expected[id] != version ||
              version < 1 ||
              row['optimistic_version_no'] != version ||
              row['remote_status'] != RemoteRecordStatus.active.name ||
              !_rowOverlapsRange(row, from, to)) {
            continue;
          }
          await _store.deleteRecord(
            transaction,
            ownerKey: ownerKey,
            recordId: id,
            preservePhotos: true,
          );
          evictedIds.add(id);
        }
        if (evictedIds.isNotEmpty && !_loadedOwners.contains(ownerKey)) {
          cacheBase = await _store.readRecordsForOwner(
            ownerKey,
            executor: transaction,
          );
        }
        ensureSession();
      });
    } on _RemotePullCancelled {
      return const RecordPageApplyResult(applied: false, changedCount: 0);
    }
    if (evictedIds.isNotEmpty) {
      _recordsByOwner[ownerKey] = List.unmodifiable(
        cacheBase ??
            getAllRecordsForOwner(
              ownerKey,
            ).where((record) => !evictedIds.contains(record.id)),
      );
      _loadedOwners.add(ownerKey);
      notifyListeners();
    }
    return RecordPageApplyResult(
      applied: true,
      changedCount: evictedIds.length,
    );
  }

  Future<List<Map<String, Object?>>> _readRangeBodyVersions(
    DatabaseExecutor executor,
    String ownerKey,
  ) => executor.rawQuery(
    '''
    SELECT r.record_id, r.start_at, r.end_at,
      s.server_version_no, s.optimistic_version_no, s.remote_status
    FROM ${AppDatabase.fishingRecordsTable} AS r
    INNER JOIN ${AppDatabase.recordSyncStatesTable} AS s
      ON s.owner_key = r.owner_key AND s.record_id = r.record_id
    WHERE r.owner_key = ?
  ''',
    [ownerKey],
  );

  bool _rowOverlapsRange(
    Map<String, Object?> row,
    DateTime from,
    DateTime to,
  ) =>
      DateTime.parse(row['start_at']! as String).isBefore(to) &&
      DateTime.parse(row['end_at']! as String).isAfter(from);

  Future<RecordPageApplyResult> _applyRemoteChanges({
    required String ownerKey,
    required List<RemoteRecordRevision> revisions,
    required RecordSyncCheckpoint? checkpoint,
    required bool Function() isCurrentSession,
    required bool fullSnapshot,
    bool Function(FishingRecord)? retainRecord,
    bool protectLocalsPerRecord = false,
  }) async {
    void ensureSession() {
      if (!isCurrentSession()) throw const _RemotePullCancelled();
    }

    final changes = <String, FishingRecord?>{};
    List<FishingRecord>? cacheBase;
    var applied = false;
    try {
      await AppDatabase.instance.transaction((transaction) async {
        ensureSession();
        if (!protectLocalsPerRecord &&
            !await _canApplyRemoteChanges(transaction, ownerKey)) {
          return;
        }
        ensureSession();

        Map<String, FishingRecord>? localById;
        if (fullSnapshot || !_loadedOwners.contains(ownerKey)) {
          cacheBase = await _store.readRecordsForOwner(
            ownerKey,
            executor: transaction,
          );
          localById = {for (final record in cacheBase!) record.id: record};
        }

        Map<String, RecordSyncMetadata>? metadataById;
        if (fullSnapshot) {
          final rows = await transaction.query(
            AppDatabase.recordSyncStatesTable,
            where: 'owner_key = ?',
            whereArgs: <Object?>[ownerKey],
          );
          metadataById = {
            for (final row in rows)
              row['record_id']! as String: RecordSyncMetadata(
                recordId: row['record_id']! as String,
                serverVersionNo: (row['server_version_no']! as num).toInt(),
                optimisticVersionNo: (row['optimistic_version_no']! as num)
                    .toInt(),
                remoteStatus: RemoteRecordStatus.values.byName(
                  row['remote_status']! as String,
                ),
              ),
          };
        }

        for (final revision in revisions) {
          ensureSession();
          if (protectLocalsPerRecord &&
              !await _canApplyRemoteChanges(
                transaction,
                ownerKey,
                recordId: revision.recordId,
              )) {
            continue;
          }
          ensureSession();
          final current = localById != null
              ? localById[revision.recordId]
              : await _store.readRecordForOwner(
                  ownerKey,
                  revision.recordId,
                  executor: transaction,
                );
          final metadata = metadataById != null
              ? metadataById[revision.recordId]
              : await _store.readRecordSyncMetadata(
                  ownerKey,
                  revision.recordId,
                  executor: transaction,
                );
          ensureSession();
          if (metadata != null &&
              revision.versionNo < metadata.serverVersionNo) {
            continue;
          }
          if (revision.status == RemoteRecordStatus.active) {
            final record = await _restoreLocalPhotos(
              transaction,
              ownerKey: ownerKey,
              remoteRecord: revision.record!,
              localRecord: current,
            );
            if (!(retainRecord?.call(record) ?? true)) {
              if (current != null) {
                await _store.deleteRecord(
                  transaction,
                  ownerKey: ownerKey,
                  recordId: revision.recordId,
                  preservePhotos: true,
                );
                changes[revision.recordId] = null;
                localById?.remove(revision.recordId);
              }
            } else if (current == null || !_sameRecord(current, record)) {
              await _store.insertRecord(
                transaction,
                ownerKey: ownerKey,
                record: record,
                replace: current != null,
              );
              changes[revision.recordId] = record;
              localById?[revision.recordId] = record;
            }
          } else {
            if (current != null) {
              await _store.deleteRecord(
                transaction,
                ownerKey: ownerKey,
                recordId: revision.recordId,
              );
              changes[revision.recordId] = null;
              localById?.remove(revision.recordId);
            } else if ((await _store.readArchivedPhotosForRecord(
              ownerKey,
              revision.recordId,
              executor: transaction,
            )).isNotEmpty) {
              await _store.deleteArchivedPhotosForRecord(
                transaction,
                ownerKey: ownerKey,
                recordId: revision.recordId,
              );
            }
          }
          if (metadata == null ||
              metadata.serverVersionNo != revision.versionNo ||
              metadata.optimisticVersionNo != revision.versionNo ||
              metadata.remoteStatus != revision.status) {
            await _store.writeRecordSyncMetadata(
              transaction,
              ownerKey: ownerKey,
              metadata: RecordSyncMetadata(
                recordId: revision.recordId,
                serverVersionNo: revision.versionNo,
                optimisticVersionNo: revision.versionNo,
                remoteStatus: revision.status,
              ),
              resetOptimisticVersion: true,
            );
          }
        }

        if (fullSnapshot) {
          final knownIds = revisions
              .map((revision) => revision.recordId)
              .toSet();
          for (final id in localById!.keys.toList(growable: false)) {
            if (knownIds.contains(id)) continue;
            await _store.deleteRecord(
              transaction,
              ownerKey: ownerKey,
              recordId: id,
            );
            changes[id] = null;
            localById.remove(id);
          }
          for (final id in metadataById!.keys) {
            if (knownIds.contains(id)) continue;
            await transaction.delete(
              AppDatabase.recordSyncStatesTable,
              where: 'owner_key = ? AND record_id = ?',
              whereArgs: <Object?>[ownerKey, id],
            );
          }
          final archivedIds = await _store.readArchivedRecordIdsForOwner(
            ownerKey,
            executor: transaction,
          );
          for (final id in archivedIds) {
            if (knownIds.contains(id)) continue;
            await _store.deleteArchivedPhotosForRecord(
              transaction,
              ownerKey: ownerKey,
              recordId: id,
            );
          }
        }

        if (checkpoint != null) {
          final key = RecordSyncCheckpoint.metadataKey(ownerKey);
          final previous = await _store.readMetadata(transaction, key);
          var next = checkpoint;
          if (!fullSnapshot && previous != null) {
            try {
              final priorCheckpoint = RecordSyncCheckpoint.decode(previous);
              if (next.cursor.compareTo(priorCheckpoint.cursor) < 0) {
                next = priorCheckpoint;
              }
            } on FormatException {
              // A valid page can replace malformed old progress safely.
            } on TypeError {
              // A valid page can replace malformed old progress safely.
            }
          }
          if (previous != next.encode()) {
            await _store.writeMetadata(
              transaction,
              key: key,
              value: next.encode(),
            );
          }
        }
        ensureSession();
        applied = true;
      });
    } on _RemotePullCancelled {
      return const RecordPageApplyResult(applied: false, changedCount: 0);
    }
    if (!applied) {
      return const RecordPageApplyResult(applied: false, changedCount: 0);
    }

    if (changes.isNotEmpty || !_loadedOwners.contains(ownerKey)) {
      final records = <String, FishingRecord>{
        for (final record in cacheBase ?? getAllRecordsForOwner(ownerKey))
          record.id: record,
      };
      for (final entry in changes.entries) {
        if (entry.value == null) {
          records.remove(entry.key);
        } else {
          records[entry.key] = entry.value!;
        }
      }
      _recordsByOwner[ownerKey] = List.unmodifiable(records.values);
      _loadedOwners.add(ownerKey);
      notifyListeners();
    }
    return RecordPageApplyResult(applied: true, changedCount: changes.length);
  }

  Future<bool> _canApplyRemoteChanges(
    DatabaseExecutor executor,
    String ownerKey, {
    String? recordId,
  }) async {
    for (final (table, extraWhere, arguments)
        in <(String, String, List<Object?>)>[
          (
            AppDatabase.outboxItemsTable,
            'status != ?',
            [OutboxStatus.succeeded.name],
          ),
          (AppDatabase.recordConflictsTable, 'status != ?', ['resolved']),
          (AppDatabase.localRecordChangesTable, '1 = 1', []),
        ]) {
      final rows = await executor.query(
        table,
        columns: const ['record_id'],
        where: recordId == null
            ? 'owner_key = ? AND ($extraWhere)'
            : 'owner_key = ? AND record_id = ? AND ($extraWhere)',
        whereArgs: <Object?>[ownerKey, ?recordId, ...arguments],
        limit: 1,
      );
      if (rows.isNotEmpty) return false;
    }
    return true;
  }

  bool _sameRecord(FishingRecord left, FishingRecord right) =>
      jsonEncode(left.toJson()) == jsonEncode(right.toJson());

  Future<FishingRecord> _restoreLocalPhotos(
    DatabaseExecutor executor, {
    required String ownerKey,
    required FishingRecord remoteRecord,
    required FishingRecord? localRecord,
  }) async {
    if (localRecord != null) {
      return _preserveLocalPhotos(remoteRecord, localRecord);
    }
    final archived = await _store.readArchivedPhotosForRecord(
      ownerKey,
      remoteRecord.id,
      executor: executor,
    );
    if (archived.isEmpty) return remoteRecord;
    return _withLocalPhotos(remoteRecord, archived);
  }

  FishingRecord _preserveLocalPhotos(
    FishingRecord remoteRecord,
    FishingRecord? localRecord,
  ) {
    if (localRecord == null || localRecord.photos.isEmpty) {
      return remoteRecord;
    }

    return _withLocalPhotos(remoteRecord, localRecord.photos);
  }

  FishingRecord _withLocalPhotos(
    FishingRecord remoteRecord,
    List<RecordPhoto> photos,
  ) {
    return FishingRecord(
      id: remoteRecord.id,
      location: remoteRecord.location,
      latitude: remoteRecord.latitude,
      longitude: remoteRecord.longitude,
      startAt: remoteRecord.startAt,
      endAt: remoteRecord.endAt,
      genreName: remoteRecord.genreName,
      tide: remoteRecord.tide,
      weather: remoteRecord.weather,
      airTemperature: remoteRecord.airTemperature,
      waterTemperature: remoteRecord.waterTemperature,
      catches: remoteRecord.catches,
      photos: photos,
      memo: remoteRecord.memo,
    );
  }

  Future<void> clear() async {
    final ownerKey = _ownerKey;
    await AppDatabase.instance.transaction((transaction) async {
      await _store.deleteAllRecords(transaction, ownerKey: ownerKey);
      await transaction.delete(
        AppDatabase.localMetadataTable,
        where: 'metadata_key = ?',
        whereArgs: <Object?>[RecordSyncCheckpoint.metadataKey(ownerKey)],
      );
    });
    await reloadOwner(ownerKey);
  }

  Future<int> importQuarantinedLegacyRecords() async {
    if (!AuthSessionRepository.instance.isMember) {
      throw StateError('Only a signed-in member can import legacy records.');
    }
    if (!_hasQuarantinedLegacyData) {
      return 0;
    }

    final legacyRecords = _quarantinedLegacyRecords;
    if (legacyRecords == null) {
      throw StateError('Legacy records could not be decoded safely.');
    }

    final ownerKey = _ownerKey;
    final existingIds = _records.map((record) => record.id).toSet();
    final importedRecords = legacyRecords
        .where((record) => existingIds.add(record.id))
        .toList();

    await AppDatabase.instance.transaction((transaction) async {
      for (final record in importedRecords) {
        await _store.insertRecord(
          transaction,
          ownerKey: ownerKey,
          record: record,
        );
      }
    });
    await reloadOwner(ownerKey);

    final preferences = await SharedPreferences.getInstance();
    final removed = await preferences.remove(_legacyStorageKey);
    if (!removed) {
      throw StateError('Failed to finish the legacy record import.');
    }

    _hasQuarantinedLegacyData = false;
    _quarantinedLegacyRecords = <FishingRecord>[];
    notifyListeners();
    return importedRecords.length;
  }

  @visibleForTesting
  void clearCacheOnlyForTesting() {
    _recordsByOwner.clear();
    _loadedOwners.clear();
    _quarantinedLegacyRecords = null;
    _hasQuarantinedLegacyData = false;
    notifyListeners();
  }
}

class RecordPageApplyResult {
  final bool applied;
  final int changedCount;

  const RecordPageApplyResult({
    required this.applied,
    required this.changedCount,
  });
}

class _RemotePullCancelled implements Exception {
  const _RemotePullCancelled();
}
