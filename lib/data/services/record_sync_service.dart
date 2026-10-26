import 'dart:async';

import 'package:flutter/foundation.dart';

import '../local/app_database.dart';
import '../local/local_data_store.dart';
import '../models/conflict_item.dart';
import '../models/fishing_record.dart';
import '../models/outbox_item.dart';
import '../models/record_sync_metadata.dart';
import '../remote/record_sync_gateway.dart';
import '../repositories/auth_session_repository.dart';
import '../repositories/conflict_repository.dart';
import '../repositories/fishing_record_repository.dart';
import '../repositories/outbox_repository.dart';
import 'network_status_service.dart';
import 'plan_policy_service.dart';
import 'record_refresh_watcher.dart';

enum RecordSyncState { idle, syncing, succeeded, failed }

enum RecordSyncSkipReason {
  none,
  gatewayUnavailable,
  signedOut,
  paidPlanRequired,
  offline,
  sessionChanged,
}

class RecordSyncResult {
  final int pushedCount;
  final int pulledCount;
  final int failedCount;
  final RecordSyncSkipReason skipReason;
  final String? errorMessage;

  const RecordSyncResult({
    this.pushedCount = 0,
    this.pulledCount = 0,
    this.failedCount = 0,
    this.skipReason = RecordSyncSkipReason.none,
    this.errorMessage,
  });

  bool get wasSkipped => skipReason != RecordSyncSkipReason.none;
  bool get isSuccess => !wasSkipped && failedCount == 0 && errorMessage == null;
}

/// Coordinates the local SQLite outbox with the member's Firestore records.
///
/// The service is single-flight: all callers share one in-progress sync. It
/// pushes the durable outbox in insertion order and only replaces the local
/// cache after every mutation has reached the server.
class RecordSyncService extends ChangeNotifier {
  RecordSyncService({
    AuthSessionRepository? authSession,
    FishingRecordRepository? recordRepository,
    OutboxRepository? outboxRepository,
    ConflictRepository? conflictRepository,
    NetworkStatusService? networkStatusService,
    LocalDataStore? localDataStore,
    DateTime Function()? now,
  }) : _authSession = authSession ?? AuthSessionRepository.instance,
       _recordRepository = recordRepository ?? FishingRecordRepository.instance,
       _outboxRepository = outboxRepository ?? OutboxRepository.instance,
       _conflictRepository = conflictRepository ?? ConflictRepository.instance,
       _networkStatusService =
           networkStatusService ?? NetworkStatusService.instance,
       _localDataStore = localDataStore ?? LocalDataStore.instance,
       _now = now ?? DateTime.now;

  static final RecordSyncService instance = RecordSyncService();

  static const String _syncMarkerPrefix = 'firestore_record_sync_v2';

  final AuthSessionRepository _authSession;
  final FishingRecordRepository _recordRepository;
  final OutboxRepository _outboxRepository;
  final ConflictRepository _conflictRepository;
  final NetworkStatusService _networkStatusService;
  final LocalDataStore _localDataStore;
  final DateTime Function() _now;

  RecordSyncGateway? _gateway;
  Future<RecordSyncResult>? _syncFuture;
  RecordSyncState _state = RecordSyncState.idle;
  RecordSyncResult? _lastResult;
  DateTime? _lastSyncedAt;
  String? _lastError;
  bool _isInitialized = false;
  bool _wasConnected = false;
  bool _rerunRequested = false;
  bool _forceFullRequested = false;
  String? _statusOwnerKey;
  int _followUpGeneration = 0;
  late final _recordRefreshWatcher = RecordRefreshWatcher(
    authSession: _authSession,
    store: _localDataStore,
    gateway: () => _gateway,
    refresh: () async {
      await syncNow(scheduleFollowUpIfBusy: true);
    },
  );

  VoidCallback observeRecord(String recordId) =>
      _recordRefreshWatcher.observe(recordId);

  bool get _statusBelongsToCurrentOwner =>
      _statusOwnerKey == _authSession.dataOwnerKey;
  RecordSyncState get state =>
      _statusBelongsToCurrentOwner ? _state : RecordSyncState.idle;
  RecordSyncResult? get lastResult =>
      _statusBelongsToCurrentOwner ? _lastResult : null;
  DateTime? get lastSyncedAt =>
      _statusBelongsToCurrentOwner ? _lastSyncedAt : null;
  String? get lastError => _statusBelongsToCurrentOwner ? _lastError : null;
  bool get isSyncing =>
      _statusBelongsToCurrentOwner && _state == RecordSyncState.syncing;
  bool get hasGateway => _gateway != null;

