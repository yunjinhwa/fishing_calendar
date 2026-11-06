import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fishing_build/data/fish/fish_api_configuration.dart';
import 'package:fishing_build/data/fish/fish_catalog_service.dart';
import 'package:fishing_build/data/fish/nifs_naris_fish_service.dart';
import 'package:fishing_build/data/models/fish_species.dart';
import 'package:flutter_test/flutter_test.dart';

const _base = FishSpecies(
  id: 'nifs:fish1',
  name: '붕어',
  scientificName: 'Carassius auratus',
  category: FishCategory.freshwater,
  family: '잉어과',
  aliases: ['붕애'],
);

void main() {
  late _Adapter adapter;
  late Dio dio;
  late DateTime now;
  late NifsNarisFishService service;

  setUp(() {
    now = DateTime.utc(2026, 11, 4);
    adapter = _Adapter(_catalogResponse);
    dio = Dio()..httpClientAdapter = adapter;
    service = NifsNarisFishService(
      dio: dio,
      clock: () => now,
      configuration: const FishApiConfiguration(
        nifsApiKey: 'nifs+private',
        narisApiKey: 'naris/private',
      ),
    );
  });
  tearDown(() => dio.close(force: true));

  test('configuration never exposes credentials', () {
    const configuration = FishApiConfiguration(
      nifsApiKey: ' nifs+private ',
      narisApiKey: 'naris/private',
    );
    expect(configuration.normalizedNifsApiKey, 'nifs+private');
    expect(configuration.toString(), isNot(contains('private')));
    for (final key in ['', 'bad key', 'line\nkey']) {
      expect(
        FishApiConfiguration(nifsApiKey: key).isCatalogConfigured,
        isFalse,
      );
    }
  });

  test('missing issuer keys fail before a network call', () async {
    final unconfigured = NifsNarisFishService(
      dio: dio,
      configuration: const FishApiConfiguration(),
    );
    await expectLater(
      unconfigured.fetchCatalog(),
      _failure(FishCatalogFailure.configuration),
    );
    await expectLater(
      unconfigured.fetchDetail(_base),
      _failure(FishCatalogFailure.configuration),
    );
    expect(adapter.calls, isEmpty);
  });

  test(
    'discovers fish under vertebrates and restricts species requests',
    () async {
      final result = await service.fetchCatalog();
      expect(result, hasLength(1));
      expect(result.single.name, '붕어');
      expect(result.single.id, 'nifs:fish1');
      expect(result.single.family, '잉어과');
      expect(result.single.scientificName, 'Carassius auratus');
      expect(result.single.aliases, containsAll(['붕애', '토종붕어']));
      final speciesCalls = adapter.calls.where(
        (call) => call.queryParameters['id'] == 'frcenterInfo2',
      );
      expect(speciesCalls, hasLength(1));
      expect(speciesCalls.single.queryParameters, {
        'id': 'frcenterInfo2',
        'key': 'nifs+private',
        'mf_l_cls_cd': 'V1',
        'mf_m_cls_cd': 'F7',
      });
      expect(adapter.calls.every((call) => call.uri.scheme == 'https'), isTrue);
      expect(
        adapter.calls.every((call) => call.uri.path == '/api/OpenAPI_json'),
        isTrue,
      );
      expect(adapter.calls.every((call) => !call.followRedirects), isTrue);
    },
  );

  test(
    'live nested classification envelope needs only one discovery call',
    () async {
      adapter.respond = (call) {
        if (call.queryParameters['id'] == 'frcenterCode2') {
          // Sanitized subset of the authenticated 2026-11-04 public code tree.
          // Codes come from that response rather than assumed taxonomy IDs.
          return _nifs([
            {
              'mf_l_cls_cd': 'LV',
              'mf_l_cls_nm': '척추동물',
              'item2': [
                {'mf_m_cls_cd': 'FS', 'mf_m_cls_nm': '어류', 'item3': []},
                {'mf_m_cls_cd': 'MM', 'mf_m_cls_nm': '포유류', 'item3': []},
                {'mf_m_cls_cd': 'AV', 'mf_m_cls_nm': '바다새', 'item3': []},
              ],
            },
            {
              'mf_l_cls_cd': 'LI',
              'mf_l_cls_nm': '무척추동물',
              'item2': [
                {'mf_m_cls_cd': 'EN', 'mf_m_cls_nm': '극피동물', 'item3': []},
                {'mf_m_cls_cd': 'ML', 'mf_m_cls_nm': '연체동물', 'item3': []},
              ],
            },
            {
              'mf_l_cls_cd': 'LP',
              'mf_l_cls_nm': '식물',
              'item2': [
                {'mf_m_cls_cd': 'PT', 'mf_m_cls_nm': '관속식물', 'item3': []},
              ],
            },
            {
              'mf_l_cls_cd': 'LR',
              'mf_l_cls_nm': '원생생물',
              'item2': [
                {'mf_m_cls_cd': 'PZ', 'mf_m_cls_nm': '원생동물', 'item3': []},
              ],
            },
            {
              'mf_l_cls_cd': 'LM',
              'mf_l_cls_nm': '미생물',
              'item2': [
                {'mf_m_cls_cd': 'BT', 'mf_m_cls_nm': '세균', 'item3': []},
              ],
            },
          ]);
        }
        return _nifs([_fish('fish1')]);
      };
      expect(await service.fetchCatalog(), hasLength(1));
      expect(adapter.calls, hasLength(2));
      expect(adapter.calls.first.queryParameters['id'], 'frcenterCode2');
      expect(adapter.calls.last.queryParameters, {
        'id': 'frcenterInfo2',
        'key': 'nifs+private',
        'mf_l_cls_cd': 'LV',
        'mf_m_cls_cd': 'FS',
      });
    },
  );

  test(
    'a chordate label alone never triggers a fish species request',
    () async {
      adapter.respond = (_) => _nifs([
        {'mf_l_cls_cd': 'V1', 'mf_l_cls_nm': '척삭동물문'},
      ]);
      await expectLater(
        service.fetchCatalog(),
        _failure(FishCatalogFailure.noData),
      );
      expect(
        adapter.calls.any(
          (call) => call.queryParameters['id'] == 'frcenterInfo2',
        ),
        isFalse,
      );
    },
  );

  test(
    'official NIFS water code labels classify marine and freshwater fish',
    () async {
      // Verified 2026-11-04: waterKindCd/waterKindCdNm pairs in the public response:
      // https://www.nifs.go.kr/portal/bt/frctA/selectSpeciesList.do?largeClass=LV&midClass=FS&selectPage=1&pageUnit=3
      // BTBS-WK-01 = 해수; BTBS-WK-02 = 육상 담수. No other code is inferred.
      adapter.respond = (call) => call.queryParameters['id'] == 'frcenterInfo2'
          ? _nifs([
              _fish('marine', water: 'BTBS-WK-01'),
              _fish('fresh', water: 'BTBS-WK-02'),
              _fish('named', water: '육상 담수'),
              _fish('unknown', water: 'BTBS-WK-03'),
              _fish('numeric', water: '02'),
            ])
          : _catalogResponse(call);
      final values = {
        for (final fish in await service.fetchCatalog()) fish.id: fish,
      };
      expect(values['nifs:marine']!.category, FishCategory.sea);
      expect(values['nifs:marine']!.habitat, '해수');
      for (final id in ['nifs:fresh', 'nifs:named']) {
        expect(values[id]!.category, FishCategory.freshwater);
        expect(values[id]!.habitat, '육상 담수');
      }
      for (final id in ['nifs:unknown', 'nifs:numeric']) {
        expect(values[id]!.category, FishCategory.unknown);
        expect(values[id]!.habitat, isEmpty);
      }
    },
  );

  test('numeric and mixed habitat codes remain unknown', () async {
    adapter.respond = (call) => call.queryParameters['id'] == 'frcenterInfo2'
        ? _nifs([
            _fish('1', water: '01'),
            _fish('2', water: '담수'),
            _fish('3', water: '해수'),
            _fish('4', water: '해수, 담수'),
          ])
        : _catalogResponse(call);
    final values = {
      for (final fish in await service.fetchCatalog()) fish.id: fish,
    };
    expect(values['nifs:1']!.category, FishCategory.unknown);
    expect(values['nifs:1']!.habitat, isEmpty);
    expect(values['nifs:2']!.category, FishCategory.freshwater);
    expect(values['nifs:2']!.habitat, '담수');
    expect(values['nifs:3']!.category, FishCategory.sea);
    expect(values['nifs:3']!.habitat, '해수');
    expect(values['nifs:4']!.category, FishCategory.unknown);
    expect(values['nifs:4']!.habitat, '해수, 담수');
  });

  test('rejects birds even if a server ignores the fish filter', () async {
    adapter.respond = (call) => call.queryParameters['id'] == 'frcenterInfo2'
        ? _nifs([
            {..._fish('bird'), 'mf_m_cls_nm': '조류', 'mf_kor_class': '조강'},
          ])
        : _catalogResponse(call);
    await expectLater(
      service.fetchCatalog(),
      _failure(FishCatalogFailure.noData),
    );
  });

  test(
    'catalog calls share in-flight work and respect refresh and TTL',
    () async {
      final first = service.fetchCatalog();
      final second = service.fetchCatalog();
      expect(await first, same(await second));
      final calls = adapter.calls.length;
      await service.fetchCatalog();
      expect(adapter.calls, hasLength(calls));
      await service.fetchCatalog(forceRefresh: true);
      expect(adapter.calls, hasLength(calls * 2));
      now = now.add(const Duration(days: 2));
      await service.fetchCatalog();
      expect(adapter.calls, hasLength(calls * 3));
    },
  );

  test('classification discovery has a strict request budget', () async {
    final limited = NifsNarisFishService(
      dio: dio,
      maxCatalogRequests: 2,
      configuration: const FishApiConfiguration(nifsApiKey: 'private'),
    );
    await expectLater(
      limited.fetchCatalog(),
      _failure(FishCatalogFailure.invalidResponse),
    );
    expect(adapter.calls, hasLength(2));
  });

  test('catalog deadline is positive and cancels a stalled request', () async {
    expect(
      () => NifsNarisFishService(catalogTimeout: Duration.zero),
      throwsArgumentError,
    );
    adapter.respond = (_) => Completer<Object>().future;
    final limited = NifsNarisFishService(
      dio: dio,
      catalogTimeout: const Duration(milliseconds: 25),
      requestTimeout: const Duration(seconds: 1),
      configuration: const FishApiConfiguration(nifsApiKey: 'private'),
    );
    final elapsed = Stopwatch()..start();
    await expectLater(
      limited.fetchCatalog(),
      _failure(FishCatalogFailure.timedOut),
    );
    await adapter.cancelled.future;
    expect(elapsed.elapsed, lessThan(const Duration(milliseconds: 500)));
    expect(adapter.calls, hasLength(1));
    expect(
      adapter.calls.single.receiveTimeout,
      lessThanOrEqualTo(const Duration(milliseconds: 25)),
    );
  });

  test(
    'serial calls share one catalog deadline and stop after expiry',
    () async {
      adapter.respond = (call) async {
        await Future<void>.delayed(const Duration(milliseconds: 45));
        return _catalogResponse(call);
      };
      final limited = NifsNarisFishService(
        dio: dio,
        catalogTimeout: const Duration(milliseconds: 100),
        requestTimeout: const Duration(seconds: 1),
        configuration: const FishApiConfiguration(nifsApiKey: 'private'),
      );
      final elapsed = Stopwatch()..start();
      await expectLater(
        limited.fetchCatalog(),
        _failure(FishCatalogFailure.timedOut),
      );
      final stoppedAt = adapter.calls.length;
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(elapsed.elapsed, lessThan(const Duration(milliseconds: 700)));
      expect(adapter.calls, hasLength(stoppedAt));
      expect(adapter.calls.length, lessThanOrEqualTo(3));
      if (adapter.calls.length > 1) {
        expect(
          adapter.calls.last.receiveTimeout!,
          lessThan(adapter.calls.first.receiveTimeout!),
        );
      }
    },
  );

  test(
    'catalog rejects more than the repository limit of 10000 fish',
    () async {
      adapter.respond = (call) => call.queryParameters['id'] == 'frcenterInfo2'
          ? _nifs(
              List.generate(
                10001,
                (index) => {
                  'mf_tax_id': '$index',
                  'mf_m_cls_nm': '어류',
                  'mf_kor_nor': 'fish$index',
                },
              ),
            )
          : _catalogResponse(call);
      await expectLater(
        service.fetchCatalog(),
        _failure(FishCatalogFailure.invalidResponse),
      );
    },
  );

  test('NIFS invalid-license errors are sanitized and not cached', () async {
    adapter.respond = (_) => {
      'header': {'resultCode': '02', 'resultMsg': 'invalid license private'},
      'body': <String, Object>{},
    };
    for (var attempt = 0; attempt < 2; attempt++) {
      await expectLater(
        service.fetchCatalog(),
        _failure(FishCatalogFailure.unauthorized),
      );
    }
    expect(adapter.calls, hasLength(2));
    expect(
      const FishCatalogException(FishCatalogFailure.unauthorized).toString(),
      isNot(contains('private')),
    );
  });

  test(
    'NARIS enriches only an exact scientific name and keeps habitat',
    () async {
      adapter.respond = (_) => _naris([
        {'scientificName': 'Carassius gibelio', 'generalSpftrKor': 'wrong'},
        {
          'scientificName': 'Carassius auratus',
          'scientificNameKor': '다른 국명',
          'generalSpftrKor': '<p>몸의 특징</p>',
          'ecologySpftrKor': '해수라는 단어가 설명에 있어도 서식수종을 추정하지 않습니다.',
          'representationImage': '/images/fish.jpg',
        },
      ]);
      final result = await service.fetchDetail(_base);
      expect(result.name, '붕어');
      expect(result.family, '잉어과');
      expect(result.aliases, ['붕애']);
      expect(result.category, FishCategory.freshwater);
      expect(result.feature, contains('몸의 특징'));
      expect(result.feature, isNot(contains('<p>')));
      expect(result.imageUrl, 'https://naris.science.go.kr/images/fish.jpg');
      expect(result.photoAttribution, contains('NARIS'));
      expect(adapter.calls.single.queryParameters, {
        'apiKey': 'naris/private',
        'nameOfSpecies': 'Carassius auratus',
        'pageNo': 1,
        'recordCount': 50,
      });
    },
  );

  test('same Korean name or an author-stripped guess cannot enrich', () async {
    adapter.respond = (_) => _naris([
      {
        'scientificName': 'Carassius auratus (Linnaeus, 1758)',
        'scientificNameKor': '붕어',
        'representationImage': 'https://example.org/fish.jpg',
      },
    ]);
    await expectLater(
      service.fetchDetail(_base),
      _failure(FishCatalogFailure.noData),
    );
    adapter.respond = (_) => _naris([
      {'scientificName': 'Carassius auratus', 'generalSpftrKor': 'correct'},
    ]);
    expect((await service.fetchDetail(_base)).feature, 'correct');
    expect(adapter.calls, hasLength(2));
  });

  test(
    'matching descriptions work when a photo is missing or unsafe',
    () async {
      for (final image in [
        '',
        'http://example.org/fish.jpg',
        'javascript:alert(1)',
        'https://private:secret@example.org/fish.jpg',
        'http://private:secret@naris.science.go.kr/fish.jpg',
        'data:image/png;base64,abc',
      ]) {
        adapter.respond = (_) => _naris([
          {
            'scientificName': _base.scientificName,
            'generalSpftrKor': 'description',
            'representationImage': image,
          },
        ]);
        final result = await service.fetchDetail(_base, forceRefresh: true);
        expect(result.feature, 'description');
        expect(result.imageUrl, isNull);
        expect(result.photoAttribution, isNull);
      }
    },
  );

  test(
    'empty exact matches are noData and can be retried for enrichment',
    () async {
      adapter.respond = (_) => _naris([
        {
          'scientificName': _base.scientificName,
          'generalSpftrKor': '<p> </p>',
          'ecologySpftrKor': '&nbsp;',
          'representationImage': 'http://example.org/fish.jpg',
        },
      ]);
      await expectLater(
        service.fetchDetail(_base),
        _failure(FishCatalogFailure.noData),
      );
      adapter.respond = (_) => _naris([
        {
          'scientificName': _base.scientificName,
          'generalSpftrKor': 'new details',
        },
      ]);
      expect((await service.fetchDetail(_base)).feature, 'new details');
      expect(adapter.calls, hasLength(2));
    },
  );

  test(
    'only legacy official NARIS image hosts are upgraded to HTTPS',
    () async {
      for (final host in ['naris.science.go.kr', 'www.naris.science.go.kr']) {
        adapter.respond = (_) => _naris([
          {
            'scientificName': _base.scientificName,
            'representationImage': 'http://$host/fish.jpg',
          },
        ]);
        final detail = await service.fetchDetail(_base, forceRefresh: true);
        expect(detail.imageUrl, 'https://$host/fish.jpg');
        expect(detail.feature, isEmpty);
        expect(detail.photoAttribution, contains('NARIS'));
      }
    },
  );

  test('details cache exact lookups and refresh after 30 days', () async {
    adapter.respond = (_) => _naris([
      {
        'scientificName': _base.scientificName,
        'generalSpftrKor': 'description',
      },
    ]);
    final first = service.fetchDetail(_base);
    final second = service.fetchDetail(_base);
    expect(await first, same(await second));
    await service.fetchDetail(_base);
    expect(adapter.calls, hasLength(1));
    now = now.add(const Duration(days: 31));
    await service.fetchDetail(_base);
    expect(adapter.calls, hasLength(2));
  });

  test('NARIS current authentication envelope is recognized', () async {
    adapter.respond = (_) => {
      'result': [],
      'resultCode': 'E01',
      'resultMsg': '사용자 인증에 실패하였습니다.',
    };
    await expectLater(
      service.fetchDetail(_base),
      _failure(FishCatalogFailure.unauthorized),
    );
  });

  test(
    'timeouts, HTTP limits, malformed and oversized responses are bounded',
    () async {
      adapter.status = 429;
      await expectLater(
        service.fetchCatalog(),
        _failure(FishCatalogFailure.rateLimited),
      );
      adapter.status = 200;
      adapter.respond = (_) => '<html>unavailable</html>';
      await expectLater(
        service.fetchCatalog(),
        _failure(FishCatalogFailure.invalidResponse),
      );
      adapter.respond = (_) => ' ' * (4 * 1024 * 1024 + 1);
      await expectLater(
        service.fetchCatalog(),
        _failure(FishCatalogFailure.invalidResponse),
      );
      adapter.respond = (_) => Completer<Object>().future;
      final fastTimeout = NifsNarisFishService(
        dio: dio,
        requestTimeout: const Duration(milliseconds: 10),
        configuration: const FishApiConfiguration(nifsApiKey: 'private'),
      );
      await expectLater(
        fastTimeout.fetchCatalog(),
        _failure(FishCatalogFailure.timedOut),
      );
    },
  );
}

