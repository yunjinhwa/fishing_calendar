import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fishing_build/data/maps/map_location.dart';
import 'package:fishing_build/data/services/external_data_service.dart';
import 'package:fishing_build/data/services/kma_weather_service.dart';
import 'package:fishing_build/data/weather/kma_forecast_time.dart';
import 'package:fishing_build/data/weather/kma_weather_configuration.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late DateTime now;
  late _Adapter adapter;
  late Dio dio;
  late KmaWeatherService service;
  final seoul = MapLocation(
    name: '서울',
    latitude: 37.5635694444444,
    longitude: 126.980008333333,
  );

  setUp(() {
    now = DateTime.utc(2026, 11, 2, 1, 10); // 10:10 KST.
    adapter = _Adapter(
      (request) => _success(
        request,
        validAt: KmaForecastTime.forCurrentHour(now).validAt,
      ),
    );
    dio = Dio()..httpClientAdapter = adapter;
    service = KmaWeatherService(
      dio: dio,
      clock: () => now,
      configuration: const KmaWeatherConfiguration(
        provider: 'data_go_kr',
        serviceKey: 'development+a/b==',
      ),
    );
  });

  test(
    'encoded and decoded public-data keys preserve literal plus characters',
    () async {
      const encoded = KmaWeatherConfiguration(
        provider: 'data_go_kr',
        serviceKey: ' development%2Ba%2Fb%3D%3D ',
      );
      expect(encoded.normalizedServiceKey, 'development+a/b==');
      expect(
        const KmaWeatherConfiguration(
          serviceKey: 'development+a/b==',
        ).normalizedServiceKey,
        'development+a/b==',
      );
      for (final key in [
        '',
        ' ',
        'invalid%ZZ',
        'has\nspace',
        'encoded%20space',
      ]) {
        expect(
          KmaWeatherConfiguration(
            provider: 'data_go_kr',
            serviceKey: key,
          ).isConfigured,
          isFalse,
        );
      }
      expect(encoded.toString(), isNot(contains('development')));
      service = KmaWeatherService(
        dio: dio,
        clock: () => now,
        configuration: encoded,
      );
      await service.fetchCurrentData(location: seoul);
      expect(
        adapter.calls.single.queryParameters['serviceKey'],
        'development+a/b==',
      );
      expect(
        adapter.calls.single.uri.queryParameters['serviceKey'],
        'development+a/b==',
      );
    },
  );

  test(
    'current hour is queried with truthful KST forecast metadata and no marine placeholders',
    () async {
      now = DateTime.utc(2026, 11, 2, 1, 50); // 10:50 -> previous09:30 issue.
      final result = await service.fetchCurrentData(location: seoul);
      final request = adapter.calls.single;
      expect(request.uri.scheme, 'https');
      expect(request.uri.host, 'apis.data.go.kr');
      expect(request.queryParameters, contains('serviceKey'));
      expect(request.queryParameters, isNot(contains('authKey')));
      expect(
        request.uri.path,
        '/1360000/VilageFcstInfoService_2.0/getUltraSrtFcst',
      );
      expect(request.queryParameters, containsPair('base_date', '20261102'));
      expect(request.queryParameters, containsPair('base_time', '0930'));
      expect(request.queryParameters, containsPair('numOfRows', '1000'));
      expect(request.queryParameters, containsPair('nx', '60'));
      expect(request.queryParameters, containsPair('ny', '127'));
      expect(result.weather, '흐림');
      expect(result.airTemperature, -1.5);
      expect(result.issuedAt, DateTime.utc(2026, 11, 2, 0, 30));
      expect(result.validAt, DateTime.utc(2026, 11, 2, 1));
      expect(result.fetchedAt, now);
      expect(result.sourceName, '기상청 초단기예보');
      expect(result.tide, isNull);
      expect(result.waterTemperature, isNull);
    },
  );

  test('API Hub uses only its selected endpoint and authKey', () async {
    service = KmaWeatherService(
      dio: dio,
      clock: () => now,
      configuration: const KmaWeatherConfiguration(
        provider: 'apihub',
        serviceKey: 'hub-test-key',
      ),
    );
    final result = await service.fetchCurrentData(location: seoul);
    final request = adapter.calls.single;
    expect(request.uri.scheme, 'https');
    expect(request.uri.host, 'apihub.kma.go.kr');
    expect(
      request.uri.path,
      '/api/typ02/openApi/VilageFcstInfoService_2.0/getUltraSrtFcst',
    );
    expect(request.queryParameters['authKey'], 'hub-test-key');
    expect(request.queryParameters, isNot(contains('serviceKey')));
    expect(result.weather, '흐림');
    final invalid = KmaWeatherService(
      dio: dio,
      configuration: const KmaWeatherConfiguration(
        provider: 'unknown-provider',
        serviceKey: 'hub-test-key',
      ),
    );
    await expectLater(
      invalid.fetchCurrentData(location: seoul),
      _failure(ExternalDataFailure.configuration),
    );
    expect(adapter.calls, hasLength(1));
  });

  test(
    'API Hub accepts its same-hour nominal base and preserves returned issue metadata',
    () async {
      service = KmaWeatherService(
        dio: dio,
        clock: () => now,
        configuration: const KmaWeatherConfiguration(
          provider: 'apihub',
          serviceKey: 'hub-test-key',
        ),
      );
      adapter.respond = (request) {
        final rows = _rows(
          request,
          KmaForecastTime.forCurrentHour(now).validAt,
        );
        for (final row in rows) {
          row['baseTime'] =
              '${(request.queryParameters['base_time'] as String).substring(0, 2)}00';
        }
        return _successWithRows(rows);
      };
      final result = await service.fetchCurrentData(location: seoul);
      expect(adapter.calls.single.queryParameters['base_time'], '0930');
      expect(result.issuedAt, DateTime.utc(2026, 11, 2, 0));
      expect(result.validAt, DateTime.utc(2026, 11, 2, 1));
      expect(result.weather, '흐림');
      expect(result.airTemperature, -1.5);

      // The public-data portal does not opt into API Hub's nominal-base convention.
      final portal = KmaWeatherService(
        dio: dio,
        clock: () => now,
        configuration: const KmaWeatherConfiguration(
          provider: 'data_go_kr',
          serviceKey: 'portal-test-key',
        ),
      );
      await expectLater(
        portal.fetchCurrentData(location: seoul),
        _failure(ExternalDataFailure.noData),
      );
      expect(adapter.calls, hasLength(3));
    },
  );

  test(
    'API Hub never mixes category rows from nominal and exact issue groups',
    () async {
      service = KmaWeatherService(
        dio: dio,
        clock: () => now,
        configuration: const KmaWeatherConfiguration(
          provider: 'apihub',
          serviceKey: 'hub-test-key',
        ),
      );
      adapter.respond = (request) {
        final rows = _rows(
          request,
          KmaForecastTime.forCurrentHour(now).validAt,
        );
        rows.first['baseTime'] =
            '${(request.queryParameters['base_time'] as String).substring(0, 2)}00';
        return _successWithRows(rows);
      };
      await expectLater(
        service.fetchCurrentData(location: seoul),
        _failure(ExternalDataFailure.invalidResponse),
      );
      expect(adapter.calls, hasLength(1));
      adapter.respond = (request) {
        final rows = _rows(
          request,
          KmaForecastTime.forCurrentHour(now).validAt,
        );
        for (final row in rows) {
          row['baseTime'] = '0700';
        }
        return _successWithRows(rows);
      };
      await expectLater(
        service.fetchCurrentData(location: seoul),
        _failure(ExternalDataFailure.noData),
      );
      expect(adapter.calls, hasLength(3));
    },
  );

  test(
    'coordinate-less and unsupported points and missing configuration never call the API',
    () async {
      await expectLater(
        service.fetchCurrentData(location: MapLocation(name: '수동 장소')),
        _failure(ExternalDataFailure.coordinatesRequired),
      );
      await expectLater(
        service.fetchCurrentData(
          location: MapLocation(name: '호주', latitude: -33.86, longitude: 151.2),
        ),
        _failure(ExternalDataFailure.unsupportedLocation),
      );
      final unconfigured = KmaWeatherService(
        dio: dio,
        configuration: const KmaWeatherConfiguration(
          provider: 'data_go_kr',
          serviceKey: '',
        ),
      );
      await expectLater(
        unconfigured.fetchCurrentData(location: seoul),
        _failure(ExternalDataFailure.configuration),
      );
      expect(adapter.calls, isEmpty);
    },
  );

  test(
    'same-grid in-flight requests share a call but keep each caller place identity',
    () async {
      final pending = Completer<ResponseBody>();
      adapter.respond = (_) => pending.future;
      final first = service.fetchCurrentData(location: seoul);
      final nearby = MapLocation(
        name: '다른 이름',
        latitude: seoul.latitude! + 0.00001,
        longitude: seoul.longitude! + 0.00001,
      );
      final second = service.fetchCurrentData(
        location: nearby,
        forceRefresh: true,
      );
      await adapter.started.future;
      expect(adapter.calls, hasLength(1));
      pending.complete(
        _success(
          adapter.calls.single,
          validAt: KmaForecastTime.forCurrentHour(now).validAt,
        ),
      );
      final results = await Future.wait([first, second]);
      expect(results.first.locationName, '서울');
      expect(results.last.locationName, '다른 이름');
      expect(results.last.latitude, nearby.latitude);
      expect(results.last.longitude, nearby.longitude);
      final cached = await service.fetchCurrentData(location: nearby);
      expect(cached.locationName, '다른 이름');
      expect(adapter.calls, hasLength(1));
    },
  );

  test(
    'cache expires at ten minutes and forced refresh bypasses fresh data',
    () async {
      await service.fetchCurrentData(location: seoul);
      now = now.add(const Duration(minutes: 9));
      await service.fetchCurrentData(location: seoul);
      expect(adapter.calls, hasLength(1));
      now = now.add(const Duration(minutes: 1));
      await service.fetchCurrentData(location: seoul);
      expect(adapter.calls, hasLength(2));
      await service.fetchCurrentData(location: seoul, forceRefresh: true);
      expect(adapter.calls, hasLength(3));
    },
  );

  test(
    'hour rollover chooses the new forecast rather than a cached prior hour',
    () async {
      now = DateTime.utc(2026, 11, 2, 1, 59);
      final old = await service.fetchCurrentData(location: seoul);
      now = now.add(const Duration(minutes: 2));
      final latest = await service.fetchCurrentData(location: seoul);
      expect(adapter.calls, hasLength(2));
      expect(latest.issuedAt, old.issuedAt.add(const Duration(hours: 1)));
      expect(latest.validAt, old.validAt.add(const Duration(hours: 1)));
    },
  );

  test('bounded cache evicts the least recently used grid', () async {
    service = KmaWeatherService(
      dio: dio,
      clock: () => now,
      maxCachedEntries: 2,
      configuration: const KmaWeatherConfiguration(
        provider: 'data_go_kr',
        serviceKey: 'test-key',
      ),
    );
    final busan = MapLocation(
      name: '부산',
      latitude: 35.0881166666666,
      longitude: 129.070186111111,
    );
    final jeju = MapLocation(
      name: '제주',
      latitude: 33.4856944444444,
      longitude: 126.500333333333,
    );
    await service.fetchCurrentData(location: seoul);
    await service.fetchCurrentData(location: busan);
    await service.fetchCurrentData(location: seoul);
    await service.fetchCurrentData(location: jeju);
    await service.fetchCurrentData(location: busan);
    expect(adapter.calls, hasLength(4));
  });

  test(
    'precipitation overrides sky and missing partial values never become fake weather',
    () async {
      final cases = <(String?, String?, String?, String?, double?)>[
        ('1', '1', '12', '비', 12),
        ('1', '2', '12', '비/눈', 12),
        ('1', '3', '12', '눈', 12),
        ('1', '4', '12', '소나기', 12),
        ('1', '5', '12', '빗방울', 12),
        ('1', '6', '12', '빗방울/눈날림', 12),
        ('1', '7', '12', '눈날림', 12),
        ('3', '0', '-999', '구름많음', null),
        (null, '0', '0', null, 0),
        ('1', '99', '3', null, 3),
        ('4', null, 'NaN', '흐림', null),
      ];
      for (final (sky, pty, temperature, expectedWeather, expectedTemperature)
          in cases) {
        adapter.respond = (request) => _success(
          request,
          validAt: KmaForecastTime.forCurrentHour(now).validAt,
          sky: sky,
          pty: pty,
          temperature: temperature,
        );
        final result = await service.fetchCurrentData(
          location: seoul,
          forceRefresh: true,
        );
        expect(result.weather, expectedWeather);
        expect(result.airTemperature, expectedTemperature);
      }
    },
  );

  test(
    'all missing fields retry one previous issue and preserve the requested valid time',
    () async {
      adapter.respond = (request) => adapter.calls.length == 1
          ? _success(
              request,
              validAt: KmaForecastTime.forCurrentHour(now).validAt,
              sky: '900',
              pty: '900',
              temperature: '-999',
            )
          : _success(
              request,
              validAt: KmaForecastTime.forCurrentHour(now).validAt,
            );
      final result = await service.fetchCurrentData(location: seoul);
      expect(adapter.calls, hasLength(2));
      expect(adapter.calls.last.queryParameters['base_time'], '0830');
      expect(result.issuedAt, DateTime.utc(2026, 11, 1, 23, 30));
      expect(result.validAt, DateTime.utc(2026, 11, 2, 1));
    },
  );

  test(
    'no data response retries at most once and failures are not cached',
    () async {
      adapter.respond = (_) => _json({
        'response': {
          'header': {'resultCode': '03', 'resultMsg': 'NO_DATA'},
        },
      });
      await expectLater(
        service.fetchCurrentData(location: seoul),
        _failure(ExternalDataFailure.noData),
      );
      expect(adapter.calls, hasLength(2));
      adapter.respond = (request) => _success(
        request,
        validAt: KmaForecastTime.forCurrentHour(now).validAt,
      );
      await service.fetchCurrentData(location: seoul);
      expect(adapter.calls, hasLength(3));
    },
  );

  test(
    'rows from another forecast time, base or grid are never merged',
    () async {
      adapter.respond = (request) {
        final rows = _rows(
          request,
          KmaForecastTime.forCurrentHour(now).validAt,
        );
        rows[0]['fcstTime'] = '1100';
        rows[1]['baseTime'] = '0130';
        rows[2]['nx'] = 99;
        return _successWithRows(rows);
      };
      await expectLater(
        service.fetchCurrentData(location: seoul),
        _failure(ExternalDataFailure.noData),
      );
      expect(adapter.calls, hasLength(2));
    },
  );

  test(
    'conflicting duplicates are rejected instead of silently choosing one',
    () async {
      adapter.respond = (request) {
        final rows = _rows(
          request,
          KmaForecastTime.forCurrentHour(now).validAt,
        );
        rows.add({...rows.first, 'fcstValue': '1'});
        return _successWithRows(rows);
      };
      await expectLater(
        service.fetchCurrentData(location: seoul),
        _failure(ExternalDataFailure.invalidResponse),
      );
      expect(adapter.calls, hasLength(1));
    },
  );

  test(
    'JSON authentication and quota errors do not retry or expose server messages',
    () async {
      for (final (code, expected) in [
        ('20', ExternalDataFailure.unauthorized),
        ('30', ExternalDataFailure.unauthorized),
        ('22', ExternalDataFailure.rateLimited),
        ('10', ExternalDataFailure.invalidResponse),
      ]) {
        final before = adapter.calls.length;
        adapter.respond = (_) => _json({
          'response': {
            'header': {
              'resultCode': code,
              'resultMsg': 'development+a/b== private URI',
            },
          },
        });
        try {
          await service.fetchCurrentData(location: seoul);
          fail('Expected a sanitized failure');
        } on ExternalDataException catch (error) {
          expect(error.reason, expected);
          expect(error.toString(), isNot(contains('development')));
          expect(error.message, isNot(contains('private')));
        }
        expect(adapter.calls.length, before + 1);
      }
    },
  );

  test(
    'XML service errors and non-JSON documents become safe typed failures',
    () async {
      adapter.respond = (_) => ResponseBody.fromString(
        '''<OpenAPI_ServiceResponse><cmmMsgHeader>
      <errMsg>SERVICE ERROR</errMsg><returnAuthMsg>SERVICE_KEY_IS_NOT_REGISTERED_ERROR</returnAuthMsg>
      <returnReasonCode>30</returnReasonCode></cmmMsgHeader></OpenAPI_ServiceResponse>''',
        200,
      );
      await expectLater(
        service.fetchCurrentData(location: seoul),
        _failure(ExternalDataFailure.unauthorized),
      );
      adapter.respond = (_) =>
          ResponseBody.fromString('<html>upstream error</html>', 200);
      await expectLater(
        service.fetchCurrentData(location: seoul),
        _failure(ExternalDataFailure.invalidResponse),
      );
      adapter.respond = (_) => ResponseBody.fromString('{broken JSON', 200);
      await expectLater(
        service.fetchCurrentData(location: seoul),
        _failure(ExternalDataFailure.invalidResponse),
      );
      expect(adapter.calls, hasLength(3));
    },
  );

  test(
    'HTTP access, quota and server errors never retry and retain no raw transport details',
    () async {
      for (final (status, expected) in [
        (401, ExternalDataFailure.unauthorized),
        (403, ExternalDataFailure.unauthorized),
        (429, ExternalDataFailure.rateLimited),
        (503, ExternalDataFailure.network),
        (404, ExternalDataFailure.invalidResponse),
      ]) {
        final before = adapter.calls.length;
        adapter.respond = (_) =>
            ResponseBody.fromString('development+a/b==', status);
        await expectLater(
          service.fetchCurrentData(location: seoul),
          _failure(expected),
        );
        expect(adapter.calls.length, before + 1);
      }
    },
  );

  test('Dio connection failures are sanitized without a retry', () async {
    adapter.respond = (request) => throw DioException(
      requestOptions: request,
      type: DioExceptionType.connectionError,
      message: 'secret-key in request URI',
    );
    await expectLater(
      service.fetchCurrentData(location: seoul),
      _failure(ExternalDataFailure.network),
    );
    expect(adapter.calls, hasLength(1));
  });

  test(
    'an unresponsive transport has a bounded wait and can later be retried',
    () async {
      final pending = Completer<ResponseBody>();
      adapter.respond = (_) => pending.future;
      service = KmaWeatherService(
        dio: dio,
        clock: () => now,
        requestTimeout: const Duration(milliseconds: 10),
        configuration: const KmaWeatherConfiguration(
          provider: 'data_go_kr',
          serviceKey: 'test-key',
        ),
      );
      await expectLater(
        service.fetchCurrentData(location: seoul),
        _failure(ExternalDataFailure.timedOut),
      );
      pending.complete(
        _success(
          adapter.calls.single,
          validAt: KmaForecastTime.forCurrentHour(now).validAt,
        ),
      );
      adapter.respond = (request) => _success(
        request,
        validAt: KmaForecastTime.forCurrentHour(now).validAt,
      );
      expect((await service.fetchCurrentData(location: seoul)).weather, '흐림');
    },
  );
}

