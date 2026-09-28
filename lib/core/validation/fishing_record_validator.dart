import '../../data/models/fishing_record.dart';

class FishingRecordValidator {
  FishingRecordValidator._();

  // Outbox IDs include the record ID plus a timestamp/prefix and are capped at
  // 300 characters by the Firestore rules.
  static const int maxDocumentIdLength = 200;
  static const int maxLocationLength = 200;
  static const int maxGenreNameLength = 100;
  static const int maxTideLength = 100;
  static const int maxWeatherLength = 100;
  static const int maxCatchCount = 100;
  static const int maxSpeciesNameLength = 100;
  static const int maxMemoLength = 5000;

  static String? validate(FishingRecord record) {
    if (record.id.trim().isEmpty ||
        record.id.contains('/') ||
        record.id.length > maxDocumentIdLength) {
      return '기록 ID 형식이 올바르지 않습니다.';
    }
    if (record.location.trim().isEmpty) {
      return '위치를 입력하세요.';
    }
    if (record.location.length > maxLocationLength) {
      return '위치는 $maxLocationLength자 이하로 입력하세요.';
    }
    if (!record.startAt.isBefore(record.endAt)) {
      return '종료 시간은 시작 시간보다 늦어야 합니다.';
    }
    if (record.genreName.trim().isEmpty) {
      return '낚시 장르를 선택하세요.';
    }
    if (record.genreName.length > maxGenreNameLength) {
      return '낚시 장르는 $maxGenreNameLength자 이하로 입력하세요.';
    }
    if (record.tide != null && record.tide!.length > maxTideLength) {
      return '물때는 $maxTideLength자 이하로 입력하세요.';
    }
    if (record.weather != null && record.weather!.length > maxWeatherLength) {
      return '날씨는 $maxWeatherLength자 이하로 입력하세요.';
    }
    if (!_isFinite(record.airTemperature)) {
      return '기온은 유한한 숫자로 입력하세요.';
    }
    if (!_isFinite(record.waterTemperature)) {
      return '수온은 유한한 숫자로 입력하세요.';
    }
    if (record.catches.length > maxCatchCount) {
      return '조과는 최대 $maxCatchCount개까지 입력할 수 있습니다.';
    }
    for (var index = 0; index < record.catches.length; index++) {
      final catchRecord = record.catches[index];
      if (catchRecord.speciesName.trim().isEmpty) {
        return '조과 ${index + 1}의 어종을 입력하세요.';
      }
      if (catchRecord.speciesName.length > maxSpeciesNameLength) {
        return '조과 ${index + 1}의 어종은 '
            '$maxSpeciesNameLength자 이하로 입력하세요.';
      }
      final length = catchRecord.lengthCm;
      if (length != null && (!length.isFinite || length < 0)) {
        return '조과 ${index + 1}의 크기는 0 이상의 유한한 숫자로 입력하세요.';
      }
      final weight = catchRecord.weightG;
      if (weight != null && weight < 0) {
        return '조과 ${index + 1}의 무게는 0 이상의 정수(g)로 입력하세요.';
      }
    }
    final memo = record.memo;
    if (memo != null && memo.length > maxMemoLength) {
      return '메모는 $maxMemoLength자 이하로 입력하세요.';
    }
    return null;
  }

  static bool _isFinite(double? value) => value == null || value.isFinite;
}
