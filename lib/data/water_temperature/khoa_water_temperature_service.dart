import 'package:dio/dio.dart';

import '../maps/map_location.dart';
import 'khoa_water_temperature_configuration.dart';
import 'khoa_water_temperature_day_client.dart';
import 'khoa_water_temperature_stations.dart';
import 'water_temperature_models.dart';
import 'water_temperature_service.dart';

/// Current measured temperatures from nearby coastal KHOA tide stations.
/// Provider text and transport errors never leave this class: either can contain
/// a URL carrying the service key.
class KhoaWaterTemperatureService implements WaterTemperatureService {
  KhoaWaterTemperatureService({
    Dio? dio,
    DateTime Function()? clock,
    List<WaterTemperatureStation> stations = khoaWaterTemperatureStations,
    this.configuration = const KhoaWaterTemperatureConfiguration(),
    this.cacheTtl = const Duration(minutes: 10),
    this.requestTimeout = const Duration(seconds: 12),
    this.maxCachedEntries = 64,
  }) : _clock = clock ?? DateTime.now,
       _stations = List.unmodifiable(stations),
       _dayClient = KhoaWaterTemperatureDayClient(
         dio: dio ?? Dio(),
         clock: clock ?? DateTime.now,
         configuration: configuration,
         requestTimeout: requestTimeout,
       ) {
    if (cacheTtl <= Duration.zero ||
        requestTimeout <= Duration.zero ||
        maxCachedEntries < 1) {
      throw ArgumentError(
        'Observation cache and request limits must be positive.',
      );
    }
    for (final station in _stations) {
      if (!RegExp(r'^DT_[0-9]{4}$').hasMatch(station.code) ||
          station.name.trim().isEmpty ||
          !station.latitude.isFinite ||
          !station.longitude.isFinite ||
          station.latitude.abs() > 90 ||
          station.longitude.abs() > 180) {
        throw ArgumentError('Invalid water-temperature station.');
      }
    }
  }

  static final KhoaWaterTemperatureService instance =
      KhoaWaterTemperatureService();
  static const _maxStationDistanceKm = 50;
  static const _maxStations = 3;
  final KhoaWaterTemperatureDayClient _dayClient;
  final DateTime Function() _clock;
  final List<WaterTemperatureStation> _stations;
  final KhoaWaterTemperatureConfiguration configuration;
  final Duration cacheTtl;
  final Duration requestTimeout;
  final int maxCachedEntries;
  final _cache = <_CacheKey, _CacheEntry>{};
  final _inFlight = <_CacheKey, Future<_Reading>>{};

  @override
  Future<WaterTemperatureObservation> fetchCurrentData({
    required MapLocation location,
    bool forceRefresh = false,
  }) async {
    if (!location.hasCoordinates) {
      throw const WaterTemperatureException(
        WaterTemperatureFailure.coordinatesRequired,
      );
    }
    final nearest =
        _stations
            .where(
              (station) =>
                  station.distanceKmTo(
                    location.latitude!,
                    location.longitude!,
                  ) <=
                  _maxStationDistanceKm,
            )
            .toList()
          ..sort(
            (a, b) => a
                .distanceKmTo(location.latitude!, location.longitude!)
                .compareTo(
                  b.distanceKmTo(location.latitude!, location.longitude!),
                ),
          );
    if (nearest.isEmpty) {
      throw const WaterTemperatureException(
        WaterTemperatureFailure.unsupportedLocation,
      );
    }
    final serviceKey = configuration.normalizedServiceKey;
    if (serviceKey == null) {
      throw const WaterTemperatureException(
        WaterTemperatureFailure.configuration,
      );
    }
    final now = _clock().toUtc();
    final day = KhoaWaterTemperatureDayClient.kstDay(now);
    for (final station in nearest.take(_maxStations)) {
      try {
        final reading = await _fetchRecentStation(
          station,
          now,
          day,
          serviceKey,
          forceRefresh,
        );
        final result = WaterTemperatureObservation(
          location: location,
          station: station,
          temperatureCelsius: reading.temperature,
          observedAt: reading.observedAt,
          fetchedAt: reading.fetchedAt,
        );
        // A cached value must still be fresh when returned to a new caller.
        if (!result.isUsableAt(_clock())) {
          throw const WaterTemperatureException(WaterTemperatureFailure.noData);
        }
        return result;
      } on WaterTemperatureException catch (error) {
        if (error.reason != WaterTemperatureFailure.noData) rethrow;
      }
    }
    throw const WaterTemperatureException(WaterTemperatureFailure.noData);
  }

