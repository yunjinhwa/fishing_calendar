import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../maps/map_location.dart';
import '../models/external_data.dart';
import '../weather/kma_forecast_time.dart';
import '../weather/kma_grid.dart';
import '../weather/kma_weather_configuration.dart';
import 'external_data_service.dart';

/// Current-hour forecasts from the explicitly configured KMA API provider.
/// Keys and transport errors are deliberately excluded from public failures.
class KmaWeatherService implements ExternalDataService {
  KmaWeatherService({
    Dio? dio,
    DateTime Function()? clock,
    this.configuration = const KmaWeatherConfiguration(),
    this.cacheTtl = const Duration(minutes: 10),
    this.requestTimeout = const Duration(seconds: 12),
    this.maxCachedEntries = 128,
  }) : _dio = dio ?? Dio(),
       _clock = clock ?? DateTime.now {
    if (cacheTtl <= Duration.zero ||
        requestTimeout <= Duration.zero ||
        maxCachedEntries < 1) {
      throw ArgumentError('Weather cache and request limits must be positive.');
    }
  }

  static final KmaWeatherService instance = KmaWeatherService();

  final Dio _dio;
  final DateTime Function() _clock;
  final KmaWeatherConfiguration configuration;
  final Duration cacheTtl;
  final Duration requestTimeout;
  final int maxCachedEntries;
  final LinkedHashMap<_CacheKey, _Forecast> _cache = LinkedHashMap();
  final _inFlight = <_CacheKey, Future<_Forecast>>{};

  @override
  Future<ExternalData> fetchCurrentData({
    required MapLocation location,
    bool forceRefresh = false,
  }) async {
    if (!location.hasCoordinates) {
      throw const ExternalDataException(
        ExternalDataFailure.coordinatesRequired,
      );
    }
    final grid = KmaGrid.fromWgs84(location.latitude!, location.longitude!);
    final serviceKey = configuration.normalizedServiceKey;
    if (serviceKey == null || !configuration.isConfigured) {
      throw const ExternalDataException(ExternalDataFailure.configuration);
    }
    final now = _clock().toUtc();
    final period = KmaForecastTime.forCurrentHour(now);
    final key = (grid, period.issuedAt, period.validAt);
    final cached = _cache.remove(key);
    if (cached != null && !forceRefresh) {
      final age = now.difference(cached.fetchedAt);
      if (!age.isNegative && age < cacheTtl) {
        _cache[key] = cached;
        return cached.forLocation(location);
      }
    }
    final operation = _inFlight[key] ??= _loadAndCache(
      key,
      grid,
      period,
      serviceKey,
    );
    return (await operation).forLocation(location);
  }

