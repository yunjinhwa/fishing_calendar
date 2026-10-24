import '../models/fishing_record.dart';
import '../models/outbox_item.dart';
import '../models/record_sync_metadata.dart';

class RemoteRecordRevision {
  final String recordId;
  final int versionNo;
  final RemoteRecordStatus status;
  final FishingRecord? record;

  const RemoteRecordRevision({
    required this.recordId,
    required this.versionNo,
    required this.status,
    required this.record,
  }) : assert(versionNo >= 1),
       assert(
         (status == RemoteRecordStatus.active && record != null) ||
             (status == RemoteRecordStatus.deleted && record == null),
       );
}

/// Complete server view for one member, including deletion tombstones.
class RemoteRecordSnapshot {
  final List<RemoteRecordRevision> revisions;

  const RemoteRecordSnapshot({required this.revisions});

  static const empty = RemoteRecordSnapshot(
    revisions: <RemoteRecordRevision>[],
  );

  List<FishingRecord> get activeRecords => List<FishingRecord>.unmodifiable(
    revisions
        .where((revision) => revision.status == RemoteRecordStatus.active)
        .map((revision) => revision.record!),
  );

  Set<String> get knownRecordIds =>
      Set<String>.unmodifiable(revisions.map((revision) => revision.recordId));

  RemoteRecordRevision? revisionFor(String recordId) {
    for (final revision in revisions) {
      if (revision.recordId == recordId) {
        return revision;
      }
    }
    return null;
  }
}

class RecordPushResult {
  final int versionNo;
  final RemoteRecordStatus status;

  const RecordPushResult({required this.versionNo, required this.status});
}

/// Optional live invalidation for a record currently being viewed or edited.
/// Events must be authoritative server revisions, not local pending writes.
abstract interface class RecordRevisionWatchGateway {
  Stream<RemoteRecordRevision?> watchRecordRevision({
    required String uid,
    required String recordId,
  });
}

abstract interface class RecordSyncGateway {
  /// Applies one local mutation exactly once for [uid].
  Future<RecordPushResult> pushOutboxItem({
    required String uid,
    required OutboxItem item,
  });

  /// Reads the authoritative server snapshot, bypassing any client cache.
  Future<RemoteRecordSnapshot> fetchSnapshot({required String uid});

  /// Reads one current server revision for conflict resolution.
  Future<RemoteRecordRevision?> fetchRecordRevision({
    required String uid,
    required String recordId,
  });
}

class RecordSyncGatewayException implements Exception {
  final String message;
  final String? code;
  final Object? cause;
  final StackTrace? causeStackTrace;

  const RecordSyncGatewayException({
    required this.message,
    this.code,
    this.cause,
    this.causeStackTrace,
  });

  @override
  String toString() => code == null
      ? 'RecordSyncGatewayException: $message'
      : 'RecordSyncGatewayException($code): $message';
}

class RecordVersionConflictException extends RecordSyncGatewayException {
  final String recordId;
  final int? baseVersionNo;
  final int remoteVersionNo;
  final RemoteRecordStatus remoteStatus;
  final FishingRecord? remoteRecord;

  const RecordVersionConflictException({
    required this.recordId,
    required this.baseVersionNo,
    required this.remoteVersionNo,
    required this.remoteStatus,
    required this.remoteRecord,
  }) : super(code: 'version-conflict', message: '다른 기기에서 변경된 기록과 충돌했습니다.');
}
