import 'dart:convert';

import 'fishing_record.dart';
import 'outbox_item.dart';
import 'record_sync_metadata.dart';

enum ConflictStatus { unresolved, resolving, resolved }

enum ConflictResolutionType { useMine, useTheirs, manualMerge }

class ConflictFieldKey {
  ConflictFieldKey._();

  static const status = 'status';
  static const location = 'location';
  static const startAt = 'startAt';
  static const endAt = 'endAt';
  static const genreName = 'genreName';
  static const tide = 'tide';
  static const weather = 'weather';
  static const airTemperature = 'airTemperature';
  static const waterTemperature = 'waterTemperature';
  static const catches = 'catches';
  static const memo = 'memo';
  static const version = 'version';
}

class ConflictItem {
  final String id;
  final String ownerKey;
  final String recordId;
  final String outboxId;
  final OutboxOperationType localOperationType;
  final int? baseVersionNo;
  final int remoteVersionNo;
  final RemoteRecordStatus remoteStatus;
  final FishingRecord? localRecord;
  final FishingRecord? remoteRecord;
  final DateTime occurredAt;
  final ConflictStatus status;
  final ConflictResolutionType? resolutionType;
  final String? resolutionOutboxId;
  final DateTime? resolvedAt;

  const ConflictItem({
    required this.id,
    required this.ownerKey,
    required this.recordId,
    required this.outboxId,
    required this.localOperationType,
    required this.baseVersionNo,
    required this.remoteVersionNo,
    required this.remoteStatus,
    required this.localRecord,
    required this.remoteRecord,
    required this.occurredAt,
    required this.status,
    this.resolutionType,
    this.resolutionOutboxId,
    this.resolvedAt,
  });

  bool get localDeleted => localOperationType == OutboxOperationType.delete;
  bool get remoteDeleted => remoteStatus != RemoteRecordStatus.active;
  bool get canManualMerge =>
      !localDeleted &&
      remoteStatus == RemoteRecordStatus.active &&
      localRecord != null &&
      remoteRecord != null;

  String get recordTitle =>
      localRecord?.summaryTitle ?? remoteRecord?.summaryTitle ?? '삭제된 출조 기록';

  String get location =>
      localRecord?.location ?? remoteRecord?.location ?? '위치 정보 없음';

  List<ConflictField> get fields {
    if (localDeleted || remoteDeleted) {
      return <ConflictField>[
        ConflictField(
          key: ConflictFieldKey.status,
          fieldName: '기록 상태',
          mineValue: localDeleted ? '삭제' : '기록 유지',
          theirsValue: switch (remoteStatus) {
            RemoteRecordStatus.active => '기록 유지',
            RemoteRecordStatus.deleted => '삭제',
            RemoteRecordStatus.missing => '서버에 기록 없음',
          },
        ),
      ];
    }

    final mine = localRecord;
    final theirs = remoteRecord;
    if (mine == null || theirs == null) {
      return <ConflictField>[
        ConflictField(
          key: ConflictFieldKey.version,
          fieldName: '서버 버전',
          mineValue: baseVersionNo?.toString() ?? '알 수 없음',
          theirsValue: remoteVersionNo.toString(),
        ),
      ];
    }

    final candidates = <ConflictField>[
      ConflictField(
        key: ConflictFieldKey.location,
        fieldName: '위치',
        mineValue: mine.location,
        theirsValue: theirs.location,
      ),
      ConflictField(
        key: ConflictFieldKey.startAt,
        fieldName: '시작 시간',
        mineValue: _formatDateTime(mine.startAt),
        theirsValue: _formatDateTime(theirs.startAt),
      ),
      ConflictField(
        key: ConflictFieldKey.endAt,
        fieldName: '종료 시간',
        mineValue: _formatDateTime(mine.endAt),
        theirsValue: _formatDateTime(theirs.endAt),
      ),
      ConflictField(
        key: ConflictFieldKey.genreName,
        fieldName: '낚시 장르',
        mineValue: mine.genreName,
        theirsValue: theirs.genreName,
      ),
      ConflictField(
        key: ConflictFieldKey.tide,
        fieldName: '물때',
        mineValue: _displayNullable(mine.tide),
        theirsValue: _displayNullable(theirs.tide),
      ),
      ConflictField(
        key: ConflictFieldKey.weather,
        fieldName: '날씨',
        mineValue: _displayNullable(mine.weather),
        theirsValue: _displayNullable(theirs.weather),
      ),
      ConflictField(
        key: ConflictFieldKey.airTemperature,
        fieldName: '기온',
        mineValue: _displayNumber(mine.airTemperature, suffix: '℃'),
        theirsValue: _displayNumber(theirs.airTemperature, suffix: '℃'),
      ),
      ConflictField(
        key: ConflictFieldKey.waterTemperature,
        fieldName: '수온',
        mineValue: _displayNumber(mine.waterTemperature, suffix: '℃'),
        theirsValue: _displayNumber(theirs.waterTemperature, suffix: '℃'),
      ),
      ConflictField(
        key: ConflictFieldKey.catches,
        fieldName: '조과',
        mineValue: _formatCatches(mine.catches),
        theirsValue: _formatCatches(theirs.catches),
      ),
      ConflictField(
        key: ConflictFieldKey.memo,
        fieldName: '메모',
        mineValue: _displayNullable(mine.memo),
        theirsValue: _displayNullable(theirs.memo),
      ),
    ];

    final changed = candidates
        .where((field) => field.mineValue != field.theirsValue)
        .toList(growable: false);
    if (changed.isNotEmpty) {
      return changed;
    }
    return <ConflictField>[
      ConflictField(
        key: ConflictFieldKey.version,
        fieldName: '서버 버전',
        mineValue: baseVersionNo?.toString() ?? '알 수 없음',
        theirsValue: remoteVersionNo.toString(),
      ),
    ];
  }

