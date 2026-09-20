import 'dart:convert';

import '../models/outbox_item.dart';
import '../models/user_plan.dart';
import '../repositories/auth_session_repository.dart';
import '../repositories/fishing_record_memory_repository.dart';
import '../repositories/outbox_memory_repository.dart';

enum PlanChangeResult { changed, unchanged, blockedByPendingUploads }

class PlanPolicyService {
  PlanPolicyService._();

  static final PlanPolicyService instance = PlanPolicyService._();

  final _authSession = AuthSessionRepository.instance;
  final _recordRepository = FishingRecordMemoryRepository.instance;
  final _outboxRepository = OutboxMemoryRepository.instance;

  Future<PlanChangeResult> changePlan(UserPlan nextPlan) async {
    if (!_authSession.isMember) {
      throw StateError('로그인한 회원만 플랜을 변경할 수 있습니다.');
    }

    if (nextPlan == UserPlan.guest) {
      throw ArgumentError.value(nextPlan, 'nextPlan', '회원 플랜만 선택할 수 있습니다.');
    }

    if (_authSession.plan == nextPlan && !_authSession.isPlanMigrationPending) {
      return PlanChangeResult.unchanged;
    }

    if (nextPlan == UserPlan.free) {
      if (_outboxRepository.hasUnfinishedItems) {
        return PlanChangeResult.blockedByPendingUploads;
      }

      await _authSession.changeMemberPlan(UserPlan.free);
      await _outboxRepository.clearSucceeded();
      return PlanChangeResult.changed;
    }

    final wasFree = _authSession.isFree;
    final records = _recordRepository.getAllRecords();
    if (wasFree) {
      await _outboxRepository.removeObsoleteMigrationItems(
        records.map((record) => record.id).toSet(),
      );
    }

    final migrationStatus = records.isEmpty
        ? PlanMigrationStatus.none
        : PlanMigrationStatus.localToCloudPending;

    await _authSession.changeMemberPlan(
      UserPlan.paid,
      migrationStatus: migrationStatus,
    );

    if (migrationStatus == PlanMigrationStatus.localToCloudPending) {
      await _queueMissingMigrationItems();
    }

    return PlanChangeResult.changed;
  }

  Future<void> resumePendingMigration() async {
    if (!_authSession.isPaid || !_authSession.isPlanMigrationPending) {
      return;
    }

    await _queueMissingMigrationItems();
    await completeMigrationIfPossible();
  }

  Future<void> completeMigrationIfPossible() async {
    if (!_authSession.isPaid || !_authSession.isPlanMigrationPending) {
      return;
    }

    final records = _recordRepository.getAllRecords();
    final items = _outboxRepository.getAllItems();
    final everyRecordUploaded = records.every(
      (record) => items.any(
        (item) =>
            item.isMigration &&
            item.recordId == record.id &&
            item.operationType == OutboxOperationType.create &&
            item.status == OutboxStatus.succeeded,
      ),
    );
    final hasUnfinishedMigration = items.any(
      (item) => item.isMigration && item.status != OutboxStatus.succeeded,
    );

    if (!everyRecordUploaded ||
        hasUnfinishedMigration ||
        _outboxRepository.hasUnfinishedItems) {
      return;
    }

    await _authSession.changeMemberPlan(
      UserPlan.paid,
      migrationStatus: PlanMigrationStatus.none,
    );
  }

  Future<void> _queueMissingMigrationItems() async {
    for (final record in _recordRepository.getAllRecords()) {
      final payload = record.toJson();
      final existingItems = _outboxRepository.getAllItems().where(
        (item) =>
            item.recordId == record.id &&
            item.operationType == OutboxOperationType.create &&
            item.isMigration,
      );
      final existingItem = existingItems.firstOrNull;

      if (existingItem != null &&
          jsonEncode(existingItem.payload) == jsonEncode(payload)) {
        continue;
      }

      final now = DateTime.now();
      final migrationItem = OutboxItem(
        id:
            existingItem?.id ??
            'migration-${now.microsecondsSinceEpoch}-${record.id}',
        userId: _authSession.memberId,
        recordId: record.id,
        operationType: OutboxOperationType.create,
        status: OutboxStatus.pending,
        createdAt: existingItem?.createdAt ?? now,
        retryCount: existingItem?.retryCount ?? 0,
        isMigration: true,
        payload: payload,
      );

      if (existingItem == null) {
        await _outboxRepository.addItem(migrationItem);
      } else {
        await _outboxRepository.replaceItem(migrationItem);
      }
    }
  }
}
