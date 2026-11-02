import 'dart:async';

import 'package:fishing_build/data/maps/current_location_gateway.dart';
import 'package:fishing_build/data/maps/geolocator_current_location_gateway.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

void main() {
  late _LocationPlatform platform;
  late GeolocatorCurrentLocationGateway gateway;

  setUp(() {
    platform = _LocationPlatform();
    gateway = GeolocatorCurrentLocationGateway(platform: platform);
  });

  test('construction never requests permission or a location', () {
    expect(platform.calls, isEmpty);
    expect(gateway.timeout, const Duration(seconds: 12));
  });

  test(
    'an existing foreground grant obtains one precise coordinate pair',
    () async {
      final result = await gateway.currentLocation();

      expect(result.name, '현재 위치');
      expect(result.latitude, 35.1796);
      expect(result.longitude, 129.0756);
      expect(platform.calls, ['service', 'permission', 'position']);
      expect(platform.settings!.accuracy, LocationAccuracy.high);
      expect(platform.settings!.timeLimit, const Duration(seconds: 12));
    },
  );

  test('an existing always grant does not ask for new permissions', () async {
    platform.permission = LocationPermission.always;
    await gateway.currentLocation();
    expect(platform.calls, ['service', 'permission', 'position']);
  });

  for (final permission in [
    LocationPermission.whileInUse,
    LocationPermission.always,
  ]) {
    test(
      'automatic location uses an existing ${permission.name} grant',
      () async {
        platform.permission = permission;

        final result = await gateway.currentLocation(requestPermission: false);

        expect(result.latitude, 35.1796);
        expect(result.longitude, 129.0756);
        expect(platform.calls, ['service', 'permission', 'position']);
      },
    );
  }

  for (final (permission, failure) in [
    (LocationPermission.denied, CurrentLocationFailure.denied),
    (LocationPermission.deniedForever, CurrentLocationFailure.deniedForever),
    (LocationPermission.unableToDetermine, CurrentLocationFailure.unavailable),
  ]) {
    test('automatic location never prompts for ${permission.name}', () async {
      platform.permission = permission;
      platform.requestResult = LocationPermission.whileInUse;

      await expectLater(
        gateway.currentLocation(requestPermission: false),
        _failure(failure),
      );

      expect(platform.calls, ['service', 'permission']);
    });
  }

  test(
    'automatic location does not read sensors with services disabled',
    () async {
      platform.serviceEnabled = false;

      await expectLater(
        gateway.currentLocation(requestPermission: false),
        _failure(CurrentLocationFailure.serviceDisabled),
      );

      expect(platform.calls, ['service']);
    },
  );

  test(
    'a denied permission is requested once and can become allowed',
    () async {
      platform.permission = LocationPermission.denied;
      platform.requestResult = LocationPermission.whileInUse;

      expect((await gateway.currentLocation()).hasCoordinates, isTrue);
      expect(platform.calls, ['service', 'permission', 'request', 'position']);
    },
  );

  for (final (result, expected) in [
    (LocationPermission.denied, CurrentLocationFailure.denied),
    (LocationPermission.deniedForever, CurrentLocationFailure.deniedForever),
  ]) {
    test(
      'a permission request resulting in ${result.name} never reads position',
      () async {
        platform.permission = LocationPermission.denied;
        platform.requestResult = result;

        await expectLater(gateway.currentLocation(), _failure(expected));
        expect(platform.calls, ['service', 'permission', 'request']);
      },
    );
  }

  test(
    'a permanent denial does not repeatedly open the permission prompt',
    () async {
      platform.permission = LocationPermission.deniedForever;

      await expectLater(
        gateway.currentLocation(),
        _failure(CurrentLocationFailure.deniedForever),
      );
      expect(platform.calls, ['service', 'permission']);
    },
  );

  test(
    'disabled device services are distinct from denied permissions',
    () async {
      platform.serviceEnabled = false;

      await expectLater(
        gateway.currentLocation(),
        _failure(CurrentLocationFailure.serviceDisabled),
      );
      expect(platform.calls, ['service']);
    },
  );

  test(
    'unknown permission state does not start sensors or prompt repeatedly',
    () async {
      platform.permission = LocationPermission.unableToDetermine;

      await expectLater(
        gateway.currentLocation(),
        _failure(CurrentLocationFailure.unavailable),
      );
      expect(platform.calls, ['service', 'permission']);
    },
  );

  test(
    'a platform that never completes is bounded by the client timeout',
    () async {
      final pending = Completer<Position>();
      platform.positionFuture = pending.future;
      gateway = GeolocatorCurrentLocationGateway(
        platform: platform,
        timeout: const Duration(milliseconds: 5),
      );

      await expectLater(
        gateway.currentLocation(),
        _failure(CurrentLocationFailure.timedOut),
      );
      expect(platform.calls, ['service', 'permission', 'position']);
      pending.complete(_position());
    },
  );

  for (final (error, expected) in <(Object, CurrentLocationFailure)>[
    (
      const PermissionDeniedException('Changed permission'),
      CurrentLocationFailure.denied,
    ),
    (
      const LocationServiceDisabledException(),
      CurrentLocationFailure.serviceDisabled,
    ),
    (TimeoutException('Platform timeout'), CurrentLocationFailure.timedOut),
    (StateError('Unavailable platform'), CurrentLocationFailure.unavailable),
  ]) {
    test('a late ${error.runtimeType} maps to ${expected.name}', () async {
      platform.positionError = error;
      await expectLater(gateway.currentLocation(), _failure(expected));
    });
  }

  test(
    'malformed platform coordinates cannot become a selected location',
    () async {
      for (final pair in [(91.0, 129.0), (35.0, 181.0), (double.nan, 0.0)]) {
        platform.position = _position(latitude: pair.$1, longitude: pair.$2);
        await expectLater(
          gateway.currentLocation(),
          _failure(CurrentLocationFailure.unavailable),
        );
      }
    },
  );

  test(
    'settings open only on explicit actions and propagate native results',
    () async {
      platform.appSettingsResult = true;
      platform.locationSettingsResult = false;

      expect(await gateway.openAppSettings(), isTrue);
      expect(await gateway.openLocationSettings(), isFalse);
      expect(platform.calls, ['app-settings', 'location-settings']);
    },
  );

  test(
    'unavailable settings return false without leaking plugin exceptions',
    () async {
      platform.settingsError = StateError('No platform settings');

      expect(await gateway.openAppSettings(), isFalse);
      expect(await gateway.openLocationSettings(), isFalse);
      expect(platform.calls, ['app-settings', 'location-settings']);
    },
  );
}

