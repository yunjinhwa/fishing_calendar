import 'dart:async';

import '../local/app_database.dart';
import '../local/local_data_store.dart';
import '../models/conflict_item.dart';
import '../models/fishing_record.dart';
import '../models/outbox_item.dart';
import '../models/record_sync_metadata.dart';
import '../repositories/auth_session_repository.dart';
import '../repositories/conflict_repository.dart';
import '../repositories/fishing_record_repository.dart';
import '../repositories/outbox_repository.dart';
import 'plan_policy_service.dart';
import 'record_sync_service.dart';

class ConflictResolutionService {
  ConflictResolutionService._();

  static final ConflictResolutionService instance =
      ConflictResolutionService._();

  final AuthSessionRepository _authSession = AuthSessionRepository.instance;
  final ConflictRepository _conflictRepository = ConflictRepository.instance;
  final FishingRecordRepository _recordRepository =
      FishingRecordRepository.instance;
  final OutboxRepository _outboxRepository = OutboxRepository.instance;
  final LocalDataStore _store = LocalDataStore.instance;

  Future<void> useMine(ConflictItem conflict) {
    final current = _requireCurrentConflict(conflict);
    final latestIntent = _latestUnfinishedIntent(current.recordId);
    final deleteRecord =
        latestIntent?.operationType == OutboxOperationType.delete ||
        (latestIntent == null && current.localDeleted);
    FishingRecord? record;
    if (!deleteRecord) {
      record = _recordRepository.getRecordById(current.recordId);
      final payload = latestIntent?.payload;
      if (record == null && payload != null) {
        try {
          record = FishingRecord.fromJson(payload);
        } on Object {
          record = null;
        }
      }
      record ??= current.localRecord;
    }
    return _queueLocalResolution(
      conflict: current,
      resolutionType: ConflictResolutionType.useMine,
      record: record,
      deleteRecord: deleteRecord,
    );
  }

  Future<void> useMerged(ConflictItem conflict, FishingRecord mergedRecord) {
    return _queueLocalResolution(
      conflict: conflict,
      resolutionType: ConflictResolutionType.manualMerge,
      record: mergedRecord,
      deleteRecord: false,
    );
  }

  Future<void> useTheirs(ConflictItem conflict) async {
    final current = _requireCurrentConflict(conflict);
    final uid = _authSession.memberId;
    if (uid == null) {
      throw StateError('로그인 후 충돌을 해결할 수 있습니다.');
    }

    final latest = await RecordSyncService.instance.fetchLatestRevision(
      current.recordId,
    );
    _ensureOwner(current);

    final remoteStatus = latest?.status ?? RemoteRecordStatus.missing;
    final remoteVersionNo = latest?.versionNo ?? 0;
    final localRecord =
        _recordRepository.getRecordById(current.recordId) ??
        current.localRecord;
    final remoteRecord = latest?.record;
    final resolvedRecord = remoteRecord == null
        ? null
        : _withLocalPhotos(remoteRecord, localRecord);
    final resolvedAt = DateTime.now();
    final sourceItem = _sourceOutboxItem(current);

    await AppDatabase.instance.transaction((transaction) async {
      await _store.deleteUnfinishedOutboxItemsForRecord(
        transaction,
        ownerKey: current.ownerKey,
        recordId: current.recordId,
      );
      if (resolvedRecord == null) {
        await _store.deleteRecord(
          transaction,
          ownerKey: current.ownerKey,
          recordId: current.recordId,
        );
      } else {
        await _store.insertRecord(
          transaction,
          ownerKey: current.ownerKey,
          record: resolvedRecord,
          replace: true,
        );
      }
      await _store.writeRecordSyncMetadata(
        transaction,
        ownerKey: current.ownerKey,
        metadata: RecordSyncMetadata(
          recordId: current.recordId,
          serverVersionNo: remoteVersionNo,
          optimisticVersionNo: remoteVersionNo,
          remoteStatus: remoteStatus,
        ),
        resetOptimisticVersion: true,
      );
      if (sourceItem?.isMigration == true) {
        await _store.insertOutboxItem(
          transaction,
          ownerKey: current.ownerKey,
          item: sourceItem!.copyWith(
            status: OutboxStatus.succeeded,
            lastTriedAt: resolvedAt,
            payload: resolvedRecord?.toJson() ?? sourceItem.payload,
            clearErrorMessage: true,
          ),
        );
      }
      await _store.updateConflict(
        transaction,
        conflict: current.copyWith(
          status: ConflictStatus.resolved,
          resolutionType: ConflictResolutionType.useTheirs,
          resolvedAt: resolvedAt,
          clearResolutionOutboxId: true,
        ),
      );
    });
    await _reload(current.ownerKey);
    await PlanPolicyService.instance.completeMigrationIfPossible();
  }