  void configureGateway(RecordSyncGateway? gateway) {
    if (identical(_gateway, gateway)) {
      return;
    }
    _gateway = gateway;
    _recordRefreshWatcher.synchronize();
    notifyListeners();
  }

  Future<RemoteRecordRevision?> fetchLatestRevision(String recordId) async {
    final gateway = _gateway;
    final uid = _authSession.memberId;
    final ownerKey = _authSession.dataOwnerKey;
    if (gateway == null) {
      throw StateError('Firebase가 연결된 빌드에서 충돌을 해결할 수 있습니다.');
    }
    if (!_authSession.isPaid || uid == null) {
      throw StateError('유료 회원으로 로그인한 뒤 충돌을 해결할 수 있습니다.');
    }
    if (_networkStatusService.isDisconnected) {
      throw StateError('인터넷에 연결한 뒤 상대 변경을 적용할 수 있습니다.');
    }
    final revision = await gateway.fetchRecordRevision(
      uid: uid,
      recordId: recordId,
    );
    if (!_isCurrentSession(uid, ownerKey)) {
      throw StateError('계정이 변경되어 충돌 해결을 중단했습니다.');
    }
    return revision;
  }

  void initialize() {
    if (_isInitialized) {
      return;
    }
    _isInitialized = true;
    _wasConnected = _networkStatusService.isConnected;
    _networkStatusService.addListener(_handleNetworkStatusChange);
  }

  void _handleNetworkStatusChange() {
    final connected = _networkStatusService.isConnected;
    final restored = connected && !_wasConnected;
    _wasConnected = connected;
    if (restored) {
      unawaited(_refreshPlanThenSync());
    }
  }

  Future<void> _refreshPlanThenSync() async {
    if (_authSession.isMember && _authSession.canRefreshServerPlan) {
      await PlanPolicyService.instance.refreshServerPlan();
    }
    await syncNow(scheduleFollowUpIfBusy: true);
  }

  Future<RecordSyncResult> syncNow({
    bool scheduleFollowUpIfBusy = false,
    bool forceFullRefresh = false,
  }) {
    if (forceFullRefresh) _forceFullRequested = true;
    final inProgress = _syncFuture;
    if (inProgress != null) {
      if (scheduleFollowUpIfBusy || forceFullRefresh) {
        _rerunRequested = true;
        _followUpGeneration += 1;
      }
      return inProgress;
    }

    late final Future<RecordSyncResult> future;
    future = _performSync().whenComplete(() {
      if (identical(_syncFuture, future)) {
        _syncFuture = null;
        if (_rerunRequested) {
          _rerunRequested = false;
          unawaited(syncNow());
        }
      }
    });
    _syncFuture = future;
    return future;
  }

