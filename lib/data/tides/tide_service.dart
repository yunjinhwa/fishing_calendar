import 'tide_models.dart';

abstract interface class TideService {
  Future<TideForecast> fetchForecast({
    required TideStation station,
    required TideDay day,
    bool forceRefresh = false,
  });
}

enum TideFailure {
  configuration,
  noData,
  invalidResponse,
  unauthorized,
  rateLimited,
  timedOut,
  network,
  unsupportedStation,
  unsupportedDate,
}

class TideException implements Exception {
  const TideException(this.reason);
  final TideFailure reason;
  String get message => switch (reason) {
    TideFailure.configuration => '조석 조회를 준비 중입니다. 만조·간조 예보는 준비 후 표시됩니다.',
    TideFailure.noData => '선택한 지점·날짜의 조석 예보가 없습니다. 다른 지점이나 날짜를 선택해 주세요.',
    TideFailure.invalidResponse => '조석 정보를 읽지 못했습니다. 잠시 후 다시 조회해 주세요.',
    TideFailure.unauthorized => '조석 서비스 인증을 확인할 수 없습니다. 만조·간조 예보를 조회하지 못했습니다.',
    TideFailure.rateLimited => '조석 조회가 많아 잠시 쉬고 있습니다. 잠시 후 다시 시도해 주세요.',
    TideFailure.timedOut => '조석 조회가 지연되고 있습니다. 다시 조회해 주세요.',
    TideFailure.network => '조석 정보를 가져오지 못했습니다. 인터넷 연결을 확인해 주세요.',
    TideFailure.unsupportedStation => '선택한 예보 지점을 조회할 수 없습니다. 다른 지점을 선택해 주세요.',
    TideFailure.unsupportedDate => '선택한 날짜는 조회할 수 없습니다. 다른 날짜를 선택해 주세요.',
  };
  @override
  String toString() => 'TideException(${reason.name})';
}