Matcher _failure(ExternalDataFailure reason) => throwsA(
  isA<ExternalDataException>().having(
    (error) => error.reason,
    'reason',
    reason,
  ),
);

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  FutureOr<ResponseBody> Function(RequestOptions) respond;
  final calls = <RequestOptions>[];
  final started = Completer<void>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(options);
    if (!started.isCompleted) started.complete();
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body) => ResponseBody.fromString(
  jsonEncode(body),
  200,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);

List<Map<String, Object?>> _rows(
  RequestOptions request,
  DateTime validAt, {
  String? sky = '4',
  String? pty = '0',
  String? temperature = '-1.5',
}) => [
  for (final (category, value) in [
    ('SKY', sky),
    ('PTY', pty),
    ('T1H', temperature),
  ])
    if (value != null)
      {
        'baseDate': request.queryParameters['base_date'],
        'baseTime': request.queryParameters['base_time'],
        'fcstDate': KmaForecastTime.date(validAt),
        'fcstTime': KmaForecastTime.time(validAt),
        'nx': int.parse(request.queryParameters['nx'] as String),
        'ny': int.parse(request.queryParameters['ny'] as String),
        'category': category,
        'fcstValue': value,
      },
];

ResponseBody _success(
  RequestOptions request, {
  required DateTime validAt,
  String? sky = '4',
  String? pty = '0',
  String? temperature = '-1.5',
}) => _successWithRows(
  _rows(request, validAt, sky: sky, pty: pty, temperature: temperature),
);

ResponseBody _successWithRows(List<Map<String, Object?>> rows) => _json({
  'response': {
    'header': {'resultCode': '00', 'resultMsg': 'NORMAL_SERVICE'},
    'body': {
      'items': {'item': rows},
      'totalCount': rows.length,
    },
  },
});
