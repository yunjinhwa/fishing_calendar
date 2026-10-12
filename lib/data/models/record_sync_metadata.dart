enum RemoteRecordStatus { missing, active, deleted }

class RecordSyncMetadata {
  final String recordId;
  final int serverVersionNo;
  final int optimisticVersionNo;
  final RemoteRecordStatus remoteStatus;

  const RecordSyncMetadata({
    required this.recordId,
    required this.serverVersionNo,
    required this.optimisticVersionNo,
    required this.remoteStatus,
  });
}
