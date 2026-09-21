import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'app_database.dart';
import 'data_owner_key.dart';
import 'local_data_migration_service.dart';
import 'local_data_store.dart';

enum LocalIdentityMigrationStatus {
  migrated,
  claimedWithoutData,
  alreadyMigrated,
  skippedUnverified,
}

class LocalIdentityMigrationResult {
  final LocalIdentityMigrationStatus status;
  final String sourceOwnerKey;
  final String targetOwnerKey;
  final int migratedRecordCount;
  final int migratedOutboxCount;

  const LocalIdentityMigrationResult({
    required this.status,
    required this.sourceOwnerKey,
    required this.targetOwnerKey,
    required this.migratedRecordCount,
    required this.migratedOutboxCount,
  });

  int get migratedItemCount => migratedRecordCount + migratedOutboxCount;
}

sealed class LocalIdentityMigrationConflict implements Exception {
  final String message;

  const LocalIdentityMigrationConflict(this.message);

  @override
  String toString() => '$runtimeType: $message';
}

final class LocalIdentityClaimConflict extends LocalIdentityMigrationConflict {
  final String sourceOwnerKey;
  final String claimedFirebaseUid;
  final String requestedFirebaseUid;

  const LocalIdentityClaimConflict({
    required this.sourceOwnerKey,
    required this.claimedFirebaseUid,
    required this.requestedFirebaseUid,
  }) : super('The legacy data owner is already claimed by another user.');
}

final class LocalIdentityDataConflict extends LocalIdentityMigrationConflict {
  final String sourceOwnerKey;
  final String targetOwnerKey;
  final List<String> recordIds;
  final List<String> outboxIds;

  LocalIdentityDataConflict({
    required this.sourceOwnerKey,
    required this.targetOwnerKey,
    required List<String> recordIds,
    required List<String> outboxIds,
  }) : recordIds = List.unmodifiable(recordIds),
       outboxIds = List.unmodifiable(outboxIds),
       super('The source and target owners contain colliding local IDs.');
}

final class LocalIdentityMalformedClaimException implements Exception {
  final String metadataKey;

  const LocalIdentityMalformedClaimException(this.metadataKey);

  @override
  String toString() =>
      '$runtimeType: The local identity claim metadata is malformed.';
}

class LocalIdentityMigrationService {
  LocalIdentityMigrationService._();

  static final LocalIdentityMigrationService instance =
      LocalIdentityMigrationService._();

  static const int _claimVersion = 1;
  static const String _claimMetadataPrefix = 'firebase_owner_claim_v1:';

  final LocalDataStore _store = LocalDataStore.instance;

  Future<LocalIdentityMigrationResult> claimLegacyMemberData({
    required String firebaseUid,
    required String authenticatedEmail,
    required bool allowInitialClaim,
  }) async {
    final sourceOwnerKey = DataOwnerKey.legacyEmail(authenticatedEmail);
    final targetOwnerKey = DataOwnerKey.firebaseUid(firebaseUid);

    // Older account-scoped SharedPreferences data must reach SQLite before its
    // owner key is changed, otherwise it could be imported under the old key
    // after this migration has completed.
    await LocalDataMigrationService.instance.migrateIfNeeded();

    return AppDatabase.instance.transaction(
      (transaction) => _claimInTransaction(
        transaction,
        firebaseUid: firebaseUid,
        sourceOwnerKey: sourceOwnerKey,
        targetOwnerKey: targetOwnerKey,
        allowInitialClaim: allowInitialClaim,
      ),
      exclusive: true,
    );
  }

