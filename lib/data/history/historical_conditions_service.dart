import '../maps/map_location.dart';
import 'historical_conditions.dart';

abstract interface class HistoricalWeatherService {
  Future<HistoricalWeatherObservation> fetchAt({
    required MapLocation location,
    required DateTime requestedAt,
    bool forceRefresh = false,
  });
}

abstract interface class HistoricalWaterTemperatureService {
  Future<HistoricalWaterTemperatureObservation> fetchAt({
    required MapLocation location,
    required DateTime requestedAt,
    bool forceRefresh = false,
  });
}

enum HistoricalDataFailure {
  configuration,
  coordinatesRequired,
  unsupportedLocation,
  unsupportedDate,
  noData,
  unauthorized,
  rateLimited,
  timedOut,
  network,
  invalidResponse,
}

class HistoricalDataException implements Exception {
  const HistoricalDataException(this.reason);
  final HistoricalDataFailure reason;

  @override
  String toString() => 'HistoricalDataException(${reason.name})';
}
