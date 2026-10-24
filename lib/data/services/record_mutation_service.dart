import 'dart:async';

import 'package:sqflite/sqflite.dart';

import '../../core/validation/fishing_record_validator.dart';
import '../local/app_database.dart';
import '../local/local_data_store.dart';
import '../models/fishing_record.dart';
import '../models/outbox_item.dart';
import '../models/record_edit_snapshot.dart';
import '../repositories/auth_session_repository.dart';
import '../repositories/fishing_record_repository.dart';
import '../repositories/outbox_repository.dart';
import 'record_sync_service.dart';

class RecordMutationService {
  RecordMutationService._();

  static final RecordMutationService instance = RecordMutationService._();

  final _authSession = AuthSessionRepository.instance;
  final _recordRepository = FishingRecordRepository.instance;
  final _outboxRepository = OutboxRepository.instance;
  final _store = LocalDataStore.instance;

  Future<void> addRecord(FishingRecord record) async {
    _ensureRecordAccess();
    _ensureValidRecord(record);
    await _persistMutation(record, OutboxOperationType.create);
  }

  Future<RecordEditSnapshot> beginEditingRecord(
    FishingRecord displayedRecord,
  ) async {
    final snapshot = await loadRecordForEditing(displayedRecord.id);
    if (!snapshot.matchesRecord(displayedRecord)) {
      throw RecordEditConflictException(
        RecordEditConflictReason.changed,
        currentSnapshot: snapshot,
      );
    }
    return snapshot;
  }

  Future<RecordEditSnapshot> loadRecordForEditing(String recordId) async {
    _ensureRecordAccess();
    final ownerKey = _authSession.dataOwnerKey;
    final generation = _authSession.sessionGeneration;
    return AppDatabase.instance.transaction((transaction) async {
      final snapshot = await _readEditSnapshot(
        transaction,
        ownerKey: ownerKey,
        generation: generation,
        recordId: recordId,
      );
      _ensureEditSession(ownerKey, generation);
      return snapshot;
    });
  }

  /// An editor supplies the snapshot captured before the user changed fields.
  /// Programmatic mutations may omit it when there is no open editing session.
  Future<void> updateRecord(
    FishingRecord record, {
    RecordEditSnapshot? expectedSnapshot,
  }) async {
    if (expectedSnapshot != null) {
      _ensureEditSession(
        expectedSnapshot.ownerKey,
        expectedSnapshot.sessionGeneration,
      );
    }
    _ensureRecordAccess();
    _ensureValidRecord(record);
    if (expectedSnapshot == null &&
        _recordRepository.getRecordById(record.id) == null) {
      throw StateError('Record not found: ${record.id}');
    }
    await _persistMutation(
      record,
      OutboxOperationType.update,
      expectedSnapshot: expectedSnapshot,
    );
  }

  Future<void> deleteRecord(
    String recordId, {
    RecordEditSnapshot? expectedSnapshot,
  }) async {
    if (expectedSnapshot != null) {
      _ensureEditSession(
        expectedSnapshot.ownerKey,
        expectedSnapshot.sessionGeneration,
      );
      if (expectedSnapshot.record.id != recordId) {
        throw ArgumentError('편집 기준과 삭제할 기록의 ID가 일치하지 않습니다.');
      }
    }
    _ensureRecordAccess();
    final record =
        expectedSnapshot?.record ?? _recordRepository.getRecordById(recordId);
    if (record == null) {
      throw StateError('Record not found: $recordId');
    }
    await _persistMutation(
      record,
      OutboxOperationType.delete,
      expectedSnapshot: expectedSnapshot,
    );
  }