  Future<RecordSyncResult> _performSync() async {
    final gateway = _gateway;
    if (gateway == null) {
      return _skip(RecordSyncSkipReason.gatewayUnavailable);
    }
    if (!_authSession.isMember || _authSession.memberId == null) {
      return _skip(RecordSyncSkipReason.signedOut);
    }
    if (!_authSession.isPaid || !_authSession.canUseOutbox) {
      return _skip(RecordSyncSkipReason.paidPlanRequired);
    }
    if (_networkStatusService.isDisconnected) {
      return _skip(RecordSyncSkipReason.offline);
    }

    final uid = _authSession.memberId!;
    final ownerKey = _authSession.dataOwnerKey;
    final generation = _authSession.sessionGeneration;
    bool sessionIsCurrent() =>
        _isCurrentSession(uid, ownerKey) &&
        generation == _authSession.sessionGeneration &&
        identical(gateway, _gateway);
    _statusOwnerKey = ownerKey;
    _state = RecordSyncState.syncing;
    _lastError = null;
    notifyListeners();

    var pushedCount = 0;
    try {
      // Preserve local free-plan edits/deletions before any old request is
      // retried or an authoritative server snapshot can replace the cache.
      await PlanPolicyService.instance.resumePendingMigration();
      if (!sessionIsCurrent()) {
        return _skip(RecordSyncSkipReason.sessionChanged);
      }
      final firstRealSync = !await _hasCompletedFirstSync(uid);
      if (firstRealSync) {
        final serverBeforePush = await gateway.fetchSnapshot(uid: uid);
        if (!sessionIsCurrent()) {
          return _skip(RecordSyncSkipReason.sessionChanged);
        }
        await _prepareFirstRealSync(
          uid: uid,
          ownerKey: ownerKey,
          serverSnapshot: serverBeforePush,
        );
        if (!sessionIsCurrent()) {
          return _skip(RecordSyncSkipReason.sessionChanged);
        }
      }

      while (true) {
        while (true) {
          final queuedItem = _firstUnfinishedItem(ownerKey);
          if (queuedItem == null) {
            break;
          }
          if (!sessionIsCurrent()) {
            return _skip(RecordSyncSkipReason.sessionChanged);
          }

          if (queuedItem.status == OutboxStatus.conflicted) {
            return _fail(
              pushedCount: pushedCount,
              failedCount: 1,
              message: '해결이 필요한 동기화 충돌이 있습니다.',
            );
          }
          if (queuedItem.status == OutboxStatus.failed) {
            await _outboxRepository.retryItemForOwner(
              ownerKey: ownerKey,
              itemId: queuedItem.id,
            );
          }
          await _outboxRepository.updateItemStatusForOwner(
            ownerKey: ownerKey,
            itemId: queuedItem.id,
            status: OutboxStatus.sending,
          );
          notifyListeners();

          if (!sessionIsCurrent()) {
            return _skip(RecordSyncSkipReason.sessionChanged);
          }

          late final RecordPushResult pushResult;
          try {
            pushResult = await gateway.pushOutboxItem(
              uid: uid,
              item: queuedItem,
            );
          } on RecordVersionConflictException catch (error) {
            if (sessionIsCurrent()) {
              await _recordConflict(
                ownerKey: ownerKey,
                blockingItem: queuedItem,
                error: error,
              );
            }
            return _fail(
              pushedCount: pushedCount,
              failedCount: 1,
              message: error.message,
            );
          } on Object catch (error) {
            if (error is RecordSyncGatewayException &&
                error.code == 'idempotency-conflict') {
              if (!sessionIsCurrent()) {
                return _skip(RecordSyncSkipReason.sessionChanged);
              }
              // Older builds could replace the body of a committed request.
              // Its original body cannot be recovered from a fingerprint.
              // Preserve current local intent and let the user resolve it
              // against the latest server revision using a fresh request ID.
              final remote = await gateway.fetchRecordRevision(
                uid: uid,
                recordId: queuedItem.recordId,
              );
              if (!sessionIsCurrent()) {
                return _skip(RecordSyncSkipReason.sessionChanged);
              }
              await _recordConflict(
                ownerKey: ownerKey,
                blockingItem: queuedItem,
                error: RecordVersionConflictException(
                  recordId: queuedItem.recordId,
                  baseVersionNo: queuedItem.baseVersionNo,
                  remoteVersionNo: remote?.versionNo ?? 0,
                  remoteStatus: remote?.status ?? RemoteRecordStatus.missing,
                  remoteRecord: remote?.record,
                ),
              );
              return _fail(
                pushedCount: pushedCount,
                failedCount: 1,
                message: '이전 전송 요청과 서버 처리 이력이 달라 충돌 확인이 필요합니다.',
              );
            }
            final message = _messageFor(error);
            if (sessionIsCurrent()) {
              await _outboxRepository.updateItemStatusForOwner(
                ownerKey: ownerKey,
                itemId: queuedItem.id,
                status: OutboxStatus.failed,
                errorMessage: message,
              );
            }
            return _fail(
              pushedCount: pushedCount,
              failedCount: 1,
              message: message,
            );
          }

          if (!sessionIsCurrent()) {
            return _skip(RecordSyncSkipReason.sessionChanged);
          }
          await _completeSuccessfulPush(
            ownerKey: ownerKey,
            item: queuedItem,
            result: pushResult,
            isCurrentSession: sessionIsCurrent,
          );
          pushedCount += 1;
          notifyListeners();
        }

        if (!sessionIsCurrent()) {
          return _skip(RecordSyncSkipReason.sessionChanged);
        }
        await PlanPolicyService.instance.completeMigrationIfPossible();
        if (!sessionIsCurrent()) {
          return _skip(RecordSyncSkipReason.sessionChanged);
        }
        if (_outboxRepository.hasUnfinishedItemsForOwner(ownerKey)) {
          continue;
        }
        if (!_authSession.canUseCloudSync) {
          return _fail(
            pushedCount: pushedCount,
            failedCount: 1,
            message: '기존 기록의 클라우드 이전을 완료하지 못했습니다.',
          );
        }

        final pullGeneration = _followUpGeneration;
        final pull = await _pullRemote(
          gateway: gateway,
          uid: uid,
          ownerKey: ownerKey,
          isCurrent: () =>
              sessionIsCurrent() && pullGeneration == _followUpGeneration,
        );
        if (!sessionIsCurrent()) {
          return _skip(RecordSyncSkipReason.sessionChanged);
        }
        if (!pull.applied) {
          if (pullGeneration != _followUpGeneration ||
              _outboxRepository.hasUnfinishedItemsForOwner(ownerKey)) {
            continue;
          }
          return _fail(
            pushedCount: pushedCount,
            failedCount: 1,
            message: '보호 중인 로컬 변경이나 충돌이 있습니다. 대기열과 충돌 상태를 확인해 주세요.',
          );
        }
        if (pullGeneration != _followUpGeneration) continue;
        if (firstRealSync) {
          await _markFirstSyncCompleted(uid);
          if (!sessionIsCurrent()) {
            return _skip(RecordSyncSkipReason.sessionChanged);
          }
        }
        if (_outboxRepository.hasUnfinishedItemsForOwner(ownerKey)) {
          continue;
        }

        if (pullGeneration != _followUpGeneration) continue;
        _rerunRequested = false;
        final result = RecordSyncResult(
          pushedCount: pushedCount,
          pulledCount: pull.changedCount,
        );
        _state = RecordSyncState.succeeded;
        _lastResult = result;
        _lastSyncedAt = _now();
        _lastError = null;
        notifyListeners();
        return result;
      }
    } on Object catch (error) {
      if (!sessionIsCurrent()) {
        return _skip(RecordSyncSkipReason.sessionChanged);
      }
      return _fail(
        pushedCount: pushedCount,
        failedCount: 1,
        message: _messageFor(error),
      );
    }
  }

