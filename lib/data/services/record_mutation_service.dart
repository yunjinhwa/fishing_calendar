import '../models/fishing_record.dart';
import '../models/outbox_item.dart';
import '../repositories/auth_session_repository.dart';
import '../repositories/fishing_record_memory_repository.dart';
import '../repositories/outbox_memory_repository.dart';

class RecordMutationService {
  RecordMutationService._();

  static final RecordMutationService instance = RecordMutationService._();

  final _authSession = AuthSessionRepository.instance;
  final _recordRepository = FishingRecordMemoryRepository.instance;
  final _outboxRepository = OutboxMemoryRepository.instance;

  Future<void> addRecord(FishingRecord record) async {
    _ensureRecordAccess();
    await _enqueueIfNeeded(
      record.id,
      OutboxOperationType.create,
      payload: record.toJson(),
    );
    await _recordRepository.addRecord(record);
  }

  Future<void> updateRecord(FishingRecord record) async {
    _ensureRecordAccess();
    if (_recordRepository.getRecordById(record.id) == null) {
      throw StateError('Record not found: ${record.id}');
    }

    await _enqueueIfNeeded(
      record.id,
      OutboxOperationType.update,
      payload: record.toJson(),
    );
    await _recordRepository.updateRecord(record);
  }

  Future<void> deleteRecord(String recordId) async {
    _ensureRecordAccess();
    final record = _recordRepository.getRecordById(recordId);
    if (record == null) {
      throw StateError('Record not found: $recordId');
    }

    await _enqueueIfNeeded(
      recordId,
      OutboxOperationType.delete,
      payload: record.toJson(),
    );
    await _recordRepository.deleteRecord(recordId);
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

  Future<void> _enqueueIfNeeded(
    String recordId,
    OutboxOperationType operationType, {
    required Map<String, dynamic> payload,
  }) async {
    if (!_authSession.canUseOutbox) {
      return;
    }

    final now = DateTime.now();
    await _outboxRepository.addItem(
      OutboxItem(
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
      ),
    );
  }
}
