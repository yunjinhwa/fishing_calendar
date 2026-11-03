import 'tide_models.dart';

/// A Korean lunar calendar date, including whether its month is intercalary.
class KoreanLunarDate {
  const KoreanLunarDate({
    required this.year,
    required this.month,
    required this.day,
    this.isLeapMonth = false,
  });

  final int year;
  final int month;
  final int day;
  final bool isLeapMonth;

  String get label => '음력 ${isLeapMonth ? '윤' : ''}$month.$day';

  /// Converts a Korean calendar day in 2020–2035 without network or time zones.
  ///
  /// Returns null outside 2020-01-01 through 2035-12-31. Early January can
  /// belong to the preceding lunar year, so the data starts with lunar 2019.
  static KoreanLunarDate? fromSolar(TideDay day) {
    if (day.year < 2020 || day.year > 2035) return null;

    // KASI: lunar 2019-01-01 = Gregorian 2019-02-05.
    // https://www.kasi.re.kr/kor/publication/post/newsMaterial/10397
    var remaining = DateTime.utc(
      day.year,
      day.month,
      day.day,
    ).difference(DateTime.utc(2019, 2, 5)).inDays;

    for (var index = 0; index < _yearData.length; index++) {
      final data = _yearData[index];
      final yearDays = (data >> 17) & 0x1ff;
      if (remaining >= yearDays) {
        remaining -= yearDays;
        continue;
      }

      final year = 2019 + index;
      final leapMonth = (data >> 12) & 0xf;
      for (var month = 1; month <= 12; month++) {
        final monthDays = 29 + ((data >> (12 - month)) & 1);
        if (remaining < monthDays) {
          return KoreanLunarDate(year: year, month: month, day: remaining + 1);
        }
        remaining -= monthDays;

        if (month == leapMonth) {
          final leapDays = 29 + ((data >> 16) & 1);
          if (remaining < leapDays) {
            return KoreanLunarDate(
              year: year,
              month: month,
              day: remaining + 1,
              isLeapMonth: true,
            );
          }
          remaining -= leapDays;
        }
      }
    }
    return null;
  }

  // Korean year data for lunar 2019–2035, adapted from klc 0.1.0 (MIT),
  // https://pub.dev/packages/klc/versions/0.1.0 and its go-klc source:
  // https://github.com/chunghha/go-klc/blob/main/klc.go
  // Copyright (c) 2018 usingsky(usingsky@gmail.com)
  // Copyright (c) 2022 chunghha(chunghha@users.noreply.github.com)
  // Full license: third_party/klc_LICENSE.txt.
  // Bits 0–11: regular months 12–1 (1 = 30 days; 0 = 29 days).
  // Bits 12–15: leap month (0 = none); bit 16: leap month length.
  // Bits 17–25: total lunar year days. Upper solar flags are preserved.
  static const _yearData = <int>[
    0x82c40a95, // 2019
    0xc3004b95, // 2020
    0x82c406aa, // 2021
    0x82c60ad5, // 2022
    0x830026b5, // 2023
    0xc2c404b6, // 2024
    0x83006a6e, // 2025
    0x82c60a57, // 2026
    0x82c40527, // 2027
    0xc2fe56a6, // 2028
    0x82c60d93, // 2029
    0x82c405aa, // 2030
    0x83003b6a, // 2031
    0xc2c6096d, // 2032
    0x8300b4af, // 2033
    0x82c404ae, // 2034
    0x82c40a4d, // 2035
  ];
}
