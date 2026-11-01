import 'dart:async';

import 'package:flutter/foundation.dart';

import '../local/app_database.dart';
import '../local/local_data_store.dart';
import '../models/record_cache_policy.dart';
import '../models/record_sync_metadata.dart';
import '../remote/record_sync_gateway.dart';
import '../repositories/auth_session_repository.dart';
import '../repositories/fishing_record_repository.dart';
import 'network_status_service.dart';
import 'record_sync_service.dart';

enum CachedMonthState { local, loading, ready, offline, failed }

class PaidRecordCacheService extends ChangeNotifier {
  PaidRecordCacheService({RecordCachePolicy? policy})
    : policy = policy ?? RecordCachePolicy.instance;

  static final instance = PaidRecordCacheService();
  final RecordCachePolicy policy;
  final _auth = AuthSessionRepository.instance;
  final _records = FishingRecordRepository.instance;
  final _store = LocalDataStore.instance;
  final _sync = RecordSyncService.instance;
  final _network = NetworkStatusService.instance;
  final _states = <(String, DateTime), CachedMonthState>{};
  final _loads = <(String, int, int, DateTime), Future<void>>{};
  final _historyStates = <String, CachedMonthState>{};
  final _historyLoads = <(String, int, int), Future<void>>{};
  Future<void>? _trimFuture;
  bool _trimAgain = false;
  bool _initialized = false;
  int? _generation;
  bool _wasAllowed = false;
  int _epoch = 0;
  Object? lastTrimError;

  bool get _canManageCache => policy.enabled && _auth.canUseCloudSync;

  void initialize() {
    if (_initialized) return;
    _initialized = true;
    _generation = _auth.sessionGeneration;
    policy.enabled = true;
    _wasAllowed = _canManageCache;
    policy.onPinsChanged = requestTrim;
    _auth.addListener(_onStateChanged);
    _records.addListener(requestTrim);
    _sync.addListener(_onSyncChanged);
    _network.addListener(_onStateChanged);
    requestTrim();
  }

  void _onStateChanged() {
    if (_generation != _auth.sessionGeneration ||
        _wasAllowed != _canManageCache) {
      _generation = _auth.sessionGeneration;
      _wasAllowed = _canManageCache;
      _epoch++;
      _states.clear();
      _historyStates.clear();
    }
    notifyListeners();
    requestTrim();
  }

  void _onSyncChanged() {
    if (!_sync.isSyncing) requestTrim();
  }

  CachedMonthState stateFor(DateTime month) {
    if (!_canManageCache || !policy.needsMonthQuery(month)) {
      return CachedMonthState.local;
    }
    return _states[(_auth.dataOwnerKey, DateTime(month.year, month.month))] ??
        (_network.isDisconnected
            ? CachedMonthState.offline
            : CachedMonthState.local);
  }

  void Function() holdMonth(DateTime month) {
    final owner = _auth.dataOwnerKey;
    final normalized = DateTime(month.year, month.month);
    final release = policy.holdMonth(owner, normalized);
    return () {
      release();
      if (!policy.holdsMonth(owner, normalized)) {
        _states.remove((owner, normalized));
      }
    };
  }

  CachedMonthState get historyState => !_canManageCache
      ? CachedMonthState.local
      : _historyStates[_auth.dataOwnerKey] ??
            (_network.isDisconnected
                ? CachedMonthState.offline
                : CachedMonthState.local);

  void Function() holdHistory() {
    final owner = _auth.dataOwnerKey;
    final release = policy.holdHistory(owner);
    return () {
      release();
      if (!policy.holdsHistory(owner)) _historyStates.remove(owner);
    };
  }

  Future<void> loadHistory({bool force = false}) {
    if (!_canManageCache) return Future.value();
    final owner = _auth.dataOwnerKey;
    final generation = _auth.sessionGeneration;
    final epoch = _epoch;
    final key = (owner, generation, epoch);
    final existing = _historyLoads[key];
    if (existing != null) return existing;
    if (!force && _historyStates[owner] == CachedMonthState.ready) {
      return Future.value();
    }
    late final Future<void> future;
    future = _loadHistory(owner, generation, epoch).whenComplete(() {
      if (identical(_historyLoads[key], future)) _historyLoads.remove(key);
    });
    _historyLoads[key] = future;
    return future;
  }

