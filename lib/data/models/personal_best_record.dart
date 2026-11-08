import 'fishing_record.dart';

class PersonalBestEvidence {
  const PersonalBestEvidence({
    required this.record,
    required this.catchRecord,
    required this.catchIndex,
  });
  final FishingRecord record;
  final CatchRecord catchRecord;
  final int catchIndex;

  double? get lengthCm {
    final value = catchRecord.lengthCm;
    return value != null && value.isFinite && value > 0 ? value : null;
  }

  int? get weightG {
    final value = catchRecord.weightG;
    return value != null && value > 0 ? value : null;
  }
}

class PersonalBestRecord {
  final String speciesName;

  /// The two maxima may belong to different catches, even within one trip.
  final PersonalBestEvidence? lengthBest;
  final PersonalBestEvidence? weightBest;
  final PersonalBestSortType sortType;

  const PersonalBestRecord({
    required this.speciesName,
    required this.lengthBest,
    required this.weightBest,
    this.sortType = PersonalBestSortType.length,
  }) : assert(lengthBest != null || weightBest != null);

  double? get bestLengthCm => lengthBest?.lengthCm;
  int? get bestWeightG => weightBest?.weightG;

  PersonalBestSortType get selectedType {
    if (sortType == PersonalBestSortType.length && lengthBest != null) {
      return PersonalBestSortType.length;
    }
    if (sortType == PersonalBestSortType.weight && weightBest != null) {
      return PersonalBestSortType.weight;
    }
    return lengthBest != null
        ? PersonalBestSortType.length
        : PersonalBestSortType.weight;
  }

  PersonalBestEvidence get selectedEvidence =>
      selectedType == PersonalBestSortType.length ? lengthBest! : weightBest!;

  /// Trip metadata and photos for the selected criterion only.
  FishingRecord get sourceRecord => selectedEvidence.record;

  String get lengthText {
    if (bestLengthCm == null) {
      return '-';
    }

    return '${bestLengthCm!.toStringAsFixed(1)} cm';
  }

  String get weightText {
    if (bestWeightG == null) {
      return '-';
    }

    return '$bestWeightG g';
  }

  String get locationText {
    return sourceRecord.location;
  }

  DateTime get caughtAt {
    return sourceRecord.startAt;
  }
}

enum PersonalBestSortType { length, weight, name }