Matcher _failure(FishCatalogFailure reason) => throwsA(
  isA<FishCatalogException>().having((error) => error.reason, 'reason', reason),
);

Object _catalogResponse(RequestOptions options) {
  if (options.queryParameters['id'] == 'frcenterInfo2') {
    return _nifs([_fish('fish1')]);
  }
  if (options.queryParameters['mf_l_cls_cd'] == null) {
    return _nifs([
      {'mf_l_cls_cd': 'V1', 'mf_l_cls_nm': '척추동물'},
    ]);
  }
  return _nifs([
    {'mf_m_cls_cd': 'F7', 'mf_m_cls_nm': '어류'},
  ]);
}

Map<String, Object?> _fish(String id, {String water = '01'}) => {
  'mf_tax_id': id,
  'mf_l_cls_nm': '척추동물',
  'mf_m_cls_nm': '어류',
  'mf_kor_nor': '붕어',
  'mf_sci_nor': 'Carassius auratus',
  'mf_kor_family': '잉어과',
  'mf_kor_equ': '붕애; 토종붕어',
  'mf_water_kind': water,
};

Map<String, Object?> _nifs(List<Map<String, Object?>> rows) => {
  'header': {'resultCode': '00', 'resultMsg': 'NORMAL SERVICE'},
  'body': {'item': rows},
};
Map<String, Object?> _naris(List<Map<String, Object?>> rows) => {
  'resultCode': '0000',
  'resultMessage': 'success',
  'result': rows,
};

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  FutureOr<Object> Function(RequestOptions) respond;
  final calls = <RequestOptions>[];
  final cancelled = Completer<void>();
  int status = 200;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(options);
    cancelFuture?.then((_) {
      if (!cancelled.isCompleted) cancelled.complete();
    });
    final value = await respond(options);
    return ResponseBody.fromString(
      value is String ? value : jsonEncode(value),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