  FishingRecord buildMergedRecord(Set<String> remoteFieldKeys) {
    final mine = localRecord;
    final theirs = remoteRecord;
    if (!canManualMerge || mine == null || theirs == null) {
      throw StateError('활성 기록끼리 충돌한 경우에만 직접 병합할 수 있습니다.');
    }

    T choose<T>(String key, T mineValue, T theirsValue) =>
        remoteFieldKeys.contains(key) ? theirsValue : mineValue;

    return FishingRecord(
      id: recordId,
      location: choose(
        ConflictFieldKey.location,
        mine.location,
        theirs.location,
      ),
      startAt: choose(ConflictFieldKey.startAt, mine.startAt, theirs.startAt),
      endAt: choose(ConflictFieldKey.endAt, mine.endAt, theirs.endAt),
      genreName: choose(
        ConflictFieldKey.genreName,
        mine.genreName,
        theirs.genreName,
      ),
      tide: choose(ConflictFieldKey.tide, mine.tide, theirs.tide),
      weather: choose(ConflictFieldKey.weather, mine.weather, theirs.weather),
      airTemperature: choose(
        ConflictFieldKey.airTemperature,
        mine.airTemperature,
        theirs.airTemperature,
      ),
      waterTemperature: choose(
        ConflictFieldKey.waterTemperature,
        mine.waterTemperature,
        theirs.waterTemperature,
      ),
      catches: choose(ConflictFieldKey.catches, mine.catches, theirs.catches),
      // Photos never leave this device and are always taken from the local
      // side of a merge.
      photos: mine.photos,
      memo: choose(ConflictFieldKey.memo, mine.memo, theirs.memo),
    );
  }

  ConflictItem copyWith({
    ConflictStatus? status,
    ConflictResolutionType? resolutionType,
    String? resolutionOutboxId,
    DateTime? resolvedAt,
    bool clearResolutionOutboxId = false,
  }) {
    return ConflictItem(
      id: id,
      ownerKey: ownerKey,
      recordId: recordId,
      outboxId: outboxId,
      localOperationType: localOperationType,
      baseVersionNo: baseVersionNo,
      remoteVersionNo: remoteVersionNo,
      remoteStatus: remoteStatus,
      localRecord: localRecord,
      remoteRecord: remoteRecord,
      occurredAt: occurredAt,
      status: status ?? this.status,
      resolutionType: resolutionType ?? this.resolutionType,
      resolutionOutboxId: clearResolutionOutboxId
          ? null
          : resolutionOutboxId ?? this.resolutionOutboxId,
      resolvedAt: resolvedAt ?? this.resolvedAt,
    );
  }

  String? get localPayloadJson =>
      localRecord == null ? null : jsonEncode(localRecord!.toJson());
  String? get remotePayloadJson =>
      remoteRecord == null ? null : jsonEncode(remoteRecord!.toJson());

  String get statusLabel => switch (status) {
    ConflictStatus.unresolved => '해결 필요',
    ConflictStatus.resolving => '해결 내용 동기화 중',
    ConflictStatus.resolved => '해결 완료',
  };

  String get resolutionLabel => switch (resolutionType) {
    ConflictResolutionType.useMine => '내 변경 적용',
    ConflictResolutionType.useTheirs => '상대 변경 적용',
    ConflictResolutionType.manualMerge => '직접 병합',
    null => '-',
  };

  static String _displayNullable(String? value) =>
      value == null || value.trim().isEmpty ? '-' : value;

  static String _displayNumber(num? value, {required String suffix}) =>
      value == null ? '-' : '$value$suffix';

  static String _formatDateTime(DateTime value) {
    String twoDigits(int number) => number.toString().padLeft(2, '0');
    return '${value.year}.${twoDigits(value.month)}.${twoDigits(value.day)} '
        '${twoDigits(value.hour)}:${twoDigits(value.minute)}';
  }

  static String _formatCatches(List<CatchRecord> catches) {
    if (catches.isEmpty) {
      return '-';
    }
    return catches
        .map((item) {
          final parts = <String>[item.speciesName];
          if (item.lengthCm != null) {
            parts.add('${item.lengthCm}cm');
          }
          if (item.weightG != null) {
            parts.add('${item.weightG}g');
          }
          return parts.join(' · ');
        })
        .join('\n');
  }
}

class ConflictField {
  final String key;
  final String fieldName;
  final String mineValue;
  final String theirsValue;

  const ConflictField({
    required this.key,
    required this.fieldName,
    required this.mineValue,
    required this.theirsValue,
  });
}
