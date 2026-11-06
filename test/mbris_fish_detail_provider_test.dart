import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fishing_build/data/fish/fish_catalog_service.dart';
import 'package:fishing_build/data/fish/mbris_fish_detail_provider.dart';
import 'package:fishing_build/data/models/fish_species.dart';
import 'package:flutter_test/flutter_test.dart';

const _fish = FishSpecies(
  id: 'nifs:123',
  name: '갈치',
  aliases: ['갈티'],
  scientificName: 'Trichiurus lepturus',
  category: FishCategory.sea,
  family: '갈치과',
  habitat: '바다',
  maxSize: '기존 크기',
  feature: '기존 설명',
  imageUrl: 'https://example.org/photo.jpg',
  photoAttribution: '기존 사진 저작자',
  photoSourceUrl: 'https://example.org/photo',
  photoLicenseUrl: 'https://example.org/license',
  sourceName: '국립수산과학원',
  sourceUrl: 'https://example.org/catalog',
);

void main() {
  late _Adapter adapter;
  late Dio dio;
  late MbrisFishDetailProvider provider;
  setUp(() {
    adapter = _Adapter((_) => _response([_row()]));
    dio = Dio()..httpClientAdapter = adapter;
    provider = MbrisFishDetailProvider(dio: dio, serviceKey: 'test+/key==');
  });
  tearDown(() => dio.close(force: true));

  test(
    'uses current XML contract and preserves catalog and photo data',
    () async {
      final result = await provider.fetchDetail(_fish);
      expect(result.id, _fish.id);
      expect(result.name, _fish.name);
      expect(result.aliases, _fish.aliases);
      expect(result.scientificName, _fish.scientificName);
      expect(result.family, _fish.family);
      expect(result.category, _fish.category);
      expect(result.habitat, _fish.habitat);
      expect(result.maxSize, _fish.maxSize);
      expect(result.imageUrl, _fish.imageUrl);
      expect(result.photoAttribution, _fish.photoAttribution);
      expect(result.photoSourceUrl, _fish.photoSourceUrl);
      expect(result.photoLicenseUrl, _fish.photoLicenseUrl);
      expect(
        result.feature,
        '몸은 길다.\n\n은빛이며 몸길이는 1m이다.\n\n작은 물고기를 먹는다.\n\n서식지: 연안 바다',
      );
      expect(result.descriptionAttribution, '국립해양생물자원관 MBRIS');
      expect(result.descriptionSourceUrl, MbrisFishDetailProvider.sourceUrl);
      expect(result.sourceName, contains(_fish.sourceName));
      expect(result.sourceName, contains('MBRIS'));
      expect(result.sourceUrl, _fish.sourceUrl);
      final call = adapter.calls.single;
      expect(call.uri.scheme, 'https');
      expect(call.uri.host, 'apis.data.go.kr');
      expect(call.uri.path, '/B553482/mbrisdataview3/taxonlist3');
      expect(call.queryParameters, {
        'serviceKey': 'test+/key==',
        'pageNo': 1,
        'numOfRows': 20,
        'SpcScitfNm': 'Trichiurus lepturus',
      });
      expect(call.followRedirects, isFalse);
      expect(call.maxRedirects, 0);
      expect(call.responseType, ResponseType.stream);
    },
  );

  test(
    'retains verified domestic and foreign distribution as separate paragraphs',
    () async {
      adapter.respond = (_) => _response([
        _row().replaceFirst(
          '</item>',
          '<NADI>우리나라 남해 연안</NADI><INDI>일본과 중국 연안</INDI></item>',
        ),
      ]);
      final fish = await provider.fetchDetail(_fish);
      expect(fish.feature, contains('\n\n국내 분포: 우리나라 남해 연안'));
      expect(fish.feature, contains('\n\n해외 분포: 일본과 중국 연안'));
      expect(fish.scientificName, _fish.scientificName);
    },
  );

  test(
    'disagreeing distributions cannot be resolved by selecting the first row',
    () async {
      adapter.respond = (_) => _response([
        _row().replaceFirst('</item>', '<NADI>남해</NADI></item>'),
        _row().replaceFirst('</item>', '<NADI>동해</NADI></item>'),
      ]);
      await expectLater(
        provider.fetchDetail(_fish),
        _failure(FishCatalogFailure.invalidResponse),
      );
    },
  );

  test('normalizes an Encoding key once and preserves literal plus', () async {
    provider = MbrisFishDetailProvider(
      dio: dio,
      serviceKey: 'test%2B%2Fkey%3D%3D',
    );
    expect(provider.isConfigured, isTrue);
    await provider.fetchDetail(_fish);
    final uri = adapter.calls.single.uri;
    expect(uri.queryParameters['serviceKey'], 'test+/key==');
    expect(uri.query, contains('serviceKey=test%2B%2Fkey%3D%3D'));
    expect(uri.query, isNot(contains('%252B')));
  });

  test(
    'absent and invalid keys never send a request or expose a key',
    () async {
      for (final key in [
        '',
        '  ',
        'secret%ZZ',
        'secret%252B',
        'a\nb',
        'https://key',
      ]) {
        final unconfigured = MbrisFishDetailProvider(dio: dio, serviceKey: key);
        expect(unconfigured.isConfigured, isFalse);
        await expectLater(
          unconfigured.fetchDetail(_fish),
          _failure(FishCatalogFailure.configuration),
        );
      }
      expect(adapter.calls, isEmpty);
    },
  );

  test(
    'requires exact scientific and Korean identity including aliases',
    () async {
      for (final row in [
        _row(scientific: 'Trichiurus'),
        _row(scientific: 'Trichiurus lepturus japonicus'),
        _row(scientific: 'Trichiurus lepturus Linnaeus, 1758'),
        _row(korean: '풀갈치'),
        _row(korean: ''),
        _row(accepted: 'Trichiurus japonicus'),
      ]) {
        adapter.respond = (_) => _response([row]);
        await expectLater(
          provider.fetchDetail(_fish),
          _failure(FishCatalogFailure.noData),
        );
      }
      adapter.respond = (_) => _response([_row(korean: '갈티')]);
      expect((await provider.fetchDetail(_fish)).feature, contains('몸은 길다.'));
    },
  );

  test(
    'matches explicit canonical names while retaining author-bearing full names',
    () async {
      const fullName = 'Trichiurus lepturus Linnaeus, 1758';
      for (final accepted in [fullName, _fish.scientificName]) {
        adapter.respond = (_) => _response([
          _row(
            scientific: fullName,
            shortScientific: _fish.scientificName,
            accepted: accepted,
          ),
        ]);
        final result = await provider.fetchDetail(_fish);
        expect(result.scientificName, _fish.scientificName);
        expect(result.feature, contains('몸은 길다.'));
      }
    },
  );

  test(
    'never guesses canonical names or follows another accepted taxon',
    () async {
      const fullName = 'Trichiurus lepturus Linnaeus, 1758';
      for (final row in [
        _row(scientific: fullName, accepted: fullName),
        _row(
          scientific: fullName,
          shortScientific: 'Trichiurus japonicus',
          accepted: fullName,
        ),
        _row(
          scientific: fullName,
          shortScientific: _fish.scientificName,
          accepted: 'Trichiurus japonicus Temminck & Schlegel, 1844',
        ),
        _row(
          scientific: fullName,
          shortScientific: _fish.scientificName,
          korean: '풀갈치',
          accepted: fullName,
        ),
      ]) {
        adapter.respond = (_) => _response([row]);
        await expectLater(
          provider.fetchDetail(_fish),
          _failure(FishCatalogFailure.noData),
        );
      }
    },
  );

  test(
    'reads the verified flounder envelope with explicit short name and authors',
    () async {
      final flounder = FishSpecies.fromJson({
        ..._fish.toJson(),
        'id': 'nifs:flounder',
        'name': '넙치',
        'scientificName': 'Paralichthys olivaceus',
        'aliases': ['광어'],
        'maxSize': '',
      });
      adapter.respond = (_) => _verifiedFlounderEnvelope;
      final result = await provider.fetchDetail(flounder);
      expect(result.id, flounder.id);
      expect(result.name, flounder.name);
      expect(result.scientificName, flounder.scientificName);
      expect(result.feature, '검증용 개요\n\n검증용 형태\n\n검증용 생태\n\n서식지: 검증용 서식지');
      expect(result.maxSize, '');
      expect(result.imageUrl, flounder.imageUrl);
      expect(result.photoAttribution, flounder.photoAttribution);
      expect(result.photoSourceUrl, flounder.photoSourceUrl);
      expect(result.photoLicenseUrl, flounder.photoLicenseUrl);
      expect(
        adapter.calls.single.queryParameters['SpcScitfNm'],
        flounder.scientificName,
      );
    },
  );

  test('never ranks a partial result above an exact one', () async {
    adapter.respond = (_) =>
        _response([_row(korean: '풀갈치', overview: '잘못된 설명'), _row()]);
    final result = await provider.fetchDetail(_fish);
    expect(result.feature, contains('몸은 길다.'));
    expect(result.feature, isNot(contains('잘못된 설명')));
  });

  test(
    'rejects conflicting exact records and accepts identical duplicates',
    () async {
      adapter.respond = (_) => _response([_row(), _row(overview: '상충하는 설명')]);
      await expectLater(
        provider.fetchDetail(_fish),
        _failure(FishCatalogFailure.invalidResponse),
      );
      adapter.respond = (_) => _response([_row(), _row(id: 'different-taxon')]);
      await expectLater(
        provider.fetchDetail(_fish),
        _failure(FishCatalogFailure.invalidResponse),
      );
      adapter.respond = (_) =>
          _response([_row(), _row(accepted: 'Trichiurus japonicus')]);
      await expectLater(
        provider.fetchDetail(_fish),
        _failure(FishCatalogFailure.invalidResponse),
      );
      adapter.respond = (_) => _response([_row(), _row()]);
      expect((await provider.fetchDetail(_fish)).feature, contains('몸은 길다.'));
    },
  );

  test('cleans HTML, entities and scripts without inventing maxSize', () async {
    adapter.respond = (_) => _response([
      _row(
        overview: '<p>갈치는 &nbsp; 길다.</p><script>위험한 내용</script>',
        form: '&lt;b&gt;체장 100cm&lt;/b&gt;',
        ecology: '갈치는 &#51089;&#51008; 물고기를 먹는다.',
        habitat: '',
      ),
    ]);
    final result = await provider.fetchDetail(_fish);
    expect(result.feature, '갈치는 길다.\n\n체장 100cm\n\n갈치는 작은 물고기를 먹는다.');
    expect(result.maxSize, _fish.maxSize);
  });

  test(
    'preserves explicit maximum body length and qualifiers in either phrase order',
    () async {
      final noSize = FishSpecies.fromJson({..._fish.toJson(), 'maxSize': ''});
      for (final sentence in [
        '최대 전장 50cm이다.',
        '몸길이는 최대 50cm이다.',
        '암컷의 몸길이는 최대 50.5cm이다.',
        '수컷은 최대 체장 300밀리미터이다.',
        '몸길이는 최대 1.2 m이다.',
        '최대 전장은 35센티미터에 이른다.',
      ]) {
        adapter.respond = (_) => _response([_row(form: sentence)]);
        final result = await provider.fetchDetail(noSize);
        expect(result.maxSize, sentence);
        expect(result.id, noSize.id);
        expect(result.scientificName, noSize.scientificName);
        expect(result.imageUrl, noSize.imageUrl);
        expect(result.photoAttribution, noSize.photoAttribution);
        expect(result.photoSourceUrl, noSize.photoSourceUrl);
        expect(result.photoLicenseUrl, noSize.photoLicenseUrl);
      }
    },
  );

  test(
    'keeps original provided size before an explicit FORM maximum',
    () async {
      adapter.respond = (_) => _response([_row(form: '최대 전장 50cm이다.')]);
      expect((await provider.fetchDetail(_fish)).maxSize, _fish.maxSize);
    },
  );

  test(
    'accepts ordinary body lengths without relabeling them as a maximum',
    () async {
      final noSize = FishSpecies.fromJson({..._fish.toJson(), 'maxSize': ''});
      for (final (sentence, measurement) in [
        ('몸길이는 50cm이다.', '50cm'),
        ('몸의 길이는 약 30cm에 이른다.', '30cm'),
        ('몸 길이는 5~7cm이며 모양은 방추형이다.', '5~7cm'),
        ('전장 약 40cm.', '40cm'),
        ('표준체장은 약 35cm이다.', '35cm'),
        ('가랑이체장은 약 28cm이다.', '28cm'),
      ]) {
        adapter.respond = (_) => _response([_row(form: sentence)]);
        final result = await provider.fetchDetail(noSize);
        expect(result.maxSize, contains(measurement), reason: sentence);
        expect(result.maxSize, isNot(contains('최대')), reason: sentence);
        expect(result.feature, contains(sentence));
      }
    },
  );

  test('retains sex and mixed-unit body-length ranges', () async {
    final noSize = FishSpecies.fromJson({..._fish.toJson(), 'maxSize': ''});
    adapter.respond = (_) =>
        _response([_row(form: '수컷의 전장은 약 10cm로 보고되어 있다.')]);
    final male = await provider.fetchDetail(noSize);
    expect(male.maxSize, contains('수컷'));
    expect(male.maxSize, contains('10cm'));
    expect(male.maxSize, isNot(contains('최대')));

    adapter.respond = (_) =>
        _response([_row(form: '몸길이가 50cm에서 1m에 이르며 무게가 5~8kg에 이르는 대형 어종이다.')]);
    final range = await provider.fetchDetail(noSize);
    expect(range.maxSize, contains('50cm'));
    expect(range.maxSize, contains('1m'));
    expect(range.maxSize, isNot(contains('최대')));
    expect(range.maxSize, isNot(contains('5~8kg')));
  });

  test(
    'extracts body length independently of depth and weight clauses',
    () async {
      final noSize = FishSpecies.fromJson({..._fish.toJson(), 'maxSize': ''});
      for (final sentence in [
        '수심은 최대 50m이고 몸길이는 20cm이다.',
        '최대 몸무게는 50kg이며 몸길이는 20cm이다.',
      ]) {
        adapter.respond = (_) => _response([_row(form: sentence)]);
        final result = await provider.fetchDetail(noSize);
        expect(result.maxSize, contains('20cm'), reason: sentence);
        expect(result.maxSize, isNot(contains('50m')), reason: sentence);
        expect(result.maxSize, isNot(contains('50kg')), reason: sentence);
        expect(result.maxSize, isNot(contains('최대')), reason: sentence);
      }
    },
  );

  test(
    'extracts verified size from long FORM prose and multiple sentences',
    () async {
      final noSize = FishSpecies.fromJson({..._fish.toJson(), 'maxSize': ''});
      final prose =
          '${'몸은 은빛이고 옆으로 납작하다. ' * 30}'
          '수컷의 최대 전장은 약 10cm로 보고되어 있다. '
          '서식 수심은 18~105m이다.';
      adapter.respond = (_) => _response([_row(form: prose)]);
      final result = await provider.fetchDetail(noSize);
      expect(result.maxSize, contains('수컷'));
      expect(result.maxSize, contains('최대'));
      expect(result.maxSize, contains('10cm'));
      expect(result.maxSize, isNot(contains('105m')));
      expect(result.feature, contains('몸은 은빛이고 옆으로 납작하다.'));
    },
  );

  test(
    'rejects depth-only weight-only fin negated and incomplete size prose',
    () async {
      final noSize = FishSpecies.fromJson({..._fish.toJson(), 'maxSize': ''});
      for (final sentence in [
        '수심은 최대 50m이다.',
        '최대 몸무게는 50kg이다.',
        '등지느러미 길이는 3cm이다.',
        '꼬리지느러미 길이는 최대 12cm이다.',
        '몸길이는 최대 -50cm이다.',
        '몸길이는 최대 0cm이다.',
        '몸길이는 최대 50이다.',
        '최대 전장 50cm가 아니다.',
        '먹이인 작은 물고기의 몸길이는 5cm이다.',
        '최대 수명은 8년이다.',
        '최대 5만마리까지 무리지어 다닌다.',
      ]) {
        adapter.respond = (_) => _response([_row(form: sentence)]);
        expect(
          (await provider.fetchDetail(noSize)).maxSize,
          '',
          reason: sentence,
        );
      }
    },
  );

  test(
    'uses verified overview and ecology body length as size sources',
    () async {
      final noSize = FishSpecies.fromJson({..._fish.toJson(), 'maxSize': ''});
      adapter.respond = (_) => _response([
        _row(
          overview: '최대 전장 50cm이다.',
          form: '몸은 은빛이다.',
          ecology: '작은 물고기를 먹는다.',
        ),
      ]);
      expect((await provider.fetchDetail(noSize)).maxSize, '최대 전장 50cm이다.');
      adapter.respond = (_) => _response([
        _row(overview: '몸은 길다.', form: '몸은 은빛이다.', ecology: '몸길이는 약 60cm이다.'),
      ]);
      final ecology = await provider.fetchDetail(noSize);
      expect(ecology.maxSize, contains('60cm'));
      expect(ecology.maxSize, isNot(contains('최대')));
    },
  );

  test('permits partial Korean descriptions and deduplicates fields', () async {
    adapter.respond = (_) => _response([
      _row(overview: '', form: '은빛이다.', ecology: '은빛이다.', habitat: ''),
    ]);
    expect((await provider.fetchDetail(_fish)).feature, '은빛이다.');
    adapter.respond = (_) => _response([
      _row(overview: '', form: '', ecology: '', habitat: '연안 바다'),
    ]);
    expect((await provider.fetchDetail(_fish)).feature, '서식지: 연안 바다');
  });

  test('empty results and descriptions produce noData', () async {
    adapter.respond = (_) => _response([]);
    await expectLater(
      provider.fetchDetail(_fish),
      _failure(FishCatalogFailure.noData),
    );
    adapter.respond = (_) =>
        _response([_row(overview: '', form: '', ecology: '', habitat: '')]);
    await expectLater(
      provider.fetchDetail(_fish),
      _failure(FishCatalogFailure.noData),
    );
    adapter.respond = (_) => _response([
      _row(overview: 'English only', form: '', ecology: '', habitat: ''),
    ]);
    await expectLater(
      provider.fetchDetail(_fish),
      _failure(FishCatalogFailure.noData),
    );
  });

  test(
    'searches all advertised pages before selecting an exact result',
    () async {
      adapter.respond = (options) {
        final page = options.queryParameters['pageNo'] as int;
        return _response(
          [page == 1 ? _row(korean: '풀갈치') : _row()],
          page: page,
          pageSize: 1,
          total: 2,
        );
      };
      expect((await provider.fetchDetail(_fish)).feature, contains('몸은 길다.'));
      expect(adapter.calls, hasLength(2));
    },
  );

  test(
    'incomplete pagination is invalidResponse even after an exact match',
    () async {
      adapter.respond = (options) => _response(
        [_row()],
        page: options.queryParameters['pageNo'] as int,
        pageSize: 1,
        total: 4,
      );
      await expectLater(
        provider.fetchDetail(_fish),
        _failure(FishCatalogFailure.invalidResponse),
      );
      expect(adapter.calls, hasLength(3));
    },
  );

  test('rejects ignored pages, truncated rows and changing totals', () async {
    for (final mode in ['page', 'rows', 'total']) {
      adapter.respond = (options) {
        final page = options.queryParameters['pageNo'] as int;
        return _response(
          mode == 'rows' ? [] : [_row()],
          page: mode == 'page' ? 1 : page,
          pageSize: 1,
          total: mode == 'total' && page == 2 ? 3 : 2,
        );
      };
      await expectLater(
        provider.fetchDetail(_fish),
        _failure(FishCatalogFailure.invalidResponse),
      );
    }
  });

  test(
    'rejects a changing page size before accepting an incomplete search',
    () async {
      adapter.respond = (options) {
        final page = options.queryParameters['pageNo'] as int;
        return _response(
          page == 1 ? [_row(), _row()] : [_row()],
          page: page,
          pageSize: page == 1 ? 2 : 1,
          total: 3,
        );
      };
      await expectLater(
        provider.fetchDetail(_fish),
        _failure(FishCatalogFailure.invalidResponse),
      );
    },
  );

  test('maps documented HTTP 200 result and gateway failures', () async {
    final reasons = {
      '20': FishCatalogFailure.unauthorized,
      '29': FishCatalogFailure.unauthorized,
      '30': FishCatalogFailure.unauthorized,
      '31': FishCatalogFailure.unauthorized,
      '22': FishCatalogFailure.rateLimited,
      '23': FishCatalogFailure.rateLimited,
      '05': FishCatalogFailure.timedOut,
      '01': FishCatalogFailure.network,
      '04': FishCatalogFailure.network,
      '10': FishCatalogFailure.invalidResponse,
      '99': FishCatalogFailure.invalidResponse,
    };
    for (final entry in reasons.entries) {
      adapter.respond = (_) => _response([], code: entry.key);
      await expectLater(provider.fetchDetail(_fish), _failure(entry.value));
      adapter.respond = (_) =>
          '<OpenAPI_ServiceResponse><cmmMsgHeader>'
          '<returnReasonCode>${entry.key}</returnReasonCode>'
          '<returnAuthMsg>Never expose this provider text</returnAuthMsg>'
          '</cmmMsgHeader></OpenAPI_ServiceResponse>';
      await expectLater(provider.fetchDetail(_fish), _failure(entry.value));
    }
  });

  test('does not infer success from a missing or unknown ResultCode', () async {
    for (final code in ['', '0', '0000', 'SUCCESS']) {
      adapter.respond = (_) => _response([_row()], code: code);
      await expectLater(
        provider.fetchDetail(_fish),
        _failure(FishCatalogFailure.invalidResponse),
      );
    }
    adapter.respond = (_) =>
        _response([_row()]).replaceFirst('<ResultCode>00</ResultCode>', '');
    await expectLater(
      provider.fetchDetail(_fish),
      _failure(FishCatalogFailure.invalidResponse),
    );
  });

  test('maps status errors and refuses redirects', () async {
    for (final entry in {
      401: FishCatalogFailure.unauthorized,
      403: FishCatalogFailure.unauthorized,
      429: FishCatalogFailure.rateLimited,
      302: FishCatalogFailure.network,
      500: FishCatalogFailure.network,
    }.entries) {
      adapter.status = entry.key;
      await expectLater(provider.fetchDetail(_fish), _failure(entry.value));
    }
  });

  test(
    'rejects malformed XML, DTDs, missing pagination and duplicate fields',
    () async {
      for (final text in [
        '<response>',
        '{"response": {}}',
        '<!DOCTYPE response [<!ENTITY x SYSTEM "file:///private">]><response/>',
        _response([_row()]).replaceFirst('<totalCount>1</totalCount>', ''),
        _response([_row()]).replaceFirst('<ABST>', '<ABST>x</ABST><ABST>'),
        _response([
          _row(),
        ]).replaceFirst('<pageNo>1</pageNo>', '<pageNo>-1</pageNo>'),
      ]) {
        adapter.respond = (_) => text;
        await expectLater(
          provider.fetchDetail(_fish),
          _failure(FishCatalogFailure.invalidResponse),
        );
      }
    },
  );

  test('bounds streamed response bytes', () async {
    adapter.respond = (_) => 'x' * (2 * 1024 * 1024 + 1);
    await expectLater(
      provider.fetchDetail(_fish),
      _failure(FishCatalogFailure.invalidResponse),
    );
    await adapter.cancelled.future.timeout(const Duration(seconds: 1));
  });

  test('whole lookup deadline cancels a stalled request', () async {
    provider = MbrisFishDetailProvider(
      dio: dio,
      serviceKey: 'test',
    ).withDeadline(const Duration(milliseconds: 20));
    final pending = Completer<String>();
    adapter.respond = (_) => pending.future;
    await expectLater(
      provider.fetchDetail(_fish),
      _failure(FishCatalogFailure.timedOut),
    );
    await adapter.cancelled.future;
    pending.complete(_response([_row()]));
  });

  test('Dio failures expose only sanitized catalog reasons', () async {
    adapter.respond = (options) => throw DioException(
      requestOptions: options,
      type: DioExceptionType.connectionError,
      message: 'request contains serviceKey=test+/key==',
    );
    try {
      await provider.fetchDetail(_fish);
      fail('Expected a catalog failure');
    } on FishCatalogException catch (error) {
      expect(error.reason, FishCatalogFailure.network);
      expect(error.toString(), 'FishCatalogException(network)');
    }
  });
}