  Future<({bool applied, int changedCount})> _pullRemote({
    required RecordSyncGateway gateway,
    required String uid,
    required String ownerKey,
    required bool Function() isCurrent,
  }) async {
    final incremental = gateway is IncrementalRecordSyncGateway
        ? gateway as IncrementalRecordSyncGateway
        : null;
    var checkpoint = incremental == null
        ? null
        : await _recordRepository.readSyncCheckpoint(ownerKey);
    if (!isCurrent()) return (applied: false, changedCount: 0);
    final now = _now().toUtc();
    final needsFull =
        incremental == null ||
        checkpoint == null ||
        _forceFullRequested ||
        now.isBefore(checkpoint.lastFullSyncAt) ||
        now.difference(checkpoint.lastFullSyncAt) >= const Duration(hours: 24);
    RecordSyncCursor? upper;
    if (!needsFull) {
      upper = await incremental.fetchLatestCursor(uid: uid);
      if (!isCurrent()) return (applied: false, changedCount: 0);
    }
    if (needsFull || upper!.compareTo(checkpoint.cursor) < 0) {
      final snapshot = await gateway.fetchSnapshot(uid: uid);
      if (!isCurrent()) return (applied: false, changedCount: 0);
      if (incremental != null && snapshot.cursor == null) {
        throw const RecordSyncGatewayException(
          code: 'invalid-checkpoint',
          message: '서버 기록의 동기화 기준을 확인하지 못했습니다.',
        );
      }
      final applied = await _recordRepository.replaceWithRemoteSnapshot(
        snapshot,
        ownerKey: ownerKey,
        isCurrentSession: isCurrent,
        checkpoint: incremental == null
            ? null
            : RecordSyncCheckpoint(
                cursor: snapshot.cursor!,
                lastFullSyncAt: now,
              ),
      );
      if (applied && isCurrent()) _forceFullRequested = false;
      return (applied: applied, changedCount: snapshot.activeRecords.length);
    }

    var activeCheckpoint = checkpoint;
    final through = upper;
    final since = activeCheckpoint.cursor;
    RecordSyncCursor? after;
    var changedCount = 0;
    while (true) {
      if (!isCurrent() ||
          _outboxRepository.hasUnfinishedItemsForOwner(ownerKey)) {
        return (applied: false, changedCount: changedCount);
      }
      final page = await incremental.fetchChanges(
        uid: uid,
        since: since,
        through: through,
        after: after,
      );
      if (!isCurrent()) return (applied: false, changedCount: changedCount);
      var previous = after;
      final seenIds = <String>{};
      for (final revision in page.revisions) {
        final cursor = revision.cursor;
        final lower = RecordSyncCursor(
          seconds: since.seconds,
          nanoseconds: since.nanoseconds,
          recordId: '',
        );
        if (cursor == null ||
            cursor.recordId != revision.recordId ||
            cursor.compareTo(lower) < 0 ||
            cursor.compareTo(through) > 0 ||
            (previous != null && cursor.compareTo(previous) <= 0) ||
            !seenIds.add(revision.recordId)) {
          throw const RecordSyncGatewayException(
            code: 'invalid-change-page',
            message: '서버 기록의 변경 순서를 확인하지 못했습니다.',
          );
        }
        previous = cursor;
      }
      if (page.hasMore && page.revisions.isEmpty) {
        throw const RecordSyncGatewayException(
          code: 'invalid-change-page',
          message: '서버 기록을 이어서 불러오지 못했습니다.',
        );
      }
      final next =
          previous != null && previous.compareTo(activeCheckpoint.cursor) > 0
          ? previous
          : activeCheckpoint.cursor;
      final nextCheckpoint = RecordSyncCheckpoint(
        cursor: next,
        lastFullSyncAt: activeCheckpoint.lastFullSyncAt,
      );
      final applied = await _recordRepository.applyRemotePage(
        ownerKey: ownerKey,
        revisions: page.revisions,
        checkpoint: nextCheckpoint,
        isCurrentSession: isCurrent,
      );
      if (!applied.applied) return (applied: false, changedCount: changedCount);
      changedCount += applied.changedCount;
      activeCheckpoint = nextCheckpoint;
      if (!page.hasMore) {
        return (applied: true, changedCount: changedCount);
      }
      after = previous;
    }
  }