  Future<LocalIdentityMigrationResult> _claimInTransaction(
    Transaction transaction, {
    required String firebaseUid,
    required String sourceOwnerKey,
    required String targetOwnerKey,
    required bool allowInitialClaim,
  }) async {
    final metadataKey = _claimMetadataKey(sourceOwnerKey);
    final existingClaim = await _readClaim(
      transaction,
      metadataKey: metadataKey,
      expectedSourceOwnerKey: sourceOwnerKey,
    );

    if (existingClaim != null && existingClaim.firebaseUid != firebaseUid) {
      if (allowInitialClaim) {
        throw LocalIdentityClaimConflict(
          sourceOwnerKey: sourceOwnerKey,
          claimedFirebaseUid: existingClaim.firebaseUid,
          requestedFirebaseUid: firebaseUid,
        );
      }
      return LocalIdentityMigrationResult(
        status: LocalIdentityMigrationStatus.skippedUnverified,
        sourceOwnerKey: sourceOwnerKey,
        targetOwnerKey: targetOwnerKey,
        migratedRecordCount: 0,
        migratedOutboxCount: 0,
      );
    }

    if (existingClaim == null && !allowInitialClaim) {
      return LocalIdentityMigrationResult(
        status: LocalIdentityMigrationStatus.skippedUnverified,
        sourceOwnerKey: sourceOwnerKey,
        targetOwnerKey: targetOwnerKey,
        migratedRecordCount: 0,
        migratedOutboxCount: 0,
      );
    }

    final recordCollisions = await _readRecordIdentityCollisions(
      transaction,
      sourceOwnerKey: sourceOwnerKey,
      targetOwnerKey: targetOwnerKey,
    );
    final outboxCollisions = await _readCollidingIds(
      transaction,
      table: AppDatabase.outboxItemsTable,
      idColumn: 'outbox_id',
      sourceOwnerKey: sourceOwnerKey,
      targetOwnerKey: targetOwnerKey,
    );
    if (recordCollisions.isNotEmpty || outboxCollisions.isNotEmpty) {
      throw LocalIdentityDataConflict(
        sourceOwnerKey: sourceOwnerKey,
        targetOwnerKey: targetOwnerKey,
        recordIds: recordCollisions,
        outboxIds: outboxCollisions,
      );
    }

    final migratedRecordCount = await transaction.rawUpdate(
      '''
      UPDATE ${AppDatabase.fishingRecordsTable}
      SET owner_key = ?
      WHERE owner_key = ?
      ''',
      <Object?>[targetOwnerKey, sourceOwnerKey],
    );
    final migratedOutboxCount = await transaction.rawUpdate(
      '''
      UPDATE ${AppDatabase.outboxItemsTable}
      SET owner_key = ?, user_id = ?
      WHERE owner_key = ?
      ''',
      <Object?>[targetOwnerKey, firebaseUid, sourceOwnerKey],
    );

    await _store.writeMetadata(
      transaction,
      key: metadataKey,
      value: jsonEncode(<String, Object>{
        'version': _claimVersion,
        'firebaseUid': firebaseUid,
        'sourceOwnerKey': sourceOwnerKey,
        'targetOwnerKey': targetOwnerKey,
      }),
    );

    final status = migratedRecordCount > 0 || migratedOutboxCount > 0
        ? LocalIdentityMigrationStatus.migrated
        : existingClaim == null
        ? LocalIdentityMigrationStatus.claimedWithoutData
        : LocalIdentityMigrationStatus.alreadyMigrated;

    return LocalIdentityMigrationResult(
      status: status,
      sourceOwnerKey: sourceOwnerKey,
      targetOwnerKey: targetOwnerKey,
      migratedRecordCount: migratedRecordCount,
      migratedOutboxCount: migratedOutboxCount,
    );
  }

