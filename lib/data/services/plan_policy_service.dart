import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../local/app_database.dart';
import '../local/local_data_store.dart';
import '../models/outbox_item.dart';
import '../models/plan_entitlement.dart';
import '../models/record_sync_metadata.dart';
import '../models/user_plan.dart';
import '../repositories/auth_session_repository.dart';
import '../repositories/outbox_repository.dart';

enum PlanChangeResult { changed, unchanged, blockedByPendingUploads }

class PlanPolicyService {
  PlanPolicyService._();

  static final PlanPolicyService instance = PlanPolicyService._();

  final _authSession = AuthSessionRepository.instance;
  final _outboxRepository = OutboxRepository.instance;
  final _store = LocalDataStore.instance;
  Future<PlanEntitlementRefreshResult>? _refreshFuture;
  int? _refreshGeneration;
  final Map<int, Future<void>> _migrationFutures = {};

  Future<PlanEntitlementRefreshResult> refreshServerPlan() {
    final generation = _authSession.sessionGeneration;
    final inProgress = _refreshFuture;
    if (inProgress != null && _refreshGeneration == generation) {
      return inProgress;
    }
    late final Future<PlanEntitlementRefreshResult> future;
    future = _performServerPlanRefresh(generation).whenComplete(() {
      if (identical(_refreshFuture, future)) _refreshFuture = null;
    });
    _refreshGeneration = generation;
    _refreshFuture = future;
    return future;
  }

  Future<PlanEntitlementRefreshResult> _performServerPlanRefresh(
    int generation,
  ) async {
    final result = await _authSession.refreshServerPlan();
    if (generation == _authSession.sessionGeneration && _authSession.isPaid) {
      await resumePendingMigration();
    }
    return result;
  }

  Future<PlanChangeResult> changePlan(UserPlan nextPlan) async {
    if (!_authSession.isMember) {
      throw StateError('로그인한 회원만 플랜을 변경할 수 있습니다.');
    }
    if (nextPlan == UserPlan.guest) {
      throw ArgumentError.value(nextPlan, 'nextPlan', '회원 플랜만 선택할 수 있습니다.');
    }
    final session = _captureSession();
    if (_authSession.plan == nextPlan && !_authSession.isPlanMigrationPending) {
      return PlanChangeResult.unchanged;
    }
    if (nextPlan == UserPlan.free) {
      if (_outboxRepository.hasUnfinishedItemsForOwner(session.ownerKey)) {
        return PlanChangeResult.blockedByPendingUploads;
      }
      await _authSession.changeMemberPlan(
        UserPlan.free,
        expectedSessionGeneration: session.generation,
      );
      if (!_isCurrent(session) || !_authSession.isFree) {
        return PlanChangeResult.unchanged;
      }
      await AppDatabase.instance
          .transaction((transaction) async {
            if (!_isCurrent(session)) throw const _MigrationCancelled();
            await _store.deleteOutboxItems(
              transaction,
              ownerKey: session.ownerKey,
              where: 'status = ?',
              whereArgs: <Object?>[OutboxStatus.succeeded.name],
            );
            if (!_isCurrent(session)) throw const _MigrationCancelled();
          })
          .onError<_MigrationCancelled>((_, _) {});
      await _outboxRepository.reloadOwner(session.ownerKey);
      return PlanChangeResult.changed;
    }

    // Even an empty local record list can contain durable deletion intent.
    await _authSession.changeMemberPlan(
      UserPlan.paid,
      migrationStatus: PlanMigrationStatus.localToCloudPending,
      expectedSessionGeneration: session.generation,
    );
    if (!_isCurrent(session)) return PlanChangeResult.unchanged;
    await resumePendingMigration();
    return PlanChangeResult.changed;
  }