  Future<void> _completeSuccessfulPush({
    required String ownerKey,
    required OutboxItem item,
    required RecordPushResult result,
    required bool Function() isCurrentSession,
  }) async {
    final pendingItems = _outboxRepository.getUnfinishedItemsForRecord(
      ownerKey: ownerKey,
      recordId: item.recordId,
    );
    var optimisticVersionNo = result.versionNo;
    final laterLegacyItems = <OutboxItem>[];
    final itemIndex = pendingItems.indexWhere(
      (candidate) => candidate.id == item.id,
    );
    if (itemIndex >= 0) {
      var nextBaseVersion = result.versionNo;
      for (final candidate in pendingItems.skip(itemIndex + 1)) {
        if (candidate.baseVersionNo == null) {
          laterLegacyItems.add(
            candidate.copyWith(baseVersionNo: nextBaseVersion),
          );
          nextBaseVersion += 1;
        } else if (candidate.baseVersionNo! >= nextBaseVersion) {
          nextBaseVersion = candidate.baseVersionNo! + 1;
        }
      }
      optimisticVersionNo = nextBaseVersion;
    }

    final committed = await AppDatabase.instance.transaction((
      transaction,
    ) async {
      if (!isCurrentSession()) throw StateError('Sync session changed.');
      final count = await transaction.update(
        AppDatabase.outboxItemsTable,
        {
          'status': OutboxStatus.succeeded.name,
          'last_tried_at': _now().toIso8601String(),
          'error_message': null,
        },
        where: 'owner_key = ? AND outbox_id = ?',
        whereArgs: <Object?>[ownerKey, item.id],
      );
      if (count == 0) throw StateError('Completed request no longer exists.');
      final changedItems = <OutboxItem>[];
      changedItems.add(
        (await _localDataStore.readOutboxItemForOwner(
          ownerKey,
          item.id,
          executor: transaction,
        ))!,
      );
      for (final legacyItem in laterLegacyItems) {
        await transaction.update(
          AppDatabase.outboxItemsTable,
          {'base_version_no': legacyItem.baseVersionNo},
          where: 'owner_key = ? AND outbox_id = ? AND base_version_no IS NULL',
          whereArgs: <Object?>[ownerKey, legacyItem.id],
        );
        final changed = await _localDataStore.readOutboxItemForOwner(
          ownerKey,
          legacyItem.id,
          executor: transaction,
        );
        if (changed != null) changedItems.add(changed);
      }
      await _localDataStore.writeRecordSyncMetadata(
        transaction,
        ownerKey: ownerKey,
        metadata: RecordSyncMetadata(
          recordId: item.recordId,
          serverVersionNo: result.versionNo,
          optimisticVersionNo: optimisticVersionNo,
          remoteStatus: result.status,
        ),
      );
      final changedConflicts = await _localDataStore
          .completeResolvingConflictForOutbox(
            transaction,
            ownerKey: ownerKey,
            outboxId: item.id,
            resolvedAt: _now(),
          );
      if (!isCurrentSession()) throw StateError('Sync session changed.');
      return (items: changedItems, conflictsChanged: changedConflicts > 0);
    });
    _outboxRepository.publishCommittedItems(
      ownerKey: ownerKey,
      items: committed.items,
    );
    if (committed.conflictsChanged) {
      await _conflictRepository.reloadOwner(ownerKey);
    }
  }

