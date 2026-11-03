import '../maps/map_location.dart';
import 'water_temperature_models.dart';

abstract interface class WaterTemperatureService {
  Future<WaterTemperatureObservation> fetchCurrentData({
    required MapLocation location,
    bool forceRefresh = false,
  });
}

enum WaterTemperatureFailure {
  configuration,
  coordinatesRequired,
  unsupportedLocation,
  noData,
  unauthorized,
  rateLimited,
  timedOut,
  network,
  invalidResponse,
}

class WaterTemperatureException implements Exception {
  const WaterTemperatureException(this.reason);
  final WaterTemperatureFailure reason;

  @override
  String toString() => 'WaterTemperatureException(${reason.name})';
}
