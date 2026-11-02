/// KMA timestamps are always expressed in Korea Standard Time, irrespective of
/// the phone's configured time zone. Public instants remain UTC.
class KmaForecastTime {
  const KmaForecastTime._({required this.issuedAt, required this.validAt});

  static const _koreaOffset = Duration(hours: 9);

  final DateTime issuedAt;
  final DateTime validAt;

  factory KmaForecastTime.forCurrentHour(DateTime now) {
    final korea = now.toUtc().add(_koreaOffset);
    final koreaHour = DateTime.utc(
      korea.year,
      korea.month,
      korea.day,
      korea.hour,
    );
    // The previous-hour hh:30 issue covers this hour and has been available
    // since the previous hour's :45, including at the start of this hour.
    final issueHour = koreaHour.subtract(const Duration(hours: 1));
    return KmaForecastTime._(
      issuedAt: issueHour
          .add(const Duration(minutes: 30))
          .subtract(_koreaOffset),
      validAt: koreaHour.subtract(_koreaOffset),
    );
  }

  static String date(DateTime instant) {
    final korea = instant.toUtc().add(_koreaOffset);
    return '${korea.year.toString().padLeft(4, '0')}'
        '${_two(korea.month)}${_two(korea.day)}';
  }

  static String time(DateTime instant) {
    final korea = instant.toUtc().add(_koreaOffset);
    return '${_two(korea.hour)}${_two(korea.minute)}';
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
}