  Future<void> _persistMutation(
    FishingRecord record,
    OutboxOperationType operation, {
    RecordEditSnapshot? expectedSnapshot,
  }) async {
    final ownerKey = _authSession.dataOwnerKey;
    final generation = _authSession.sessionGeneration;
    final userId = _authSession.memberId;
    final usesOutbox = _authSession.canUseOutbox;
    final isMigration =
        _authSession.isPlanMigrationPending &&
        operation == OutboxOperationType.create;
    void ensureSession() {
      if (expectedSnapshot != null) {
        _ensureEditSession(
          expectedSnapshot.ownerKey,
          expectedSnapshot.sessionGeneration,
        );
      }
      if (generation != _authSession.sessionGeneration ||
          ownerKey != _authSession.dataOwnerKey ||
          !_authSession.canManageRecords ||
          usesOutbox != _authSession.canUseOutbox) {
        throw StateError('계정 또는 플랜이 변경되어 저장을 중단했습니다. 다시 시도해 주세요.');
      }
    }

    final committed = await AppDatabase.instance.transaction((
      transaction,
    ) async {
      ensureSession();
      if (expectedSnapshot != null) {
        _ensureEditSession(
          expectedSnapshot.ownerKey,
          expectedSnapshot.sessionGeneration,
        );
        if (expectedSnapshot.record.id != record.id) {
          throw ArgumentError('편집 기준과 저장할 기록의 ID가 일치하지 않습니다.');
        }
        final current = await _readEditSnapshot(
          transaction,
          ownerKey: ownerKey,
          generation: generation,
          recordId: record.id,
        );
        if (current.optimisticVersionNo !=
                expectedSnapshot.optimisticVersionNo ||
            !expectedSnapshot.matchesRecord(current.record)) {
          throw RecordEditConflictException(
            RecordEditConflictReason.changed,
            currentSnapshot: current,
          );
        }
      }
      ensureSession();
      if (usesOutbox) {
        final baseVersion = await _store.reserveNextRecordVersion(
          transaction,
          ownerKey: ownerKey,
          recordId: record.id,
        );
        ensureSession();
        final now = DateTime.now();
        await _store.insertOutboxItem(
          transaction,
          ownerKey: ownerKey,
          item: OutboxItem(
            id: 'outbox-${now.microsecondsSinceEpoch}-${record.id}',
            userId: userId,
            recordId: record.id,
            operationType: operation,
            status: OutboxStatus.pending,
            createdAt: now,
            isMigration: isMigration,
            baseVersionNo: baseVersion,
            payload: record.toJson(),
          ),
        );
        await _store.deleteLocalRecordChange(
          transaction,
          ownerKey: ownerKey,
          recordId: record.id,
        );
      } else {
        // Latest free-plan intent survives restart, including local deletion.
        await _store.writeLocalRecordChange(
          transaction,
          ownerKey: ownerKey,
          record: record,
          deleted: operation == OutboxOperationType.delete,
        );
      }
      ensureSession();
      if (operation == OutboxOperationType.delete) {
        await _store.deleteRecord(
          transaction,
          ownerKey: ownerKey,
          recordId: record.id,
        );
      } else {
        await _store.insertRecord(
          transaction,
          ownerKey: ownerKey,
          record: record,
          replace: operation == OutboxOperationType.update,
        );
      }
      // Read and decode before committing: any failure must roll back the
      // mutation too, rather than report failure after a durable save.
      final records = await _store.readRecordsForOwner(
        ownerKey,
        executor: transaction,
      );
      final outboxItems = usesOutbox
          ? await _store.readOutboxItemsForOwner(
              ownerKey,
              executor: transaction,
            )
          : null;
      ensureSession();
      return (records: records, outboxItems: outboxItems);
    });
    // Keep both caches consistent before synchronous record listeners run.
    final outboxItems = committed.outboxItems;
    if (outboxItems != null) {
      _outboxRepository.publishCommittedSnapshot(
        ownerKey: ownerKey,
        items: outboxItems,
      );
    }
    _recordRepository.publishCommittedSnapshot(
      ownerKey: ownerKey,
      records: committed.records,
    );
    if (usesOutbox) {
      if (generation == _authSession.sessionGeneration) {
        unawaited(
          RecordSyncService.instance.syncNow(scheduleFollowUpIfBusy: true),
        );
      }
    }
  }

  Future<void> reconcileOutboxWithLocalRecords() async {
    // SQLite mutations are atomic. Legacy recovery must never replay an old
    // paid request over the authoritative local copy being migrated.
    if (!_authSession.canUseOutbox || _authSession.isPlanMigrationPending) {
      return;
    }
    final ownerKey = _authSession.dataOwnerKey;
    final generation = _authSession.sessionGeneration;
    await AppDatabase.instance
        .transaction((transaction) async {
          if (generation != _authSession.sessionGeneration) return;
          final changes = await _store.readLocalRecordChangesForOwner(
            ownerKey,
            executor: transaction,
          );
          if (changes.isNotEmpty) return;
          final items = await _store.readOutboxItemsForOwner(
            ownerKey,
            executor: transaction,
          );
          for (final item in items) {
            if (generation != _authSession.sessionGeneration) {
              throw const _ReconciliationCancelled();
            }
            if (!_authSession.canUseOutbox ||
                _authSession.isPlanMigrationPending) {
              throw const _ReconciliationCancelled();
            }
            if (item.isMigration || item.status == OutboxStatus.succeeded) {
              continue;
            }
            if (item.operationType == OutboxOperationType.delete) {
              await _store.deleteRecord(
                transaction,
                ownerKey: ownerKey,
                recordId: item.recordId,
              );
              continue;
            }
            final payload = item.payload;
            if (payload == null) continue;
            FishingRecord record;
            try {
              record = FishingRecord.fromJson(payload);
            } on FormatException {
              continue;
            } on TypeError {
              continue;
            }
            await _store.insertRecord(
              transaction,
              ownerKey: ownerKey,
              record: record,
              replace: true,
            );
          }
          if (generation != _authSession.sessionGeneration) {
            throw const _ReconciliationCancelled();
          }
        })
        .onError<_ReconciliationCancelled>((_, _) {});
    await _recordRepository.reloadOwner(ownerKey);
  }

  void _ensureRecordAccess() {
    if (!_authSession.canManageRecords) {
      throw StateError('로그인한 회원만 출조 기록을 변경할 수 있습니다.');
    }
  }

  void _ensureEditSession(String ownerKey, int generation) {
    if (ownerKey != _authSession.dataOwnerKey ||
        generation != _authSession.sessionGeneration ||
        !_authSession.canManageRecords) {
      throw const RecordEditConflictException(
        RecordEditConflictReason.sessionChanged,
      );
    }
  }

  Future<RecordEditSnapshot> _readEditSnapshot(
    DatabaseExecutor transaction, {
    required String ownerKey,
    required int generation,
    required String recordId,
  }) async {
    _ensureEditSession(ownerKey, generation);
    final record = await _store.readRecordForOwner(
      ownerKey,
      recordId,
      executor: transaction,
    );
    final metadata = await _store.readRecordSyncMetadata(
      ownerKey,
      recordId,
      executor: transaction,
    );
    _ensureEditSession(ownerKey, generation);
    if (record == null) {
      throw const RecordEditConflictException(RecordEditConflictReason.deleted);
    }
    return RecordEditSnapshot(
      record: record,
      ownerKey: ownerKey,
      sessionGeneration: generation,
      optimisticVersionNo: metadata?.optimisticVersionNo ?? 0,
    );
  }

  void _ensureValidRecord(FishingRecord record) {
    final errorMessage = FishingRecordValidator.validate(record);
    if (errorMessage != null) {
      throw ArgumentError.value(record, 'record', errorMessage);
    }
  }
}

class _ReconciliationCancelled implements Exception {
  const _ReconciliationCancelled();
}
