import 'map_location.dart';

enum CurrentLocationFailure {
  denied,
  deniedForever,
  serviceDisabled,
  timedOut,
  unavailable,
}

class CurrentLocationException implements Exception {
  const CurrentLocationException(this.reason);
  final CurrentLocationFailure reason;
}

abstract interface class CurrentLocationGateway {
  Future<MapLocation> currentLocation({bool requestPermission = true});
  Future<bool> openAppSettings();
  Future<bool> openLocationSettings();
}
