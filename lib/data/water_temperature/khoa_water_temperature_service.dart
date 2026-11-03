import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../maps/map_location.dart';
import 'khoa_water_temperature_configuration.dart';
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
  }) : _dio = dio ?? Dio(),
       _clock = clock ?? DateTime.now,
       _stations = List.unmodifiable(stations) {
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
  static const _pageSize = 300;
  static const _maxPages = 5;
  static const _maxResponseBytes = 512 * 1024;
  static const _maxStationDistanceKm = 50;
  static const _maxStations = 3;
  final Dio _dio;
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
    final day = _kstDay(now);
    for (final station in nearest.take(_maxStations)) {
      try {
        final reading = await _fetchStation(
          station,
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
      final rows = <Map>[];
      int? expectedTotal;
      for (var pageNo = 1; pageNo <= _maxPages; pageNo++) {
        final page = await _request(station, day, serviceKey, pageNo);
        if (page.totalCount != null) {
          if (expectedTotal != null && expectedTotal != page.totalCount) {
            throw const WaterTemperatureException(
              WaterTemperatureFailure.invalidResponse,
            );
          }
          expectedTotal = page.totalCount;
        }
        if (expectedTotal != null && expectedTotal > _pageSize * _maxPages) {
          throw const WaterTemperatureException(
            WaterTemperatureFailure.invalidResponse,
          );
        }
        rows.addAll(page.rows);
        if (expectedTotal != null && rows.length > expectedTotal) {
          throw const WaterTemperatureException(
            WaterTemperatureFailure.invalidResponse,
          );
        }
        final finished = expectedTotal != null
            ? rows.length == expectedTotal
            : page.rows.length < _pageSize;
        if (finished) break;
        if (page.rows.isEmpty || pageNo == _maxPages) {
          throw const WaterTemperatureException(
            WaterTemperatureFailure.invalidResponse,
          );
        }
      }
      final reading = _latestReading(rows, station, day);
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

  Future<_Page> _request(
    WaterTemperatureStation station,
    String day,
    String serviceKey,
    int pageNo,
  ) async {
    final cancellation = CancelToken();
    try {
      final (
        body,
        status,
      ) = await _send(station, day, serviceKey, pageNo, cancellation).timeout(
        requestTimeout,
        onTimeout: () {
          cancellation.cancel();
          throw const WaterTemperatureException(
            WaterTemperatureFailure.timedOut,
          );
        },
      );
      final providerFailure = _providerFailure(body);
      if (providerFailure != null) {
        throw WaterTemperatureException(providerFailure);
      }
      final httpFailure = _httpFailure(status);
      if (httpFailure != null) throw WaterTemperatureException(httpFailure);
      return _parsePage(body, pageNo);
    } on WaterTemperatureException {
      rethrow;
    } on DioException catch (error) {
      final reason = switch (error.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout => WaterTemperatureFailure.timedOut,
        _ =>
          _httpFailure(error.response?.statusCode) ??
              WaterTemperatureFailure.network,
      };
      throw WaterTemperatureException(reason);
    } on TimeoutException {
      throw const WaterTemperatureException(WaterTemperatureFailure.timedOut);
    } on Object {
      throw const WaterTemperatureException(
        WaterTemperatureFailure.invalidResponse,
      );
    }
  }

  Future<(String, int?)> _send(
    WaterTemperatureStation station,
    String day,
    String serviceKey,
    int pageNo,
    CancelToken cancellation,
  ) async {
    final response = await _dio.get<ResponseBody>(
      configuration.endpoint,
      queryParameters: {
        'serviceKey': serviceKey,
        'obsCode': station.code,
        'reqDate': day,
        'type': 'json',
        // KHOA documents this as the output time interval in minutes.
        'min': '10',
        'pageNo': '$pageNo',
        'numOfRows': '$_pageSize',
      },
      cancelToken: cancellation,
      options: Options(
        responseType: ResponseType.stream,
        sendTimeout: requestTimeout,
        receiveTimeout: requestTimeout,
        followRedirects: false,
        maxRedirects: 0,
        validateStatus: (_) => true,
      ),
    );
    final responseBody = response.data;
    if (responseBody == null) {
      throw const WaterTemperatureException(
        WaterTemperatureFailure.invalidResponse,
      );
    }
    final bytes = <int>[];
    await for (final chunk in responseBody.stream) {
      if (bytes.length + chunk.length > _maxResponseBytes) {
        cancellation.cancel();
        throw const WaterTemperatureException(
          WaterTemperatureFailure.invalidResponse,
        );
      }
      bytes.addAll(chunk);
    }
    return (utf8.decode(bytes), response.statusCode);
  }

  static WaterTemperatureFailure? _httpFailure(int? status) {
    if (status == 401 || status == 403) {
      return WaterTemperatureFailure.unauthorized;
    }
    if (status == 429) return WaterTemperatureFailure.rateLimited;
    if (status != null && status >= 500) return WaterTemperatureFailure.network;
    if (status != null && (status < 200 || status >= 300)) {
      return WaterTemperatureFailure.invalidResponse;
    }
    return null;
  }

  static WaterTemperatureFailure _apiFailure(String code) =>
      switch (code.trim().padLeft(2, '0')) {
        '03' || '40' || '41' => WaterTemperatureFailure.noData,
        '20' ||
        '21' ||
        '30' ||
        '31' ||
        '32' ||
        '33' => WaterTemperatureFailure.unauthorized,
        '22' || '23' => WaterTemperatureFailure.rateLimited,
        '05' => WaterTemperatureFailure.timedOut,
        '01' || '02' || '04' => WaterTemperatureFailure.network,
        _ => WaterTemperatureFailure.invalidResponse,
      };

  static WaterTemperatureFailure? _providerFailure(String body) {
    try {
      if (body.trimLeft().startsWith('<')) {
        String field(String name) =>
            RegExp(
              '<$name(?:\\s[^>]*)?>([\\s\\S]*?)</$name>',
              caseSensitive: false,
            ).firstMatch(body)?.group(1)?.trim() ??
            '';
        final gatewayCode = field('returnReasonCode');
        final code = gatewayCode.isEmpty ? field('resultCode') : gatewayCode;
        if (code.isEmpty || code.padLeft(2, '0') == '00') return null;
        return _apiFailure(code);
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      final root = decoded['response'] ?? decoded;
      if (root is! Map || root['header'] is! Map) return null;
      final code = (root['header'] as Map)['resultCode']?.toString().trim();
      if (code == null || code.padLeft(2, '0') == '00') return null;
      return _apiFailure(code);
    } on Object {
      return null;
    }
  }

  static _Page _parsePage(String body, int requestedPage) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const WaterTemperatureException(
        WaterTemperatureFailure.invalidResponse,
      );
    }
    final root = decoded['response'] ?? decoded;
    if (root is! Map || root['header'] is! Map || root['body'] is! Map) {
      throw const WaterTemperatureException(
        WaterTemperatureFailure.invalidResponse,
      );
    }
    final header = root['header'] as Map;
    if (header['resultCode']?.toString().trim().padLeft(2, '0') != '00') {
      throw const WaterTemperatureException(
        WaterTemperatureFailure.invalidResponse,
      );
    }
    final data = root['body'] as Map;
    final total = _optionalInt(data, 'totalCount', minimum: 0);
    final page = _optionalInt(data, 'pageNo', minimum: 1);
    final size = _optionalInt(data, 'numOfRows', minimum: 0);
    if ((page != null && page != requestedPage) ||
        (size != null && size > _pageSize)) {
      throw const WaterTemperatureException(
        WaterTemperatureFailure.invalidResponse,
      );
    }
    Object? items = data['items'];
    if (items is Map && items.containsKey('item')) items = items['item'];
    if (items == null ||
        items == '' ||
        (items is List && items.isEmpty) ||
        (items is Map && items.isEmpty)) {
      if (total != 0) {
        throw const WaterTemperatureException(
          WaterTemperatureFailure.invalidResponse,
        );
      }
      return _Page(const [], total);
    }
    final List list;
    if (items is List) {
      list = items;
    } else if (items is Map && items.containsKey('obsrvnDt')) {
      list = [items];
    } else {
      throw const WaterTemperatureException(
        WaterTemperatureFailure.invalidResponse,
      );
    }
    if (list.length > _pageSize || list.any((item) => item is! Map)) {
      throw const WaterTemperatureException(
        WaterTemperatureFailure.invalidResponse,
      );
    }
    return _Page(list.cast<Map>(), total);
  }

  static int? _optionalInt(Map data, String key, {required int minimum}) {
    if (!data.containsKey(key)) return null;
    final text = data[key].toString();
    final value = RegExp(r'^\d+$').hasMatch(text) ? int.tryParse(text) : null;
    if (value == null || value < minimum) {
      throw const WaterTemperatureException(
        WaterTemperatureFailure.invalidResponse,
      );
    }
    return value;
  }

  _Reading _latestReading(
    List<Map> rows,
    WaterTemperatureStation station,
    String day,
  ) {
    final now = _clock().toUtc();
    final readings = <DateTime, double>{};
    for (final row in rows) {
      final latitude = _number(row['lat']);
      final longitude = _number(row['lot']);
      if (row['obsvtrNm']?.toString().trim() != station.name ||
          latitude == null ||
          longitude == null ||
          latitude.abs() > 90 ||
          longitude.abs() > 180 ||
          station.distanceKmTo(latitude, longitude) > 1 ||
          (row.containsKey('obsCode') && row['obsCode'] != station.code)) {
        throw const WaterTemperatureException(
          WaterTemperatureFailure.invalidResponse,
        );
      }
      final temperature = _number(row['wtem']);
      // Missing sensor values, sentinels, and physically invalid temperatures
      // cannot become observations; a measured zero remains valid.
      if (temperature == null || temperature < -5 || temperature > 45) continue;
      final observedAt = _parseKst(row['obsrvnDt']);
      if (_kstDay(observedAt) != day) {
        throw const WaterTemperatureException(
          WaterTemperatureFailure.invalidResponse,
        );
      }
      final age = now.difference(observedAt);
      if (age.isNegative ||
          age > WaterTemperatureObservation.maxObservationAge) {
        continue;
      }
      final previous = readings[observedAt];
      if (previous != null && previous != temperature) {
        throw const WaterTemperatureException(
          WaterTemperatureFailure.invalidResponse,
        );
      }
      readings[observedAt] = temperature;
    }
    if (readings.isEmpty) {
      throw const WaterTemperatureException(WaterTemperatureFailure.noData);
    }
    final latest = readings.keys.reduce((a, b) => a.isAfter(b) ? a : b);
    return _Reading(readings[latest]!, latest, now);
  }

  static double? _number(Object? raw) {
    final value = raw is num ? raw.toDouble() : double.tryParse('$raw');
    return value != null && value.isFinite ? value : null;
  }

  static String _kstDay(DateTime instant) {
    final day = instant.toUtc().add(const Duration(hours: 9));
    return '${day.year.toString().padLeft(4, '0')}'
        '${day.month.toString().padLeft(2, '0')}'
        '${day.day.toString().padLeft(2, '0')}';
  }

  static DateTime _parseKst(Object? raw) {
    final match = raw is String
        ? RegExp(
            r'^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?$',
          ).firstMatch(raw.trim())
        : null;
    if (match == null) {
      throw const WaterTemperatureException(
        WaterTemperatureFailure.invalidResponse,
      );
    }
    final parts = [
      for (var index = 1; index <= 6; index++)
        int.parse(match.group(index) ?? '0'),
    ];
    final wallTime = DateTime.utc(
      parts[0],
      parts[1],
      parts[2],
      parts[3],
      parts[4],
      parts[5],
    );
    if (wallTime.year != parts[0] ||
        wallTime.month != parts[1] ||
        wallTime.day != parts[2] ||
        wallTime.hour != parts[3] ||
        wallTime.minute != parts[4] ||
        wallTime.second != parts[5]) {
      throw const WaterTemperatureException(
        WaterTemperatureFailure.invalidResponse,
      );
    }
    return wallTime.subtract(const Duration(hours: 9));
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

class _Page {
  const _Page(this.rows, this.totalCount);
  final List<Map> rows;
  final int? totalCount;
}
