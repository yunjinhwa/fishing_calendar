import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fishing_build/data/tides/khoa_tide_configuration.dart';
import 'package:fishing_build/data/tides/khoa_tide_service.dart';
import 'package:fishing_build/data/tides/tide_models.dart';
import 'package:fishing_build/data/tides/tide_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const gunsan = TideStation(
    code: 'DT_0018',
    name: '군산',
    latitude: 35.975556,
    longitude: 126.563056,
  );
  final day = TideDay(2025, 11, 11);
  late DateTime now;
  late _Adapter adapter;
  late Dio dio;
  late KhoaTideService service;

  setUp(() {
    now = DateTime.utc(2025, 11, 10, 23);
    adapter = _Adapter((request) => _success(_rows(request)));
    dio = Dio()..httpClientAdapter = adapter;
    service = KhoaTideService(
      dio: dio,
      clock: () => now,
      configuration: const KhoaTideConfiguration(
        serviceKey: 'development+a/b==',
      ),
    );
  });

  test(
    'portal key is decoded once, preserving plus, and never printed',
    () async {
      const encoded = KhoaTideConfiguration(
        serviceKey: ' development%2Ba%2Fb%3D%3D ',
      );
      expect(encoded.normalizedServiceKey, 'development+a/b==');
      expect(
        const KhoaTideConfiguration(
          serviceKey: 'literal+a/b==',
        ).normalizedServiceKey,
        'literal+a/b==',
      );
      expect(
        const KhoaTideConfiguration(
          serviceKey: 'once%252B',
        ).normalizedServiceKey,
        'once%2B',
      );
      for (final key in ['', ' ', 'invalid%ZZ', 'has\nspace', 'has%20space']) {
        expect(KhoaTideConfiguration(serviceKey: key).isConfigured, isFalse);
      }
      expect(encoded.toString(), isNot(contains('development')));
      service = KhoaTideService(dio: dio, configuration: encoded);
      await service.fetchForecast(station: gunsan, day: day);
      expect(
        adapter.calls.single.uri.queryParameters['serviceKey'],
        'development+a/b==',
      );
    },
  );

  test(
    'official query and direct JSON fields produce ordered UTC events',
    () async {
      final result = await service.fetchForecast(station: gunsan, day: day);
      final request = adapter.calls.single;
      expect(request.uri.scheme, 'https');
      expect(request.uri.host, 'apis.data.go.kr');
      expect(
        request.uri.path,
        '/1192136/tideFcstHghLw/GetTideFcstHghLwApiService',
      );
      expect(request.queryParameters, {
        'serviceKey': 'development+a/b==',
        'obsCode': 'DT_0018',
        'reqDate': '20251111',
        'type': 'json',
        'pageNo': '1',
        'numOfRows': '300',
      });
      expect(result.day, day);
      expect(result.station.name, '군산');
      expect(result.station.latitude, 35.975556);
      expect(result.fetchedAt, now);
      expect(result.sourceName, '국립해양조사원 조석예보');
      expect(result.events.map((event) => event.at), [
        DateTime.utc(2025, 11, 10, 16, 30),
        DateTime.utc(2025, 11, 10, 22, 45),
        DateTime.utc(2025, 11, 11, 4, 10),
        DateTime.utc(2025, 11, 11, 10, 20),
      ]);
      expect(result.events.every((event) => event.at.isUtc), isTrue);
      expect(result.events.map((event) => event.kind), [
        TideEventKind.low,
        TideEventKind.high,
        TideEventKind.low,
        TideEventKind.high,
      ]);
      expect(result.events.first.heightCm, -13.5);
      expect(() => result.events.clear(), throwsUnsupportedError);
    },
  );

  test(
    'documented JSON wrapper, singleton item and list variants work',
    () async {
      for (var shape = 0; shape < 4; shape++) {
        adapter.respond = (request) {
          final row = _rows(request).last;
          return _success([row], shape: shape, wrapped: true);
        };
        final result = await service.fetchForecast(
          station: gunsan,
          day: day,
          forceRefresh: true,
        );
        expect(result.events, hasLength(1));
        expect(result.events.single.kind, TideEventKind.low);
      }
    },
  );

  test('provider station alias and numeric text are preserved', () async {
    adapter.respond = (request) {
      final row = _rows(request).last
        ..['obsvtrNm'] = '군산항'
        ..['lat'] = '35.97555'
        ..['lot'] = '126.56305'
        ..['predcTdlvVl'] = '-2.5'
        ..['extrSe'] = 2;
      return _success([row]);
    };
    final forecast = await service.fetchForecast(station: gunsan, day: day);
    expect(forecast.station.name, '군산항');
    expect(forecast.events.single.heightCm, -2.5);
  });

  test('exact duplicates are removed but conflicting events fail', () async {
    adapter.respond = (request) {
      final rows = _rows(request);
      return _success([...rows, Map<String, Object?>.from(rows.first)]);
    };
    final result = await service.fetchForecast(station: gunsan, day: day);
    expect(result.events, hasLength(4));
    adapter.respond = (request) {
      final rows = _rows(request);
      return _success([
        ...rows,
        {...rows.first, 'predcTdlvVl': 999},
      ]);
    };
    await expectLater(
      service.fetchForecast(station: gunsan, day: day, forceRefresh: true),
      _failure(TideFailure.invalidResponse),
    );
  });

  test('calendar day is defined in Korea across UTC midnight', () {
    expect(
      TideDay.fromInstant(DateTime.utc(2025, 11, 10, 14, 59)),
      TideDay(2025, 11, 10),
    );
    expect(TideDay.fromInstant(DateTime.utc(2025, 11, 10, 15)), day);
    expect(
      TideDay.fromInstant(DateTime.parse('2025-11-11T00:00:00+09:00')),
      day,
    );
  });

  test(
    'cache coalesces requests, force refresh, expiry and date keys',
    () async {
      final gate = Completer<Object>();
      adapter.respond = (_) => gate.future;
      final first = service.fetchForecast(station: gunsan, day: day);
      final concurrent = service.fetchForecast(station: gunsan, day: day);
      final forced = service.fetchForecast(
        station: gunsan,
        day: day,
        forceRefresh: true,
      );
      await adapter.started.future;
      expect(adapter.calls, hasLength(1));
      gate.complete(_success(_rows(adapter.calls.single)));
      final values = await Future.wait([first, concurrent, forced]);
      expect(identical(values[0], values[1]), isTrue);
      expect(identical(values[1], values[2]), isTrue);
      await service.fetchForecast(station: gunsan, day: day);
      expect(adapter.calls, hasLength(1));

      adapter.respond = (request) => _success(_rows(request));
      now = now.add(const Duration(minutes: 9, seconds: 59));
      await service.fetchForecast(station: gunsan, day: day);
      expect(adapter.calls, hasLength(1));
      now = now.add(const Duration(seconds: 1));
      await service.fetchForecast(station: gunsan, day: day);
      expect(adapter.calls, hasLength(2));
      await service.fetchForecast(
        station: gunsan,
        day: day,
        forceRefresh: true,
      );
      expect(adapter.calls, hasLength(3));
      await service.fetchForecast(station: gunsan, day: TideDay(2025, 11, 12));
      expect(adapter.calls, hasLength(4));
    },
  );

  test(
    'cache evicts least recently used entries and rejects clock reversal',
    () async {
      service = KhoaTideService(
        dio: dio,
        clock: () => now,
        maxCachedEntries: 2,
        configuration: const KhoaTideConfiguration(serviceKey: 'test'),
      );
      final secondDay = TideDay(2025, 11, 12);
      await service.fetchForecast(station: gunsan, day: day);
      await service.fetchForecast(station: gunsan, day: secondDay);
      await service.fetchForecast(station: gunsan, day: day);
      await service.fetchForecast(station: gunsan, day: TideDay(2025, 11, 13));
      await service.fetchForecast(station: gunsan, day: secondDay);
      expect(adapter.calls, hasLength(4));
      now = now.subtract(const Duration(seconds: 1));
      await service.fetchForecast(station: gunsan, day: secondDay);
      expect(adapter.calls, hasLength(5));
    },
  );

  test('configuration, station and date guards never make a request', () async {
    final unconfigured = KhoaTideService(
      dio: dio,
      configuration: const KhoaTideConfiguration(serviceKey: ''),
    );
    await expectLater(
      unconfigured.fetchForecast(station: gunsan, day: day),
      _failure(TideFailure.configuration),
    );
    for (final station in [
      const TideStation(code: 'bad', name: '군산', latitude: 35, longitude: 126),
      const TideStation(
        code: 'DT_0018',
        name: '군산',
        latitude: double.nan,
        longitude: 126,
      ),
      const TideStation(
        code: 'DT_0018',
        name: '군산',
        latitude: 91,
        longitude: 126,
      ),
    ]) {
      await expectLater(
        service.fetchForecast(station: station, day: day),
        _failure(TideFailure.unsupportedStation),
      );
    }
    await expectLater(
      service.fetchForecast(station: gunsan, day: TideDay(10000, 1, 1)),
      _failure(TideFailure.unsupportedDate),
    );
    expect(adapter.calls, isEmpty);
  });

  test(
    'wrong day, station coordinates and inconsistent metadata fail',
    () async {
      final invalidRows = <String, Object?>{
        'predcDt': '2025-11-12 01:30',
        'lat': 35.5,
        'lot': 125,
        'obsvtrNm': '다른 지점',
        'obsCode': 'DT_0001',
      };
      for (final entry in invalidRows.entries) {
        adapter.respond = (request) {
          final rows = _rows(request);
          rows.first[entry.key] = entry.value;
          return _success(rows);
        };
        await expectLater(
          service.fetchForecast(station: gunsan, day: day),
          _failure(TideFailure.invalidResponse),
        );
      }
      expect(adapter.calls, hasLength(5));
    },
  );

  test(
    'cache also validates a caller reusing a code for a different site',
    () async {
      await service.fetchForecast(station: gunsan, day: day);
      await expectLater(
        service.fetchForecast(
          station: const TideStation(
            code: 'DT_0018',
            name: 'wrong',
            latitude: 37,
            longitude: 126,
          ),
          day: day,
        ),
        _failure(TideFailure.invalidResponse),
      );
      expect(adapter.calls, hasLength(1));
    },
  );

  test('malformed timestamps, heights and unknown extremes fail', () async {
    final invalidFields = <(String, Object?)>[
      ('predcDt', '2025-11-11 25:30'),
      ('predcDt', '2025-02-30 01:30'),
      ('predcDt', 'not a timestamp'),
      ('predcTdlvVl', 'NaN'),
      ('predcTdlvVl', 'Infinity'),
      ('predcTdlvVl', null),
      ('lat', null),
      ('extrSe', '5'),
      ('extrSe', null),
    ];
    for (final (field, value) in invalidFields) {
      adapter.respond = (request) {
        final rows = _rows(request);
        rows.first[field] = value;
        return _success(rows);
      };
      await expectLater(
        service.fetchForecast(station: gunsan, day: day),
        _failure(TideFailure.invalidResponse),
      );
    }
  });

  test(
    'success with empty items is no data; malformed body is invalid',
    () async {
      for (final body in [
        _success([]),
        {
          'header': {'resultCode': '00'},
          'body': {'totalCount': 0},
        },
        _error('3', 'NO_DATA'),
      ]) {
        adapter.respond = (_) => body;
        await expectLater(
          service.fetchForecast(station: gunsan, day: day),
          _failure(TideFailure.noData),
        );
      }
      for (final body in [
        'not-json',
        [],
        {
          'header': {'resultCode': '00'},
          'body': {},
        },
        {
          'header': {},
          'body': {'items': []},
        },
        {
          'header': {'resultCode': '00'},
          'body': {
            'items': ['bad'],
          },
        },
        {
          'header': {'resultCode': '00'},
          'body': {
            'items': {'unexpected': 1},
          },
        },
      ]) {
        adapter.respond = (_) => body;
        await expectLater(
          service.fetchForecast(station: gunsan, day: day),
          _failure(TideFailure.invalidResponse),
        );
      }
    },
  );

  test(
    'documented provider failures are mapped without retries or secrets',
    () async {
      final failures = <String, TideFailure>{
        '20': TideFailure.unauthorized,
        '21': TideFailure.unauthorized,
        '30': TideFailure.unauthorized,
        '31': TideFailure.unauthorized,
        '32': TideFailure.unauthorized,
        '33': TideFailure.unauthorized,
        '22': TideFailure.rateLimited,
        '23': TideFailure.rateLimited,
        '10': TideFailure.invalidResponse,
        '11': TideFailure.invalidResponse,
      };
      for (final entry in failures.entries) {
        adapter.respond = (_) => _error(entry.key, 'development+a/b==');
        await expectLater(
          service.fetchForecast(station: gunsan, day: day),
          throwsA(
            isA<TideException>()
                .having((e) => e.reason, 'reason', entry.value)
                .having(
                  (e) => e.toString(),
                  'sanitized',
                  isNot(contains('development')),
                ),
          ),
        );
      }
      expect(adapter.calls, hasLength(failures.length));
      adapter.respond = (_) => _error('10', 'INVALID obsCode');
      await expectLater(
        service.fetchForecast(station: gunsan, day: day),
        _failure(TideFailure.unsupportedStation),
      );
      adapter.respond = (_) => _error('11', 'INVALID reqDate');
      await expectLater(
        service.fetchForecast(station: gunsan, day: day),
        _failure(TideFailure.unsupportedDate),
      );
    },
  );

  test('XML gateway errors are recognized even with an HTTP error', () async {
    for (final code in ['30', '22', '3']) {
      adapter.status = 500;
      adapter.respond = (_) =>
          '<OpenAPI_ServiceResponse><cmmMsgHeader>'
          '<errMsg>SERVICE ERROR</errMsg><returnAuthMsg>provider text</returnAuthMsg>'
          '<returnReasonCode>$code</returnReasonCode>'
          '</cmmMsgHeader></OpenAPI_ServiceResponse>';
      await expectLater(
        service.fetchForecast(station: gunsan, day: day),
        _failure(switch (code) {
          '30' => TideFailure.unauthorized,
          '22' => TideFailure.rateLimited,
          _ => TideFailure.noData,
        }),
      );
    }
    adapter.status = 200;
    adapter.respond = (_) =>
        '<response><header><resultCode>31</resultCode>'
        '<resultMsg>key error</resultMsg></header></response>';
    await expectLater(
      service.fetchForecast(station: gunsan, day: day),
      _failure(TideFailure.unauthorized),
    );
  });

  test(
    'HTTP and Dio failures never expose request URLs or transport errors',
    () async {
      for (final (status, reason) in [
        (401, TideFailure.unauthorized),
        (403, TideFailure.unauthorized),
        (429, TideFailure.rateLimited),
        (503, TideFailure.network),
        (400, TideFailure.invalidResponse),
      ]) {
        adapter.status = status;
        adapter.respond = (_) => 'HTTP error';
        await expectLater(
          service.fetchForecast(station: gunsan, day: day),
          _failure(reason),
        );
      }
      for (final type in [
        DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
        DioExceptionType.connectionError,
      ]) {
        adapter.respond = (request) => throw DioException(
          requestOptions: request,
          type: type,
          message: 'development+a/b== transport secret',
        );
        await expectLater(
          service.fetchForecast(station: gunsan, day: day),
          _failure(
            type == DioExceptionType.connectionError
                ? TideFailure.network
                : TideFailure.timedOut,
          ),
        );
      }
    },
  );

  test(
    'wall timeout cancels the request and failed requests are not cached',
    () async {
      service = KhoaTideService(
        dio: dio,
        requestTimeout: const Duration(milliseconds: 100),
        configuration: const KhoaTideConfiguration(serviceKey: 'test'),
      );
      adapter.respond = (_) => Completer<Object>().future;
      await expectLater(
        service.fetchForecast(station: gunsan, day: day),
        _failure(TideFailure.timedOut),
      );
      await adapter.cancellation.future;
      expect(adapter.cancelled, isTrue);
      adapter.respond = (request) => _success(_rows(request));
      await service.fetchForecast(station: gunsan, day: day);
      expect(adapter.calls, hasLength(2));
    },
  );

  test(
    'pagination fetches remaining rows and checks advertised totals',
    () async {
      adapter.respond = (request) {
        final rows = _rows(request);
        final pageNo = int.parse(request.queryParameters['pageNo'] as String);
        return _success(
          pageNo == 1 ? rows.sublist(0, 2) : rows.sublist(2),
          pageNo: pageNo,
          totalCount: 4,
        );
      };
      final result = await service.fetchForecast(station: gunsan, day: day);
      expect(result.events, hasLength(4));
      expect(adapter.calls.map((call) => call.queryParameters['pageNo']), [
        '1',
        '2',
      ]);
      adapter.respond = (request) => _success(_rows(request), totalCount: 1201);
      await expectLater(
        service.fetchForecast(station: gunsan, day: day, forceRefresh: true),
        _failure(TideFailure.invalidResponse),
      );
      expect(adapter.calls, hasLength(3));
    },
  );

  test('changing pagination, empty pages and wrong page number fail', () async {
    for (var scenario = 0; scenario < 3; scenario++) {
      adapter.respond = (request) {
        final pageNo = int.parse(request.queryParameters['pageNo'] as String);
        if (pageNo == 1) {
          return _success(_rows(request).sublist(0, 2), totalCount: 4);
        }
        return _success(
          scenario == 1 ? [] : _rows(request).sublist(2),
          totalCount: scenario == 0 ? 5 : 4,
          pageNo: scenario == 2 ? 1 : 2,
        );
      };
      await expectLater(
        service.fetchForecast(station: gunsan, day: day),
        _failure(TideFailure.invalidResponse),
      );
    }
  });
}