  Future<void> _queueLocalResolution({
    required ConflictItem conflict,
    required ConflictResolutionType resolutionType,
    required FishingRecord? record,
    required bool deleteRecord,
  }) async {
    final current = _requireCurrentConflict(conflict);
    if (!deleteRecord && record == null) {
      throw StateError('적용할 로컬 기록이 없습니다.');
    }
    final now = DateTime.now();
    final sourceItem = _sourceOutboxItem(current);
    final isMigration = sourceItem?.isMigration ?? false;
    if (deleteRecord && current.remoteStatus == RemoteRecordStatus.missing) {
      await AppDatabase.instance.transaction((transaction) async {
        await _store.deleteUnfinishedOutboxItemsForRecord(
          transaction,
          ownerKey: current.ownerKey,
          recordId: current.recordId,
        );
        await _store.deleteRecord(
          transaction,
          ownerKey: current.ownerKey,
          recordId: current.recordId,
        );
        await _store.writeRecordSyncMetadata(
          transaction,
          ownerKey: current.ownerKey,
          metadata: RecordSyncMetadata(
            recordId: current.recordId,
            serverVersionNo: 0,
            optimisticVersionNo: 0,
            remoteStatus: RemoteRecordStatus.missing,
          ),
          resetOptimisticVersion: true,
        );
        await _store.updateConflict(
          transaction,
          conflict: current.copyWith(
            status: ConflictStatus.resolved,
            resolutionType: resolutionType,
            resolvedAt: now,
            clearResolutionOutboxId: true,
          ),
        );
      });
      await _reload(current.ownerKey);
      await PlanPolicyService.instance.completeMigrationIfPossible();
      return;
    }
    final resolutionOutboxId =
        'resolve-${now.microsecondsSinceEpoch}-${current.recordId}';

    await AppDatabase.instance.transaction((transaction) async {
      await _store.deleteUnfinishedOutboxItemsForRecord(
        transaction,
        ownerKey: current.ownerKey,
        recordId: current.recordId,
      );
      await _store.writeRecordSyncMetadata(
        transaction,
        ownerKey: current.ownerKey,
        metadata: RecordSyncMetadata(
          recordId: current.recordId,
          serverVersionNo: current.remoteVersionNo,
          optimisticVersionNo: current.remoteVersionNo,
          remoteStatus: current.remoteStatus,
        ),
        resetOptimisticVersion: true,
      );
      final baseVersionNo = await _store.reserveNextRecordVersion(
        transaction,
        ownerKey: current.ownerKey,
        recordId: current.recordId,
      );

      if (deleteRecord) {
        await _store.deleteRecord(
          transaction,
          ownerKey: current.ownerKey,
          recordId: current.recordId,
        );
      } else {
        await _store.insertRecord(
          transaction,
          ownerKey: current.ownerKey,
          record: record!,
          replace: true,
        );
      }

      final operationType = deleteRecord
          ? OutboxOperationType.delete
          : current.remoteStatus == RemoteRecordStatus.missing
          ? OutboxOperationType.create
          : OutboxOperationType.update;
      await _store.insertOutboxItem(
        transaction,
        ownerKey: current.ownerKey,
        item: OutboxItem(
          id: resolutionOutboxId,
          userId: _authSession.memberId,
          recordId: current.recordId,
          operationType: operationType,
          status: OutboxStatus.pending,
          createdAt: now,
          isMigration: isMigration,
          baseVersionNo: baseVersionNo,
          payload: record?.toJson() ?? current.localRecord?.toJson(),
        ),
      );
      await _store.updateConflict(
        transaction,
        conflict: current.copyWith(
          status: ConflictStatus.resolving,
          resolutionType: resolutionType,
          resolutionOutboxId: resolutionOutboxId,
        ),
      );
    });
    await _reload(current.ownerKey);
    unawaited(RecordSyncService.instance.syncNow(scheduleFollowUpIfBusy: true));
  }

  ConflictItem _requireCurrentConflict(ConflictItem conflict) {
    _ensureOwner(conflict);
    final current = _conflictRepository.findById(conflict.id);
    if (current == null || current.status != ConflictStatus.unresolved) {
      throw StateError('이미 처리되었거나 찾을 수 없는 충돌입니다.');
    }
    return current;
  }

  void _ensureOwner(ConflictItem conflict) {
    if (!_authSession.isPaid ||
        conflict.ownerKey != _authSession.dataOwnerKey) {
      throw StateError('현재 계정의 충돌만 해결할 수 있습니다.');
    }
  }

  OutboxItem? _sourceOutboxItem(ConflictItem conflict) {
    for (final item in _outboxRepository.getAllItems()) {
      if (item.id == conflict.outboxId) {
        return item;
      }
    }
    return null;
  }

  OutboxItem? _latestUnfinishedIntent(String recordId) {
    OutboxItem? result;
    for (final item in _outboxRepository.getAllItems()) {
      if (item.recordId == recordId && item.status != OutboxStatus.succeeded) {
        result = item;
      }
    }
    return result;
  }

  FishingRecord _withLocalPhotos(
    FishingRecord remoteRecord,
    FishingRecord? localRecord,
  ) {
    return FishingRecord(
      id: remoteRecord.id,
      location: remoteRecord.location,
      startAt: remoteRecord.startAt,
      endAt: remoteRecord.endAt,
      genreName: remoteRecord.genreName,
      tide: remoteRecord.tide,
      weather: remoteRecord.weather,
      airTemperature: remoteRecord.airTemperature,
      waterTemperature: remoteRecord.waterTemperature,
      catches: remoteRecord.catches,
      photos: localRecord?.photos ?? const [],
      memo: remoteRecord.memo,
    );
  }

  Future<void> _reload(String ownerKey) async {
    await _recordRepository.reloadOwner(ownerKey);
    await _outboxRepository.reloadOwner(ownerKey);
    await _conflictRepository.reloadOwner(ownerKey);
  }
}
