import 'fishing_record.dart';

class PersonalBestRecord {
  final String speciesName;
  final double? bestLengthCm;
  final int? bestWeightG;
  final FishingRecord sourceRecord;

  const PersonalBestRecord({
    required this.speciesName,
    required this.bestLengthCm,
    required this.bestWeightG,
    required this.sourceRecord,
  });

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

enum PersonalBestSortType {
  length,
  weight,
}