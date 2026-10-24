import 'dart:convert';

import 'fishing_record.dart';

/// The body and local version the user actually started editing.
/// Server acknowledgements alone do not invalidate the optimistic version.
class RecordEditSnapshot {
  final FishingRecord record;
  final String ownerKey;
  final int sessionGeneration;
  final int optimisticVersionNo;
  final String _encodedRecord;

  RecordEditSnapshot({
    required FishingRecord record,
    required this.ownerKey,
    required this.sessionGeneration,
    required this.optimisticVersionNo,
  }) : record = FishingRecord.fromJson(record.toJson()),
       _encodedRecord = jsonEncode(record.toJson());

  bool matchesRecord(FishingRecord current) =>
      _encodedRecord == jsonEncode(current.toJson());
}

enum RecordEditConflictReason { changed, deleted, sessionChanged }

class RecordEditConflictException implements Exception {
  final RecordEditConflictReason reason;
  final RecordEditSnapshot? currentSnapshot;

  const RecordEditConflictException(this.reason, {this.currentSnapshot});

  String get message => switch (reason) {
    RecordEditConflictReason.changed =>
      '편집 중 기록이 변경되었습니다. 입력한 내용은 유지됩니다. 최신 기록을 확인한 뒤 다시 수정해 주세요.',
    RecordEditConflictReason.deleted =>
      '이 기록은 삭제되었습니다. 입력한 내용은 유지되지만 삭제된 기록에 저장할 수 없습니다.',
    RecordEditConflictReason.sessionChanged =>
      '로그인 계정이 변경되어 저장할 수 없습니다. 입력한 내용은 유지됩니다.',
  };

  @override
  String toString() => message;
}
