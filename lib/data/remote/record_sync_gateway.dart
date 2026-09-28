import '../models/fishing_record.dart';
import '../models/outbox_item.dart';

/// Complete server view for one member.
///
/// [knownRecordIds] also contains tombstones. This lets the first real sync
/// distinguish a record deleted on another device from a record that has never
/// reached the server.
class RemoteRecordSnapshot {
  final List<FishingRecord> activeRecords;
  final Set<String> knownRecordIds;

  const RemoteRecordSnapshot({
    required this.activeRecords,
    required this.knownRecordIds,
  });

  static const empty = RemoteRecordSnapshot(
    activeRecords: <FishingRecord>[],
    knownRecordIds: <String>{},
  );
}

abstract interface class RecordSyncGateway {
  /// Applies one local mutation exactly once for [uid].
  Future<void> pushOutboxItem({required String uid, required OutboxItem item});

  /// Reads the authoritative server snapshot, bypassing any client cache.
  Future<RemoteRecordSnapshot> fetchSnapshot({required String uid});
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
