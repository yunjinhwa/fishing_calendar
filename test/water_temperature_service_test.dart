import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fishing_build/data/maps/map_location.dart';
import 'package:fishing_build/data/water_temperature/khoa_water_temperature_configuration.dart';
import 'package:fishing_build/data/water_temperature/khoa_water_temperature_service.dart';
import 'package:fishing_build/data/water_temperature/khoa_water_temperature_stations.dart';
import 'package:fishing_build/data/water_temperature/water_temperature_models.dart';
import 'package:fishing_build/data/water_temperature/water_temperature_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _station = WaterTemperatureStation(
  code: 'DT_0001',
  name: 'First station',
  latitude: 35,
  longitude: 127,
);
const _second = WaterTemperatureStation(
  code: 'DT_0002',
  name: 'Second station',
  latitude: 35.01,
  longitude: 127,
);
const _third = WaterTemperatureStation(
  code: 'DT_0003',
  name: 'Third station',
  latitude: 35.02,
  longitude: 127,
);
const _fourth = WaterTemperatureStation(
  code: 'DT_0004',
  name: 'Fourth station',
  latitude: 35.03,
  longitude: 127,
);

void main() {
  late DateTime now;
  late Dio dio;
  late _Adapter adapter;
  late KhoaWaterTemperatureService service;
  late MapLocation location;

  setUp(() {
    now = DateTime.utc(2026, 11, 3, 3); // Noon in KST.
    location = MapLocation(name: 'Fishing spot', latitude: 35, longitude: 127);
    adapter = _Adapter((_) => _success([_row()]));
    dio = Dio()..httpClientAdapter = adapter;
    service = KhoaWaterTemperatureService(
      dio: dio,
      clock: () => now,
      stations: const [_station],
      configuration: const KhoaWaterTemperatureConfiguration(
        serviceKey: 'test+a/b==',
      ),
    );
  });

  tearDown(() => dio.close(force: true));

  test('configuration normalizes either portal key and does not print it', () {
    const key = KhoaWaterTemperatureConfiguration(
      serviceKey: ' test%2Ba%2Fb%3D%3D ',
    );
    expect(key.normalizedServiceKey, 'test+a/b==');
    expect(key.toString(), isNot(contains('test')));
    for (final raw in ['', '%not-encoded', 'with space', 'key\nsecret']) {
      expect(
        KhoaWaterTemperatureConfiguration(serviceKey: raw).isConfigured,
        isFalse,
      );
    }
  });

  test('official catalog uses current coastal codes and coordinates', () {
    expect(khoaWaterTemperatureStations, hasLength(52));
    expect(
      khoaWaterTemperatureStations.map((station) => station.code).toSet(),
      hasLength(52),
    );
    expect(
      khoaWaterTemperatureStations.any((station) => station.code == 'DT_0091'),
      isTrue,
    );
    for (final station in khoaWaterTemperatureStations) {
      expect(station.code, startsWith('DT_'));
      expect(station.name, isNot(matches(r'\(구\)|과거|_구')));
      expect(station.latitude, inInclusiveRange(33, 39));
      expect(station.longitude, inInclusiveRange(125, 132));
    }
  });

  test(
    'missing coordinates, unsupported locations and keys make no call',
    () async {
      await expectLater(
        service.fetchCurrentData(location: MapLocation(name: 'No coordinates')),
        _failure(WaterTemperatureFailure.coordinatesRequired),
      );
      await expectLater(
        service.fetchCurrentData(
          location: MapLocation(name: 'Far away', latitude: 37, longitude: 128),
        ),
        _failure(WaterTemperatureFailure.unsupportedLocation),
      );
      service = KhoaWaterTemperatureService(
        dio: dio,
        stations: const [_station],
        configuration: const KhoaWaterTemperatureConfiguration(serviceKey: ''),
      );
      await expectLater(
        service.fetchCurrentData(location: location),
        _failure(WaterTemperatureFailure.configuration),
      );
      expect(adapter.calls, isEmpty);
    },
  );

  test(
    'selects newest measured value, preserves zero and binds location',
    () async {
      adapter.respond = (_) => _success([
        _row(time: '11:40:00', temperature: 18.5),
        _row(time: '12:01:00', temperature: 22), // Future measurement.
        _row(time: '11:58:00', temperature: -999),
        _row(time: '11:57:00', temperature: null),
        _row(time: '11:59:00', temperature: '0'),
        _row(time: '11:56:00', temperature: 'NaN'),
      ]);
      final result = await service.fetchCurrentData(location: location);
      expect(result.temperatureCelsius, 0);
      expect(result.observedAt, DateTime.utc(2026, 11, 3, 2, 59));
      expect(result.station, same(_station));
      expect(result.matchesLocation(location), isTrue);
      final request = adapter.calls.single;
      expect(request.uri.scheme, 'https');
      expect(
        request.path,
        endsWith('/surveyWaterTemp/GetSurveyWaterTempApiService'),
      );
      expect(request.queryParameters, {
        'serviceKey': 'test+a/b==',
        'type': 'json',
        'obsCode': _station.code,
        'reqDate': '20261103',
        'min': '10',
        'pageNo': '1',
        'numOfRows': '300',
      });
      expect(request.followRedirects, isFalse);
    },
  );

  test('request day uses KST across the UTC date boundary', () async {
    now = DateTime.utc(2026, 11, 2, 15, 5);
    adapter.respond = (request) =>
        request.queryParameters['reqDate'] == '20261103'
        ? _success([_row(time: '00:00:00')])
        : _error('03');
    final result = await service.fetchCurrentData(location: location);
    expect(
      adapter.calls.map((request) => request.queryParameters['reqDate']),
      unorderedEquals(['20261103', '20261102']),
    );
    expect(result.observedAt, DateTime.utc(2026, 11, 2, 15));
  });

  test(
    'midnight requests both KST days concurrently and selects newest valid sample',
    () async {
      now = DateTime.utc(2026, 11, 3, 15, 6); // November 4, 00:06 KST.
      final today = Completer<Object>();
      final yesterday = Completer<Object>();
      adapter.respond = (request) =>
          request.queryParameters['reqDate'] == '20261104'
          ? today.future
          : yesterday.future;
      final pending = service.fetchCurrentData(location: location);
      await adapter.started.future;
      await Future<void>.delayed(Duration.zero);
      final startedDays = adapter.calls
          .map((request) => request.queryParameters['reqDate'])
          .toSet();
      today.complete(
        _success([
          _row(day: '2026-11-04', time: '00:01:23', temperature: 20),
          _row(day: '2026-11-04', time: '00:06:01', temperature: 25),
          _row(day: '2026-11-04', time: '00:05:00', temperature: -999),
        ]),
      );
      yesterday.complete(
        _success([
          _row(time: '22:05:59', temperature: 30), // More than two hours old.
          _row(time: '23:59:47', temperature: 19),
        ]),
      );
      final result = await pending;
      expect(startedDays, {'20261104', '20261103'});
      expect(result.temperatureCelsius, 20);
      expect(result.observedAt, DateTime.utc(2026, 11, 3, 15, 1, 23));
      expect(result.isUsableAt(now), isTrue);
      expect(adapter.calls, hasLength(2));
    },
  );

  test(
    'either day may fail if the other day has a fresh measurement',
    () async {
      now = DateTime.utc(2026, 11, 3, 15, 6);
      for (final failingDay in ['20261104', '20261103']) {
        for (final failure in ['timeout', 'noData', 'malformed', 'identity']) {
          service = KhoaWaterTemperatureService(
            dio: dio,
            clock: () => now,
            stations: const [_station, _second],
            configuration: const KhoaWaterTemperatureConfiguration(
              serviceKey: 'test',
            ),
          );
          adapter.calls.clear();
          adapter.respond = (request) {
            final day = request.queryParameters['reqDate'];
            if (day == failingDay) {
              return switch (failure) {
                'timeout' => throw DioException(
                  requestOptions: request,
                  type: DioExceptionType.receiveTimeout,
                  message: 'test+ secret',
                ),
                'noData' => _error('03'),
                'identity' => _success([
                  {
                    ..._row(
                      day: day == '20261104' ? '2026-11-04' : '2026-11-03',
                      time: day == '20261104' ? '00:01:23' : '23:59:47',
                    ),
                    'obsvtrNm': 'Wrong station',
                  },
                ]),
                _ => 'not valid JSON test+ secret',
              };
            }
            return _success([
              _row(
                day: day == '20261104' ? '2026-11-04' : '2026-11-03',
                time: day == '20261104' ? '00:01:23' : '23:59:47',
              ),
            ]);
          };
          final result = await service.fetchCurrentData(location: location);
          expect(
            result.observedAt,
            failingDay == '20261104'
                ? DateTime.utc(2026, 11, 3, 14, 59, 47)
                : DateTime.utc(2026, 11, 3, 15, 1, 23),
            reason: '$failingDay $failure',
          );
          expect(result.station.code, _station.code);
          expect(result.isUsableAt(now), isTrue);
          expect(adapter.calls, hasLength(2));
        }
      }
    },
  );

  test(
    'midnight failure with no fresh sample surfaces without station fallback',
    () async {
      now = DateTime.utc(2026, 11, 3, 15, 6);
      for (final failingDay in ['20261104', '20261103']) {
        for (final (code, failure) in [
          ('22', WaterTemperatureFailure.rateLimited),
          ('05', WaterTemperatureFailure.timedOut),
          ('10', WaterTemperatureFailure.invalidResponse),
        ]) {
          service = KhoaWaterTemperatureService(
            dio: dio,
            clock: () => now,
            stations: const [_station, _second, _third],
            configuration: const KhoaWaterTemperatureConfiguration(
              serviceKey: 'test',
            ),
          );
          adapter.calls.clear();
          adapter.respond = (request) => _error(
            request.queryParameters['reqDate'] == failingDay ? code : '03',
          );
          await expectLater(
            service.fetchCurrentData(location: location),
            _failure(failure),
          );
          expect(adapter.calls, hasLength(2));
          expect(
            adapter.calls.map((request) => request.queryParameters['obsCode']),
            everyElement(_station.code),
          );
        }
      }
    },
  );

  test(
    'midnight all-no-data fallback still stops after three stations',
    () async {
      now = DateTime.utc(2026, 11, 3, 15, 6);
      service = KhoaWaterTemperatureService(
        dio: dio,
        clock: () => now,
        stations: const [_fourth, _third, _second, _station],
        configuration: const KhoaWaterTemperatureConfiguration(
          serviceKey: 'test',
        ),
      );
      adapter.respond = (_) => _error('03');
      await expectLater(
        service.fetchCurrentData(location: location),
        _failure(WaterTemperatureFailure.noData),
      );
      expect(adapter.calls, hasLength(6));
      for (final station in [_station, _second, _third]) {
        expect(
          adapter.calls
              .where(
                (request) => request.queryParameters['obsCode'] == station.code,
              )
              .map((request) => request.queryParameters['reqDate']),
          unorderedEquals(['20261104', '20261103']),
        );
      }
    },
  );

  test(
    'previous day is queried before 02:00 KST and omitted from 02:00',
    () async {
      now = DateTime.utc(2026, 11, 3, 16, 59, 59); // 01:59:59 KST.
      adapter.respond = (request) =>
          request.queryParameters['reqDate'] == '20261103'
          ? _success([_row(time: '23:59:59')])
          : _error('03');
      final result = await service.fetchCurrentData(location: location);
      expect(result.observedAt, DateTime.utc(2026, 11, 3, 14, 59, 59));
      expect(
        result.isUsableAt(now),
        isTrue,
      ); // Exactly two hours remains valid.
      expect(adapter.calls, hasLength(2));
      now = now.add(const Duration(seconds: 1));
      service = KhoaWaterTemperatureService(
        dio: dio,
        clock: () => now,
        stations: const [_station],
        configuration: const KhoaWaterTemperatureConfiguration(
          serviceKey: 'test',
        ),
      );
      adapter.calls.clear();
      adapter.respond = (_) =>
          _success([_row(day: '2026-11-04', time: '01:59:59')]);
      await service.fetchCurrentData(location: location);
      expect(adapter.calls.single.queryParameters['reqDate'], '20261104');
    },
  );

  test(
    'both day requests reuse in-flight work and caches across midnight',
    () async {
      now = DateTime.utc(2026, 11, 3, 14, 59); // 23:59 KST.
      final yesterday = Completer<Object>();
      final today = Completer<Object>();
      adapter.respond = (request) =>
          request.queryParameters['reqDate'] == '20261103'
          ? yesterday.future
          : today.future;
      final first = service.fetchCurrentData(location: location);
      await adapter.started.future;
      now = now.add(const Duration(minutes: 2)); // 00:01 KST.
      final otherLocation = MapLocation(
        name: 'Another spot',
        latitude: 35.0001,
        longitude: 127,
      );
      final second = service.fetchCurrentData(location: otherLocation);
      await Future<void>.delayed(Duration.zero);
      yesterday.complete(_success([_row(time: '23:58:37')]));
      today.complete(
        _success([_row(day: '2026-11-04', time: '00:00:23', temperature: 20)]),
      );
      final results = await Future.wait([first, second]);
      expect(adapter.calls, hasLength(2));
      expect(
        adapter.calls.map((request) => request.queryParameters['reqDate']),
        unorderedEquals(['20261103', '20261104']),
      );
      expect(results[0].observedAt, DateTime.utc(2026, 11, 3, 14, 58, 37));
      expect(results[0].matchesLocation(location), isTrue);
      expect(results[1].observedAt, DateTime.utc(2026, 11, 3, 15, 0, 23));
      expect(results[1].matchesLocation(otherLocation), isTrue);
      now = now.add(const Duration(minutes: 1));
      final cached = await service.fetchCurrentData(location: location);
      expect(cached.observedAt, results[1].observedAt);
      expect(cached.matchesLocation(location), isTrue);
      expect(adapter.calls, hasLength(2));
    },
  );

  test(
    'missing, nonfinite, sentinel, stale and future readings stay unavailable',
    () async {
      for (final row in [
        _row(temperature: null),
        _row(temperature: ''),
        _row(temperature: 'NaN'),
        _row(temperature: 'Infinity'),
        _row(temperature: -999),
        _row(temperature: 9999),
        _row(temperature: -5.1),
        _row(temperature: 45.1),
        _row(time: '09:59:59'),
        _row(time: '12:00:01'),
      ]) {
        adapter.respond = (_) => _success([row]);
        await expectLater(
          service.fetchCurrentData(location: location, forceRefresh: true),
          _failure(WaterTemperatureFailure.noData),
        );
      }
    },
  );

  test(
    'invalid station identity, dates and conflicting duplicates fail closed',
    () async {
      for (final rows in [
        [
          {..._row(), 'lat': 36},
        ],
        [
          {..._row(), 'obsvtrNm': 'Other station'},
        ],
        [
          {..._row(), 'obsCode': 'DT_9999'},
        ],
        [
          {..._row(), 'obsrvnDt': '2026-02-30 11:50:00'},
        ],
        [
          {..._row(), 'obsrvnDt': '2026-11-02 11:50:00'},
        ],
        [_row(), _row(temperature: 12)],
      ]) {
        adapter.respond = (_) => _success(rows);
        await expectLater(
          service.fetchCurrentData(location: location, forceRefresh: true),
          _failure(WaterTemperatureFailure.invalidResponse),
        );
      }
    },
  );

  test(
    'only no-data or suspended sensors fall back to a nearby station',
    () async {
      service = KhoaWaterTemperatureService(
        dio: dio,
        clock: () => now,
        stations: const [_station, _second],
        configuration: const KhoaWaterTemperatureConfiguration(
          serviceKey: 'test',
        ),
      );
      for (final code in ['3', '40', '41']) {
        adapter.calls.clear();
        adapter.respond = (request) =>
            request.queryParameters['obsCode'] == _station.code
            ? _error(code)
            : _success([_row(station: _second)]);
        final result = await service.fetchCurrentData(
          location: location,
          forceRefresh: true,
        );
        expect(result.station.code, _second.code);
        expect(adapter.calls, hasLength(2));
      }
      for (final (code, failure) in [
        ('30', WaterTemperatureFailure.unauthorized),
        ('22', WaterTemperatureFailure.rateLimited),
        ('05', WaterTemperatureFailure.timedOut),
        ('10', WaterTemperatureFailure.invalidResponse),
      ]) {
        adapter.calls.clear();
        adapter.respond = (_) => _error(code);
        await expectLater(
          service.fetchCurrentData(location: location, forceRefresh: true),
          _failure(failure),
        );
        expect(adapter.calls, hasLength(1));
      }
    },
  );

  test('search stops after three nearby stations', () async {
    service = KhoaWaterTemperatureService(
      dio: dio,
      clock: () => now,
      stations: const [_fourth, _third, _second, _station],
      configuration: const KhoaWaterTemperatureConfiguration(
        serviceKey: 'test',
      ),
    );
    adapter.respond = (_) => _error('03');
    await expectLater(
      service.fetchCurrentData(location: location),
      _failure(WaterTemperatureFailure.noData),
    );
    expect(adapter.calls.map((request) => request.queryParameters['obsCode']), [
      _station.code,
      _second.code,
      _third.code,
    ]);
  });

  test(
    'shared station requests coalesce and cached results bind every caller',
    () async {
      final pending = Completer<Object>();
      adapter.respond = (_) => pending.future;
      final otherLocation = MapLocation(
        name: 'Another spot',
        latitude: 35.0001,
        longitude: 127,
      );
      final first = service.fetchCurrentData(location: location);
      final second = service.fetchCurrentData(location: otherLocation);
      await adapter.started.future;
      pending.complete(_success([_row()]));
      final results = await Future.wait([first, second]);
      expect(adapter.calls, hasLength(1));
      expect(results[0].matchesLocation(location), isTrue);
      expect(results[1].matchesLocation(otherLocation), isTrue);
      expect(results[1].matchesLocation(location), isFalse);
      now = now.add(const Duration(minutes: 9));
      await service.fetchCurrentData(location: location);
      expect(adapter.calls, hasLength(1));
      now = now.add(const Duration(minutes: 1));
      adapter.respond = (_) => _success([_row()]);
      await service.fetchCurrentData(location: location);
      expect(adapter.calls, hasLength(2));
    },
  );

  test(
    'no-data cache avoids repeated fallbacks and force refresh bypasses it',
    () async {
      adapter.respond = (_) => _error('03');
      for (var index = 0; index < 2; index++) {
        await expectLater(
          service.fetchCurrentData(location: location),
          _failure(WaterTemperatureFailure.noData),
        );
      }
      expect(adapter.calls, hasLength(1));
      adapter.respond = (_) => _success([_row()]);
      await service.fetchCurrentData(location: location, forceRefresh: true);
      expect(adapter.calls, hasLength(2));
    },
  );

  test('station cache evicts old entries at its configured bound', () async {
    service = KhoaWaterTemperatureService(
      dio: dio,
      clock: () => now,
      stations: const [_station, _second],
      maxCachedEntries: 1,
      configuration: const KhoaWaterTemperatureConfiguration(
        serviceKey: 'test',
      ),
    );
    adapter.respond = (request) => _success([
      _row(
        station: request.queryParameters['obsCode'] == _station.code
            ? _station
            : _second,
      ),
    ]);
    await service.fetchCurrentData(location: location);
    await service.fetchCurrentData(
      location: MapLocation(name: 'Second', latitude: 35.01, longitude: 127),
    );
    await service.fetchCurrentData(location: location);
    expect(adapter.calls, hasLength(3));
  });

  test(
    'full pagination is required before choosing the most recent value',
    () async {
      adapter.respond = (request) {
        final page = int.parse(request.queryParameters['pageNo'] as String);
        return _success(
          [
            _row(
              time: page == 1 ? '11:40:00' : '11:59:00',
              temperature: page * 10,
            ),
          ],
          page: page,
          total: 2,
        );
      };
      final result = await service.fetchCurrentData(location: location);
      expect(result.temperatureCelsius, 20);
      expect(adapter.calls, hasLength(2));
      adapter.respond = (_) => _success([_row()], total: 1501);
      await expectLater(
        service.fetchCurrentData(location: location, forceRefresh: true),
        _failure(WaterTemperatureFailure.invalidResponse),
      );
      expect(adapter.calls, hasLength(3));
    },
  );

  test(
    'incomplete, wrong-page or changing totals cannot become partial readings',
    () async {
      for (var scenario = 0; scenario < 3; scenario++) {
        adapter.respond = (request) {
          final page = int.parse(request.queryParameters['pageNo'] as String);
          return _success(
            page == 2 && scenario == 0 ? [] : [_row()],
            page: scenario == 1 ? 1 : page,
            total: page == 2 && scenario == 2 ? 3 : 2,
          );
        };
        await expectLater(
          service.fetchCurrentData(location: location, forceRefresh: true),
          _failure(WaterTemperatureFailure.invalidResponse),
        );
      }
    },
  );

  test(
    'XML gateway, HTTP and transport errors stay sanitized without retries',
    () async {
      adapter.status = 500;
      adapter.respond = (_) =>
          '<OpenAPI_ServiceResponse><cmmMsgHeader>'
          '<returnAuthMsg>test+a/b== secret</returnAuthMsg>'
          '<returnReasonCode>30</returnReasonCode>'
          '</cmmMsgHeader></OpenAPI_ServiceResponse>';
      await expectLater(
        service.fetchCurrentData(location: location),
        _failure(WaterTemperatureFailure.unauthorized),
      );
      for (final (status, failure) in [
        (403, WaterTemperatureFailure.unauthorized),
        (429, WaterTemperatureFailure.rateLimited),
        (503, WaterTemperatureFailure.network),
        (302, WaterTemperatureFailure.invalidResponse),
      ]) {
        adapter.status = status;
        adapter.respond = (_) => 'test+a/b== secret';
        await expectLater(
          service.fetchCurrentData(location: location),
          _failure(failure),
        );
      }
      adapter.respond = (request) => throw DioException(
        requestOptions: request,
        type: DioExceptionType.connectionError,
        message: 'test+a/b== secret',
      );
      await expectLater(
        service.fetchCurrentData(location: location),
        _failure(WaterTemperatureFailure.network),
      );
      expect(adapter.calls, hasLength(6));
    },
  );

  test(
    'oversized responses are rejected and requests cancel at wall timeout',
    () async {
      adapter.respond = (_) => 'x' * (512 * 1024 + 1);
      await expectLater(
        service.fetchCurrentData(location: location),
        _failure(WaterTemperatureFailure.invalidResponse),
      );
      service = KhoaWaterTemperatureService(
        dio: dio,
        clock: () => now,
        stations: const [_station],
        requestTimeout: const Duration(milliseconds: 50),
        configuration: const KhoaWaterTemperatureConfiguration(
          serviceKey: 'test',
        ),
      );
      adapter.respond = (_) => Completer<Object>().future;
      await expectLater(
        service.fetchCurrentData(location: location),
        _failure(WaterTemperatureFailure.timedOut),
      );
      await adapter.cancellation.future;
      expect(adapter.cancelled, isTrue);
    },
  );
}

