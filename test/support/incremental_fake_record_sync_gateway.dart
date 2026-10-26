import 'dart:async';
import 'dart:math' as math;

import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/outbox_item.dart';
import 'package:fishing_build/data/remote/record_sync_gateway.dart';

import 'fake_record_sync_gateway.dart';

class IncrementalFakeRecordSyncGateway extends FakeRecordSyncGateway
    implements IncrementalRecordSyncGateway {
  IncrementalFakeRecordSyncGateway({this.pageSize = 100});

  final int pageSize;
  final Map<String, Map<String, RecordSyncCursor>> _cursors = {};
  final Map<String, Set<String>> _physicallyDeleted = {};
  int _logicalSeconds = 0;

  int latestCursorFetchCount = 0;
  int changeDocumentReadCount = 0;
  final List<FakeChangeRequest> changeRequests = [];
  final Set<int> failingChangeCalls = {};
  RemoteRecordChangePage? nextChangePageOverride;

  Completer<void>? changePageCaptured;
  Completer<void>? _changePageRelease;

  void holdNextChangePage() {
    if (_changePageRelease != null) {
      throw StateError('A change page is already held.');
    }
    changePageCaptured = Completer<void>();
    _changePageRelease = Completer<void>();
  }

  void releaseChangePage() {
    final release = _changePageRelease;
    if (release != null && !release.isCompleted) release.complete();
    _changePageRelease = null;
  }

  @override
  void seedActive(
    String uid,
    FishingRecord record, {
    int? versionNo,
    RecordSyncCursor? cursor,
  }) {
    super.seedActive(uid, record, versionNo: versionNo);
    _setCursor(uid, record.id, cursor);
  }

  @override
  void seedDeleted(
    String uid,
    String recordId, {
    int? versionNo,
    RecordSyncCursor? cursor,
  }) {
    super.seedDeleted(uid, recordId, versionNo: versionNo);
    _setCursor(uid, recordId, cursor);
  }

  /// Simulates an administrator bypassing the application's tombstone writes.
  void physicallyDelete(String uid, String recordId) {
    _physicallyDeleted.putIfAbsent(uid, () => <String>{}).add(recordId);
  }

  @override
  Future<RecordPushResult> pushOutboxItem({
    required String uid,
    required OutboxItem item,
  }) async {
    final previousVersion = version(uid, item.recordId);
    final result = await super.pushOutboxItem(uid: uid, item: item);
    if (version(uid, item.recordId) != previousVersion) {
      _setCursor(uid, item.recordId, null);
    }
    return result;
  }

  @override
  Future<RemoteRecordRevision?> fetchRecordRevision({
    required String uid,
    required String recordId,
  }) async {
    final revision = await super.fetchRecordRevision(
      uid: uid,
      recordId: recordId,
    );
    if (revision == null || _isPhysicallyDeleted(uid, recordId)) return null;
    return _decorate(uid, revision);
  }

  @override
  Future<RemoteRecordSnapshot> fetchSnapshot({required String uid}) async {
    final snapshot = await super.fetchSnapshot(uid: uid);
    final revisions = snapshot.revisions
        .where((revision) => !_isPhysicallyDeleted(uid, revision.recordId))
        .map((revision) => _decorate(uid, revision))
        .toList(growable: false);
    return RemoteRecordSnapshot(
      revisions: revisions,
      cursor: _latestCursor(uid),
    );
  }

  @override
  Future<RecordSyncCursor> fetchLatestCursor({required String uid}) async {
    latestCursorFetchCount += 1;
    return _latestCursor(uid);
  }

  @override
  Future<RemoteRecordChangePage> fetchChanges({
    required String uid,
    required RecordSyncCursor since,
    required RecordSyncCursor through,
    RecordSyncCursor? after,
    int limit = 100,
  }) async {
    changeRequests.add(
      FakeChangeRequest(uid: uid, since: since, through: through, after: after),
    );
    if (failingChangeCalls.contains(changeRequests.length)) {
      throw const RecordSyncGatewayException(
        code: 'unavailable',
        message: 'The test change query failed.',
      );
    }

    final eligible =
        (_cursors[uid] ?? const <String, RecordSyncCursor>{}).values
            .where(
              (cursor) =>
                  !_isPhysicallyDeleted(uid, cursor.recordId) &&
                  _compareTimestamp(cursor, since) >= 0 &&
                  cursor.compareTo(through) <= 0 &&
                  (after == null || cursor.compareTo(after) > 0),
            )
            .toList()
          ..sort((left, right) => left.compareTo(right));
    final effectiveLimit = math.min(limit, pageSize);
    final revisions = <RemoteRecordRevision>[];
    for (final cursor in eligible.take(effectiveLimit)) {
      final revision = await super.fetchRecordRevision(
        uid: uid,
        recordId: cursor.recordId,
      );
      if (revision == null) throw StateError('Missing fake server revision.');
      revisions.add(_decorate(uid, revision));
    }
    changeDocumentReadCount += revisions.length;
    final override = nextChangePageOverride;
    nextChangePageOverride = null;
    final page =
        override ??
        RemoteRecordChangePage(
          revisions: revisions,
          hasMore: eligible.length > effectiveLimit,
        );

    final release = _changePageRelease;
    final captured = changePageCaptured;
    if (release != null) {
      if (captured != null && !captured.isCompleted) captured.complete();
      await release.future;
    }
    return page;
  }

  void _setCursor(String uid, String recordId, RecordSyncCursor? cursor) {
    if (cursor != null && cursor.recordId != recordId) {
      throw ArgumentError('A fake cursor must identify its record.');
    }
    final next =
        cursor ??
        RecordSyncCursor(
          seconds: ++_logicalSeconds,
          nanoseconds: 0,
          recordId: recordId,
        );
    _logicalSeconds = math.max(_logicalSeconds, next.seconds);
    _cursors.putIfAbsent(uid, () => <String, RecordSyncCursor>{})[recordId] =
        next;
    _physicallyDeleted[uid]?.remove(recordId);
  }

  bool _isPhysicallyDeleted(String uid, String recordId) =>
      _physicallyDeleted[uid]?.contains(recordId) ?? false;

  RecordSyncCursor _latestCursor(String uid) {
    var latest = RecordSyncCursor.origin;
    for (final cursor
        in (_cursors[uid] ?? const <String, RecordSyncCursor>{}).values) {
      if (!_isPhysicallyDeleted(uid, cursor.recordId) &&
          cursor.compareTo(latest) > 0) {
        latest = cursor;
      }
    }
    return latest;
  }

  RemoteRecordRevision _decorate(String uid, RemoteRecordRevision revision) =>
      RemoteRecordRevision(
        recordId: revision.recordId,
        versionNo: revision.versionNo,
        status: revision.status,
        record: revision.record,
        cursor: _cursors[uid]![revision.recordId]!,
      );

  int _compareTimestamp(RecordSyncCursor left, RecordSyncCursor right) {
    final seconds = left.seconds.compareTo(right.seconds);
    return seconds == 0
        ? left.nanoseconds.compareTo(right.nanoseconds)
        : seconds;
  }
}

class FakeChangeRequest {
  final String uid;
  final RecordSyncCursor since;
  final RecordSyncCursor through;
  final RecordSyncCursor? after;

  const FakeChangeRequest({
    required this.uid,
    required this.since,
    required this.through,
    required this.after,
  });
}
