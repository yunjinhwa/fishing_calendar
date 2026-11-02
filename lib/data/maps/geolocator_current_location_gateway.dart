import 'dart:async';

import 'package:geolocator/geolocator.dart';

import 'current_location_gateway.dart';
import 'map_location.dart';

/// Obtains one foreground position, optionally using only an existing grant.
class GeolocatorCurrentLocationGateway implements CurrentLocationGateway {
  GeolocatorCurrentLocationGateway({
    GeolocatorPlatform? platform,
    this.timeout = const Duration(seconds: 12),
  }) : _platform = platform ?? GeolocatorPlatform.instance;

  final GeolocatorPlatform _platform;
  final Duration timeout;

  @override
  Future<MapLocation> currentLocation({bool requestPermission = true}) async {
    try {
      if (!await _platform.isLocationServiceEnabled()) {
        throw const CurrentLocationException(
          CurrentLocationFailure.serviceDisabled,
        );
      }
      var permission = await _platform.checkPermission();
      if (permission == LocationPermission.denied && requestPermission) {
        permission = await _platform.requestPermission();
      }
      if (permission == LocationPermission.deniedForever) {
        throw const CurrentLocationException(
          CurrentLocationFailure.deniedForever,
        );
      }
      if (permission == LocationPermission.denied) {
        throw const CurrentLocationException(CurrentLocationFailure.denied);
      }
      if (permission != LocationPermission.whileInUse &&
          permission != LocationPermission.always) {
        throw const CurrentLocationException(
          CurrentLocationFailure.unavailable,
        );
      }
      final position = await _platform
          .getCurrentPosition(
            locationSettings: LocationSettings(
              accuracy: LocationAccuracy.high,
              timeLimit: timeout,
            ),
          )
          .timeout(timeout);
      return MapLocation(
        name: '현재 위치',
        latitude: position.latitude,
        longitude: position.longitude,
      );
    } on CurrentLocationException {
      rethrow;
    } on PermissionDeniedException {
      throw const CurrentLocationException(CurrentLocationFailure.denied);
    } on LocationServiceDisabledException {
      throw const CurrentLocationException(
        CurrentLocationFailure.serviceDisabled,
      );
    } on TimeoutException {
      throw const CurrentLocationException(CurrentLocationFailure.timedOut);
    } on Object {
      // Includes unavailable plugins and malformed platform coordinates.
      throw const CurrentLocationException(CurrentLocationFailure.unavailable);
    }
  }

  @override
  Future<bool> openAppSettings() async {
    try {
      return await _platform.openAppSettings();
    } on Object {
      return false;
    }
  }

  @override
  Future<bool> openLocationSettings() async {
    try {
      return await _platform.openLocationSettings();
    } on Object {
      return false;
    }
  }
}
