import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../maps/map_location.dart';
import 'historical_conditions.dart';
import 'historical_conditions_service.dart';
import 'kma_historical_weather_configuration.dart';

/// Exact-hour ASOS observations and the station coordinates valid at that hour.
/// Contract: https://apihub.kma.go.kr/getAttachFile.do?fileName=API.pdf
class KmaHistoricalWeatherService implements HistoricalWeatherService {
  KmaHistoricalWeatherService({
    Dio? dio,
    DateTime Function()? clock,
    this.configuration = const KmaHistoricalWeatherConfiguration(),
    this.cacheTtl = const Duration(hours: 24),
    this.noDataCacheTtl = const Duration(minutes: 10),
    this.requestTimeout = const Duration(seconds: 12),
    this.maxCachedEntries = 128,
  }) : _dio = dio ?? Dio(),
       _clock = clock ?? DateTime.now {
    if (cacheTtl <= Duration.zero ||
        noDataCacheTtl <= Duration.zero ||
        requestTimeout <= Duration.zero ||
        maxCachedEntries < 1) {
      throw ArgumentError('Historical weather limits must be positive.');
    }
  }

  static final KmaHistoricalWeatherService instance =
      KmaHistoricalWeatherService();
  static const _maxResponseBytes = 512 * 1024;
  static const _maxStationDistanceKm = 50;
  static final _firstHour = DateTime.utc(2019, 12, 31, 15); // 2020-01-01 KST.

  final Dio _dio;
  final DateTime Function() _clock;
  final KmaHistoricalWeatherConfiguration configuration;
  final Duration cacheTtl;
  final Duration noDataCacheTtl;
  final Duration requestTimeout;
  final int maxCachedEntries;
  final _cache = <DateTime, _CacheEntry>{};
  final _inFlight = <DateTime, Future<_HourSnapshot>>{};

  @override
  Future<HistoricalWeatherObservation> fetchAt({
    required MapLocation location,
    required DateTime requestedAt,
    bool forceRefresh = false,
  }) async {
    if (!location.hasCoordinates) {
      throw const HistoricalDataException(
        HistoricalDataFailure.coordinatesRequired,
      );
    }
    final hour = historicalHour(requestedAt);
    final now = _clock().toUtc();
    if (hour.isBefore(_firstHour) || !hour.isBefore(historicalHour(now))) {
      throw const HistoricalDataException(
        HistoricalDataFailure.unsupportedDate,
      );
    }
    final serviceKey = configuration.normalizedServiceKey;
    if (!configuration.isConfigured || serviceKey == null) {
      throw const HistoricalDataException(HistoricalDataFailure.configuration);
    }
    final snapshot = await _fetchHour(hour, serviceKey, forceRefresh);
    final nearby =
        snapshot.stations
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
    if (nearby.isEmpty) {
      throw const HistoricalDataException(
        HistoricalDataFailure.unsupportedLocation,
      );
    }
    for (final station in nearby) {
      final reading = snapshot.readings[station.code];
      if (reading == null) continue;
      return HistoricalWeatherObservation(
        location: location,
        station: station,
        requestedAt: requestedAt.toUtc(),
        observedAt: hour,
        fetchedAt: snapshot.fetchedAt,
        weather: reading.weather,
        airTemperature: reading.temperature,
      );
    }
    throw const HistoricalDataException(HistoricalDataFailure.noData);
  }

  Future<_HourSnapshot> _fetchHour(
    DateTime hour,
    String serviceKey,
    bool forceRefresh,
  ) {
    final cached = _cache.remove(hour);
    if (cached != null && !forceRefresh) {
      final age = _clock().toUtc().difference(cached.fetchedAt);
      final ttl = cached.snapshot == null ? noDataCacheTtl : cacheTtl;
      if (!age.isNegative && age < ttl) {
        _cache[hour] = cached;
        if (cached.snapshot case final snapshot?) return Future.value(snapshot);
        return Future.error(
          const HistoricalDataException(HistoricalDataFailure.noData),
        );
      }
    }
    return _inFlight[hour] ??= _loadAndCache(hour, serviceKey);
  }

