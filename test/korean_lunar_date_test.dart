import 'package:fishing_build/data/tides/korean_lunar_date.dart';
import 'package:fishing_build/data/tides/tide_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  void expectLunar(
    TideDay solar,
    int year,
    int month,
    int day, {
    bool leap = false,
  }) {
    final lunar = KoreanLunarDate.fromSolar(solar);
    expect(lunar, isNotNull, reason: solar.label);
    expect(
      [lunar!.year, lunar.month, lunar.day, lunar.isLeapMonth],
      [year, month, day, leap],
      reason: solar.label,
    );
  }

  test('KASI current day is Korean lunar September 23', () {
    // https://astro.kasi.re.kr/life/pageView/5 (2026-11 calendar)
    expectLunar(TideDay(2026, 11, 2), 2026, 9, 23);
    expect(KoreanLunarDate.fromSolar(TideDay(2026, 11, 2))!.label, '음력 9.23');
  });

  test('KASI leap February follows regular February and has 29 days', () {
    // https://astro.kasi.re.kr/kor/life/post/calendarData?search_year=2023
    expectLunar(TideDay(2023, 3, 21), 2023, 2, 30);
    expectLunar(TideDay(2023, 3, 22), 2023, 2, 1, leap: true);
    expectLunar(TideDay(2023, 4, 19), 2023, 2, 29, leap: true);
    expectLunar(TideDay(2023, 4, 20), 2023, 3, 1);
    expect(KoreanLunarDate.fromSolar(TideDay(2023, 3, 22))!.label, '음력 윤2.1');
  });

  test('KASI Seollal changes lunar year and handles Gregorian leap day', () {
    // https://astro.kasi.re.kr/kor/life/post/calendarData?search_year=2024
    expectLunar(TideDay(2024, 2, 9), 2023, 12, 30);
    expectLunar(TideDay(2024, 2, 10), 2024, 1, 1);
    expectLunar(TideDay(2024, 2, 29), 2024, 1, 20);
    expectLunar(TideDay(2024, 3, 9), 2024, 1, 29);
    expectLunar(TideDay(2024, 3, 10), 2024, 2, 1);
  });

  test('Korean 2027 new year differs from the Chinese calendar', () {
    // Korean lunar 1/1 is February 7:
    // https://astro.kasi.re.kr/kor/life/post/calendarData?search_year=2027
    // HKO Chinese lunar 1/1 is February 6; a generic Chinese table fails here:
    // https://my.weather.gov.hk/en/gts/time/calendar/pdf/files/2027e.pdf
    expectLunar(TideDay(2027, 2, 6), 2026, 12, 30);
    expectLunar(TideDay(2027, 2, 7), 2027, 1, 1);
  });

  test(
    'supported solar range includes both endpoints and prior lunar year',
    () {
      expectLunar(TideDay(2020, 1, 1), 2019, 12, 7);
      expectLunar(TideDay(2020, 1, 24), 2019, 12, 30);
      expectLunar(TideDay(2020, 1, 25), 2020, 1, 1);
      expectLunar(TideDay(2035, 12, 31), 2035, 12, 3);
      expect(KoreanLunarDate.fromSolar(TideDay(2019, 12, 31)), isNull);
      expect(KoreanLunarDate.fromSolar(TideDay(2036, 1, 1)), isNull);
      expect(KoreanLunarDate.fromSolar(TideDay(1900, 1, 1)), isNull);
      expect(KoreanLunarDate.fromSolar(TideDay(2100, 1, 1)), isNull);
    },
  );
}