Matcher _failure(WaterTemperatureFailure reason) => throwsA(
  isA<WaterTemperatureException>()
      .having((error) => error.reason, 'reason', reason)
      .having(
        (error) => error.toString(),
        'sanitized',
        isNot(contains('test+')),
      ),
);

// Official 15142506 guide fields; local fixtures never call a live API.
Map<String, Object?> _row({
  WaterTemperatureStation station = _station,
  String day = '2026-11-03',
  String time = '11:50:00',
  Object? temperature = 18.5,
}) => {
  'obsvtrNm': station.name,
  'lat': station.latitude,
  'lot': station.longitude,
  'obsrvnDt': '$day $time',
  'wtem': temperature,
};

Map<String, Object?> _success(
  List<Map<String, Object?>> rows, {
  int page = 1,
  int? total,
}) => {
  'response': {
    'header': {'resultCode': '00', 'resultMsg': 'NORMAL_SERVICE'},
    'body': {
      'items': {'item': rows},
      'pageNo': page,
      'numOfRows': 300,
      'totalCount': total ?? rows.length,
    },
  },
};

Map<String, Object?> _error(String code) => {
  'response': {
    'header': {'resultCode': code, 'resultMsg': 'provider text'},
  },
};

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  FutureOr<Object> Function(RequestOptions) respond;
  final calls = <RequestOptions>[];
  final started = Completer<void>();
  final cancellation = Completer<void>();
  int status = 200;
  bool cancelled = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(options);
    if (!started.isCompleted) started.complete();
    cancelFuture?.then((_) {
      cancelled = true;
      if (!cancellation.isCompleted) cancellation.complete();
    });
    final body = await respond(options);
    return ResponseBody.fromString(
      body is String ? body : jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