  Future<void> _recordConflict({
    required String ownerKey,
    required OutboxItem blockingItem,
    required RecordVersionConflictException error,
  }) async {
    final localIntent = _latestUnfinishedItemForRecord(
      ownerKey,
      blockingItem.recordId,
    );
    FishingRecord? localRecord;
    final payload = localIntent.payload;
    if (payload != null) {
      try {
        localRecord = FishingRecord.fromJson(payload);
      } on Object {
        localRecord = null;
      }
    }
    if (localIntent.operationType != OutboxOperationType.delete) {
      localRecord =
          _recordRepository.getRecordById(localIntent.recordId) ?? localRecord;
    }

    final now = _now();
    final conflict = ConflictItem(
      id: 'conflict-${now.microsecondsSinceEpoch}-${blockingItem.recordId}',
      ownerKey: ownerKey,
      recordId: blockingItem.recordId,
      outboxId: blockingItem.id,
      localOperationType: localIntent.operationType,
      baseVersionNo: error.baseVersionNo,
      remoteVersionNo: error.remoteVersionNo,
      remoteStatus: error.remoteStatus,
      localRecord: localRecord,
      remoteRecord: error.remoteRecord,
      occurredAt: now,
      status: ConflictStatus.unresolved,
    );
    await _conflictRepository.recordDetectedConflict(conflict);
    await _outboxRepository.reloadOwner(ownerKey);
  }

  OutboxItem _latestUnfinishedItemForRecord(String ownerKey, String recordId) {
    final matches = _outboxRepository.getUnfinishedItemsForRecord(
      ownerKey: ownerKey,
      recordId: recordId,
    );
    return matches.isEmpty ? _firstUnfinishedItem(ownerKey)! : matches.last;
  }

  Future<void> _prepareFirstRealSync({
    required String uid,
    required String ownerKey,
    required RemoteRecordSnapshot serverSnapshot,
  }) async {
    // Older builds exposed mock success buttons. Replaying their succeeded
    // items is safe because the server receipt makes a real prior commit
    // idempotent, while a mock-only success has no receipt and is uploaded now.
    final existingItems = List<OutboxItem>.of(
      _outboxRepository.getAllItemsForOwner(ownerKey),
    );
    final localRecords = List.of(
      _recordRepository.getAllRecordsForOwner(ownerKey),
    );
    final recordIdsWithHistory = existingItems
        .map((item) => item.recordId)
        .toSet();
    final bootstrapItems = <OutboxItem>[];
    var sequence = 0;
    for (final record in localRecords) {
      if (recordIdsWithHistory.contains(record.id) ||
          serverSnapshot.knownRecordIds.contains(record.id)) {
        continue;
      }

      final now = _now();
      bootstrapItems.add(
        OutboxItem(
          id: 'bootstrap-${now.microsecondsSinceEpoch}-${sequence++}-${record.id}',
          userId: uid,
          recordId: record.id,
          operationType: OutboxOperationType.create,
          status: OutboxStatus.pending,
          createdAt: now,
          isMigration: true,
          baseVersionNo: 0,
          payload: record.toJson(),
        ),
      );
    }

    // Use the captured owner key for the whole transaction. A logout/account
    // switch during this await can stop the sync, but can never move one
    // account's replay/bootstrap items into another account's SQLite partition.
    await AppDatabase.instance.transaction((transaction) async {
      for (final revision in serverSnapshot.revisions) {
        await _localDataStore.writeRecordSyncMetadata(
          transaction,
          ownerKey: ownerKey,
          metadata: RecordSyncMetadata(
            recordId: revision.recordId,
            serverVersionNo: revision.versionNo,
            optimisticVersionNo: revision.versionNo,
            remoteStatus: revision.status,
          ),
        );
      }
      for (final item in existingItems) {
        if (item.status != OutboxStatus.succeeded) {
          continue;
        }
        await _localDataStore.insertOutboxItem(
          transaction,
          ownerKey: ownerKey,
          item: item.copyWith(
            status: OutboxStatus.pending,
            clearErrorMessage: true,
          ),
          replace: true,
        );
      }
      for (final item in bootstrapItems) {
        await _localDataStore.writeRecordSyncMetadata(
          transaction,
          ownerKey: ownerKey,
          metadata: RecordSyncMetadata(
            recordId: item.recordId,
            serverVersionNo: 0,
            optimisticVersionNo: 1,
            remoteStatus: RemoteRecordStatus.missing,
          ),
          resetOptimisticVersion: true,
        );
        await _localDataStore.insertOutboxItem(
          transaction,
          ownerKey: ownerKey,
          item: item,
        );
      }
    });
    await _outboxRepository.reloadOwner(ownerKey);
    notifyListeners();
  }