  Future<void> _loadHistory(String owner, int generation, int epoch) async {
    bool current() =>
        _canManageCache &&
        _auth.dataOwnerKey == owner &&
        _auth.sessionGeneration == generation &&
        _epoch == epoch &&
        policy.holdsHistory(owner);
    if (!current()) return;
    if (_network.isDisconnected) {
      _historyStates[owner] = CachedMonthState.offline;
      notifyListeners();
      return;
    }
    _historyStates[owner] = CachedMonthState.loading;
    notifyListeners();
    try {
      final from = DateTime.utc(1);
      final to = DateTime.utc(10000);
      final expectedVersions = await _records.captureRemoteRangeVersions(
        ownerKey: owner,
        from: from,
        to: to,
        isCurrentSession: current,
      );
      if (!current()) return;
      final snapshot = await _sync.fetchHistorySnapshot();
      if (!current()) return;
      final result = await _records.applyRemoteRange(
        ownerKey: owner,
        revisions: snapshot.revisions,
        isCurrentSession: current,
      );
      if (!current()) return;
      if (!result.applied) throw StateError('History was not applied.');
      final reconciled = await _records.reconcileRemoteRange(
        ownerKey: owner,
        from: from,
        to: to,
        knownRecordIds: snapshot.knownRecordIds,
        expectedVersions: expectedVersions,
        isCurrentSession: current,
      );
      if (!current()) return;
      if (!reconciled.applied) throw StateError('History was not reconciled.');
      _historyStates[owner] = CachedMonthState.ready;
    } on Object {
      if (!current()) return;
      _historyStates[owner] = _network.isDisconnected
          ? CachedMonthState.offline
          : CachedMonthState.failed;
    }
    notifyListeners();
  }

  Future<void> loadMonth(DateTime month, {bool force = false}) {
    final normalized = DateTime(month.year, month.month);
    if (!_canManageCache || !policy.needsMonthQuery(normalized)) {
      return Future.value();
    }
    final owner = _auth.dataOwnerKey;
    final generation = _auth.sessionGeneration;
    final epoch = _epoch;
    final key = (owner, generation, epoch, normalized);
    final existing = _loads[key];
    if (existing != null) return existing;
    if (!force && _states[(owner, normalized)] == CachedMonthState.ready) {
      return Future.value();
    }
    late final Future<void> future;
    future = _loadMonth(owner, generation, epoch, normalized).whenComplete(() {
      if (identical(_loads[key], future)) _loads.remove(key);
    });
    _loads[key] = future;
    return future;
  }

  Future<void> _loadMonth(
    String owner,
    int generation,
    int epoch,
    DateTime month,
  ) async {
    bool current() =>
        _canManageCache &&
        _auth.dataOwnerKey == owner &&
        _auth.sessionGeneration == generation &&
        _epoch == epoch &&
        policy.holdsMonth(owner, month);
    if (!current()) return;
    final key = (owner, month);
    if (_network.isDisconnected) {
      _states[key] = CachedMonthState.offline;
      notifyListeners();
      return;
    }
    _states[key] = CachedMonthState.loading;
    notifyListeners();
    try {
      final to = DateTime(month.year, month.month + 1);
      final expectedVersions = await _records.captureRemoteRangeVersions(
        ownerKey: owner,
        from: month,
        to: to,
        isCurrentSession: current,
      );
      if (!current()) return;
      final knownIds = <String>{};
      RecordRangeCursor? after;
      while (current()) {
        final page = await _sync.fetchRecordRange(
          from: month,
          to: to,
          after: after,
        );
        if (!current()) return;
        if (page.hasMore &&
            (page.revisions.isEmpty ||
                page.nextCursor == null ||
                (after != null && page.nextCursor!.compareTo(after) <= 0))) {
          throw StateError('The month query did not advance.');
        }
        final applied = await _records.applyRemoteRange(
          ownerKey: owner,
          revisions: page.revisions,
          isCurrentSession: current,
        );
        if (!current()) return;
        if (!applied.applied) {
          throw StateError('The month query was not applied.');
        }
        knownIds.addAll(page.revisions.map((revision) => revision.recordId));
        if (!page.hasMore) {
          final reconciled = await _records.reconcileRemoteRange(
            ownerKey: owner,
            from: month,
            to: to,
            knownRecordIds: knownIds,
            expectedVersions: expectedVersions,
            isCurrentSession: current,
          );
          if (!current()) return;
          if (!reconciled.applied) {
            throw StateError('The month query was not reconciled.');
          }
          _states[key] = CachedMonthState.ready;
          notifyListeners();
          return;
        }
        after = page.nextCursor;
      }
    } on Object {
      if (!current()) return;
      _states[key] = _network.isDisconnected
          ? CachedMonthState.offline
          : CachedMonthState.failed;
      notifyListeners();
    }
  }

