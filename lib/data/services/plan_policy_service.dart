import 'dart:convert';

import '../local/app_database.dart';
import '../local/local_data_store.dart';
import '../models/outbox_item.dart';
import '../models/user_plan.dart';
import '../repositories/auth_session_repository.dart';
import '../repositories/fishing_record_repository.dart';
import '../repositories/outbox_repository.dart';

enum PlanChangeResult { changed, unchanged, blockedByPendingUploads }

class PlanPolicyService {
  PlanPolicyService._();

  static final PlanPolicyService instance = PlanPolicyService._();

  final _authSession = AuthSessionRepository.instance;
  final _recordRepository = FishingRecordRepository.instance;
  final _outboxRepository = OutboxRepository.instance;
  final _store = LocalDataStore.instance;

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
      final existingItems = _outboxRepository
          .getAllItems()
          .where((item) => item.recordId == record.id && item.isMigration)
          .toList(growable: false);
      final existingItem = existingItems.isEmpty ? null : existingItems.last;

      if (existingItem?.status == OutboxStatus.conflicted) {
        continue;
      }
      if (existingItem != null &&
          jsonEncode(existingItem.payload) == jsonEncode(payload)) {
        continue;
      }

      final now = DateTime.now();
      if (existingItem == null ||
          existingItem.status == OutboxStatus.succeeded) {
        final ownerKey = _authSession.dataOwnerKey;
        final syncMetadata = await _store.readRecordSyncMetadata(
          ownerKey,
          record.id,
        );
        final operationType =
            existingItem != null || (syncMetadata?.serverVersionNo ?? 0) > 0
            ? OutboxOperationType.update
            : OutboxOperationType.create;
        await AppDatabase.instance.transaction((transaction) async {
          final baseVersionNo = await _store.reserveNextRecordVersion(
            transaction,
            ownerKey: ownerKey,
            recordId: record.id,
          );
          await _store.insertOutboxItem(
            transaction,
            ownerKey: ownerKey,
            item: OutboxItem(
              id: 'migration-${now.microsecondsSinceEpoch}-${record.id}',
              userId: _authSession.memberId,
              recordId: record.id,
              operationType: operationType,
              status: OutboxStatus.pending,
              createdAt: now,
              isMigration: true,
              baseVersionNo: baseVersionNo,
              payload: payload,
            ),
          );
        });
        await _outboxRepository.reloadOwner(ownerKey);
      } else {
        await _outboxRepository.replaceItem(
          OutboxItem(
            id: existingItem.id,
            userId: _authSession.memberId,
            recordId: record.id,
            operationType: existingItem.operationType,
            status: OutboxStatus.pending,
            createdAt: existingItem.createdAt,
            retryCount: existingItem.retryCount,
            isMigration: true,
            baseVersionNo: existingItem.baseVersionNo,
            payload: payload,
          ),
        );
      }
    }
  }
}
