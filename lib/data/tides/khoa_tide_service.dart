import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import 'khoa_tide_configuration.dart';
import 'tide_models.dart';
import 'tide_service.dart';

/// Daily high/low predictions. Provider text and transport exceptions are never
/// included in public failures because they may contain a credential-bearing URL.
class KhoaTideService implements TideService {
  KhoaTideService({
    Dio? dio,
    DateTime Function()? clock,
    this.configuration = const KhoaTideConfiguration(),
    this.cacheTtl = const Duration(minutes: 10),
    this.requestTimeout = const Duration(seconds: 12),
    this.maxCachedEntries = 128,
  }) : _dio = dio ?? Dio(),
       _clock = clock ?? DateTime.now {
    if (cacheTtl <= Duration.zero ||
        requestTimeout <= Duration.zero ||
        maxCachedEntries < 1) {
      throw ArgumentError('Tide cache and request limits must be positive.');
    }
  }

  static final KhoaTideService instance = KhoaTideService();

  static const _pageSize = 300;
  static const _maxPages = 4;
  final Dio _dio;
  final DateTime Function() _clock;
  final KhoaTideConfiguration configuration;
  final Duration cacheTtl;
  final Duration requestTimeout;
  final int maxCachedEntries;
  final _cache = <_CacheKey, TideForecast>{};
  final _inFlight = <_CacheKey, Future<TideForecast>>{};

  @override
  Future<TideForecast> fetchForecast({
    required TideStation station,
    required TideDay day,
    bool forceRefresh = false,
  }) async {
    _validateStation(station);
    if (day.year < 1 || day.year > 9999) {
      throw const TideException(TideFailure.unsupportedDate);
    }
    final serviceKey = configuration.normalizedServiceKey;
    if (serviceKey == null) {
      throw const TideException(TideFailure.configuration);
    }
    final key = (station.code, day);
    final cached = _cache[key];
    if (cached != null && !forceRefresh) {
      final age = _clock().toUtc().difference(cached.fetchedAt);
      if (!age.isNegative && age < cacheTtl) {
        _checkStationCoordinates(station, cached.station);
        _cache.remove(key);
        _cache[key] = cached;
        return cached;
      }
      _cache.remove(key);
    }
    final operation = _inFlight[key] ??= _loadAndCache(
      key,
      station,
      day,
      serviceKey,
    );
    final forecast = await operation;
    _checkStationCoordinates(station, forecast.station);
    return forecast;
  }

