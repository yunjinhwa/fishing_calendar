import 'dart:convert';

/// Exact Firestore ordering position. Never round this through DateTime.
class RecordSyncCursor implements Comparable<RecordSyncCursor> {
  final int seconds;
  final int nanoseconds;
  final String recordId;

  const RecordSyncCursor({
    required this.seconds,
    required this.nanoseconds,
    required this.recordId,
  });

  /// Firestore's earliest timestamp, before any application record exists.
  static const origin = RecordSyncCursor(
    seconds: -62135596800,
    nanoseconds: 0,
    recordId: '',
  );

  factory RecordSyncCursor.fromJson(Map<String, dynamic> json) {
    final seconds = json['seconds'];
    final nanoseconds = json['nanoseconds'];
    final recordId = json['recordId'];
    if (seconds is! int ||
        seconds < -62135596800 ||
        seconds > 253402300799 ||
        nanoseconds is! int ||
        nanoseconds < 0 ||
        nanoseconds >= 1000000000 ||
        recordId is! String ||
        recordId.contains('/') ||
        (recordId.isEmpty && (seconds != origin.seconds || nanoseconds != 0))) {
      throw const FormatException('Invalid record sync cursor.');
    }
    return RecordSyncCursor(
      seconds: seconds,
      nanoseconds: nanoseconds,
      recordId: recordId,
    );
  }

  Map<String, dynamic> toJson() => {
    'seconds': seconds,
    'nanoseconds': nanoseconds,
    'recordId': recordId,
  };

  @override
  int compareTo(RecordSyncCursor other) {
    var comparison = seconds.compareTo(other.seconds);
    if (comparison != 0) return comparison;
    comparison = nanoseconds.compareTo(other.nanoseconds);
    if (comparison != 0) return comparison;
    // Firestore strings/document IDs are ordered by their UTF-8 bytes.
    final left = utf8.encode(recordId);
    final right = utf8.encode(other.recordId);
    for (var index = 0; index < left.length && index < right.length; index++) {
      comparison = left[index].compareTo(right[index]);
      if (comparison != 0) return comparison;
    }
    return left.length.compareTo(right.length);
  }
}

/// Owner-scoped pull progress, committed atomically with the received records.
class RecordSyncCheckpoint {
  final RecordSyncCursor cursor;
  final DateTime lastFullSyncAt;

  const RecordSyncCheckpoint({
    required this.cursor,
    required this.lastFullSyncAt,
  });

  static String metadataKey(String ownerKey) =>
      'record_incremental_sync_v1:$ownerKey';

  factory RecordSyncCheckpoint.decode(String value) {
    final json = jsonDecode(value);
    if (json is! Map<String, dynamic> ||
        json['schemaVersion'] != 1 ||
        json['cursor'] is! Map<String, dynamic> ||
        json['lastFullSyncAt'] is! String) {
      throw const FormatException('Invalid record sync checkpoint.');
    }
    return RecordSyncCheckpoint(
      cursor: RecordSyncCursor.fromJson(json['cursor'] as Map<String, dynamic>),
      lastFullSyncAt: DateTime.parse(json['lastFullSyncAt'] as String).toUtc(),
    );
  }

  String encode() => jsonEncode({
    'schemaVersion': 1,
    'cursor': cursor.toJson(),
    'lastFullSyncAt': lastFullSyncAt.toUtc().toIso8601String(),
  });
}