  Future<_IdentityClaim?> _readClaim(
    DatabaseExecutor executor, {
    required String metadataKey,
    required String expectedSourceOwnerKey,
  }) async {
    final rows = await executor.query(
      AppDatabase.localMetadataTable,
      columns: const <String>['metadata_value'],
      where: 'metadata_key = ?',
      whereArgs: <Object?>[metadataKey],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }

    final rawValue = rows.single['metadata_value'];
    if (rawValue is! String || rawValue.isEmpty) {
      throw LocalIdentityMalformedClaimException(metadataKey);
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(rawValue);
    } on FormatException {
      throw LocalIdentityMalformedClaimException(metadataKey);
    }
    if (decoded is! Map) {
      throw LocalIdentityMalformedClaimException(metadataKey);
    }

    final claim = Map<String, dynamic>.from(decoded);
    final version = claim['version'];
    final firebaseUid = claim['firebaseUid'];
    final sourceOwnerKey = claim['sourceOwnerKey'];
    final targetOwnerKey = claim['targetOwnerKey'];
    if (version != _claimVersion ||
        firebaseUid is! String ||
        firebaseUid.trim().isEmpty ||
        sourceOwnerKey != expectedSourceOwnerKey ||
        targetOwnerKey is! String ||
        targetOwnerKey != DataOwnerKey.firebaseUid(firebaseUid)) {
      throw LocalIdentityMalformedClaimException(metadataKey);
    }

    return _IdentityClaim(firebaseUid: firebaseUid);
  }

  Future<List<String>> _readCollidingIds(
    DatabaseExecutor executor, {
    required String table,
    required String idColumn,
    required String sourceOwnerKey,
    required String targetOwnerKey,
  }) async {
    final rows = await executor.rawQuery(
      '''
      SELECT source.$idColumn AS conflicting_id
      FROM $table AS source
      INNER JOIN $table AS target
        ON target.owner_key = ?
       AND target.$idColumn = source.$idColumn
      WHERE source.owner_key = ?
      ORDER BY source.$idColumn ASC
      ''',
      <Object?>[targetOwnerKey, sourceOwnerKey],
    );

    return rows
        .map((row) => row['conflicting_id'])
        .whereType<String>()
        .toList(growable: false);
  }

  Future<List<String>> _readRecordIdentityCollisions(
    DatabaseExecutor executor, {
    required String sourceOwnerKey,
    required String targetOwnerKey,
  }) async {
    final records = AppDatabase.fishingRecordsTable;
    final outbox = AppDatabase.outboxItemsTable;
    final rows = await executor.rawQuery(
      '''
      SELECT conflicting_id
      FROM (
        SELECT source_record.record_id AS conflicting_id
        FROM $records AS source_record
        INNER JOIN $records AS target_record
          ON target_record.owner_key = ?
         AND target_record.record_id = source_record.record_id
        WHERE source_record.owner_key = ?

        UNION

        SELECT source_record.record_id AS conflicting_id
        FROM $records AS source_record
        INNER JOIN $outbox AS target_outbox
          ON target_outbox.owner_key = ?
         AND target_outbox.record_id = source_record.record_id
        WHERE source_record.owner_key = ?

        UNION

        SELECT source_outbox.record_id AS conflicting_id
        FROM $outbox AS source_outbox
        INNER JOIN $records AS target_record
          ON target_record.owner_key = ?
         AND target_record.record_id = source_outbox.record_id
        WHERE source_outbox.owner_key = ?

        UNION

        SELECT source_outbox.record_id AS conflicting_id
        FROM $outbox AS source_outbox
        INNER JOIN $outbox AS target_outbox
          ON target_outbox.owner_key = ?
         AND target_outbox.record_id = source_outbox.record_id
        WHERE source_outbox.owner_key = ?
      )
      ORDER BY conflicting_id ASC
      ''',
      <Object?>[
        targetOwnerKey,
        sourceOwnerKey,
        targetOwnerKey,
        sourceOwnerKey,
        targetOwnerKey,
        sourceOwnerKey,
        targetOwnerKey,
        sourceOwnerKey,
      ],
    );

    return rows
        .map((row) => row['conflicting_id'])
        .whereType<String>()
        .toList(growable: false);
  }

  String _claimMetadataKey(String sourceOwnerKey) =>
      '$_claimMetadataPrefix$sourceOwnerKey';
}

class _IdentityClaim {
  final String firebaseUid;

  const _IdentityClaim({required this.firebaseUid});
}
