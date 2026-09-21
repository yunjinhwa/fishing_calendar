import '../local/app_database.dart';
import '../local/local_data_store.dart';
import '../models/fishing_record.dart';
import '../models/outbox_item.dart';
import '../repositories/auth_session_repository.dart';
import '../repositories/fishing_record_repository.dart';
import '../repositories/outbox_repository.dart';

class RecordMutationService {
  RecordMutationService._();

  static final RecordMutationService instance = RecordMutationService._();

  final _authSession = AuthSessionRepository.instance;
  final _recordRepository = FishingRecordRepository.instance;
  final _outboxRepository = OutboxRepository.instance;
  final _store = LocalDataStore.instance;

  Future<void> addRecord(FishingRecord record) async {
    _ensureRecordAccess();
    final ownerKey = _authSession.dataOwnerKey;
    final outboxItem = _createOutboxIfNeeded(
      record.id,
      OutboxOperationType.create,
      payload: record.toJson(),
    );

    await AppDatabase.instance.transaction((transaction) async {
      await _store.insertRecord(
        transaction,
        ownerKey: ownerKey,
        record: record,
      );
      if (outboxItem != null) {
        await _store.insertOutboxItem(
          transaction,
          ownerKey: ownerKey,
          item: outboxItem,
        );
      }
    });
    await _reloadAfterMutation(ownerKey, hasOutboxItem: outboxItem != null);
  }

  Future<void> updateRecord(FishingRecord record) async {
    _ensureRecordAccess();
    if (_recordRepository.getRecordById(record.id) == null) {
      throw StateError('Record not found: ${record.id}');
    }

    final ownerKey = _authSession.dataOwnerKey;
    final outboxItem = _createOutboxIfNeeded(
      record.id,
      OutboxOperationType.update,
      payload: record.toJson(),
    );

    await AppDatabase.instance.transaction((transaction) async {
      await _store.insertRecord(
        transaction,
        ownerKey: ownerKey,
        record: record,
        replace: true,
      );
      if (outboxItem != null) {
        await _store.insertOutboxItem(
          transaction,
          ownerKey: ownerKey,
          item: outboxItem,
        );
      }
    });
    await _reloadAfterMutation(ownerKey, hasOutboxItem: outboxItem != null);
  }

  Future<void> deleteRecord(String recordId) async {
    _ensureRecordAccess();
    final record = _recordRepository.getRecordById(recordId);
    if (record == null) {
      throw StateError('Record not found: $recordId');
    }

    final ownerKey = _authSession.dataOwnerKey;
    final outboxItem = _createOutboxIfNeeded(
      recordId,
      OutboxOperationType.delete,
      payload: record.toJson(),
    );

    await AppDatabase.instance.transaction((transaction) async {
      await _store.deleteRecord(
        transaction,
        ownerKey: ownerKey,
        recordId: recordId,
      );
      if (outboxItem != null) {
        await _store.insertOutboxItem(
          transaction,
          ownerKey: ownerKey,
          item: outboxItem,
        );
      }
    });
    await _reloadAfterMutation(ownerKey, hasOutboxItem: outboxItem != null);
  }

  Future<void> reconcileOutboxWithLocalRecords() async {
    if (!_authSession.isMember) {
      return;
    }

    for (final item in _outboxRepository.getAllItems()) {
      if (item.isMigration) {
        continue;
      }

      if (item.operationType == OutboxOperationType.delete) {
        if (_recordRepository.getRecordById(item.recordId) != null) {
          await _recordRepository.deleteRecord(item.recordId);
        }
        continue;
      }

      final payload = item.payload;
      if (payload == null) {
        continue;
      }

      FishingRecord record;
      try {
        record = FishingRecord.fromJson(payload);
      } on FormatException {
        continue;
      } on TypeError {
        continue;
      }

      if (_recordRepository.getRecordById(record.id) == null) {
        await _recordRepository.addRecord(record);
      } else {
        await _recordRepository.updateRecord(record);
      }
    }
  }

  void _ensureRecordAccess() {
    if (!_authSession.canManageRecords) {
      throw StateError('로그인한 회원만 출조 기록을 변경할 수 있습니다.');
    }
  }

  OutboxItem? _createOutboxIfNeeded(
    String recordId,
    OutboxOperationType operationType, {
    required Map<String, dynamic> payload,
  }) {
    if (!_authSession.canUseOutbox) {
      return null;
    }

    final now = DateTime.now();
    return OutboxItem(
      id: 'outbox-${now.microsecondsSinceEpoch}-$recordId',
      userId: _authSession.memberId,
      recordId: recordId,
      operationType: operationType,
      status: OutboxStatus.pending,
      createdAt: now,
      isMigration:
          _authSession.isPlanMigrationPending &&
          operationType == OutboxOperationType.create,
      payload: payload,
    );
  }

  Future<void> _reloadAfterMutation(
    String ownerKey, {
    required bool hasOutboxItem,
  }) async {
    await _recordRepository.reloadOwner(ownerKey);
    if (hasOutboxItem) {
      await _outboxRepository.reloadOwner(ownerKey);
    }
  }
}
