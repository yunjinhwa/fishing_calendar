import 'dart:math' as math;

import '../maps/map_location.dart';
import '../water_temperature/water_temperature_models.dart';

DateTime historicalHour(DateTime instant) {
  final utc = instant.toUtc();
  return DateTime.utc(utc.year, utc.month, utc.day, utc.hour);
}

bool historicalLocationMatches(
  MapLocation location, {
  required String locationName,
  double? latitude,
  double? longitude,
}) =>
    location.hasCoordinates &&
    location.name.trim() == locationName.trim() &&
    latitude == location.latitude &&
    longitude == location.longitude;

class HistoricalWeatherStation {
  const HistoricalWeatherStation({
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

class HistoricalWeatherObservation {
  const HistoricalWeatherObservation({
    required this.location,
    required this.station,
    required this.requestedAt,
    required this.observedAt,
    required this.fetchedAt,
    this.weather,
    this.airTemperature,
  });

  final MapLocation location;
  final HistoricalWeatherStation station;
  final DateTime requestedAt;
  final DateTime observedAt;
  final DateTime fetchedAt;
  final String? weather;
  final double? airTemperature;

  bool get hasValidData =>
      weather?.trim().isNotEmpty == true ||
      (airTemperature?.isFinite == true && airTemperature!.abs() < 100);

  bool matchesSelection(MapLocation selected, DateTime target) =>
      hasValidData &&
      historicalLocationMatches(
        location,
        locationName: selected.name,
        latitude: selected.latitude,
        longitude: selected.longitude,
      ) &&
      historicalHour(target) == historicalHour(requestedAt) &&
      observedAt.toUtc() == historicalHour(requestedAt);

  bool appliesToRecord({
    required DateTime startAt,
    required String locationName,
    double? latitude,
    double? longitude,
  }) =>
      hasValidData &&
      historicalLocationMatches(
        location,
        locationName: locationName,
        latitude: latitude,
        longitude: longitude,
      ) &&
      observedAt.toUtc() == historicalHour(requestedAt) &&
      historicalHour(startAt) == historicalHour(requestedAt);
}

class HistoricalWaterTemperatureObservation {
  const HistoricalWaterTemperatureObservation({
    required this.location,
    required this.station,
    required this.requestedAt,
    required this.observedAt,
    required this.fetchedAt,
    required this.temperatureCelsius,
  });

  final MapLocation location;
  final WaterTemperatureStation station;
  final DateTime requestedAt;
  final DateTime observedAt;
  final DateTime fetchedAt;
  final double temperatureCelsius;

  bool get hasValidData {
    final age = requestedAt.toUtc().difference(observedAt.toUtc());
    final requestedKst = requestedAt.toUtc().add(const Duration(hours: 9));
    final observedKst = observedAt.toUtc().add(const Duration(hours: 9));
    return temperatureCelsius.isFinite &&
        temperatureCelsius >= -5 &&
        temperatureCelsius <= 45 &&
        !age.isNegative &&
        age < const Duration(hours: 1) &&
        requestedKst.year == observedKst.year &&
        requestedKst.month == observedKst.month &&
        requestedKst.day == observedKst.day;
  }

  bool matchesSelection(MapLocation selected, DateTime target) =>
      hasValidData &&
      historicalLocationMatches(
        location,
        locationName: selected.name,
        latitude: selected.latitude,
        longitude: selected.longitude,
      ) &&
      target.toUtc() == requestedAt.toUtc();

  bool appliesToRecord({
    required DateTime startAt,
    required String locationName,
    double? latitude,
    double? longitude,
  }) {
    final start = startAt.toUtc();
    return hasValidData &&
        historicalLocationMatches(
          location,
          locationName: locationName,
          latitude: latitude,
          longitude: longitude,
        ) &&
        historicalHour(start) == historicalHour(requestedAt) &&
        !start.isBefore(observedAt.toUtc()) &&
        start.difference(observedAt.toUtc()) < const Duration(hours: 1);
  }
}