  void requestTrim() {
    if (!_canManageCache) return;
    if (_trimFuture != null) {
      _trimAgain = true;
      return;
    }
    late final Future<void> future;
    future =
        Future<void>.microtask(() async {
          do {
            _trimAgain = false;
            try {
              await trimNow();
              lastTrimError = null;
            } on Object catch (error) {
              lastTrimError = error;
            }
          } while (_trimAgain && _canManageCache);
        }).whenComplete(() {
          if (identical(_trimFuture, future)) _trimFuture = null;
        });
    _trimFuture = future;
  }

  Future<int> trimNow() async {
    if (!_canManageCache) return 0;
    final owner = _auth.dataOwnerKey;
    final generation = _auth.sessionGeneration;
    final pinsRevision = policy.revision;
    bool current() =>
        _canManageCache &&
        _auth.dataOwnerKey == owner &&
        _auth.sessionGeneration == generation &&
        policy.revision == pinsRevision;
    try {
      final result = await AppDatabase.instance.transaction((
        transaction,
      ) async {
        if (!current()) throw const _CacheTrimCancelled();
        final records = await _store.readRecordsForOwner(
          owner,
          executor: transaction,
        );
        final protected = <String>{};
        for (final (table, condition) in [
          (AppDatabase.outboxItemsTable, "status != 'succeeded'"),
          (AppDatabase.recordConflictsTable, "status != 'resolved'"),
          (AppDatabase.localRecordChangesTable, '1 = 1'),
        ]) {
          final rows = await transaction.query(
            table,
            columns: const ['record_id'],
            where: 'owner_key = ? AND ($condition)',
            whereArgs: [owner],
          );
          protected.addAll(rows.map((row) => row['record_id']! as String));
        }
        final evictedIds = <String>{};
        for (final record in records) {
          if (policy.keepsRecord(owner, record) ||
              protected.contains(record.id)) {
            continue;
          }
          final metadata = await _store.readRecordSyncMetadata(
            owner,
            record.id,
            executor: transaction,
          );
          if (metadata == null ||
              metadata.serverVersionNo == 0 ||
              metadata.optimisticVersionNo != metadata.serverVersionNo ||
              metadata.remoteStatus != RemoteRecordStatus.active) {
            continue;
          }
          if (!current()) throw const _CacheTrimCancelled();
          await _store.deleteRecord(
            transaction,
            ownerKey: owner,
            recordId: record.id,
            preservePhotos: true,
          );
          evictedIds.add(record.id);
        }
        if (!current()) throw const _CacheTrimCancelled();
        return (
          count: evictedIds.length,
          retained: records
              .where((record) => !evictedIds.contains(record.id))
              .toList(),
        );
      });
      if (result.count > 0) {
        _records.publishCommittedSnapshot(
          ownerKey: owner,
          records: result.retained,
        );
      }
      return result.count;
    } on _CacheTrimCancelled {
      return 0;
    }
  }

  Future<void> flushPending() async {
    while (_trimFuture != null ||
        _loads.isNotEmpty ||
        _historyLoads.isNotEmpty) {
      final trim = _trimFuture;
      if (trim != null) await trim;
      await Future.wait(_loads.values.toList());
      await Future.wait(_historyLoads.values.toList());
    }
  }

  void _detach() {
    if (_initialized) {
      _auth.removeListener(_onStateChanged);
      _records.removeListener(requestTrim);
      _sync.removeListener(_onSyncChanged);
      _network.removeListener(_onStateChanged);
      policy.onPinsChanged = null;
      policy.enabled = false;
      _initialized = false;
    }
    policy.enabled = false;
    _epoch++;
  }

  @visibleForTesting
  Future<void> resetForTesting() async {
    _detach();
    await flushPending();
    _states.clear();
    _historyStates.clear();
    _generation = null;
    _trimAgain = false;
    lastTrimError = null;
    policy.reset();
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }
}

class _CacheTrimCancelled implements Exception {
  const _CacheTrimCancelled();
}
