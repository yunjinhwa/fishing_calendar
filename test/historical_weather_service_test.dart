import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fishing_build/data/history/historical_conditions_service.dart';
import 'package:fishing_build/data/history/kma_historical_weather_configuration.dart';
import 'package:fishing_build/data/history/kma_historical_weather_service.dart';
import 'package:fishing_build/data/maps/map_location.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late DateTime now;
  late _Adapter adapter;
  late KmaHistoricalWeatherService service;
  final seoul = MapLocation(name: '서울', latitude: 37.57, longitude: 126.96);
  final target = DateTime.utc(2022, 11, 30, 0, 35); // 09:35 KST.

  KmaHistoricalWeatherService create({
    int maxCachedEntries = 128,
    Duration requestTimeout = const Duration(seconds: 12),
    KmaHistoricalWeatherConfiguration configuration =
        const KmaHistoricalWeatherConfiguration(serviceKey: 'test+key/='),
  }) => KmaHistoricalWeatherService(
    dio: Dio()..httpClientAdapter = adapter,
    clock: () => now,
    configuration: configuration,
    maxCachedEntries: maxCachedEntries,
    requestTimeout: requestTimeout,
  );

  setUp(() {
    now = DateTime.utc(2026, 11, 3, 3, 10);
    adapter = _Adapter((request) => _success(request));
    service = create();
  });

  test(
    'configuration preserves literal key characters and excludes secrets',
    () {
      const configuration = KmaHistoricalWeatherConfiguration(
        serviceKey: ' test%2Bkey%2F%3D ',
      );
      expect(configuration.normalizedServiceKey, 'test+key/=');
      expect(configuration.toString(), isNot(contains('test')));
      expect(configuration.isConfigured, isTrue);
      for (final key in ['', ' ', 'bad%ZZ', 'has\nspace', 'encoded%20space']) {
        expect(
          KmaHistoricalWeatherConfiguration(serviceKey: key).isConfigured,
          isFalse,
        );
      }
      expect(
        const KmaHistoricalWeatherConfiguration(
          provider: 'data_go_kr',
          serviceKey: 'other-provider-key',
        ).isConfigured,
        isFalse,
      );
    },
  );

  test(
    'accepts live STN catalog header without confusing the later STN code',
    () async {
      final liveStations = _stations
          .replaceFirst('STN_ID LON LAT', 'STN LON LAT')
          .replaceFirst('STN_CD STN_KO', 'STN STN_KO')
          .replaceFirst('1.5 10 1 - 서울', '1.5 10 1 159 서울');
      adapter.handler = (request) => request.uri.path.endsWith('stn_inf.php')
          ? _text(liveStations)
          : _success(request);
      final result = await service.fetchAt(
        location: seoul,
        requestedAt: target,
      );
      expect(result.station.code, '108');
      expect(result.station.name, '서울');
      expect(result.airTemperature, -3);
    },
  );

  test(
    'queries the historical KST hour and the catalog valid at that hour',
    () async {
      final result = await service.fetchAt(
        location: seoul,
        requestedAt: target,
      );
      expect(adapter.calls, hasLength(2));
      expect(
        adapter.calls.map((call) => call.uri.path),
        containsAll([
          '/api/typ01/url/stn_inf.php',
          '/api/typ01/url/kma_sfctm2.php',
        ]),
      );
      for (final call in adapter.calls) {
        expect(call.uri.host, 'apihub.kma.go.kr');
        expect(call.uri.scheme, 'https');
        expect(call.queryParameters['tm'], '202211300900');
        expect(call.queryParameters['authKey'], 'test+key/=');
        expect(call.queryParameters['stn'], '0');
        expect(call.queryParameters['help'], '1');
        expect(call.queryParameters, isNot(contains('base_date')));
        expect(call.queryParameters, isNot(contains('serviceKey')));
      }
      expect(result.station.code, '108');
      expect(result.station.name, '서울');
      expect(result.observedAt, DateTime.utc(2022, 11, 30));
      expect(result.requestedAt, target);
      expect(result.fetchedAt, now);
      expect(result.airTemperature, -3);
      expect(result.weather, '맑음');
    },
  );

  test(
    'KST midnight and the earliest supported 2020 hour cross UTC dates',
    () async {
      final result = await service.fetchAt(
        location: seoul,
        requestedAt: DateTime.utc(2019, 12, 31, 15, 59),
      );
      expect(adapter.calls.first.queryParameters['tm'], '202001010000');
      expect(result.observedAt, DateTime.utc(2019, 12, 31, 15));
    },
  );

  test(
    'published 46-field ASOS fixture parses without numbered help',
    () async {
      adapter.handler = (request) => request.uri.path.endsWith('stn_inf.php')
          ? _text(_stations)
          : _text('''#START7777
# YYMMDDHHMI STN WD WS GST GST GST PA PS PT PR TA TD HM PV RN RN RN RN SD SD SD WC WP WW CA CA CH CT CT CT CT VS SS SI ST TS TE TE TE TE ST WH BF IR IX
202211300900 108 29 4.6 32 10.0 331 1025.7 1028.0 2 1.7 -3.0 -24.6 17.0 0.8 -9.0 -9.0 -9.0 -9.0 -9.0 -9.0 -9.0 -9 -9 - 2 0 -9 - -9 -9 -9 5000 1.0 -9.00 -9 -1.0 -99.0 -99.0 -99.0 -99.0 -9 -9.0 -9 3 -9
#7777END''');
      final result = await service.fetchAt(
        location: seoul,
        requestedAt: target,
      );
      expect(result.airTemperature, -3);
      expect(result.weather, '맑음');
    },
  );

  test(
    'domestic two-digit rain and mist codes override clear cloud amount',
    () async {
      adapter.handler = (request) => _success(
        request,
        rows: [_row(request, domestic: '0119', cloud: '0')],
      );
      final result = await service.fetchAt(
        location: seoul,
        requestedAt: target,
      );
      expect(result.weather, '비, 박무');
    },
  );

  test('WMO current rain wins over a cloud sky description', () async {
    adapter.handler = (request) => _success(
      request,
      rows: [_row(request, wc: '61', cloud: '0')],
    );
    expect(
      (await service.fetchAt(location: seoul, requestedAt: target)).weather,
      '비',
    );
  });

  test('WMO preceding-hour rain is not presented as current rain', () async {
    adapter.handler = (request) => _success(
      request,
      rows: [_row(request, wc: '21', cloud: '-9')],
    );
    final result = await service.fetchAt(location: seoul, requestedAt: target);
    expect(result.weather, isNull);
    expect(result.airTemperature, -3);
  });

  test(
    'zero rainfall does not manufacture clear weather or a missing temperature',
    () async {
      adapter.handler = (request) => _success(
        request,
        rows: [
          _row(request, temperature: '-99.9', cloud: '-9', rainfall: '0.0'),
        ],
      );
      await expectLater(
        service.fetchAt(location: seoul, requestedAt: target),
        _fails(HistoricalDataFailure.noData),
      );
    },
  );

  test(
    'minus nine is a real air temperature and missing weather stays null',
    () async {
      adapter.handler = (request) => _success(
        request,
        rows: [_row(request, temperature: '-9.0', cloud: '-9')],
      );
      final result = await service.fetchAt(
        location: seoul,
        requestedAt: target,
      );
      expect(result.airTemperature, -9);
      expect(result.weather, isNull);
    },
  );

  test('weather remains usable when only temperature is missing', () async {
    adapter.handler = (request) => _success(
      request,
      rows: [_row(request, temperature: '-99.0', domestic: '05', cloud: '-9')],
    );
    final result = await service.fetchAt(location: seoul, requestedAt: target);
    expect(result.airTemperature, isNull);
    expect(result.weather, '눈');
  });

  test(
    'does not substitute another hour, day, or station outside the historical catalog',
    () async {
      adapter.handler = (request) => _success(
        request,
        rows: [
          _row(request, time: '202211300800'),
          _row(request, code: '999'),
        ],
      );
      await expectLater(
        service.fetchAt(location: seoul, requestedAt: target),
        _fails(HistoricalDataFailure.noData),
      );
      expect(adapter.calls, hasLength(2));
    },
  );

  test(
    'selects an available observation within 50 km and rejects distant stations',
    () async {
      adapter.handler = (request) => _success(
        request,
        rows: [
          _row(request, temperature: '-99.9', cloud: '-9'),
          _row(request, code: '119', temperature: '5.1'),
        ],
      );
      final result = await service.fetchAt(
        location: seoul,
        requestedAt: target,
      );
      expect(result.station.code, '119');
      expect(result.airTemperature, 5.1);
      await expectLater(
        service.fetchAt(
          location: MapLocation(name: '멀리', latitude: 35, longitude: 130),
          requestedAt: target,
        ),
        _fails(HistoricalDataFailure.unsupportedLocation),
      );
    },
  );

  test(
    'rejects current, future, and pre-2020 hours before any request',
    () async {
      for (final requested in [
        now,
        DateTime.utc(2026, 11, 4),
        DateTime.utc(2019, 12, 31, 14, 59),
      ]) {
        await expectLater(
          service.fetchAt(location: seoul, requestedAt: requested),
          _fails(HistoricalDataFailure.unsupportedDate),
        );
      }
      await expectLater(
        service.fetchAt(
          location: MapLocation(name: '좌표 없음'),
          requestedAt: target,
        ),
        _fails(HistoricalDataFailure.coordinatesRequired),
      );
      service = create(
        configuration: const KmaHistoricalWeatherConfiguration(
          provider: 'data_go_kr',
          serviceKey: 'private',
        ),
      );
      await expectLater(
        service.fetchAt(location: seoul, requestedAt: target),
        _fails(HistoricalDataFailure.configuration),
      );
      expect(adapter.calls, isEmpty);
    },
  );

  test(
    'coalesces concurrent hours and rebinds cached results to each selection',
    () async {
      final gate = Completer<void>();
      adapter.handler = (request) async {
        await gate.future;
        return _success(request);
      };
      final other = MapLocation(name: '인근', latitude: 37.58, longitude: 126.97);
      final first = service.fetchAt(location: seoul, requestedAt: target);
      final second = service.fetchAt(
        location: other,
        requestedAt: target.add(const Duration(minutes: 10)),
      );
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      final results = await Future.wait([first, second]);
      expect(adapter.calls, hasLength(2));
      expect(results[0].location.name, '서울');
      expect(results[1].location.name, '인근');
      expect(results[1].requestedAt, target.add(const Duration(minutes: 10)));
      await service.fetchAt(location: seoul, requestedAt: target);
      expect(adapter.calls, hasLength(2));
    },
  );

  test(
    'refresh, 24-hour expiration, and bounded eviction require fresh requests',
    () async {
      service = create(maxCachedEntries: 1);
      await service.fetchAt(location: seoul, requestedAt: target);
      await service.fetchAt(
        location: seoul,
        requestedAt: target,
        forceRefresh: true,
      );
      expect(adapter.calls, hasLength(4));
      now = now.add(const Duration(hours: 24));
      await service.fetchAt(location: seoul, requestedAt: target);
      expect(adapter.calls, hasLength(6));
      await service.fetchAt(
        location: seoul,
        requestedAt: target.add(const Duration(hours: 1)),
      );
      await service.fetchAt(location: seoul, requestedAt: target);
      expect(adapter.calls, hasLength(10));
    },
  );

  test('global no-data responses expire after ten minutes', () async {
    adapter.handler = (request) => _success(request, rows: []);
    for (var i = 0; i < 2; i++) {
      await expectLater(
        service.fetchAt(location: seoul, requestedAt: target),
        _fails(HistoricalDataFailure.noData),
      );
    }
    expect(adapter.calls, hasLength(2));
    now = now.add(const Duration(minutes: 10));
    adapter.handler = (request) => _success(request);
    expect(
      (await service.fetchAt(
        location: seoul,
        requestedAt: target,
      )).airTemperature,
      -3,
    );
    expect(adapter.calls, hasLength(4));
  });

  test('rejects conflicting observations and truncated ASOS bodies', () async {
    adapter.handler = (request) => _success(
      request,
      rows: [
        _row(request),
        _row(request, temperature: '20'),
      ],
    );
    await expectLater(
      service.fetchAt(location: seoul, requestedAt: target),
      _fails(HistoricalDataFailure.invalidResponse),
    );
    adapter.handler = (_) => _text('#START7777\npartial');
    await expectLater(
      service.fetchAt(location: seoul, requestedAt: target),
      _fails(HistoricalDataFailure.invalidResponse),
    );
  });

  test('provider and transport failures expose only a sanitized enum', () async {
    for (final entry in <int, HistoricalDataFailure>{
      403: HistoricalDataFailure.unauthorized,
      429: HistoricalDataFailure.rateLimited,
      503: HistoricalDataFailure.network,
    }.entries) {
      adapter.handler = (_) => _text('private key / secret URL', entry.key);
      await expectLater(
        service.fetchAt(location: seoul, requestedAt: target),
        _fails(entry.value),
      );
    }
    adapter.handler = (_) => _text(
      '<OpenAPI_ServiceResponse><returnReasonCode>30</returnReasonCode>'
      '<errMsg>private key and https://private</errMsg></OpenAPI_ServiceResponse>',
    );
    try {
      await service.fetchAt(location: seoul, requestedAt: target);
      fail('Expected unauthorized response');
    } on HistoricalDataException catch (error) {
      expect(error.reason, HistoricalDataFailure.unauthorized);
      expect(error.toString(), 'HistoricalDataException(unauthorized)');
    }
    adapter.handler = (request) => throw DioException(
      requestOptions: request,
      type: DioExceptionType.connectionError,
      error: 'private URL',
    );
    await expectLater(
      service.fetchAt(location: seoul, requestedAt: target),
      _fails(HistoricalDataFailure.network),
    );
  });

  test('bounds streamed and declared response bodies to 512 KiB', () async {
    adapter.handler = (_) =>
        ResponseBody.fromBytes(Uint8List(512 * 1024 + 1), 200);
    await expectLater(
      service.fetchAt(location: seoul, requestedAt: target),
      _fails(HistoricalDataFailure.invalidResponse),
    );
    adapter.handler = (_) => ResponseBody.fromString(
      '',
      200,
      headers: {
        Headers.contentLengthHeader: ['524289'],
      },
    );
    await expectLater(
      service.fetchAt(location: seoul, requestedAt: target),
      _fails(HistoricalDataFailure.invalidResponse),
    );
  });

  test('a stalled body times out within the total request deadline', () async {
    service = create(requestTimeout: const Duration(milliseconds: 15));
    adapter.handler = (_) => ResponseBody(
      Stream<Uint8List>.fromFuture(Completer<Uint8List>().future),
      200,
    );
    await expectLater(
      service.fetchAt(location: seoul, requestedAt: target),
      _fails(HistoricalDataFailure.timedOut),
    );
  });
}