  bool _isCurrentSession(String uid, String ownerKey) {
    return _authSession.isPaid &&
        !_authSession.isDeletingAccount &&
        !_authSession.hasPendingAccountDeletion &&
        _authSession.memberId == uid &&
        _authSession.dataOwnerKey == ownerKey;
  }

  OutboxItem? _firstUnfinishedItem(String ownerKey) =>
      _outboxRepository.firstUnfinishedItemForOwner(ownerKey);

  String _syncMarkerKey(String uid) => '$_syncMarkerPrefix:$uid';

  Future<bool> _hasCompletedFirstSync(String uid) async {
    final database = await AppDatabase.instance.database;
    return await _localDataStore.readMetadata(database, _syncMarkerKey(uid)) ==
        AppDatabase.migrationCompletedValue;
  }

  Future<void> _markFirstSyncCompleted(String uid) async {
    await AppDatabase.instance.transaction((transaction) {
      return _localDataStore.writeMetadata(
        transaction,
        key: _syncMarkerKey(uid),
        value: AppDatabase.migrationCompletedValue,
      );
    });
  }

  RecordSyncResult _skip(RecordSyncSkipReason reason) {
    final result = RecordSyncResult(skipReason: reason);
    _statusOwnerKey = _authSession.dataOwnerKey;
    _state = RecordSyncState.idle;
    _lastResult = result;
    _lastError = null;
    notifyListeners();
    return result;
  }

  RecordSyncResult _fail({
    required int pushedCount,
    required int failedCount,
    required String message,
  }) {
    final result = RecordSyncResult(
      pushedCount: pushedCount,
      failedCount: failedCount,
      errorMessage: message,
    );
    _state = RecordSyncState.failed;
    _lastResult = result;
    _lastError = message;
    notifyListeners();
    return result;
  }

  String _messageFor(Object error) {
    if (error is RecordSyncGatewayException) {
      return error.message;
    }
    return '기록을 동기화하지 못했습니다. 잠시 후 다시 시도해 주세요.';
  }

  @visibleForTesting
  Future<void> resetForTesting() async {
    _recordRefreshWatcher.clear();
    final running = _syncFuture;
    if (running != null) {
      await running;
    }
    if (_isInitialized) {
      _networkStatusService.removeListener(_handleNetworkStatusChange);
    }
    _gateway = null;
    _syncFuture = null;
    _state = RecordSyncState.idle;
    _lastResult = null;
    _lastSyncedAt = null;
    _lastError = null;
    _isInitialized = false;
    _wasConnected = false;
    _rerunRequested = false;
    _forceFullRequested = false;
    _statusOwnerKey = null;
    _followUpGeneration = 0;
  }

  @override
  void dispose() {
    _recordRefreshWatcher.clear();
    if (_isInitialized) {
      _networkStatusService.removeListener(_handleNetworkStatusChange);
    }
    super.dispose();
  }
}
