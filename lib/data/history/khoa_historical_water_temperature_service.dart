import 'package:dio/dio.dart';

import '../maps/map_location.dart';
import '../water_temperature/khoa_water_temperature_configuration.dart';
import '../water_temperature/khoa_water_temperature_day_client.dart';
import '../water_temperature/khoa_water_temperature_stations.dart';
import '../water_temperature/water_temperature_models.dart';
import '../water_temperature/water_temperature_service.dart';
import 'historical_conditions.dart';
import 'historical_conditions_service.dart';

/// Selects measured KHOA samples for the requested past time, independently of
/// the current-observation service's two-hour freshness limit.
class KhoaHistoricalWaterTemperatureService
    implements HistoricalWaterTemperatureService {
  KhoaHistoricalWaterTemperatureService({
    Dio? dio,
    DateTime Function()? clock,
    List<WaterTemperatureStation> stations = khoaWaterTemperatureStations,
    this.configuration = const KhoaWaterTemperatureConfiguration(),
    this.cacheTtl = const Duration(hours: 24),
    this.recentDayCacheTtl = const Duration(minutes: 10),
    this.noDataCacheTtl = const Duration(minutes: 10),
    this.failureCacheTtl = const Duration(seconds: 30),
    this.requestTimeout = const Duration(seconds: 12),
    this.maxCachedEntries = 128,
  }) : _clock = clock ?? DateTime.now,
       _stations = List.unmodifiable(stations),
       _dayClient = KhoaWaterTemperatureDayClient(
         dio: dio ?? Dio(),
         clock: clock ?? DateTime.now,
         configuration: configuration,
         requestTimeout: requestTimeout,
       ) {
    if (cacheTtl <= Duration.zero ||
        recentDayCacheTtl <= Duration.zero ||
        noDataCacheTtl <= Duration.zero ||
        failureCacheTtl <= Duration.zero ||
        requestTimeout <= Duration.zero ||
        maxCachedEntries < 1) {
      throw ArgumentError(
        'Historical cache and request limits must be positive.',
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

  static final KhoaHistoricalWaterTemperatureService instance =
      KhoaHistoricalWaterTemperatureService();

  // The application's history picker starts at 2020-01-01 in Korea. This is an
  // application boundary, rather than an assumption about provider retention.
  static final earliestRequestedAt = DateTime.utc(2019, 12, 31, 15);
  static const _maxStationDistanceKm = 50;
  static const _maxStations = 3;

  final DateTime Function() _clock;
  final List<WaterTemperatureStation> _stations;
  final KhoaWaterTemperatureDayClient _dayClient;
  final KhoaWaterTemperatureConfiguration configuration;
  final Duration cacheTtl;
  final Duration recentDayCacheTtl;
  final Duration noDataCacheTtl;
  final Duration failureCacheTtl;
  final Duration requestTimeout;
  final int maxCachedEntries;
  final _cache = <_CacheKey, _CacheEntry>{};
  final _inFlight = <_CacheKey, Future<KhoaWaterTemperatureDay>>{};

  @override
  Future<HistoricalWaterTemperatureObservation> fetchAt({
    required MapLocation location,
    required DateTime requestedAt,
    bool forceRefresh = false,
  }) async {
    if (!location.hasCoordinates) {
      throw const HistoricalDataException(
        HistoricalDataFailure.coordinatesRequired,
      );
    }
    final target = requestedAt.toUtc();
    final now = _clock().toUtc();
    if (target.isBefore(earliestRequestedAt) || !target.isBefore(now)) {
      throw const HistoricalDataException(
        HistoricalDataFailure.unsupportedDate,
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
      throw const HistoricalDataException(
        HistoricalDataFailure.unsupportedLocation,
      );
    }
    final serviceKey = configuration.normalizedServiceKey;
    if (serviceKey == null) {
      throw const HistoricalDataException(HistoricalDataFailure.configuration);
    }
    final day = KhoaWaterTemperatureDayClient.kstDay(target);
    for (final station in nearest.take(_maxStations)) {
      try {
        final data = await _fetchDay(station, day, serviceKey, forceRefresh);
        KhoaWaterTemperatureSample? latest;
        for (final sample in data.samples) {
          final age = target.difference(sample.observedAt);
          if (age.isNegative || age >= const Duration(hours: 1)) continue;
          if (latest == null || sample.observedAt.isAfter(latest.observedAt)) {
            latest = sample;
          }
        }
        if (latest == null) {
          throw const HistoricalDataException(HistoricalDataFailure.noData);
        }
        return HistoricalWaterTemperatureObservation(
          location: location,
          station: station,
          requestedAt: target,
          observedAt: latest.observedAt,
          fetchedAt: data.fetchedAt,
          temperatureCelsius: latest.temperatureCelsius,
        );
      } on HistoricalDataException catch (error) {
        if (error.reason != HistoricalDataFailure.noData) rethrow;
      }
    }
    throw const HistoricalDataException(HistoricalDataFailure.noData);
  }

  Future<KhoaWaterTemperatureDay> _fetchDay(
    WaterTemperatureStation station,
    String day,
    String serviceKey,
    bool forceRefresh,
  ) async {
    final key = (station.code, day);
    final pending = _inFlight[key];
    if (pending != null) return pending;
    final cached = _cache[key];
    if (cached != null) {
      final now = _clock().toUtc();
      final age = now.difference(cached.fetchedAt);
      final failure = cached.failure;
      final transientFailure =
          failure != null && failure != HistoricalDataFailure.noData;
      final ttl = failure == HistoricalDataFailure.noData
          ? noDataCacheTtl
          : transientFailure
          ? failureCacheTtl
          : day == KhoaWaterTemperatureDayClient.kstDay(now)
          ? recentDayCacheTtl
          : cacheTtl;
      if (!age.isNegative && age < ttl && (!forceRefresh || transientFailure)) {
        _cache.remove(key);
        _cache[key] = cached;
        if (failure != null) throw HistoricalDataException(failure);
        return cached.data!;
      }
      _cache.remove(key);
    }
    return _inFlight[key] ??= _loadAndCache(key, station, day, serviceKey);
  }

  Future<KhoaWaterTemperatureDay> _loadAndCache(
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
      if (data.samples.isEmpty) {
        const failure = HistoricalDataFailure.noData;
        _putCache(key, _CacheEntry.failure(failure, data.fetchedAt));
        throw const HistoricalDataException(failure);
      }
      _putCache(key, _CacheEntry.data(data));
      return data;
    } on WaterTemperatureException catch (error) {
      final reason = switch (error.reason) {
        WaterTemperatureFailure.configuration =>
          HistoricalDataFailure.configuration,
        WaterTemperatureFailure.coordinatesRequired =>
          HistoricalDataFailure.coordinatesRequired,
        WaterTemperatureFailure.unsupportedLocation =>
          HistoricalDataFailure.unsupportedLocation,
        WaterTemperatureFailure.noData => HistoricalDataFailure.noData,
        WaterTemperatureFailure.unauthorized =>
          HistoricalDataFailure.unauthorized,
        WaterTemperatureFailure.rateLimited =>
          HistoricalDataFailure.rateLimited,
        WaterTemperatureFailure.timedOut => HistoricalDataFailure.timedOut,
        WaterTemperatureFailure.network => HistoricalDataFailure.network,
        WaterTemperatureFailure.invalidResponse =>
          HistoricalDataFailure.invalidResponse,
      };
      _putCache(key, _CacheEntry.failure(reason, _clock().toUtc()));
      throw HistoricalDataException(reason);
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
}

typedef _CacheKey = (String, String);

class _CacheEntry {
  _CacheEntry.data(KhoaWaterTemperatureDay value)
    : data = value,
      failure = null,
      fetchedAt = value.fetchedAt;
  const _CacheEntry.failure(HistoricalDataFailure value, this.fetchedAt)
    : data = null,
      failure = value;

  final KhoaWaterTemperatureDay? data;
  final HistoricalDataFailure? failure;
  final DateTime fetchedAt;
}