  Future<void> resumePendingMigration() {
    if (!_authSession.isPaid || !_authSession.canUseOutbox) {
      return Future.value();
    }
    final session = _captureSession();
    final inProgress = _migrationFutures[session.generation];
    if (inProgress != null) return inProgress;
    late final Future<void> future;
    future = _performMigration(session).whenComplete(() {
      if (identical(_migrationFutures[session.generation], future)) {
        _migrationFutures.remove(session.generation);
      }
    });
    _migrationFutures[session.generation] = future;
    return future;
  }

  Future<void> _performMigration(_MigrationSession session) async {
    try {
      await _queueMissingMigrationItems(session);
      if (_isCurrent(session)) await completeMigrationIfPossible();
    } on _MigrationCancelled {
      // The SQLite transaction rolls back all work from the old session.
    }
  }

  Future<void> completeMigrationIfPossible() async {
    if (!_authSession.isPlanMigrationPending || !_authSession.canUseOutbox) {
      return;
    }
    final session = _captureSession();
    var complete = false;
    await AppDatabase.instance
        .transaction((transaction) async {
          _ensurePaidSession(session);
          final changes = await _store.readLocalRecordChangesForOwner(
            session.ownerKey,
            executor: transaction,
          );
          final records = await _store.readRecordsForOwner(
            session.ownerKey,
            executor: transaction,
          );
          final items = await _store.readOutboxItemsForOwner(
            session.ownerKey,
            executor: transaction,
          );
          final latestByRecord = <String, OutboxItem>{
            for (final item in items) item.recordId: item,
          };
          complete =
              changes.isEmpty &&
              items.every((item) => item.status == OutboxStatus.succeeded) &&
              records.every((record) {
                final latest = latestByRecord[record.id];
                return latest != null &&
                    latest.operationType != OutboxOperationType.delete &&
                    jsonEncode(latest.payload) == jsonEncode(record.toJson());
              });
          _ensurePaidSession(session);
        })
        .onError<_MigrationCancelled>((_, _) {});
    if (!complete || !_isCurrent(session) || !_authSession.canUseOutbox) return;
    await _authSession.changeMemberPlan(
      UserPlan.paid,
      migrationStatus: PlanMigrationStatus.none,
      expectedSessionGeneration: session.generation,
    );
  }

  Future<void> _queueMissingMigrationItems(_MigrationSession session) async {
    await AppDatabase.instance.transaction((transaction) async {
      _ensurePaidSession(session);
      final changes = await _store.readLocalRecordChangesForOwner(
        session.ownerKey,
        executor: transaction,
      );
      if (!_authSession.isPlanMigrationPending && changes.isEmpty) return;
      final records = await _store.readRecordsForOwner(
        session.ownerKey,
        executor: transaction,
      );
      final items = await _store.readOutboxItemsForOwner(
        session.ownerKey,
        executor: transaction,
      );
      final byRecord = <String, List<OutboxItem>>{};
      for (final item in items) {
        byRecord.putIfAbsent(item.recordId, () => []).add(item);
      }
      final existingIds = records.map((record) => record.id).toSet();
      for (final record in records) {
        _ensurePaidSession(session);
        final history = byRecord[record.id] ?? const <OutboxItem>[];
        final latest = history.isEmpty ? null : history.last;
        final payload = record.toJson();
        if (latest == null ||
            latest.operationType == OutboxOperationType.delete ||
            jsonEncode(latest.payload) != jsonEncode(payload)) {
          await _appendIntent(
            transaction,
            session: session,
            recordId: record.id,
            payload: payload,
            history: history,
            deleted: false,
          );
        }
        await _store.deleteLocalRecordChange(
          transaction,
          ownerKey: session.ownerKey,
          recordId: record.id,
        );
      }
      for (final change in changes) {
        _ensurePaidSession(session);
        if (existingIds.contains(change.recordId)) continue;
        final history = byRecord[change.recordId] ?? const <OutboxItem>[];
        if (change.operationType == OutboxOperationType.delete) {
          final latest = history.isEmpty ? null : history.last;
          final metadata = await _store.readRecordSyncMetadata(
            session.ownerKey,
            change.recordId,
            executor: transaction,
          );
          if (latest?.operationType != OutboxOperationType.delete &&
              (history.isNotEmpty || (metadata?.serverVersionNo ?? 0) > 0)) {
            await _appendIntent(
              transaction,
              session: session,
              recordId: change.recordId,
              payload: change.payload,
              history: history,
              deleted: true,
            );
          }
        }
        await _store.deleteLocalRecordChange(
          transaction,
          ownerKey: session.ownerKey,
          recordId: change.recordId,
        );
      }
      _ensurePaidSession(session);
    });
    await _outboxRepository.reloadOwner(session.ownerKey);
  }

