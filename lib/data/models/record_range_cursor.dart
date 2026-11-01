import 'record_sync_checkpoint.dart';

/// Exact position in an endAt/startAt/document ID ordered range query.
/// This is independent of the incremental synchronization checkpoint.
class RecordRangeCursor implements Comparable<RecordRangeCursor> {
  final int endSeconds;
  final int endNanoseconds;
  final int startSeconds;
  final int startNanoseconds;
  final String recordId;

  const RecordRangeCursor({
    required this.endSeconds,
    required this.endNanoseconds,
    required this.startSeconds,
    required this.startNanoseconds,
    required this.recordId,
  });

  factory RecordRangeCursor.fromJson(Map<String, dynamic> json) {
    final end = RecordSyncCursor.fromJson({
      'seconds': json['endSeconds'],
      'nanoseconds': json['endNanoseconds'],
      'recordId': json['recordId'],
    });
    final start = RecordSyncCursor.fromJson({
      'seconds': json['startSeconds'],
      'nanoseconds': json['startNanoseconds'],
      'recordId': json['recordId'],
    });
    if (end.recordId.trim().isEmpty || start.compareTo(end) >= 0) {
      throw const FormatException('Invalid record range cursor.');
    }
    return RecordRangeCursor(
      endSeconds: end.seconds,
      endNanoseconds: end.nanoseconds,
      startSeconds: start.seconds,
      startNanoseconds: start.nanoseconds,
      recordId: end.recordId,
    );
  }

  Map<String, dynamic> toJson() => {
    'endSeconds': endSeconds,
    'endNanoseconds': endNanoseconds,
    'startSeconds': startSeconds,
    'startNanoseconds': startNanoseconds,
    'recordId': recordId,
  };

  @override
  int compareTo(RecordRangeCursor other) {
    var comparison = endSeconds.compareTo(other.endSeconds);
    if (comparison != 0) return comparison;
    comparison = endNanoseconds.compareTo(other.endNanoseconds);
    if (comparison != 0) return comparison;
    return RecordSyncCursor(
      seconds: startSeconds,
      nanoseconds: startNanoseconds,
      recordId: recordId,
    ).compareTo(
      RecordSyncCursor(
        seconds: other.startSeconds,
        nanoseconds: other.startNanoseconds,
        recordId: other.recordId,
      ),
    );
  }
}