  Future<_Forecast> _loadAndCache(
    _CacheKey key,
    KmaGrid grid,
    KmaForecastTime period,
    String serviceKey,
  ) async {
    try {
      _Forecast forecast;
      try {
        forecast = await _request(
          grid,
          period.issuedAt,
          period.validAt,
          serviceKey,
        );
      } on ExternalDataException catch (error) {
        if (error.reason != ExternalDataFailure.noData) rethrow;
        // Only an unpublished/missing issue justifies one older-issue request.
        forecast = await _request(
          grid,
          period.issuedAt.subtract(const Duration(hours: 1)),
          period.validAt,
          serviceKey,
        );
      }
      _cache.remove(key);
      _cache[key] = forecast;
      while (_cache.length > maxCachedEntries) {
        _cache.remove(_cache.keys.first);
      }
      return forecast;
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<_Forecast> _request(
    KmaGrid grid,
    DateTime issuedAt,
    DateTime validAt,
    String serviceKey,
  ) async {
    final cancellation = CancelToken();
    try {
      final response = await _dio
          .get<Object?>(
            configuration.endpoint!,
            queryParameters: {
              configuration.authParameter: serviceKey,
              'dataType': 'JSON',
              'numOfRows': '1000',
              'pageNo': '1',
              'base_date': KmaForecastTime.date(issuedAt),
              'base_time': KmaForecastTime.time(issuedAt),
              'nx': grid.x.toString(),
              'ny': grid.y.toString(),
            },
            cancelToken: cancellation,
            options: Options(
              responseType: ResponseType.plain,
              sendTimeout: requestTimeout,
              receiveTimeout: requestTimeout,
              validateStatus: (_) => true,
            ),
          )
          .timeout(
            requestTimeout,
            onTimeout: () {
              cancellation.cancel();
              throw const ExternalDataException(ExternalDataFailure.timedOut);
            },
          );
      _checkHttpStatus(response.statusCode);
      return _parse(response.data, grid, issuedAt, validAt);
    } on ExternalDataException {
      rethrow;
    } on DioException catch (error) {
      final reason = switch (error.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout => ExternalDataFailure.timedOut,
        _ =>
          error.response == null
              ? ExternalDataFailure.network
              : _httpFailure(error.response?.statusCode) ??
                    ExternalDataFailure.network,
      };
      throw ExternalDataException(reason);
    } on TimeoutException {
      throw const ExternalDataException(ExternalDataFailure.timedOut);
    } on Object {
      throw const ExternalDataException(ExternalDataFailure.invalidResponse);
    }
  }

  static ExternalDataFailure? _httpFailure(int? status) {
    if (status == 401 || status == 403) return ExternalDataFailure.unauthorized;
    if (status == 429) return ExternalDataFailure.rateLimited;
    if (status != null && status >= 500) return ExternalDataFailure.network;
    if (status == null || status < 200 || status >= 300) {
      return ExternalDataFailure.invalidResponse;
    }
    return null;
  }

  static void _checkHttpStatus(int? status) {
    final failure = _httpFailure(status);
    if (failure != null) throw ExternalDataException(failure);
  }

  static ExternalDataFailure _apiFailure(String code, String message) {
    final normalized = code.trim().padLeft(2, '0');
    if (normalized == '03' || message.contains('NO_DATA')) {
      return ExternalDataFailure.noData;
    }
    if (normalized == '22' || message.contains('LIMITED_NUMBER')) {
      return ExternalDataFailure.rateLimited;
    }
    if (const {'20', '21', '30', '31', '32', '33'}.contains(normalized) ||
        message.contains('SERVICE_KEY') ||
        message.contains('UNAUTHORIZED')) {
      return ExternalDataFailure.unauthorized;
    }
    if (message.contains('TIMEOUT')) return ExternalDataFailure.timedOut;
    return ExternalDataFailure.invalidResponse;
  }

  _Forecast _parse(
    Object? body,
    KmaGrid grid,
    DateTime issuedAt,
    DateTime validAt,
  ) {
    Object? decoded = body;
    if (body is String) {
      final text = body.trim();
      if (text.startsWith('<')) {
        String xmlField(String name) =>
            RegExp(
              '<$name[^>]*>([\\s\\S]*?)</$name>',
              caseSensitive: false,
            ).firstMatch(text)?.group(1)?.trim() ??
            '';
        final code = xmlField('returnReasonCode').isNotEmpty
            ? xmlField('returnReasonCode')
            : xmlField('resultCode');
        final message =
            '${xmlField('returnAuthMsg')} ${xmlField('resultMsg')} '
                    '${xmlField('errMsg')}'
                .toUpperCase();
        throw ExternalDataException(_apiFailure(code, message));
      }
      try {
        decoded = jsonDecode(text);
      } on FormatException {
        throw const ExternalDataException(ExternalDataFailure.invalidResponse);
      }
    }
    if (decoded is! Map || decoded['response'] is! Map) {
      throw const ExternalDataException(ExternalDataFailure.invalidResponse);
    }
    final response = decoded['response'] as Map;
    final header = response['header'];
    if (header is! Map || header['resultCode'] == null) {
      throw const ExternalDataException(ExternalDataFailure.invalidResponse);
    }
    final code = header['resultCode'].toString().trim().padLeft(2, '0');
    if (code != '00') {
      throw ExternalDataException(
        _apiFailure(code, header['resultMsg'].toString().toUpperCase()),
      );
    }
    final data = response['body'];
    if (data is! Map) {
      throw const ExternalDataException(ExternalDataFailure.invalidResponse);
    }
    final items = data['items'];
    final rows = items is Map ? items['item'] : null;
    if (rows == null || rows == '' || (rows is List && rows.isEmpty)) {
      throw const ExternalDataException(ExternalDataFailure.noData);
    }
    if (rows is! List) {
      throw const ExternalDataException(ExternalDataFailure.invalidResponse);
    }
    final values = <String, String>{};
    String? selectedBaseTime;
    final requestedBaseTime = KmaForecastTime.time(issuedAt);
    for (final item in rows) {
      final returnedBaseTime = item is Map ? _time(item['baseTime']) : '';
      final matchingIssue =
          returnedBaseTime == requestedBaseTime ||
          (configuration.provider == 'apihub' &&
              returnedBaseTime == '${requestedBaseTime.substring(0, 2)}00');
      if (item is! Map ||
          _text(item['baseDate']) != KmaForecastTime.date(issuedAt) ||
          !matchingIssue ||
          _text(item['fcstDate']) != KmaForecastTime.date(validAt) ||
          _time(item['fcstTime']) != KmaForecastTime.time(validAt) ||
          int.tryParse(_text(item['nx'])) != grid.x ||
          int.tryParse(_text(item['ny'])) != grid.y) {
        continue;
      }
      final category = _text(item['category']);
      if (!const {'SKY', 'PTY', 'T1H'}.contains(category)) continue;
      if (selectedBaseTime != null && selectedBaseTime != returnedBaseTime) {
        throw const ExternalDataException(ExternalDataFailure.invalidResponse);
      }
      selectedBaseTime = returnedBaseTime;
      final value = _text(item['fcstValue']);
      if (values.containsKey(category) && values[category] != value) {
        throw const ExternalDataException(ExternalDataFailure.invalidResponse);
      }
      values[category] = value;
    }
    final temperature = double.tryParse(values['T1H'] ?? '');
    final validTemperature =
        temperature != null && temperature.isFinite && temperature.abs() < 900
        ? temperature
        : null;
    final precipitation = int.tryParse(values['PTY'] ?? '');
    final weather = switch (precipitation) {
      1 => '비',
      2 => '비/눈',
      3 => '눈',
      4 => '소나기',
      5 => '빗방울',
      6 => '빗방울/눈날림',
      7 => '눈날림',
      0 || null => switch (int.tryParse(values['SKY'] ?? '')) {
        1 => '맑음',
        3 => '구름많음',
        4 => '흐림',
        _ => null,
      },
      _ => null,
    };
    if (weather == null && validTemperature == null) {
      throw const ExternalDataException(ExternalDataFailure.noData);
    }
    return _Forecast(
      weather: weather,
      temperature: validTemperature,
      grid: grid,
      issuedAt: selectedBaseTime == requestedBaseTime
          ? issuedAt
          : issuedAt.subtract(const Duration(minutes: 30)),
      validAt: validAt,
      fetchedAt: _clock().toUtc(),
    );
  }

  static String _text(Object? value) => value?.toString().trim() ?? '';
  static String _time(Object? value) => _text(value).padLeft(4, '0');
}

typedef _CacheKey = (KmaGrid, DateTime, DateTime);

class _Forecast {
  const _Forecast({
    required this.weather,
    required this.temperature,
    required this.grid,
    required this.issuedAt,
    required this.validAt,
    required this.fetchedAt,
  });

  final String? weather;
  final double? temperature;
  final KmaGrid grid;
  final DateTime issuedAt;
  final DateTime validAt;
  final DateTime fetchedAt;

  ExternalData forLocation(MapLocation location) => ExternalData(
    locationName: location.name,
    latitude: location.latitude!,
    longitude: location.longitude!,
    weather: weather,
    airTemperature: temperature,
    gridX: grid.x,
    gridY: grid.y,
    issuedAt: issuedAt,
    validAt: validAt,
    fetchedAt: fetchedAt,
  );
}
