import '../maps/map_location.dart';
import '../models/external_data.dart';

abstract interface class ExternalDataService {
  Future<ExternalData> fetchCurrentData({
    required MapLocation location,
    bool forceRefresh = false,
  });
}

enum ExternalDataFailure {
  configuration,
  coordinatesRequired,
  unsupportedLocation,
  noData,
  unauthorized,
  rateLimited,
  timedOut,
  network,
  invalidResponse,
}

class ExternalDataException implements Exception {
  const ExternalDataException(this.reason);
  final ExternalDataFailure reason;

  String get message => switch (reason) {
    ExternalDataFailure.configuration => '날씨 조회를 준비 중입니다. 기록에서는 직접 입력할 수 있습니다.',
    ExternalDataFailure.coordinatesRequired => '날씨를 조회하려면 지도에서 위치를 선택해 주세요.',
    ExternalDataFailure.unsupportedLocation =>
      '이 위치는 날씨 조회 지원 범위 밖입니다. 직접 입력해 주세요.',
    ExternalDataFailure.noData =>
      '해당 위치의 날씨 정보가 없습니다. 잠시 후 다시 조회하거나 직접 입력해 주세요.',
    ExternalDataFailure.unauthorized => '날씨 서비스 인증을 확인할 수 없습니다. 직접 입력해 주세요.',
    ExternalDataFailure.rateLimited => '날씨 조회가 많아 잠시 쉬고 있습니다. 잠시 후 다시 시도해 주세요.',
    ExternalDataFailure.timedOut => '날씨 조회가 지연되고 있습니다. 다시 조회하거나 직접 입력해 주세요.',
    ExternalDataFailure.network => '날씨를 가져오지 못했습니다. 인터넷 연결을 확인해 주세요.',
    ExternalDataFailure.invalidResponse =>
      '날씨 정보를 읽지 못했습니다. 다시 조회하거나 직접 입력해 주세요.',
  };

  @override
  String toString() => 'ExternalDataException(${reason.name})';
}
