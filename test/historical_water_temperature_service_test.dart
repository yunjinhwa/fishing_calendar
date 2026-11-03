import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fishing_build/data/history/historical_conditions_service.dart';
import 'package:fishing_build/data/history/khoa_historical_water_temperature_service.dart';
import 'package:fishing_build/data/maps/map_location.dart';
import 'package:fishing_build/data/water_temperature/khoa_water_temperature_configuration.dart';
import 'package:fishing_build/data/water_temperature/water_temperature_models.dart';
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
const _configuration = KhoaWaterTemperatureConfiguration(
  serviceKey: 'test+a/b==',
);

void main() {
  late DateTime now;
  late DateTime requestedAt;
  late MapLocation location;
  late Dio dio;
  late _Adapter adapter;
  late KhoaHistoricalWaterTemperatureService service;

  KhoaHistoricalWaterTemperatureService makeService({
    List<WaterTemperatureStation> stations = const [_station],
    int maxCachedEntries = 128,
    Duration requestTimeout = const Duration(seconds: 12),
  }) => KhoaHistoricalWaterTemperatureService(
    dio: dio,
    clock: () => now,
    stations: stations,
    configuration: _configuration,
    maxCachedEntries: maxCachedEntries,
    requestTimeout: requestTimeout,
  );

  setUp(() {
    now = DateTime.utc(2026, 11, 3, 3);
    requestedAt = DateTime.utc(2026, 11, 1, 3); // November 1, noon KST.
    location = MapLocation(name: 'Fishing spot', latitude: 35, longitude: 127);
    adapter = _Adapter((_) => _success([_row()]));
    dio = Dio()..httpClientAdapter = adapter;
    service = makeService();
  });

  tearDown(() => dio.close(force: true));

  test(
    'past selection chooses latest prior sample without current freshness',
    () async {
      adapter.respond = (_) => _success([
        _row(time: '11:00:00', temperature: 21), // Exactly one hour old.
        _row(time: '11:10:00', temperature: 19),
        _row(time: '12:00:01', temperature: 22),
        _row(time: '23:50:00', temperature: 23),
        _row(time: '11:59:00', temperature: -999),
        _row(time: '11:50:00', temperature: '0'),
      ]);
      final result = await service.fetchAt(
        location: location,
        requestedAt: requestedAt,
      );
      expect(result.temperatureCelsius, 0);
      expect(result.requestedAt, requestedAt);
      expect(result.observedAt, DateTime.utc(2026, 11, 1, 2, 50));
      expect(result.fetchedAt, now);
      expect(result.hasValidData, isTrue);
      expect(result.matchesSelection(location, requestedAt), isTrue);
      final request = adapter.calls.single;
      expect(
        request.path,
        endsWith('/surveyWaterTemp/GetSurveyWaterTempApiService'),
      );
      expect(request.queryParameters, {
        'serviceKey': 'test+a/b==',
        'obsCode': _station.code,
        'reqDate': '20261101',
        'type': 'json',
        'min': '10',
        'pageNo': '1',
        'numOfRows': '300',
      });
      expect(request.followRedirects, isFalse);
    },
  );

  test('requested day and measurement use KST across UTC midnight', () async {
    requestedAt = DateTime.utc(2026, 10, 31, 15, 5);
    adapter.respond = (_) => _success([_row(time: '00:00:00')]);
    final result = await service.fetchAt(
      location: location,
      requestedAt: requestedAt,
    );
    expect(adapter.calls.single.queryParameters['reqDate'], '20261101');
    expect(result.observedAt, DateTime.utc(2026, 10, 31, 15));
  });

  test(
    'a provider future sample cannot become valid later from the day cache',
    () async {
      adapter.respond = (_) => _success([
        _row(day: '2026-11-03'),
        _row(day: '2026-11-03', time: '12:04:00', temperature: 25),
      ]);
      await service.fetchAt(
        location: location,
        requestedAt: DateTime.utc(2026, 11, 3, 2, 59),
      );
      now = now.add(const Duration(minutes: 5));
      final result = await service.fetchAt(
        location: location,
        requestedAt: DateTime.utc(2026, 11, 3, 3, 4),
      );
      expect(result.temperatureCelsius, 18.5);
      expect(result.observedAt, DateTime.utc(2026, 11, 3, 2, 50));
      expect(adapter.calls, hasLength(1));
    },
  );

  test(
    'unsupported dates, coordinates, distance and configuration make no calls',
    () async {
      for (final date in [
        DateTime.utc(2019, 12, 31, 14, 59),
        now,
        now.add(const Duration(seconds: 1)),
      ]) {
        await expectLater(
          service.fetchAt(location: location, requestedAt: date),
          _failure(HistoricalDataFailure.unsupportedDate),
        );
      }
      await expectLater(
        service.fetchAt(
          location: MapLocation(name: 'No coordinates'),
          requestedAt: requestedAt,
        ),
        _failure(HistoricalDataFailure.coordinatesRequired),
      );
      await expectLater(
        service.fetchAt(
          location: MapLocation(
            name: 'Over 50 km away',
            latitude: 35.6,
            longitude: 127,
          ),
          requestedAt: requestedAt,
        ),
        _failure(HistoricalDataFailure.unsupportedLocation),
      );
      service = KhoaHistoricalWaterTemperatureService(
        dio: dio,
        clock: () => now,
        stations: const [_station],
        configuration: const KhoaWaterTemperatureConfiguration(serviceKey: ''),
      );
      await expectLater(
        service.fetchAt(location: location, requestedAt: requestedAt),
        _failure(HistoricalDataFailure.configuration),
      );
      expect(adapter.calls, isEmpty);
    },
  );

  test(
    'future, old and invalid sensor readings cannot become observations',
    () async {
      for (final row in [
        _row(time: '12:00:01'),
        _row(time: '11:00:00'),
        for (final temperature in [
          null,
          '',
          'NaN',
          'Infinity',
          -999,
          9999,
          -5.1,
          45.1,
        ])
          _row(temperature: temperature),
      ]) {
        adapter.respond = (_) => _success([row]);
        await expectLater(
          service.fetchAt(
            location: location,
            requestedAt: requestedAt,
            forceRefresh: true,
          ),
          _failure(HistoricalDataFailure.noData),
        );
      }
    },
  );

  test(
    'station identity, wrong dates and conflicting duplicates fail closed',
    () async {
      for (final rows in [
        [
          {..._row(), 'lat': 36},
        ],
        [
          {..._row(), 'obsvtrNm': 'Other'},
        ],
        [
          {..._row(), 'obsCode': 'DT_9999'},
        ],
        [
          {..._row(), 'obsrvnDt': '2026-02-30 11:50:00'},
        ],
        [_row(day: '2026-10-31')],
        [_row(), _row(temperature: 12)],
      ]) {
        service = makeService();
        adapter.respond = (_) => _success(rows);
        await expectLater(
          service.fetchAt(location: location, requestedAt: requestedAt),
          _failure(HistoricalDataFailure.invalidResponse),
        );
      }
    },
  );

  test(
    'only no data falls back and at most three nearest stations are tried',
    () async {
      service = makeService(
        stations: const [_fourth, _third, _second, _station],
      );
      adapter.respond = (request) =>
          request.queryParameters['obsCode'] == _station.code
          ? _error('40')
          : _success([_row(station: _second)]);
      final result = await service.fetchAt(
        location: location,
        requestedAt: requestedAt,
      );
      expect(result.station.code, _second.code);
      expect(adapter.calls, hasLength(2));
      adapter.calls.clear();
      adapter.respond = (_) => _error('03');
      await expectLater(
        service.fetchAt(
          location: location,
          requestedAt: requestedAt,
          forceRefresh: true,
        ),
        _failure(HistoricalDataFailure.noData),
      );
      expect(
        adapter.calls.map((request) => request.queryParameters['obsCode']),
        [_station.code, _second.code, _third.code],
      );
      for (final (code, failure) in [
        ('30', HistoricalDataFailure.unauthorized),
        ('22', HistoricalDataFailure.rateLimited),
        ('05', HistoricalDataFailure.timedOut),
        ('10', HistoricalDataFailure.invalidResponse),
      ]) {
        service = makeService(stations: const [_station, _second]);
        adapter.calls.clear();
        adapter.respond = (_) => _error(code);
        await expectLater(
          service.fetchAt(location: location, requestedAt: requestedAt),
          _failure(failure),
        );
        expect(adapter.calls, hasLength(1));
      }
    },
  );

  test(
    'one station day coalesces and supplies different locations and hours',
    () async {
      final pending = Completer<Object>();
      adapter.respond = (_) => pending.future;
      final otherLocation = MapLocation(
        name: 'Other',
        latitude: 35.0001,
        longitude: 127,
      );
      final first = service.fetchAt(
        location: location,
        requestedAt: requestedAt,
      );
      final secondAt = requestedAt.add(const Duration(hours: 1));
      final second = service.fetchAt(
        location: otherLocation,
        requestedAt: secondAt,
      );
      await adapter.started.future;
      pending.complete(
        _success([_row(), _row(time: '12:50:00', temperature: 20)]),
      );
      final results = await Future.wait([first, second]);
      expect(adapter.calls, hasLength(1));
      expect(results[0].matchesSelection(location, requestedAt), isTrue);
      expect(results[1].matchesSelection(otherLocation, secondAt), isTrue);
      expect(results[1].temperatureCelsius, 20);
      expect(results[1].matchesSelection(location, secondAt), isFalse);
      now = now.add(const Duration(hours: 23));
      await service.fetchAt(location: location, requestedAt: requestedAt);
      expect(adapter.calls, hasLength(1));
      now = now.add(const Duration(hours: 1));
      await service.fetchAt(location: location, requestedAt: requestedAt);
      expect(adapter.calls, hasLength(2));
    },
  );

  test('day cache has a bounded least-recently-used eviction policy', () async {
    service = makeService(maxCachedEntries: 2);
    adapter.respond = (request) {
      final day = request.queryParameters['reqDate'] as String;
      return _success([
        _row(
          day:
              '${day.substring(0, 4)}-${day.substring(4, 6)}-${day.substring(6)}',
        ),
      ]);
    };
    for (final day in [1, 2, 1, 3, 2]) {
      await service.fetchAt(
        location: location,
        requestedAt: DateTime.utc(2026, 10, day, 3),
      );
    }
    expect(adapter.calls, hasLength(4));
  });

  test(
    'today and no-data cache expire after ten minutes and force can retry',
    () async {
      adapter.respond = (_) =>
          _success([_row(day: '2026-11-03', time: '10:50:00')]);
      final todayAt = DateTime.utc(2026, 11, 3, 2);
      await service.fetchAt(location: location, requestedAt: todayAt);
      now = now.add(const Duration(minutes: 9));
      await service.fetchAt(location: location, requestedAt: todayAt);
      expect(adapter.calls, hasLength(1));
      now = now.add(const Duration(minutes: 1));
      await service.fetchAt(location: location, requestedAt: todayAt);
      expect(adapter.calls, hasLength(2));
      adapter.respond = (_) => _error('03');
      for (var index = 0; index < 2; index++) {
        await expectLater(
          service.fetchAt(location: location, requestedAt: requestedAt),
          _failure(HistoricalDataFailure.noData),
        );
      }
      expect(adapter.calls, hasLength(3));
      adapter.respond = (_) => _success([_row()]);
      await service.fetchAt(
        location: location,
        requestedAt: requestedAt,
        forceRefresh: true,
      );
      expect(adapter.calls, hasLength(4));
    },
  );

  test(
    'transient failures coalesce and back off even with repeated force refresh',
    () async {
      final pending = Completer<Object>();
      adapter.respond = (_) => pending.future;
      final requests = [
        service.fetchAt(location: location, requestedAt: requestedAt),
        service.fetchAt(
          location: location,
          requestedAt: requestedAt,
          forceRefresh: true,
        ),
      ];
      final checked = requests
          .map(
            (request) => expectLater(
              request,
              _failure(HistoricalDataFailure.rateLimited),
            ),
          )
          .toList();
      await adapter.started.future;
      pending.complete(_error('22'));
      await Future.wait(checked);
      for (var index = 0; index < 3; index++) {
        await expectLater(
          service.fetchAt(
            location: location,
            requestedAt: requestedAt,
            forceRefresh: true,
          ),
          _failure(HistoricalDataFailure.rateLimited),
        );
      }
      expect(adapter.calls, hasLength(1));
      now = now.add(const Duration(seconds: 30));
      adapter.respond = (_) => _success([_row()]);
      await service.fetchAt(location: location, requestedAt: requestedAt);
      expect(adapter.calls, hasLength(2));
    },
  );

  test(
    'all pages must be validated before selecting the historical sample',
    () async {
      adapter.respond = (request) {
        final page = int.parse(request.queryParameters['pageNo'] as String);
        return _success(
          [
            _row(
              time: page == 1 ? '11:10:00' : '11:50:00',
              temperature: page * 10,
            ),
          ],
          page: page,
          total: 2,
        );
      };
      final result = await service.fetchAt(
        location: location,
        requestedAt: requestedAt,
      );
      expect(result.temperatureCelsius, 20);
      expect(adapter.calls, hasLength(2));
      for (var scenario = 0; scenario < 4; scenario++) {
        service = makeService();
        adapter.respond = (request) {
          final page = int.parse(request.queryParameters['pageNo'] as String);
          return _success(
            page == 2 && scenario == 0 ? [] : [_row()],
            page: scenario == 1 ? 1 : page,
            total: scenario == 3
                ? 1501
                : page == 2 && scenario == 2
                ? 3
                : 2,
          );
        };
        await expectLater(
          service.fetchAt(location: location, requestedAt: requestedAt),
          _failure(HistoricalDataFailure.invalidResponse),
        );
      }
    },
  );

  test(
    'gateway, HTTP and transport errors remain sanitized without fallback',
    () async {
      for (final (status, failure) in [
        (403, HistoricalDataFailure.unauthorized),
        (429, HistoricalDataFailure.rateLimited),
        (503, HistoricalDataFailure.network),
        (302, HistoricalDataFailure.invalidResponse),
      ]) {
        service = makeService();
        adapter.status = status;
        adapter.respond = (_) => 'test+a/b== secret';
        await expectLater(
          service.fetchAt(location: location, requestedAt: requestedAt),
          _failure(failure),
        );
      }
      service = makeService();
      adapter.respond = (_) =>
          '<OpenAPI_ServiceResponse><cmmMsgHeader>'
          '<returnAuthMsg>test+a/b== secret</returnAuthMsg>'
          '<returnReasonCode>30</returnReasonCode></cmmMsgHeader></OpenAPI_ServiceResponse>';
      await expectLater(
        service.fetchAt(location: location, requestedAt: requestedAt),
        _failure(HistoricalDataFailure.unauthorized),
      );
      service = makeService();
      adapter.respond = (request) => throw DioException(
        requestOptions: request,
        type: DioExceptionType.connectionError,
        message: 'test+a/b== secret',
      );
      await expectLater(
        service.fetchAt(location: location, requestedAt: requestedAt),
        _failure(HistoricalDataFailure.network),
      );
      expect(adapter.calls, hasLength(6));
    },
  );

  test(
    'oversized responses fail and wall timeout cancels the request',
    () async {
      adapter.respond = (_) => 'x' * (512 * 1024 + 1);
      await expectLater(
        service.fetchAt(location: location, requestedAt: requestedAt),
        _failure(HistoricalDataFailure.invalidResponse),
      );
      service = makeService(requestTimeout: const Duration(milliseconds: 50));
      adapter.respond = (_) => Completer<Object>().future;
      await expectLater(
        service.fetchAt(location: location, requestedAt: requestedAt),
        _failure(HistoricalDataFailure.timedOut),
      );
      await adapter.cancellation.future;
      expect(adapter.cancelled, isTrue);
    },
  );
}

Matcher _failure(HistoricalDataFailure reason) => throwsA(
  isA<HistoricalDataException>()
      .having((error) => error.reason, 'reason', reason)
      .having(
        (error) => error.toString(),
        'sanitized',
        isNot(contains('test+')),
      ),
);

Map<String, Object?> _row({
  WaterTemperatureStation station = _station,
  String day = '2026-11-01',
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