  Future<void> _appendIntent(
    DatabaseExecutor transaction, {
    required _MigrationSession session,
    required String recordId,
    required Map<String, dynamic> payload,
    required List<OutboxItem> history,
    required bool deleted,
  }) async {
    _ensurePaidSession(session);
    final metadata = await _store.readRecordSyncMetadata(
      session.ownerKey,
      recordId,
      executor: transaction,
    );
    var nextBase = metadata?.optimisticVersionNo ?? 0;
    for (final item in history) {
      final base = item.baseVersionNo;
      if (base != null && base + 1 > nextBase) nextBase = base + 1;
    }
    if (nextBase > (metadata?.optimisticVersionNo ?? 0)) {
      await _store.writeRecordSyncMetadata(
        transaction,
        ownerKey: session.ownerKey,
        metadata: RecordSyncMetadata(
          recordId: recordId,
          serverVersionNo: metadata?.serverVersionNo ?? 0,
          optimisticVersionNo: nextBase,
          remoteStatus: metadata?.remoteStatus ?? RemoteRecordStatus.missing,
        ),
      );
    }
    final reservedBase = await _store.reserveNextRecordVersion(
      transaction,
      ownerKey: session.ownerKey,
      recordId: recordId,
    );
    // Legacy requests obtain their actual versions when their receipts return.
    // The sync service assigns those versions to following legacy requests.
    final hasLegacyPredecessor = history.any(
      (item) => item.baseVersionNo == null,
    );
    final now = DateTime.now();
    _ensurePaidSession(session);
    await _store.insertOutboxItem(
      transaction,
      ownerKey: session.ownerKey,
      item: OutboxItem(
        id: 'migration-${now.microsecondsSinceEpoch}-$recordId',
        userId: session.uid,
        recordId: recordId,
        operationType: deleted
            ? OutboxOperationType.delete
            : history.isNotEmpty || (metadata?.serverVersionNo ?? 0) > 0
            ? OutboxOperationType.update
            : OutboxOperationType.create,
        status: OutboxStatus.pending,
        createdAt: now,
        isMigration: true,
        baseVersionNo: hasLegacyPredecessor ? null : reservedBase,
        payload: payload,
      ),
    );
    _ensurePaidSession(session);
  }

  _MigrationSession _captureSession() => _MigrationSession(
    _authSession.sessionGeneration,
    _authSession.dataOwnerKey,
    _authSession.memberId!,
  );

  bool _isCurrent(_MigrationSession session) =>
      session.generation == _authSession.sessionGeneration &&
      session.ownerKey == _authSession.dataOwnerKey &&
      session.uid == _authSession.memberId;

  void _ensurePaidSession(_MigrationSession session) {
    if (!_isCurrent(session) ||
        !_authSession.isPaid ||
        !_authSession.canUseOutbox) {
      throw const _MigrationCancelled();
    }
  }
}

class _MigrationSession {
  final int generation;
  final String ownerKey;
  final String uid;
  const _MigrationSession(this.generation, this.ownerKey, this.uid);
}

class _MigrationCancelled implements Exception {
  const _MigrationCancelled();
}