  Future<TideForecast> _loadAndCache(
    _CacheKey key,
    TideStation station,
    TideDay day,
    String serviceKey,
  ) async {
    try {
      final rows = <Map>[];
      int? expectedTotal;
      for (var pageNo = 1; pageNo <= _maxPages; pageNo++) {
        final page = await _request(station, day, serviceKey, pageNo);
        if (page.totalCount != null) {
          if (expectedTotal != null && expectedTotal != page.totalCount) {
            throw const TideException(TideFailure.invalidResponse);
          }
          expectedTotal = page.totalCount;
        }
        if (expectedTotal != null && expectedTotal > _pageSize * _maxPages) {
          throw const TideException(TideFailure.invalidResponse);
        }
        rows.addAll(page.rows);
        if (expectedTotal != null && rows.length > expectedTotal) {
          throw const TideException(TideFailure.invalidResponse);
        }
        final finished = expectedTotal != null
            ? rows.length == expectedTotal
            : page.rows.length < _pageSize;
        if (finished) break;
        if (page.rows.isEmpty || pageNo == _maxPages) {
          // Never return a partial daily forecast when pagination is incomplete.
          throw const TideException(TideFailure.invalidResponse);
        }
      }
      final forecast = _forecast(rows, station, day);
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

  Future<_Page> _request(
    TideStation station,
    TideDay day,
    String serviceKey,
    int pageNo,
  ) async {
    final cancellation = CancelToken();
    try {
      final response = await _dio
          .get<String>(
            configuration.endpoint,
            queryParameters: {
              'serviceKey': serviceKey,
              'obsCode': station.code,
              'reqDate': day.apiDate,
              'type': 'json',
              'pageNo': pageNo.toString(),
              'numOfRows': _pageSize.toString(),
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
              throw const TideException(TideFailure.timedOut);
            },
          );
      final providerFailure = _providerFailure(response.data);
      if (providerFailure != null) throw TideException(providerFailure);
      final httpFailure = _httpFailure(response.statusCode);
      if (httpFailure != null) throw TideException(httpFailure);
      return _parsePage(response.data, pageNo);
    } on TideException {
      rethrow;
    } on DioException catch (error) {
      final providerFailure = _providerFailure(error.response?.data);
      final reason =
          providerFailure ??
          switch (error.type) {
            DioExceptionType.connectionTimeout ||
            DioExceptionType.sendTimeout ||
            DioExceptionType.receiveTimeout => TideFailure.timedOut,
            _ =>
              _httpFailure(error.response?.statusCode) ?? TideFailure.network,
          };
      throw TideException(reason);
    } on TimeoutException {
      throw const TideException(TideFailure.timedOut);
    } on Object {
      throw const TideException(TideFailure.invalidResponse);
    }
  }

  static TideFailure? _httpFailure(int? status) {
    if (status == 401 || status == 403) return TideFailure.unauthorized;
    if (status == 429) return TideFailure.rateLimited;
    if (status != null && status >= 500) return TideFailure.network;
    if (status != null && (status < 200 || status >= 300)) {
      return TideFailure.invalidResponse;
    }
    return null;
  }

  static TideFailure _apiFailure(String code, String message) {
    final normalized = code.trim().padLeft(2, '0');
    final text = message.toUpperCase();
    if (normalized == '03' || text.contains('NO_DATA')) {
      return TideFailure.noData;
    }
    if (const {'22', '23'}.contains(normalized) ||
        text.contains('LIMITED_NUMBER') ||
        text.contains('QUOTA')) {
      return TideFailure.rateLimited;
    }
    if (const {'20', '21', '30', '31', '32', '33'}.contains(normalized) ||
        text.contains('SERVICE_KEY') ||
        text.contains('UNAUTHORIZED')) {
      return TideFailure.unauthorized;
    }
    if (normalized == '10' || normalized == '11') {
      if (RegExp(r'OBS_?CODE|STATION|지점|관측소').hasMatch(text)) {
        return TideFailure.unsupportedStation;
      }
      if (RegExp(r'REQ_?DATE|DATE|날짜|일자').hasMatch(text)) {
        return TideFailure.unsupportedDate;
      }
    }
    if (text.contains('TIMEOUT')) return TideFailure.timedOut;
    return TideFailure.invalidResponse;
  }

  static TideFailure? _providerFailure(Object? body) {
    try {
      if (body is String && body.trimLeft().startsWith('<')) {
        String field(String name) =>
            RegExp(
              '<$name(?:\\s[^>]*)?>([\\s\\S]*?)</$name>',
              caseSensitive: false,
            ).firstMatch(body)?.group(1)?.trim() ??
            '';
        final gatewayCode = field('returnReasonCode');
        final code = gatewayCode.isEmpty ? field('resultCode') : gatewayCode;
        if (code.isEmpty || code.padLeft(2, '0') == '00') return null;
        return _apiFailure(
          code,
          '${field('returnAuthMsg')} ${field('resultMsg')} ${field('errMsg')}',
        );
      }
      final decoded = body is String ? jsonDecode(body) : body;
      if (decoded is! Map) return null;
      final root = decoded['response'] ?? decoded;
      if (root is! Map || root['header'] is! Map) return null;
      final header = root['header'] as Map;
      final code = header['resultCode']?.toString().trim();
      if (code == null || code.padLeft(2, '0') == '00') return null;
      return _apiFailure(code, header['resultMsg']?.toString() ?? '');
    } on Object {
      return null;
    }
  }

  static _Page _parsePage(Object? body, int requestedPage) {
    final decoded = body is String ? jsonDecode(body) : body;
    if (decoded is! Map) {
      throw const TideException(TideFailure.invalidResponse);
    }
    final root = decoded['response'] ?? decoded;
    if (root is! Map || root['header'] is! Map || root['body'] is! Map) {
      throw const TideException(TideFailure.invalidResponse);
    }
    final header = root['header'] as Map;
    final code = header['resultCode']?.toString().trim();
    if (code == null || code.padLeft(2, '0') != '00') {
      throw const TideException(TideFailure.invalidResponse);
    }
    final data = root['body'] as Map;
    final total = _optionalInt(data, 'totalCount', minimum: 0);
    final page = _optionalInt(data, 'pageNo', minimum: 1);
    final size = _optionalInt(data, 'numOfRows', minimum: 0);
    if ((page != null && page != requestedPage) ||
        (size != null && size > _pageSize)) {
      throw const TideException(TideFailure.invalidResponse);
    }
    Object? items = data['items'];
    if (items is Map && items.containsKey('item')) items = items['item'];
    final empty =
        items == null ||
        items == '' ||
        (items is List && items.isEmpty) ||
        (items is Map && items.isEmpty);
    if (empty) {
      if ((!data.containsKey('items') && total != 0) ||
          (total != null && total != 0)) {
        throw const TideException(TideFailure.invalidResponse);
      }
      return _Page(const [], total);
    }
    final List list;
    if (items is List) {
      list = items;
    } else if (items is Map && items.containsKey('predcDt')) {
      list = [items];
    } else {
      throw const TideException(TideFailure.invalidResponse);
    }
    if (list.length > _pageSize || list.any((item) => item is! Map)) {
      throw const TideException(TideFailure.invalidResponse);
    }
    return _Page(list.cast<Map>(), total);
  }

  static int? _optionalInt(Map data, String key, {required int minimum}) {
    if (!data.containsKey(key)) return null;
    final text = data[key].toString();
    final value = RegExp(r'^\d+$').hasMatch(text) ? int.tryParse(text) : null;
    if (value == null || value < minimum) {
      throw const TideException(TideFailure.invalidResponse);
    }
    return value;
  }

  TideForecast _forecast(List<Map> rows, TideStation requested, TideDay day) {
    if (rows.isEmpty) throw const TideException(TideFailure.noData);
    TideStation? returnedStation;
    final events = <DateTime, TideEvent>{};
    for (final row in rows) {
      final name = row['obsvtrNm'];
      final latitude = _number(row['lat']);
      final longitude = _number(row['lot']);
      if (name is! String ||
          name.trim().isEmpty ||
          latitude < -90 ||
          latitude > 90 ||
          longitude < -180 ||
          longitude > 180 ||
          (row.containsKey('obsCode') && row['obsCode'] != requested.code)) {
        throw const TideException(TideFailure.invalidResponse);
      }
      final station = TideStation(
        code: requested.code,
        name: name.trim(),
        latitude: latitude,
        longitude: longitude,
      );
      _checkStationCoordinates(requested, station);
      if (returnedStation != null &&
          (returnedStation.name != station.name ||
              (returnedStation.latitude - latitude).abs() > 0.000001 ||
              (returnedStation.longitude - longitude).abs() > 0.000001)) {
        throw const TideException(TideFailure.invalidResponse);
      }
      returnedStation ??= station;
      final at = _parseKst(row['predcDt']);
      if (TideDay.fromInstant(at) != day) {
        throw const TideException(TideFailure.invalidResponse);
      }
      final kind = switch (row['extrSe']?.toString().trim()) {
        '1' || '3' => TideEventKind.high,
        '2' || '4' => TideEventKind.low,
        _ => throw const TideException(TideFailure.invalidResponse),
      };
      final height = _number(row['predcTdlvVl']);
      final previous = events[at];
      if (previous != null &&
          (previous.kind != kind || previous.heightCm != height)) {
        throw const TideException(TideFailure.invalidResponse);
      }
      events[at] = TideEvent(at: at, heightCm: height, kind: kind);
    }
    final ordered = events.values.toList()
      ..sort((a, b) => a.at.compareTo(b.at));
    return TideForecast(
      station: returnedStation!,
      day: day,
      events: ordered,
      fetchedAt: _clock().toUtc(),
      sourceName: '국립해양조사원 조석예보',
    );
  }

  static double _number(Object? raw) {
    final value = raw is num ? raw.toDouble() : double.tryParse('$raw');
    if (value == null || !value.isFinite) {
      throw const TideException(TideFailure.invalidResponse);
    }
    return value;
  }

  static DateTime _parseKst(Object? raw) {
    final match = raw is String
        ? RegExp(
            r'^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?$',
          ).firstMatch(raw.trim())
        : null;
    if (match == null) {
      throw const TideException(TideFailure.invalidResponse);
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
      throw const TideException(TideFailure.invalidResponse);
    }
    return wallTime.subtract(const Duration(hours: 9));
  }

  static void _validateStation(TideStation station) {
    if (!RegExp(r'^[A-Z]{2}_[0-9]{4}$').hasMatch(station.code) ||
        station.name.trim().isEmpty ||
        !station.latitude.isFinite ||
        !station.longitude.isFinite ||
        station.latitude < -90 ||
        station.latitude > 90 ||
        station.longitude < -180 ||
        station.longitude > 180) {
      throw const TideException(TideFailure.unsupportedStation);
    }
  }

  static void _checkStationCoordinates(
    TideStation requested,
    TideStation actual,
  ) {
    if (requested.distanceKmTo(actual.latitude, actual.longitude) > 1) {
      throw const TideException(TideFailure.invalidResponse);
    }
  }
}

typedef _CacheKey = (String, TideDay);

class _Page {
  const _Page(this.rows, this.totalCount);
  final List<Map> rows;
  final int? totalCount;
}
