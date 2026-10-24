import 'dart:async';

import 'package:flutter/foundation.dart';

import '../local/local_data_store.dart';
import '../remote/record_sync_gateway.dart';
import '../repositories/auth_session_repository.dart';

/// Shares one document subscription between the detail page and its editor.
/// Remote events invalidate the existing sync flow rather than writing records
/// directly, so queued mutations and conflict resolution keep their semantics.
class RecordRefreshWatcher {
  RecordRefreshWatcher({
    required this.authSession,
    required this.store,
    required this.gateway,
    required this.refresh,
  });

  final AuthSessionRepository authSession;
  final LocalDataStore store;
  final RecordSyncGateway? Function() gateway;
  final Future<void> Function() refresh;
  final Map<(int, String, String), _WatchedRecord> _records = {};
  bool _listeningToAuth = false;

  VoidCallback observe(String recordId) {
    final uid = authSession.memberId;
    if (uid == null) return () {};
    final key = (
      authSession.sessionGeneration,
      authSession.dataOwnerKey,
      recordId,
    );
    final record = _records.putIfAbsent(key, () => _WatchedRecord(key, uid));
    record.references += 1;
    if (!_listeningToAuth) {
      authSession.addListener(synchronize);
      _listeningToAuth = true;
    }
    synchronize();
    var released = false;
    return () {
      if (released) return;
      released = true;
      if (!identical(_records[key], record)) return;
      record.references -= 1;
      if (record.references == 0) {
        _records.remove(key);
        _cancel(record);
        _stopAuthListenerIfEmpty();
      }
    };
  }

  bool _sameSession(_WatchedRecord record) =>
      record.key.$1 == authSession.sessionGeneration &&
      record.key.$2 == authSession.dataOwnerKey &&
      record.uid == authSession.memberId;

  bool _isActive(_WatchedRecord record, RecordSyncGateway source) =>
      identical(_records[record.key], record) &&
      _sameSession(record) &&
      authSession.isPaid &&
      authSession.canUseOutbox &&
      identical(gateway(), source) &&
      identical(record.source, source);

  void synchronize() {
    final source = gateway();
    for (final record in List<_WatchedRecord>.of(_records.values)) {
      if (!_sameSession(record)) {
        _records.remove(record.key);
        _cancel(record);
        continue;
      }
      if (!authSession.isPaid ||
          !authSession.canUseOutbox ||
          source is! RecordRevisionWatchGateway) {
        _cancel(record);
        continue;
      }
      if (record.subscription != null && identical(record.source, source)) {
        continue;
      }
      _cancel(record);
      record.source = source;
      record.subscription = (source as RecordRevisionWatchGateway)
          .watchRecordRevision(uid: record.uid, recordId: record.key.$3)
          .listen(
            (revision) {
              if (!_isActive(record, source!)) return;
              final revisionKey = revision == null
                  ? 'missing'
                  : '${revision.versionNo}:${revision.status.name}';
              if (record.lastRevisionKey == revisionKey) return;
              record.lastRevisionKey = revisionKey;
              unawaited(_refreshIfChanged(record, source, revision));
            },
            onError: (Object error, StackTrace stackTrace) {
              // Existing manual/route refresh reports sync failures. Firestore
              // transport reconnection is handled by its snapshot stream.
            },
            onDone: () {
              if (identical(record.source, source)) {
                record.subscription = null;
                record.source = null;
              }
            },
          );
    }
    _stopAuthListenerIfEmpty();
  }

  Future<void> _refreshIfChanged(
    _WatchedRecord record,
    RecordSyncGateway source,
    RemoteRecordRevision? revision,
  ) async {
    try {
      final metadata = await store.readRecordSyncMetadata(
        record.key.$2,
        record.key.$3,
      );
      if (!_isActive(record, source)) return;
      if (revision != null &&
          metadata != null &&
          (metadata.serverVersionNo > revision.versionNo ||
              (metadata.serverVersionNo == revision.versionNo &&
                  metadata.remoteStatus == revision.status))) {
        return;
      }
      await refresh();
    } on Object {
      // Keep the subscription alive; the normal sync/next navigation retries.
    }
  }

  void _cancel(_WatchedRecord record) {
    final subscription = record.subscription;
    record.subscription = null;
    record.source = null;
    record.lastRevisionKey = null;
    if (subscription != null) {
      unawaited(subscription.cancel().catchError((Object _) {}));
    }
  }

  void _stopAuthListenerIfEmpty() {
    if (_records.isEmpty && _listeningToAuth) {
      authSession.removeListener(synchronize);
      _listeningToAuth = false;
    }
  }

  void clear() {
    for (final record in _records.values) {
      _cancel(record);
    }
    _records.clear();
    _stopAuthListenerIfEmpty();
  }
}

class _WatchedRecord {
  final (int, String, String) key;
  final String uid;
  int references = 0;
  RecordSyncGateway? source;
  StreamSubscription<RemoteRecordRevision?>? subscription;
  String? lastRevisionKey;
  _WatchedRecord(this.key, this.uid);
}
