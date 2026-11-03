/// Regional defaults for the lunar-day tide names used by Badatime.
///
/// West-coast stations use the seven system; south/east-coast stations and
/// Jeju, Chuja and Ieodo use the eight system, including Wando. These defaults
/// do not represent every local tradition. Keep station choices explicit:
/// longitude alone cannot distinguish the southwestern islands.
/// Source: https://www.badatime.com/guide
enum TideConvention {
  seven,
  eight;

  String get label => this == seven ? '7물때식' : '8물때식';

  /// Returns no convention for stations outside the reviewed catalog.
  static TideConvention? forStationCode(String code) =>
      stationConventions[code];

  /// A lunar month repeats the same names on days 1–15 and 16–30.
  /// A 29-day month omits day 30; leap months use the same day-based table.
  String nameForLunarDay(int lunarDay) {
    if (lunarDay < 1 || lunarDay > 30) {
      throw RangeError.range(lunarDay, 1, 30, 'lunarDay');
    }
    final names = this == seven ? _sevenNames : _eightNames;
    return names[(lunarDay - 1) % 15];
  }

  static const _sevenNames = <String>[
    '7물',
    '8물',
    '9물',
    '10물',
    '11물',
    '12물',
    '13물',
    '조금',
    '무시',
    '1물',
    '2물',
    '3물',
    '4물',
    '5물',
    '6물',
  ];

  static const _eightNames = <String>[
    '8물',
    '9물',
    '10물',
    '11물',
    '12물',
    '13물',
    '14물',
    '조금',
    '1물',
    '2물',
    '3물',
    '4물',
    '5물',
    '6물',
    '7물',
  ];

  /// The 84 reviewed KHOA forecast stations in khoa_tide_stations.dart.
  static const stationConventions = <String, TideConvention>{
    'DT_0001': seven, // 인천
    'DT_0002': seven, // 평택
    'DT_0003': seven, // 영광
    'DT_0004': eight, // 제주
    'DT_0005': eight, // 부산
    'DT_0006': eight, // 묵호
    'DT_0007': seven, // 목포
    'DT_0008': seven, // 안산
    'DT_0010': eight, // 서귀포
    'DT_0011': eight, // 후포
    'DT_0012': eight, // 속초
    'DT_0013': eight, // 울릉도
    'DT_0014': eight, // 통영
    'DT_0016': eight, // 여수
    'DT_0017': seven, // 대산
    'DT_0018': seven, // 군산
    'DT_0020': eight, // 울산
    'DT_0021': eight, // 추자도
    'DT_0022': eight, // 성산포
    'DT_0023': eight, // 모슬포
    'DT_0024': seven, // 장항
    'DT_0025': seven, // 보령
    'DT_0026': eight, // 고흥발포
    'DT_0027': eight, // 완도
    'DT_0028': seven, // 진도
    'DT_0029': eight, // 거제도
    'DT_0031': eight, // 거문도
    'DT_0032': seven, // 강화대교
    'DT_0035': seven, // 흑산도
    'DT_0036': seven, // 대청도
    'DT_0037': seven, // 어청도
    'DT_0038': seven, // 굴업도
    'DT_0039': eight, // 왕돌초
    'DT_0041': seven, // 복사초
    'DT_0043': seven, // 영흥도
    'DT_0044': seven, // 영종대교
    'DT_0046': eight, // 쌍정초
    'DT_0047': eight, // 도농탄
    'DT_0048': eight, // 속초등표
    'DT_0049': eight, // 광양
    'DT_0050': seven, // 태안
    'DT_0051': seven, // 서천마량
    'DT_0052': seven, // 인천송도
    'DT_0056': eight, // 부산항신항
    'DT_0057': eight, // 동해항
    'DT_0058': seven, // 경인항
    'DT_0061': eight, // 삼천포
    'DT_0062': eight, // 마산
    'DT_0063': eight, // 가덕도
    'DT_0065': seven, // 덕적도
    'DT_0067': seven, // 안흥
    'DT_0068': seven, // 위도
    'DT_0091': eight, // 포항
    'DT_0903': eight, // 독도
    'IE_0060': eight, // 이어도
    'SO_0326': eight, // 미조항
    'SO_0537': seven, // 벽파진
    'SO_0538': seven, // 안마도
    'SO_0539': seven, // 강화외포
    'SO_0540': eight, // 호산항
    'SO_0547': seven, // 말도
    'SO_0548': seven, // 우이도
    'SO_0549': eight, // 초도
    'SO_0551': eight, // 여서도
    'SO_0552': eight, // 고현항
    'SO_0553': eight, // 해운대
    'SO_0554': seven, // 영종왕산
    'SO_0555': seven, // 서망항
    'SO_0562': seven, // 승봉도
    'SO_0563': seven, // 울도항
    'SO_0564': seven, // 국화도
    'SO_0565': seven, // 무안도리(향화도)
    'SO_0566': seven, // 신안송공
    'SO_0568': eight, // 백야도
    'SO_0569': eight, // 남포항
    'SO_0570': eight, // 광암항
    'SO_0571': eight, // 외포항
    'SO_0572': eight, // 읍천항
    'SO_0573': eight, // 양포항
    'SO_0574': seven, // 백사장항
    'SO_0576': seven, // 시하도(화봉리)
    'SO_0577': seven, // 가거도
    'SO_0578': eight, // 소매물도
    'SO_0581': eight, // 강양항
  };
}
