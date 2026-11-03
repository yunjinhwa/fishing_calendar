import 'package:fishing_build/data/tides/khoa_tide_stations.dart';
import 'package:fishing_build/data/tides/tide_convention.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every reviewed station has an explicit convention', () {
    expect(TideConvention.stationConventions, hasLength(84));
    expect(
      TideConvention.stationConventions.keys,
      unorderedEquals(khoaTideStations.map((station) => station.code)),
    );
    expect(TideConvention.forStationCode('UNKNOWN'), isNull);
    expect(TideConvention.forStationCode('DT_0019'), isNull);
  });

  test('coastal and offshore defaults follow the reviewed station choices', () {
    const expected = <String, TideConvention>{
      'DT_0001': TideConvention.seven, // 인천
      'DT_0018': TideConvention.seven, // 군산
      'DT_0007': TideConvention.seven, // 목포
      'DT_0028': TideConvention.seven, // 진도
      'DT_0041': TideConvention.seven, // 복사초
      'SO_0577': TideConvention.seven, // 가거도
      'DT_0027': TideConvention.eight, // 완도
      'SO_0551': TideConvention.eight, // 여서도
      'DT_0016': TideConvention.eight, // 여수
      'DT_0063': TideConvention.eight, // 가덕도
      'DT_0012': TideConvention.eight, // 속초
      'DT_0903': TideConvention.eight, // 독도
      'DT_0004': TideConvention.eight, // 제주
      'DT_0023': TideConvention.eight, // 모슬포
      'DT_0021': TideConvention.eight, // 추자도
      'IE_0060': TideConvention.eight, // 이어도
    };
    for (final entry in expected.entries) {
      expect(
        TideConvention.forStationCode(entry.key),
        entry.value,
        reason: entry.key,
      );
    }
    expect(TideConvention.seven.label, '7물때식');
    expect(TideConvention.eight.label, '8물때식');
  });

  test('lunar-day names include the regional neap-day distinction', () {
    const expected = <int, (String, String)>{
      1: ('7물', '8물'),
      7: ('13물', '14물'),
      8: ('조금', '조금'),
      9: ('무시', '1물'),
      10: ('1물', '2물'),
      15: ('6물', '7물'),
      16: ('7물', '8물'),
      22: ('13물', '14물'),
      23: ('조금', '조금'),
      24: ('무시', '1물'),
      29: ('5물', '6물'),
      30: ('6물', '7물'),
    };
    for (final entry in expected.entries) {
      expect(
        TideConvention.seven.nameForLunarDay(entry.key),
        entry.value.$1,
        reason: '7물때식 음력 ${entry.key}일',
      );
      expect(
        TideConvention.eight.nameForLunarDay(entry.key),
        entry.value.$2,
        reason: '8물때식 음력 ${entry.key}일',
      );
    }
  });

  test('lunar-day names reject dates outside a lunar month', () {
    for (final convention in TideConvention.values) {
      expect(() => convention.nameForLunarDay(0), throwsRangeError);
      expect(() => convention.nameForLunarDay(31), throwsRangeError);
    }
  });
}