Matcher _failure(TideFailure reason) => throwsA(
  isA<TideException>().having((error) => error.reason, 'reason', reason),
);

// Field names, units and enum values follow the official KHOA 2025-12 guide.
// Dates vary with the actual request; this is a local fixture, never a live call.
List<Map<String, Object?>> _rows(RequestOptions request) {
  final date = request.queryParameters['reqDate'] as String;
  final label =
      '${date.substring(0, 4)}-${date.substring(4, 6)}-${date.substring(6)}';
  Map<String, Object?> row(String time, double height, String kind) => {
    'obsvtrNm': '군산',
    'lot': 126.563056,
    'lat': 35.975556,
    'predcDt': '$label $time',
    'predcTdlvVl': height,
    'extrSe': kind,
  };
  return [
    row('19:20', 582, '3'),
    row('07:45', 570.5, '1'),
    row('13:10', 121, '4'),
    row('01:30', -13.5, '2'),
  ];
}

Map<String, Object?> _success(
  List<Map<String, Object?>> rows, {
  int shape = 0,
  bool wrapped = false,
  int pageNo = 1,
  int? totalCount,
}) {
  final Object items = switch (shape) {
    0 => {'item': rows},
    1 => {'item': rows.single},
    2 => rows,
    _ => rows.single,
  };
  final response = <String, Object?>{
    'header': {'resultCode': '00', 'resultMsg': 'NORMAL_SERVICE'},
    'body': {
      'items': items,
      'pageNo': pageNo,
      'numOfRows': 300,
      'totalCount': totalCount ?? rows.length,
      'type': 'json',
    },
  };
  return wrapped ? {'response': response} : response;
}

Map<String, Object?> _error(String code, String message) => {
  'header': {'resultCode': code, 'resultMsg': message},
};

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  FutureOr<Object> Function(RequestOptions) respond;
  final calls = <RequestOptions>[];
  int status = 200;
  bool cancelled = false;
  final started = Completer<void>();
  final cancellation = Completer<void>();

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