Matcher _fails(HistoricalDataFailure failure) => throwsA(
  isA<HistoricalDataException>().having(
    (error) => error.reason,
    'reason',
    failure,
  ),
);

const _stations = '''#START7777
# STN_ID LON LAT STN_SP HT HT_PA HT_TA HT_WD HT_RN STN_CD STN_KO STN_EN STN_AD FCT_ID LAW_ID BASIN
108 126.96 37.57 1 85 86 1.5 10 1 - 서울 Seoul 108 11B10101 1111000000 0
119 126.98 37.27 1 34 35 1.5 10 1 - 수원 Suwon 119 11B20601 4111000000 0
159 129.03 35.10 1 69 70 1.5 10 1 - 부산 Busan 159 11H20201 2611000000 0
#7777END''';

ResponseBody _success(RequestOptions request, {List<String>? rows}) =>
    request.uri.path.endsWith('stn_inf.php')
    ? _text(_stations)
    : _text('''#START7777
# 1. TM : 관측시각
# 2. STN : 국내 지점번호
# 12. TA : 기온
# 23. WC : 현재일기
# 25. WW : 국내식 일기코드
# 26. CA_TOT : 전운량
${(rows ?? [_row(request)]).join('\n')}
#7777END''');

String _row(
  RequestOptions request, {
  String code = '108',
  String? time,
  String temperature = '-3.0',
  String wc = '-9',
  String domestic = '-',
  String cloud = '2',
  String rainfall = '-9.0',
}) {
  final fields = List<String>.filled(46, '-9');
  fields[0] = time ?? request.queryParameters['tm'].toString();
  fields[1] = code;
  fields[11] = temperature;
  fields[15] = rainfall;
  fields[22] = wc;
  fields[24] = domestic;
  fields[25] = cloud;
  return fields.join(' ');
}

ResponseBody _text(String body, [int status = 200]) => ResponseBody.fromString(
  body,
  status,
  headers: {
    Headers.contentTypeHeader: ['text/plain; charset=utf-8'],
  },
);

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  FutureOr<ResponseBody> Function(RequestOptions) handler;
  final calls = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}