String _row({
  String scientific = 'Trichiurus lepturus',
  String? shortScientific,
  String korean = '갈치',
  String accepted = 'Trichiurus lepturus',
  String id = '123',
  String overview = '몸은 길다.',
  String form = '은빛이며 몸길이는 1m이다.',
  String ecology = '작은 물고기를 먹는다.',
  String habitat = '연안 바다',
}) =>
    '<item><SpcScitfNm>${_xmlText(scientific)}</SpcScitfNm>'
    '${shortScientific == null ? '' : '<SpcScitfNmShort>${_xmlText(shortScientific)}</SpcScitfNmShort>'}'
    '<CommKorNm>${_xmlText(korean)}</CommKorNm>'
    '<CorrSpcScitfNm>${_xmlText(accepted)}</CorrSpcScitfNm><SpcTxnId>${_xmlText(id)}</SpcTxnId>'
    '<ABST><![CDATA[$overview]]></ABST><FORM><![CDATA[$form]]></FORM>'
    '<ECOL><![CDATA[$ecology]]></ECOL><HABI><![CDATA[$habitat]]></HABI></item>';

// Header, pagination, taxon ID and identity fields match the signed public
// taxonlist3 flounder response verified in this session. Publisher descriptions
// are replaced with short test placeholders; no request URL or key is retained.
const _verifiedFlounderEnvelope = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<response>
  <header><ResultCode>00</ResultCode><ResultMsg>Normal Code</ResultMsg></header>
  <body>
    <items><item>
      <SpcTxnId>270000012842</SpcTxnId>
      <Family>Paralichthyidae</Family>
      <SpcScitfNm>Paralichthys olivaceus (Temminck &amp; Schlegel, 1846)</SpcScitfNm>
      <SpcScitfNmShort>Paralichthys olivaceus</SpcScitfNmShort>
      <CommKorNm>넙치</CommKorNm>
      <ABST>검증용 개요</ABST><FORM>검증용 형태</FORM><ECOL>검증용 생태</ECOL>
      <CULTIVINF/><BIOCHEMICAL/><ACTIVINFO/>
      <HABI>검증용 서식지</HABI><UTLZ/>
      <CorrNmTyp>정명</CorrNmTyp>
      <CorrSpcScitfNm>Paralichthys olivaceus (Temminck &amp; Schlegel, 1846)</CorrSpcScitfNm>
    </item></items>
    <numOfRows>20</numOfRows><pageNo>1</pageNo><totalCount>1</totalCount>
  </body>
</response>
''';

String _response(
  List<String> rows, {
  String code = '00',
  int page = 1,
  int pageSize = 20,
  int? total,
}) =>
    '<?xml version="1.0" encoding="UTF-8"?><response><header>'
    '<ResultCode>$code</ResultCode><ResultMsg>NORMAL SERVICE</ResultMsg>'
    '</header><body><items>${rows.join()}</items><numOfRows>$pageSize</numOfRows>'
    '<pageNo>$page</pageNo><totalCount>${total ?? rows.length}</totalCount>'
    '</body></response>';

Matcher _failure(FishCatalogFailure reason) => throwsA(
  isA<FishCatalogException>().having((error) => error.reason, 'reason', reason),
);

String _xmlText(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  FutureOr<String> Function(RequestOptions) respond;
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
    return ResponseBody.fromString(
      await respond(options),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/xml; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