  Future<_HourSnapshot> _loadAndCache(DateTime hour, String serviceKey) async {
    try {
      final target = _kstTime(hour);
      // Both requests describe the same historical hour, including station moves.
      final bodies = await Future.wait([
        _request(configuration.stationsEndpoint!, {
          'inf': 'SFC',
          'stn': '0',
          'tm': target,
          'help': '1',
          'authKey': serviceKey,
        }),
        _request(configuration.observationsEndpoint!, {
          'tm': target,
          'stn': '0',
          'help': '1',
          'authKey': serviceKey,
        }),
      ]);
      final stations = _parseStations(bodies[0]);
      final readings = _parseReadings(bodies[1], target);
      if (readings.isEmpty) {
        throw const HistoricalDataException(HistoricalDataFailure.noData);
      }
      final snapshot = _HourSnapshot(stations, readings, _clock().toUtc());
      _putCache(hour, _CacheEntry(snapshot, snapshot.fetchedAt));
      return snapshot;
    } on HistoricalDataException catch (error) {
      if (error.reason == HistoricalDataFailure.noData) {
        _putCache(hour, _CacheEntry(null, _clock().toUtc()));
      }
      rethrow;
    } finally {
      _inFlight.remove(hour);
    }
  }

  void _putCache(DateTime hour, _CacheEntry entry) {
    _cache.remove(hour);
    _cache[hour] = entry;
    while (_cache.length > maxCachedEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  Future<String> _request(
    String endpoint,
    Map<String, String> parameters,
  ) async {
    final cancellation = CancelToken();
    try {
      return await (() async {
        final response = await _dio.get<ResponseBody>(
          endpoint,
          queryParameters: parameters,
          cancelToken: cancellation,
          options: Options(
            responseType: ResponseType.stream,
            sendTimeout: requestTimeout,
            receiveTimeout: requestTimeout,
            followRedirects: false,
            validateStatus: (_) => true,
          ),
        );
        final failure = _httpFailure(response.statusCode);
        if (failure != null) {
          cancellation.cancel();
          throw HistoricalDataException(failure);
        }
        final body = response.data;
        if (body == null) {
          throw const HistoricalDataException(
            HistoricalDataFailure.invalidResponse,
          );
        }
        final contentLength = int.tryParse(
          response.headers.value(Headers.contentLengthHeader) ?? '',
        );
        if (contentLength != null && contentLength > _maxResponseBytes) {
          cancellation.cancel();
          throw const HistoricalDataException(
            HistoricalDataFailure.invalidResponse,
          );
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in body.stream) {
          if (bytes.length + chunk.length > _maxResponseBytes) {
            cancellation.cancel();
            throw const HistoricalDataException(
              HistoricalDataFailure.invalidResponse,
            );
          }
          bytes.add(chunk);
        }
        // Numeric observations remain readable even if an old catalog response
        // uses a legacy Korean encoding; unreadable station names get an ID label.
        final text = utf8.decode(bytes.takeBytes(), allowMalformed: true);
        _checkApiFailure(text);
        return text;
      })().timeout(
        requestTimeout,
        onTimeout: () {
          cancellation.cancel();
          throw const HistoricalDataException(HistoricalDataFailure.timedOut);
        },
      );
    } on HistoricalDataException {
      rethrow;
    } on DioException catch (error) {
      final failure = switch (error.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout => HistoricalDataFailure.timedOut,
        _ =>
          error.response == null
              ? HistoricalDataFailure.network
              : _httpFailure(error.response?.statusCode) ??
                    HistoricalDataFailure.network,
      };
      throw HistoricalDataException(failure);
    } on TimeoutException {
      throw const HistoricalDataException(HistoricalDataFailure.timedOut);
    } on Object {
      throw const HistoricalDataException(
        HistoricalDataFailure.invalidResponse,
      );
    }
  }

  static HistoricalDataFailure? _httpFailure(int? status) {
    if (status == 401 || status == 403) {
      return HistoricalDataFailure.unauthorized;
    }
    if (status == 429) return HistoricalDataFailure.rateLimited;
    if (status != null && status >= 500) return HistoricalDataFailure.network;
    if (status != null && status >= 200 && status < 300) return null;
    return HistoricalDataFailure.invalidResponse;
  }

  static void _checkApiFailure(String body) {
    if (body.trimLeft().startsWith('#START7777') &&
        body.trimRight().endsWith('#7777END')) {
      return;
    }
    final upper = body.toUpperCase();
    final code = RegExp(
      r'<(?:returnReasonCode|resultCode)>\s*(\d+)\s*</',
      caseSensitive: false,
    ).firstMatch(body)?.group(1)?.padLeft(2, '0');
    if (upper.contains('LIMITED_NUMBER') ||
        code == '22' ||
        upper.contains('TOO MANY REQUEST') ||
        body.contains('호출 제한') ||
        body.contains('요청 제한')) {
      throw const HistoricalDataException(HistoricalDataFailure.rateLimited);
    }
    if (upper.contains('AUTHORIZATION') ||
        const {'20', '21', '30', '31', '32', '33'}.contains(code) ||
        upper.contains('UNAUTHORIZED') ||
        upper.contains('SERVICE_KEY') ||
        upper.contains('INVALID AUTH') ||
        body.contains('인증키') ||
        body.contains('권한이 없') ||
        body.contains('활용신청')) {
      throw const HistoricalDataException(HistoricalDataFailure.unauthorized);
    }
    if (code == '03' ||
        upper.contains('NO_DATA') ||
        body.contains('자료가 없습니다')) {
      throw const HistoricalDataException(HistoricalDataFailure.noData);
    }
    if (!body.trimLeft().startsWith('#START7777') ||
        !body.trimRight().endsWith('#7777END')) {
      throw const HistoricalDataException(
        HistoricalDataFailure.invalidResponse,
      );
    }
  }

  static List<List<String>> _rows(String body) => const LineSplitter()
      .convert(body)
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty && !line.startsWith('#'))
      .map((line) => line.split(RegExp(r'\s+')))
      .toList();

  static Map<String, int> _numberedColumns(String body) {
    final result = <String, int>{};
    final pattern = RegExp(
      r'^#\s*(\d+)\.\s*([A-Z][A-Z0-9_]*)\s*:',
      multiLine: true,
    );
    for (final match in pattern.allMatches(body)) {
      result[match.group(2)!] = int.parse(match.group(1)!) - 1;
    }
    return result;
  }

  static List<HistoricalWeatherStation> _parseStations(String body) {
    var columns = _numberedColumns(body);
    if (!columns.keys.toSet().containsAll({'STN_ID', 'LON', 'LAT'})) {
      final header = const LineSplitter()
          .convert(body)
          .where(
            (line) =>
                RegExp(r'^#\s*(?:STN_ID|STN)\s+LON\s+LAT\b').hasMatch(line),
          );
      if (header.isEmpty) {
        throw const HistoricalDataException(
          HistoricalDataFailure.invalidResponse,
        );
      }
      final fields = header.first
          .replaceFirst(RegExp(r'^#\s*'), '')
          .trim()
          .split(RegExp(r'\s+'));
      columns = {for (var i = 0; i < fields.length; i++) fields[i]: i};
      // The live catalog labels the station ID and a later station code both
      // "STN". The leading field is the ID referenced by ASOS observations.
      if (fields.first == 'STN') columns['STN_ID'] = 0;
    }
    final result = <String, HistoricalWeatherStation>{};
    for (final row in _rows(body)) {
      String field(String name) {
        final index = columns[name];
        return index != null && index >= 0 && index < row.length
            ? row[index]
            : '';
      }

      final code = field('STN_ID');
      final latitude = double.tryParse(field('LAT'));
      final longitude = double.tryParse(field('LON'));
      if (!RegExp(r'^\d{1,4}$').hasMatch(code) ||
          latitude == null ||
          !latitude.isFinite ||
          latitude.abs() > 90 ||
          longitude == null ||
          !longitude.isFinite ||
          longitude.abs() > 180) {
        throw const HistoricalDataException(
          HistoricalDataFailure.invalidResponse,
        );
      }
      var name = field('STN_KO');
      if (name.isEmpty || name == '-' || name.contains('\uFFFD')) {
        name = '기상청 관측소 $code';
      }
      final station = HistoricalWeatherStation(
        code: code,
        name: name,
        latitude: latitude,
        longitude: longitude,
      );
      final existing = result[code];
      if (existing != null &&
          (existing.latitude != latitude ||
              existing.longitude != longitude ||
              existing.name != name)) {
        throw const HistoricalDataException(
          HistoricalDataFailure.invalidResponse,
        );
      }
      result[code] = station;
    }
    if (result.isEmpty) {
      throw const HistoricalDataException(HistoricalDataFailure.noData);
    }
    return result.values.toList(growable: false);
  }

  static Map<String, _Reading> _parseReadings(String body, String target) {
    // The fixed field order and the numbered help are published in API.pdf.
    final help = _numberedColumns(body);
    final columns = help.isEmpty ? _observationColumns : help;
    if (!columns.keys.toSet().containsAll({
      'TM',
      'STN',
      'TA',
      'WC',
      'WW',
      'CA_TOT',
    })) {
      throw const HistoricalDataException(
        HistoricalDataFailure.invalidResponse,
      );
    }
    if (help.isEmpty &&
        !RegExp(r'^#\s*YYMMDDHHMI\s+STN\b', multiLine: true).hasMatch(body)) {
      throw const HistoricalDataException(
        HistoricalDataFailure.invalidResponse,
      );
    }
    final result = <String, _Reading>{};
    final seen = <String, String>{};
    for (final row in _rows(body)) {
      if (row.length < _observationColumns.length) {
        throw const HistoricalDataException(
          HistoricalDataFailure.invalidResponse,
        );
      }
      String field(String name) {
        final index = columns[name]!;
        if (index < 0 || index >= row.length) {
          throw const HistoricalDataException(
            HistoricalDataFailure.invalidResponse,
          );
        }
        return row[index];
      }

      if (field('TM') != target) continue;
      final code = field('STN');
      if (!RegExp(r'^\d{1,4}$').hasMatch(code)) {
        throw const HistoricalDataException(
          HistoricalDataFailure.invalidResponse,
        );
      }
      final fingerprint = [
        field('TA'),
        field('WC'),
        field('WW'),
        field('CA_TOT'),
      ].join('|');
      if (seen.containsKey(code) && seen[code] != fingerprint) {
        throw const HistoricalDataException(
          HistoricalDataFailure.invalidResponse,
        );
      }
      seen[code] = fingerprint;
      final value = double.tryParse(field('TA'));
      // TA can legitimately be -9.0 C. Temperature missing markers are -99
      // variants; a physical range also rejects NaN, infinities and sentinels.
      final temperature =
          value != null && value.isFinite && value >= -60 && value <= 60
          ? value
          : null;
      final weather = _weather(field('WC'), field('WW'), field('CA_TOT'));
      if (temperature != null || weather != null) {
        result[code] = _Reading(weather, temperature);
      }
    }
    return result;
  }

  static String? _weather(String wc, String domestic, String cloud) {
    // WMO 4677 20..29 refer to the preceding hour, not current precipitation.
    final current = int.tryParse(wc) ?? -1;
    final fromWmo = switch (current) {
      4 => '연기',
      5 => '연무',
      6 => '황사',
      7 || 8 || 9 || >= 30 && <= 35 => '먼지·모래',
      10 => '박무',
      11 || 12 || >= 40 && <= 49 => '안개',
      13 => '번개',
      17 || >= 95 && <= 99 => '뇌우',
      18 => '스콜',
      19 => '깔때기 구름',
      >= 36 && <= 39 => '날린 눈',
      >= 50 && <= 55 => '이슬비',
      56 || 57 => '어는 이슬비',
      58 || 59 || >= 60 && <= 65 || 91 || 92 => '비',
      66 || 67 => '어는 비',
      68 || 69 || 83 || 84 => '진눈깨비',
      >= 70 && <= 75 || 77 || 78 || 85 || 86 => '눈',
      76 => '얼음침',
      79 => '얼음싸라기',
      >= 80 && <= 82 => '소나기',
      >= 87 && <= 90 => '우박',
      93 || 94 => '눈·우박',
      _ => null,
    };
    if (fromWmo != null) return fromWmo;
    // Domestic codes are two characters each, at most eleven codes (API.pdf).
    if (RegExp(r'^(?:\d{2}){1,11}$').hasMatch(domestic)) {
      final descriptions = <String>{};
      for (var i = 0; i < domestic.length; i += 2) {
        final description =
            _domesticWeather[int.parse(domestic.substring(i, i + 2))];
        if (description != null) descriptions.add(description);
      }
      if (descriptions.isNotEmpty) return descriptions.take(3).join(', ');
    }
    // Sky descriptions require an actual cloud observation, never RN=0.
    return switch (int.tryParse(cloud) ?? -1) {
      >= 0 && <= 2 => '맑음',
      >= 3 && <= 5 => '구름조금',
      >= 6 && <= 8 => '구름많음',
      9 || 10 => '흐림',
      _ => null,
    };
  }

  static String _kstTime(DateTime hour) {
    final kst = hour.add(const Duration(hours: 9));
    String pad(int value) => value.toString().padLeft(2, '0');
    return '${kst.year}${pad(kst.month)}${pad(kst.day)}${pad(kst.hour)}00';
  }
}

const _observationFields = [
  'TM',
  'STN',
  'WD',
  'WS',
  'GST_WD',
  'GST_WS',
  'GST_TM',
  'PA',
  'PS',
  'PT',
  'PR',
  'TA',
  'TD',
  'HM',
  'PV',
  'RN',
  'RN_DAY',
  'RN_JUN',
  'RN_INT',
  'SD_HR3',
  'SD_DAY',
  'SD_TOT',
  'WC',
  'WP',
  'WW',
  'CA_TOT',
  'CA_MID',
  'CH_MIN',
  'CT',
  'CT_TOP',
  'CT_MID',
  'CT_LOW',
  'VS',
  'SS',
  'SI',
  'ST_GD',
  'TS',
  'TE_005',
  'TE_01',
  'TE_02',
  'TE_03',
  'ST_SEA',
  'WH',
  'BF',
  'IR',
  'IX',
];
final _observationColumns = {
  for (var i = 0; i < _observationFields.length; i++) _observationFields[i]: i,
};

// KMA's official 현상코드(국내식).pdf, linked from the ASOS API documentation.
const _domesticWeather = <int, String>{
  1: '비',
  2: '이슬비',
  3: '착빙성 비',
  4: '소나기',
  5: '눈',
  6: '진눈깨비',
  7: '어는 이슬비',
  8: '소낙눈',
  9: '소낙성 진눈깨비',
  10: '싸락눈',
  11: '가루눈',
  12: '어는 비',
  13: '싸락우박',
  14: '우박',
  15: '얼음침',
  16: '안개',
  17: '땅안개',
  18: '얼음안개',
  19: '박무',
  20: '땅 날린눈',
  21: '높은 날린눈',
  22: '눈보라',
  40: '연무',
  41: '먼지연무',
  42: '황사',
  43: '연기',
  44: '강회',
  45: '땅날린 먼지',
  46: '높은날린 먼지',
  47: '먼지보라',
  48: '회오리바람',
  70: '뇌전',
  71: '천둥',
  72: '번개',
  85: '폭풍',
  90: '맑음',
  91: '구름조금',
  92: '흐림',
};

class _Reading {
  const _Reading(this.weather, this.temperature);
  final String? weather;
  final double? temperature;
}

class _HourSnapshot {
  const _HourSnapshot(this.stations, this.readings, this.fetchedAt);
  final List<HistoricalWeatherStation> stations;
  final Map<String, _Reading> readings;
  final DateTime fetchedAt;
}

class _CacheEntry {
  const _CacheEntry(this.snapshot, this.fetchedAt);
  final _HourSnapshot? snapshot;
  final DateTime fetchedAt;
}