Matcher _failure(CurrentLocationFailure reason) => throwsA(
  isA<CurrentLocationException>().having(
    (error) => error.reason,
    'reason',
    reason,
  ),
);

class _LocationPlatform extends GeolocatorPlatform {
  final calls = <String>[];
  bool serviceEnabled = true;
  LocationPermission permission = LocationPermission.whileInUse;
  LocationPermission requestResult = LocationPermission.whileInUse;
  Position position = _position();
  Object? positionError;
  Future<Position>? positionFuture;
  LocationSettings? settings;
  bool appSettingsResult = true;
  bool locationSettingsResult = true;
  Object? settingsError;

  @override
  Future<bool> isLocationServiceEnabled() async {
    calls.add('service');
    return serviceEnabled;
  }

  @override
  Future<LocationPermission> checkPermission() async {
    calls.add('permission');
    return permission;
  }

  @override
  Future<LocationPermission> requestPermission() async {
    calls.add('request');
    return requestResult;
  }

  @override
  Future<Position> getCurrentPosition({
    LocationSettings? locationSettings,
  }) async {
    calls.add('position');
    settings = locationSettings;
    final error = positionError;
    if (error != null) throw error;
    return await positionFuture ?? position;
  }

  @override
  Future<bool> openAppSettings() async {
    calls.add('app-settings');
    final error = settingsError;
    if (error != null) throw error;
    return appSettingsResult;
  }

  @override
  Future<bool> openLocationSettings() async {
    calls.add('location-settings');
    final error = settingsError;
    if (error != null) throw error;
    return locationSettingsResult;
  }
}

Position _position({double latitude = 35.1796, double longitude = 129.0756}) =>
    Position(
      latitude: latitude,
      longitude: longitude,
      timestamp: DateTime.utc(2026, 11, 2),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );
