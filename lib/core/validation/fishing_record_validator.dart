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
  static const int maxPhotoCount = 10;
  static const int maxPhotoIdLength = 100;
  static const int maxPhotoBytes = 10 * 1024 * 1024;
  static const Set<String> allowedPhotoContentTypes = <String>{
    'image/jpeg',
    'image/png',
    'image/webp',
  };

  static final RegExp _photoIdPattern = RegExp(r'^[A-Za-z0-9_-]+$');
  static final RegExp _photoChecksumPattern = RegExp(r'^[0-9a-f]{64}$');

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
    if (record.photos.length > maxPhotoCount) {
      return '사진은 최대 $maxPhotoCount장까지 첨부할 수 있습니다.';
    }
    final photoIds = <String>{};
    for (var index = 0; index < record.photos.length; index++) {
      final photo = record.photos[index];
      final photoNumber = index + 1;
      if (photo.id.isEmpty ||
          photo.id.length > maxPhotoIdLength ||
          !_photoIdPattern.hasMatch(photo.id)) {
        return '사진 $photoNumber의 ID 형식이 올바르지 않습니다.';
      }
      if (!photoIds.add(photo.id)) {
        return '같은 사진 ID를 중복해서 사용할 수 없습니다.';
      }

      final localPath = photo.localPath?.trim();
      if (localPath == null || localPath.isEmpty) {
        return '사진 $photoNumber의 파일 경로가 없습니다.';
      }

      final contentType = photo.contentType?.trim().toLowerCase();
      final sizeBytes = photo.sizeBytes;
      final checksum = photo.checksum?.trim();
      final hasAnyMetadata =
          contentType != null || sizeBytes != null || checksum != null;
      final hasAllMetadata =
          contentType != null && sizeBytes != null && checksum != null;
      if (hasAnyMetadata && !hasAllMetadata) {
        return '사진 $photoNumber의 파일 정보가 완전하지 않습니다.';
      }
      if (contentType != null &&
          !allowedPhotoContentTypes.contains(contentType)) {
        return '사진은 JPEG, PNG, WebP 형식만 사용할 수 있습니다.';
      }
      if (sizeBytes != null && (sizeBytes < 1 || sizeBytes > maxPhotoBytes)) {
        return '사진은 비어 있지 않은 10 MiB 이하 파일만 사용할 수 있습니다.';
      }
      if (checksum != null && !_photoChecksumPattern.hasMatch(checksum)) {
        return '사진 $photoNumber의 체크섬 형식이 올바르지 않습니다.';
      }
    }
    return null;
  }

  static bool _isFinite(double? value) => value == null || value.isFinite;
}
