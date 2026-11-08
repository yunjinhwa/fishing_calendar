import 'dart:typed_data';

import 'personal_best_record.dart';

/// A single real catch. Account IDs, email and file paths are never rendered.
class ShareRecordData {
  ShareRecordData({
    required this.recordId,
    required this.catchIndex,
    required this.speciesName,
    required this.nickname,
    required this.caughtAt,
    required this.location,
    required this.criterion,
    this.lengthCm,
    this.weightG,
    Uint8List? photoBytes,
  }) : photoBytes = photoBytes == null
           ? null
           : Uint8List.fromList(photoBytes).asUnmodifiableView();

  factory ShareRecordData.fromPersonalBest(
    PersonalBestRecord record, {
    required String nickname,
    Uint8List? photoBytes,
  }) {
    final evidence = record.selectedEvidence;
    return ShareRecordData(
      recordId: evidence.record.id,
      catchIndex: evidence.catchIndex,
      speciesName: record.speciesName,
      nickname: nickname.trim().isEmpty ? '낚시인' : nickname.trim(),
      caughtAt: evidence.record.startAt,
      location: evidence.record.location,
      criterion: record.selectedType,
      lengthCm: evidence.lengthCm,
      weightG: evidence.weightG,
      photoBytes: photoBytes,
    );
  }

  final String recordId;
  final int catchIndex;
  final String speciesName;
  final String nickname;
  final DateTime caughtAt;
  final String location;
  final PersonalBestSortType criterion;
  final double? lengthCm;
  final int? weightG;
  final Uint8List? photoBytes;
}

class ShareRecordOptions {
  const ShareRecordOptions({
    this.showNickname = true,
    this.showPhoto = true,
    this.showLength = true,
    this.showWeight = true,
    this.showDate = false,
    this.showLocation = false,
  });

  final bool showNickname;
  final bool showPhoto;
  final bool showLength;
  final bool showWeight;
  final bool showDate;
  final bool showLocation;

  ShareRecordOptions copyWith({
    bool? showNickname,
    bool? showPhoto,
    bool? showLength,
    bool? showWeight,
    bool? showDate,
    bool? showLocation,
  }) => ShareRecordOptions(
    showNickname: showNickname ?? this.showNickname,
    showPhoto: showPhoto ?? this.showPhoto,
    showLength: showLength ?? this.showLength,
    showWeight: showWeight ?? this.showWeight,
    showDate: showDate ?? this.showDate,
    showLocation: showLocation ?? this.showLocation,
  );
}
