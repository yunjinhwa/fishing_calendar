import 'dart:async';

import 'package:flutter/foundation.dart';

import '../local/app_database.dart';
import '../local/local_data_store.dart';
import '../models/outbox_item.dart';
import '../remote/record_sync_gateway.dart';
import '../repositories/auth_session_repository.dart';
import '../repositories/fishing_record_repository.dart';
import '../repositories/outbox_repository.dart';
import 'network_status_service.dart';
import 'plan_policy_service.dart';

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
    NetworkStatusService? networkStatusService,
    LocalDataStore? localDataStore,
    DateTime Function()? now,
  }) : _authSession = authSession ?? AuthSessionRepository.instance,
       _recordRepository = recordRepository ?? FishingRecordRepository.instance,
       _outboxRepository = outboxRepository ?? OutboxRepository.instance,
       _networkStatusService =
           networkStatusService ?? NetworkStatusService.instance,
       _localDataStore = localDataStore ?? LocalDataStore.instance,
       _now = now ?? DateTime.now;

  static final RecordSyncService instance = RecordSyncService();

  static const String _syncMarkerPrefix = 'firestore_record_sync_v1';

  final AuthSessionRepository _authSession;
  final FishingRecordRepository _recordRepository;
  final OutboxRepository _outboxRepository;
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
  String? _statusOwnerKey;

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
    notifyListeners();
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
      unawaited(syncNow(scheduleFollowUpIfBusy: true));
    }
  }

  Future<RecordSyncResult> syncNow({bool scheduleFollowUpIfBusy = false}) {
    final inProgress = _syncFuture;
    if (inProgress != null) {
      if (_state == RecordSyncState.syncing && scheduleFollowUpIfBusy) {
        _rerunRequested = true;
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
    _statusOwnerKey = ownerKey;
    _state = RecordSyncState.syncing;
    _lastError = null;
    notifyListeners();

    var pushedCount = 0;
    try {
      final firstRealSync = !await _hasCompletedFirstSync(uid);
      if (firstRealSync) {
        final serverBeforePush = await gateway.fetchSnapshot(uid: uid);
        if (!_isCurrentSession(uid, ownerKey)) {
          return _skip(RecordSyncSkipReason.sessionChanged);
        }
        await _prepareFirstRealSync(
          uid: uid,
          ownerKey: ownerKey,
          serverSnapshot: serverBeforePush,
        );
        if (!_isCurrentSession(uid, ownerKey)) {
          return _skip(RecordSyncSkipReason.sessionChanged);
        }
      }

      while (true) {
        while (true) {
          final queuedItem = _firstUnfinishedItem(ownerKey);
          if (queuedItem == null) {
            break;
          }
          if (!_isCurrentSession(uid, ownerKey)) {
            return _skip(RecordSyncSkipReason.sessionChanged);
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

          if (!_isCurrentSession(uid, ownerKey)) {
            return _skip(RecordSyncSkipReason.sessionChanged);
          }

          try {
            await gateway.pushOutboxItem(uid: uid, item: queuedItem);
          } on Object catch (error) {
            final message = _messageFor(error);
            if (_isCurrentSession(uid, ownerKey)) {
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

          if (!_isCurrentSession(uid, ownerKey)) {
            return _skip(RecordSyncSkipReason.sessionChanged);
          }
          await _outboxRepository.updateItemStatusForOwner(
            ownerKey: ownerKey,
            itemId: queuedItem.id,
            status: OutboxStatus.succeeded,
          );
          pushedCount += 1;
          notifyListeners();
        }

        if (!_isCurrentSession(uid, ownerKey)) {
          return _skip(RecordSyncSkipReason.sessionChanged);
        }
        await PlanPolicyService.instance.completeMigrationIfPossible();
        if (!_isCurrentSession(uid, ownerKey)) {
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

        final serverSnapshot = await gateway.fetchSnapshot(uid: uid);
        if (!_isCurrentSession(uid, ownerKey)) {
          return _skip(RecordSyncSkipReason.sessionChanged);
        }
        if (_outboxRepository.hasUnfinishedItemsForOwner(ownerKey)) {
          continue;
        }

        final replaced = await _recordRepository.replaceWithRemoteSnapshot(
          serverSnapshot.activeRecords,
          ownerKey: ownerKey,
        );
        if (!replaced) {
          continue;
        }
        if (!_isCurrentSession(uid, ownerKey)) {
          return _skip(RecordSyncSkipReason.sessionChanged);
        }
        if (firstRealSync) {
          await _markFirstSyncCompleted(uid);
          if (!_isCurrentSession(uid, ownerKey)) {
            return _skip(RecordSyncSkipReason.sessionChanged);
          }
        }
        if (_outboxRepository.hasUnfinishedItemsForOwner(ownerKey)) {
          continue;
        }

        _rerunRequested = false;
        final result = RecordSyncResult(
          pushedCount: pushedCount,
          pulledCount: serverSnapshot.activeRecords.length,
        );
        _state = RecordSyncState.succeeded;
        _lastResult = result;
        _lastSyncedAt = _now();
        _lastError = null;
        notifyListeners();
        return result;
      }
    } on Object catch (error) {
      return _fail(
        pushedCount: pushedCount,
        failedCount: 1,
        message: _messageFor(error),
      );
    }
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
          payload: record.toJson(),
        ),
      );
    }

    // Use the captured owner key for the whole transaction. A logout/account
    // switch during this await can stop the sync, but can never move one
    // account's replay/bootstrap items into another account's SQLite partition.
    await AppDatabase.instance.transaction((transaction) async {
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
        _authSession.memberId == uid &&
        _authSession.dataOwnerKey == ownerKey;
  }

  OutboxItem? _firstUnfinishedItem(String ownerKey) {
    for (final item in _outboxRepository.getAllItemsForOwner(ownerKey)) {
      if (item.status != OutboxStatus.succeeded) {
        return item;
      }
    }
    return null;
  }

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
    _statusOwnerKey = null;
  }

  @override
  void dispose() {
    if (_isInitialized) {
      _networkStatusService.removeListener(_handleNetworkStatusChange);
    }
    super.dispose();
  }
}
