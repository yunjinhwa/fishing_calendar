import 'dart:math' as math;

import '../maps/map_location.dart';

class TideDay {
  TideDay(this.year, this.month, this.day) {
    final date = DateTime.utc(year, month, day);
    if (date.year != year || date.month != month || date.day != day) {
      throw ArgumentError('Invalid tide date');
    }
  }

  factory TideDay.fromInstant(DateTime instant) {
    final kst = instant.toUtc().add(const Duration(hours: 9));
    return TideDay(kst.year, kst.month, kst.day);
  }

  factory TideDay.fromCalendar(DateTime date) =>
      TideDay(date.year, date.month, date.day);

  final int year;
  final int month;
  final int day;
  DateTime get calendarDate => DateTime(year, month, day);
  String get apiDate =>
      '${year.toString().padLeft(4, '0')}'
      '${month.toString().padLeft(2, '0')}${day.toString().padLeft(2, '0')}';
  String get label =>
      '$year.${month.toString().padLeft(2, '0')}.'
      '${day.toString().padLeft(2, '0')}';

  @override
  bool operator ==(Object other) =>
      other is TideDay &&
      year == other.year &&
      month == other.month &&
      day == other.day;
  @override
  int get hashCode => Object.hash(year, month, day);
}

class TideStation {
  const TideStation({
    required this.code,
    required this.name,
    required this.latitude,
    required this.longitude,
  });

  final String code;
  final String name;
  final double latitude;
  final double longitude;

  double distanceKmTo(double latitude, double longitude) {
    const radians = math.pi / 180;
    final dLat = (latitude - this.latitude) * radians;
    final dLon = (longitude - this.longitude) * radians;
    final a =
        math.pow(math.sin(dLat / 2), 2) +
        math.cos(this.latitude * radians) *
            math.cos(latitude * radians) *
            math.pow(math.sin(dLon / 2), 2);
    return 6371.0088 * 2 * math.asin(math.sqrt(a.clamp(0.0, 1.0)));
  }
}

enum TideEventKind { high, low }

class TideEvent {
  const TideEvent({
    required this.at,
    required this.heightCm,
    required this.kind,
  });
  final DateTime at;
  final double heightCm;
  final TideEventKind kind;
}

class TideForecast {
  TideForecast({
    required this.station,
    required this.day,
    required List<TideEvent> events,
    required this.fetchedAt,
    this.sourceName = '국립해양조사원 조석예보',
  }) : events = List.unmodifiable(events);

  final TideStation station;
  final TideDay day;
  final List<TideEvent> events;
  final DateTime fetchedAt;
  final String sourceName;
}

class TideRecordReference {
  const TideRecordReference({required this.location, required this.forecast});
  final MapLocation location;
  final TideForecast forecast;

  bool appliesToRecord({
    required DateTime startAt,
    required String locationName,
    double? latitude,
    double? longitude,
  }) =>
      location.hasCoordinates &&
      TideDay.fromInstant(startAt) == forecast.day &&
      locationName.trim() == location.name &&
      latitude == location.latitude &&
      longitude == location.longitude;
}
