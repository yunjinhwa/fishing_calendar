import 'korean_lunar_date.dart';
import 'tide_convention.dart';
import 'tide_models.dart';

/// A conventional lunar-day name, independent of the high/low tide prediction.
class TideName {
  const TideName._({
    required this.day,
    required this.station,
    required this.lunarDate,
    required this.convention,
  });

  final TideDay day;
  final TideStation station;
  final KoreanLunarDate lunarDate;
  final TideConvention convention;

  String get label => convention.nameForLunarDay(lunarDate.day);

  static TideName? calculate({
    required TideDay day,
    required TideStation station,
  }) {
    final convention = TideConvention.forStationCode(station.code);
    if (convention == null) return null;
    final lunarDate = KoreanLunarDate.fromSolar(day);
    if (lunarDate == null) return null;
    return TideName._(
      day: day,
      station: station,
      lunarDate: lunarDate,
      convention: convention,
    );
  }
}
