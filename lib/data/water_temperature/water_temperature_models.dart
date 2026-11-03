import 'dart:math' as math;

import '../maps/map_location.dart';

class WaterTemperatureStation {
  const WaterTemperatureStation({
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

/// A nearby station's measured value, bound to the map's selected location.
/// This is an observation, never a forecast for the tide panel's chosen date.
class WaterTemperatureObservation {
  const WaterTemperatureObservation({
    required this.location,
    required this.station,
    required this.temperatureCelsius,
    required this.observedAt,
    required this.fetchedAt,
  });

  static const maxObservationAge = Duration(hours: 2);
  final MapLocation location;
  final WaterTemperatureStation station;
  final double temperatureCelsius;
  final DateTime observedAt;
  final DateTime fetchedAt;

  bool isUsableAt(DateTime now) {
    final age = now.toUtc().difference(observedAt.toUtc());
    return temperatureCelsius.isFinite &&
        temperatureCelsius >= -5 &&
        temperatureCelsius <= 45 &&
        !age.isNegative &&
        age <= maxObservationAge;
  }

  bool matchesLocation(MapLocation selected) =>
      selected.hasCoordinates &&
      location.hasCoordinates &&
      selected.name.trim() == location.name.trim() &&
      selected.latitude == location.latitude &&
      selected.longitude == location.longitude;

  bool appliesToRecord({
    required DateTime startAt,
    required String locationName,
    double? latitude,
    double? longitude,
    DateTime? now,
  }) {
    final current = (now ?? DateTime.now()).toUtc();
    final start = startAt.toUtc();
    final measured = observedAt.toUtc();
    final currentKst = current.add(const Duration(hours: 9));
    final startKst = start.add(const Duration(hours: 9));
    return location.hasCoordinates &&
        locationName.trim() == location.name.trim() &&
        latitude == location.latitude &&
        longitude == location.longitude &&
        isUsableAt(current) &&
        currentKst.year == startKst.year &&
        currentKst.month == startKst.month &&
        currentKst.day == startKst.day &&
        !start.isBefore(measured) &&
        start.isBefore(measured.add(const Duration(hours: 1))) &&
        !start.isAfter(current.add(const Duration(minutes: 1)));
  }
}