  Future<_Reading> _fetchRecentStation(
    WaterTemperatureStation station,
    DateTime now,
    String day,
    String serviceKey,
    bool forceRefresh,
  ) async {
    final earlierDay = KhoaWaterTemperatureDayClient.kstDay(
      now.subtract(WaterTemperatureObservation.maxObservationAge),
    );
    if (earlierDay == day) {
      return _fetchStation(station, day, serviceKey, forceRefresh);
    }

    // Just after KST midnight the latest usable sample can still belong to the
    // previous day. Query both parts of the freshness window through the same
    // bounded cache instead of treating an unpublished new day as no sensor.
    Future<({_Reading? reading, WaterTemperatureException? failure})> attempt(
      String requestedDay,
    ) async {
      try {
        return (
          reading: await _fetchStation(
            station,
            requestedDay,
            serviceKey,
            forceRefresh,
          ),
          failure: null,
        );
      } on Object catch (error) {
        return (
          reading: null,
          failure: error is WaterTemperatureException
              ? error
              : const WaterTemperatureException(
                  WaterTemperatureFailure.invalidResponse,
                ),
        );
      }
    }

    final results = await Future.wait([attempt(day), attempt(earlierDay)]);
    _Reading? latest;
    WaterTemperatureException? failure;
    for (final result in results) {
      final reading = result.reading;
      if (reading != null) {
        final age = _clock().toUtc().difference(reading.observedAt);
        if (!age.isNegative &&
            age <= WaterTemperatureObservation.maxObservationAge &&
            (latest == null || reading.observedAt.isAfter(latest.observedAt))) {
          latest = reading;
        }
      }
      final error = result.failure;
      if (error != null && error.reason != WaterTemperatureFailure.noData) {
        failure ??= error;
      }
    }
    if (latest != null) return latest;
    if (failure != null) throw failure;
    throw const WaterTemperatureException(WaterTemperatureFailure.noData);
  }

  Future<_Reading> _fetchStation(
    WaterTemperatureStation station,
    String day,
    String serviceKey,
    bool forceRefresh,
  ) async {
    final key = (station.code, day);
    final cached = _cache[key];
    if (cached != null && !forceRefresh) {
      final age = _clock().toUtc().difference(cached.fetchedAt);
      if (!age.isNegative && age < cacheTtl) {
        _cache.remove(key);
        _cache[key] = cached;
        if (cached.reading case final reading?) return reading;
        throw const WaterTemperatureException(WaterTemperatureFailure.noData);
      }
      _cache.remove(key);
    }
    return _inFlight[key] ??= _loadAndCache(key, station, day, serviceKey);
  }

  Future<_Reading> _loadAndCache(
    _CacheKey key,
    WaterTemperatureStation station,
    String day,
    String serviceKey,
  ) async {
    try {
      final data = await _dayClient.fetchDay(
        station: station,
        day: day,
        serviceKey: serviceKey,
      );
      final reading = _latestReading(data);
      _putCache(key, _CacheEntry(reading, reading.fetchedAt));
      return reading;
    } on WaterTemperatureException catch (error) {
      if (error.reason == WaterTemperatureFailure.noData) {
        _putCache(key, _CacheEntry(null, _clock().toUtc()));
      }
      rethrow;
    } finally {
      _inFlight.remove(key);
    }
  }

  void _putCache(_CacheKey key, _CacheEntry entry) {
    _cache.remove(key);
    _cache[key] = entry;
    while (_cache.length > maxCachedEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  _Reading _latestReading(KhoaWaterTemperatureDay data) {
    final now = _clock().toUtc();
    KhoaWaterTemperatureSample? latest;
    for (final sample in data.samples) {
      final age = now.difference(sample.observedAt);
      if (age.isNegative ||
          age > WaterTemperatureObservation.maxObservationAge) {
        continue;
      }
      if (latest == null || sample.observedAt.isAfter(latest.observedAt)) {
        latest = sample;
      }
    }
    if (latest == null) {
      throw const WaterTemperatureException(WaterTemperatureFailure.noData);
    }
    return _Reading(
      latest.temperatureCelsius,
      latest.observedAt,
      data.fetchedAt,
    );
  }
}

typedef _CacheKey = (String, String);

class _Reading {
  const _Reading(this.temperature, this.observedAt, this.fetchedAt);
  final double temperature;
  final DateTime observedAt;
  final DateTime fetchedAt;
}

class _CacheEntry {
  const _CacheEntry(this.reading, this.fetchedAt);
  final _Reading? reading;
  final DateTime fetchedAt;
}
