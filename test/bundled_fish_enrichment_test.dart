import 'dart:convert';
import 'dart:io';

import 'package:fishing_build/data/fish/bundled_fish_enrichment.dart';
import 'package:fishing_build/data/models/fish_species.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/build_fish_enrichment.dart';

const _base = FishSpecies(
  id: 'nifs:one',
  name: '검증어',
  scientificName: 'Validus testus',
  category: FishCategory.sea,
  family: '기존 분류',
  habitat: '해수',
  aliases: ['기존 별칭'],
  sourceName: '국립수산과학원',
  sourceUrl: 'https://www.nifs.go.kr/openApi/actionOpenapiInfoList.do',
);
const _wikiCredit =
    '한국어 위키백과 기여자 · CC BY-SA 4.0 · '
    'https://creativecommons.org/licenses/by-sa/4.0/';
const _mbris = 'https://www.data.go.kr/data/15094770/openapi.do';
const _checked = '2026-11-05T03:00:00.000Z';

void main() {
  test(
    'empty enrichment has no freshness and leaves existing fields intact',
    () {
      const enrichment = BundledFishEnrichment.empty();
      expect(enrichment.length, 0);
      expect(enrichment.dataUpdatedAt, isNull);
      expect(enrichment.checkedAtFor(_base), isNull);
      expect(enrichment.hasCompleteProfileFor(_base), isFalse);
      expect(enrichment.apply(_base), same(_base));
    },
  );

  test(
    'fills verified fields atomically and retains catalog identity and classification',
    () {
      final enrichment = BundledFishEnrichment.fromJson(
        _asset([_entry(_complete())]),
      );
      final fish = enrichment.apply(_base);
      expect(enrichment.length, 1);
      expect(enrichment.dataUpdatedAt, DateTime.parse(_checked));
      expect(enrichment.checkedAtFor(_base), DateTime.parse(_checked));
      expect(enrichment.hasCompleteProfileFor(_base), isTrue);
      expect(fish.id, _base.id);
      expect(fish.name, _base.name);
      expect(fish.scientificName, _base.scientificName);
      expect(fish.category, _base.category);
      expect(fish.family, _base.family);
      expect(fish.aliases, _base.aliases);
      expect(fish.feature, '몸길이는 약 30cm이다.');
      expect(fish.maxSize, contains('30cm'));
      expect(fish.descriptionSourceUrl, _mbris);
      expect(fish.descriptionAttribution, '국립해양생물자원관 MBRIS');
      expect(
        fish.imageUrl,
        'https://upload.wikimedia.org/wikipedia/commons/a/ab/Validus_testus.jpg',
      );
      expect(
        fish.photoSourceUrl,
        'https://commons.wikimedia.org/wiki/File:Validus_testus.jpg',
      );
      expect(fish.photoAttribution, 'Test photographer · CC BY 4.0');
      expect(
        fish.photoLicenseUrl,
        'https://creativecommons.org/licenses/by/4.0/',
      );
      expect(fish.sourceUrl, _base.sourceUrl);
      expect(fish.detailNeedsRetry, isFalse);
    },
  );

  test('never matches a changed id common name or scientific name', () {
    final enrichment = BundledFishEnrichment.fromJson(
      _asset([_entry(_complete())]),
    );
    for (final patch in [
      {'id': 'another'},
      {'name': '다른 어종'},
      {'scientificName': 'Validus alius'},
    ]) {
      final base = FishSpecies.fromJson({..._base.toJson(), ...patch});
      expect(enrichment.apply(base).feature, isEmpty);
      expect(enrichment.apply(base).imageUrl, isNull);
      expect(enrichment.hasCompleteProfileFor(base), isFalse);
      expect(enrichment.checkedAtFor(base), isNull);
    }
  });

  test('preserves already verified live fields and transient state', () {
    final enrichment = BundledFishEnrichment.fromJson(
      _asset([_entry(_complete())]),
    );
    final live = FishSpecies.fromJson({
      ..._base.toJson(),
      'feature': '기존에 확인된 최신 설명',
      'maxSize': '기존 크기',
      'habitat': '기존에 확인된 암초 서식지',
      'descriptionSourceUrl': 'https://ko.wikipedia.org/wiki/Existing',
      'descriptionAttribution': _wikiCredit,
      'imageUrl':
          'https://upload.wikimedia.org/wikipedia/commons/b/bb/Existing.jpg',
      'photoSourceUrl': 'https://commons.wikimedia.org/wiki/File:Existing.jpg',
      'photoAttribution': 'Existing photographer · CC BY-SA 4.0',
      'photoLicenseUrl': 'https://creativecommons.org/licenses/by-sa/4.0/',
      'detailNeedsRetry': true,
    });
    expect(enrichment.apply(live).toJson(), live.toJson());
  });

  test(
    'invalid photo rights do not discard a separately verified description',
    () {
      final enrichment = BundledFishEnrichment.fromJson(
        _asset([
          _entry({
            ..._complete(),
            'photoLicenseUrl':
                'https://creativecommons.org/licenses/by-nc/4.0/',
          }),
        ]),
      );
      final fish = enrichment.apply(_base);
      expect(fish.feature, isNotEmpty);
      expect(fish.imageUrl, isNull);
      expect(fish.photoAttribution, isNull);
      expect(fish.photoLicenseUrl, isNull);
      expect(enrichment.hasCompleteProfileFor(_base), isFalse);
    },
  );

  test(
    'unsafe unsupported and non-photographic files never become bundled photos',
    () {
      for (final patch in [
        {'imageUrl': 'http://upload.wikimedia.org/Validus.jpg'},
        {'imageUrl': 'https://upload.wikimedia.org.evil.test/Validus.jpg'},
        {'imageUrl': 'https://user:secret@upload.wikimedia.org/Validus.jpg'},
        {
          'photoSourceUrl':
              'https://commons.wikimedia.org/w/api.php?token=private',
        },
        {
          'photoSourceUrl':
              'https://commons.wikimedia.org/wiki/File:Fish_water_colour.jpg',
        },
        {'photoAttribution': 'Unknown'},
        {'photoAttribution': ' · CC BY-SA 4.0'},
        {'photoAttribution': 'CC BY-SA 4.0'},
        {'photoAttribution': 'Test photographer · CC BY-NC 4.0'},
        {'photoLicenseUrl': 'https://creativecommons.org/licenses/by-nd/4.0/'},
        {
          'photoLicenseUrl':
              'https://creativecommons.org.evil.test/licenses/by/4.0/',
        },
      ]) {
        final enrichment = BundledFishEnrichment.fromJson(
          _asset([
            _entry({..._photo(), ...patch}),
          ]),
        );
        expect(
          enrichment.apply(_base).imageUrl,
          isNull,
          reason: patch.keys.join(','),
        );
        expect(enrichment.length, 0);
      }
    },
  );

  test(
    'accepts only scoped official NIFS photos with a verified KOGL1 claim',
    () {
      final photo = {
        ..._photo(),
        'imageUrl':
            'https://www.nifs.go.kr/cmmn/images/MF00043931_watermark_2.png',
        'photoSourceUrl':
            'https://www.nifs.go.kr/contents/actionContentsCons0088.do',
        'photoLicenseUrl':
            'https://www.nifs.go.kr/contents/actionContentsCons0001.do',
        'photoAttribution': '국립수산과학원 · 공공누리 제1유형(출처표시)',
      };
      expect(
        BundledFishEnrichment.fromJson(
          _asset([_entry(photo)]),
        ).apply(_base).imageUrl,
        photo['imageUrl'],
      );
      for (final patch in [
        {'photoAttribution': '국립수산과학원 · 공공누리 제2유형'},
        {'photoAttribution': '국립수산과학원'},
        {'photoSourceUrl': 'https://www.nifs.go.kr/contents/another.do'},
        {'photoLicenseUrl': 'https://www.nifs.go.kr/copyright'},
        {'imageUrl': 'https://www.nifs.go.kr/cmmn/images/110009.jpg'},
        {
          'imageUrl':
              'https://www.nifs.go.kr.evil.test/cmmn/images/MF00043931.png',
        },
        {
          'imageUrl':
              'https://www.nifs.go.kr/cmmn/images/MF00043931.png?key=private',
        },
      ]) {
        expect(
          BundledFishEnrichment.fromJson(
            _asset([
              _entry({...photo, ...patch}),
            ]),
          ).apply(_base).imageUrl,
          isNull,
        );
      }
    },
  );

  test('supports licensed iNaturalist photographs with a matching photo id', () {
    final photo = {
      ..._photo(),
      'imageUrl':
          'https://inaturalist-open-data.s3.amazonaws.com/photos/45/medium.jpg',
      'photoSourceUrl': 'https://www.inaturalist.org/photos/45',
      'photoAttribution': 'Photographer · CC BY-SA 4.0',
      'photoLicenseUrl': 'https://creativecommons.org/licenses/by-sa/4.0/',
    };
    expect(
      BundledFishEnrichment.fromJson(
        _asset([_entry(photo)]),
      ).apply(_base).imageUrl,
      contains('/45/'),
    );
    final mismatch = {
      ...photo,
      'photoSourceUrl': 'https://www.inaturalist.org/photos/46',
    };
    expect(
      BundledFishEnrichment.fromJson(
        _asset([_entry(mismatch)]),
      ).apply(_base).imageUrl,
      isNull,
    );
  });

  test(
    'allows reviewed pinned Wiki translations including Wikisource only with rights',
    () {
      for (final host in [
        'en.wikipedia.org',
        'ko.wikipedia.org',
        'ko.wikisource.org',
      ]) {
        final record = {
          ..._description(),
          'descriptionSourceUrl':
              'https://$host/w/index.php?title=Verified&oldid=123',
          'descriptionAttribution': _wikiCredit,
        };
        final enrichment = BundledFishEnrichment.fromJson(
          _asset([_entry(record)]),
        );
        expect(enrichment.apply(_base).feature, isNotEmpty, reason: host);
      }
      for (final source in [
        'https://ko.wikisource.org/wiki/Unpinned',
        'https://ko.wikipedia.org/w/api.php?action=query',
        'https://ko.wikipedia.org/w/index.php?title=Verified&oldid=123&serviceKey=private',
      ]) {
        final enrichment = BundledFishEnrichment.fromJson(
          _asset([
            _entry({
              ..._description(),
              'descriptionSourceUrl': source,
              'descriptionAttribution': _wikiCredit,
            }),
          ]),
        );
        expect(enrichment.apply(_base).feature, isEmpty);
      }
    },
  );

  test(
    'replaces only generic habitats with explicit verified HABI provenance',
    () {
      final record = _entry({
        ..._description(),
        'habitat': '수심이 얕고 모래가 있는 연안에 서식한다.',
      });
      record['habitatProvenance'] = _habitatProvenance;
      final enrichment = BundledFishEnrichment.fromJson(_asset([record]));
      for (final habitat in ['', '해수', '육상 담수', '민물']) {
        final fish = enrichment.apply(
          FishSpecies.fromJson({..._base.toJson(), 'habitat': habitat}),
        );
        expect(fish.habitat, contains('모래'));
        expect(fish.category, _base.category);
      }
      final detailed = FishSpecies.fromJson({
        ..._base.toJson(),
        'habitat': '기존 암초 서식지',
      });
      expect(enrichment.apply(detailed).habitat, detailed.habitat);
      record.remove('habitatProvenance');
      expect(
        BundledFishEnrichment.fromJson(_asset([record])).apply(_base).habitat,
        _base.habitat,
      );
    },
  );

  test(
    'reviewed habitat uses the same licensed description including pinned sections',
    () {
      const source =
          'https://ko.wikisource.org/w/index.php?title=Verified&oldid=123#Fish';
      final record = _entry({
        ..._description(),
        'descriptionSourceUrl': source,
        'descriptionAttribution': _wikiCredit,
        'habitat': '유속이 느린 강과 호수의 바닥에서 산다.',
      });
      record['habitatProvenance'] = {
        'field': 'reviewedDescription',
        'sourceUrl': source,
        'attribution': _wikiCredit,
      };
      final enrichment = BundledFishEnrichment.fromJson(_asset([record]));
      final fish = enrichment.apply(_base);
      expect(fish.feature, isNotEmpty);
      expect(fish.habitat, contains('호수'));
      expect(fish.sourceName, isNot(contains('MBRIS')));
      record['habitatProvenance'] = {
        'field': 'reviewedDescription',
        'sourceUrl': 'https://ko.wikipedia.org/wiki/Other',
        'attribution': _wikiCredit,
      };
      final rejected = BundledFishEnrichment.fromJson(_asset([record]));
      expect(rejected.apply(_base).habitat, _base.habitat);
      expect(rejected.apply(_base).feature, isNotEmpty);
    },
  );

  test(
    'does not invent size from unsupported prose or a standalone report size',
    () {
      final unsupported = {
        ..._base.toJson(),
        'feature': '몸길이는 최대 999cm이다.',
        'maxSize': '최대 999cm',
        'descriptionSourceUrl': 'https://example.org/private',
        'descriptionAttribution': 'unverified',
      };
      final fish = BundledFishEnrichment.fromJson(
        _asset([_entry(unsupported)]),
      ).apply(_base);
      expect(fish.feature, isEmpty);
      expect(fish.maxSize, isEmpty);
      final verified = {..._description(), 'maxSize': '검증되지 않은 999cm'};
      expect(
        BundledFishEnrichment.fromJson(
          _asset([_entry(verified)]),
        ).apply(_base).maxSize,
        isNot(contains('999')),
      );
    },
  );

  test(
    'retains separately licensed size evidence without replacing richer prose',
    () {
      final row = _entry({
        ..._description(),
        'feature': '몸이 길고 은빛을 띤다.',
        'maxSize': '',
      });
      row['sizeProvenance'] = {
        'text': '수컷의 최대 전장은 약 30cm이다.',
        'sourceUrl': 'https://ko.wikipedia.org/wiki/Verified',
        'attribution': _wikiCredit,
      };
      final fish = BundledFishEnrichment.fromJson(_asset([row])).apply(_base);
      expect(fish.feature, '몸이 길고 은빛을 띤다.');
      expect(fish.maxSize, '수컷의 최대 전장은 약 30cm이다.');
      row['sizeProvenance'] = {
        'text': '수컷의 최대 전장은 약 30cm이다.',
        'sourceUrl': 'https://unverified.example/fish',
        'attribution': _wikiCredit,
      };
      expect(
        BundledFishEnrichment.fromJson(_asset([row])).apply(_base).maxSize,
        isEmpty,
      );
    },
  );

  test('rejects unknown schemas duplicates bad dates and response bounds', () {
    final one = _entry(_complete());
    for (final asset in [
      {
        ..._asset([one]),
        'version': 2,
      },
      {
        ..._asset([one]),
        'secretConfig': 'private',
      },
      {
        ..._asset([one]),
        'recordCount': 2,
      },
      _asset([one, one]),
      _asset([
        {...one, 'checkedAt': '2027-01-01T00:00:00Z'},
      ]),
      _asset([
        {
          ...one,
          'result': {..._complete(), 'serviceKey': 'private'},
        },
      ]),
      _asset([
        _entry({..._complete(), 'feature': '가' * 12001}),
      ]),
      _asset(List.generate(801, (_) => one)),
    ]) {
      expect(
        () => BundledFishEnrichment.fromJson(asset),
        throwsFormatException,
      );
    }
  });

  group('public report builder', () {
    late Directory directory;
    late String catalogPath;
    late String outputPath;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'fish-enrichment-test-',
      );
      catalogPath = '${directory.path}/catalog.json';
      outputPath = '${directory.path}/enrichment.json';
      await File(catalogPath).writeAsString(
        jsonEncode({
          'version': 1,
          'recordCount': 1,
          'species': [_base.toJson()],
        }),
      );
    });
    tearDown(() async => directory.delete(recursive: true));

    test(
      'merges public fields with MBRIS prose priority and first verified photo',
      () async {
        final wiki = {
          ..._complete(),
          'descriptionSourceUrl': 'https://ko.wikipedia.org/wiki/Verified',
          'descriptionAttribution': _wikiCredit,
        };
        final mbris = {
          ..._complete(),
          'feature': '몸길이는 약 40cm이다.',
          'imageUrl':
              'https://upload.wikimedia.org/wikipedia/commons/b/bb/Second.jpg',
          'photoSourceUrl':
              'https://commons.wikimedia.org/wiki/File:Second.jpg',
          'habitat': '모래와 진흙이 섞인 바닥에 산다.',
          'sourceUrl':
              'https://apis.data.go.kr/private?serviceKey=private-test-value',
          'sourceName': 'private-test-value',
        };
        final older = '2026-11-03T00:00:00.000Z';
        final newer = '2026-11-06T00:00:00.000Z';
        final first = await _writeReport(directory, 'first', [
          _reportRow(wiki, checkedAt: older),
        ]);
        final secondRow = _reportRow(mbris, checkedAt: newer);
        secondRow['habitatProvenance'] = {
          ..._habitatProvenance,
          'sourceUrl': '$_mbris?format=html',
          'evidence': 'collector-only evidence',
        };
        final second = await _writeReport(directory, 'second', [secondRow]);
        final output = await buildFishEnrichment(
          reportPaths: [first, second],
          catalogPath: catalogPath,
          outputPath: outputPath,
        );
        final enrichment = BundledFishEnrichment.fromJson(output);
        final fish = enrichment.apply(_base);
        expect(fish.feature, '몸길이는 약 40cm이다.');
        expect(fish.maxSize, contains('40cm'));
        expect(fish.descriptionAttribution, '국립해양생물자원관 MBRIS');
        expect(fish.imageUrl, _complete()['imageUrl']);
        expect(fish.photoAttribution, _complete()['photoAttribution']);
        expect(fish.habitat, contains('진흙'));
        expect(enrichment.dataUpdatedAt, DateTime.parse(newer));
        expect(enrichment.checkedAtFor(_base), DateTime.parse(older));
        final serialized = await File(outputPath).readAsString();
        expect(serialized, isNot(contains('private-test-value')));
        expect(serialized, isNot(contains('serviceKey')));
        expect(serialized, isNot(contains('collector-only evidence')));
        expect((jsonDecode(serialized) as Map)['recordCount'], 1);
      },
    );

    test(
      'richer MBRIS prose preserves independently verified Wiki size',
      () async {
        final wiki = await _writeReport(directory, 'wiki-size', [
          _reportRow({
            ..._description(),
            'feature': '몸길이는 약 30cm이다.',
            'descriptionSourceUrl': 'https://ko.wikipedia.org/wiki/Verified',
            'descriptionAttribution': _wikiCredit,
          }),
        ]);
        final mbris = await _writeReport(directory, 'mbris-prose', [
          _reportRow({..._description(), 'feature': '몸이 길고 은빛을 띤다.'}),
        ]);
        final output = await buildFishEnrichment(
          reportPaths: [wiki, mbris],
          catalogPath: catalogPath,
          outputPath: outputPath,
        );
        final fish = BundledFishEnrichment.fromJson(output).apply(_base);
        expect(fish.feature, '몸이 길고 은빛을 띤다.');
        expect(fish.maxSize, '몸길이는 약 30cm이다.');
        final proof =
            ((output['records'] as List).single as Map)['sizeProvenance']
                as Map;
        expect(proof['sourceUrl'], 'https://ko.wikipedia.org/wiki/Verified');
        expect(proof['attribution'], _wikiCredit);
      },
    );

    test(
      'partial photo results survive independently of unavailable descriptions',
      () async {
        final report = await _writeReport(directory, 'partial', [
          {..._reportRow(_photo()), 'outcome': 'partial'},
        ]);
        final output = await buildFishEnrichment(
          reportPaths: [report],
          catalogPath: catalogPath,
          outputPath: outputPath,
        );
        final fish = BundledFishEnrichment.fromJson(output).apply(_base);
        expect(fish.imageUrl, isNotNull);
        expect(fish.feature, isEmpty);
      },
    );

    test(
      'description precedence never detaches reviewed habitat attribution',
      () async {
        final row = _reportRow({
          ..._description(),
          'descriptionSourceUrl': 'https://ko.wikipedia.org/wiki/Verified',
          'descriptionAttribution': _wikiCredit,
          'habitat': '강의 돌 바닥에서 산다.',
        });
        row['habitatProvenance'] = {
          'field': 'reviewedDescription',
          'sourceUrl': 'https://ko.wikipedia.org/wiki/Verified',
          'attribution': _wikiCredit,
        };
        final first = await _writeReport(directory, 'reviewed', [row]);
        final second = await _writeReport(directory, 'mbris', [
          _reportRow(_description()),
        ]);
        final output = await buildFishEnrichment(
          reportPaths: [first, second],
          catalogPath: catalogPath,
          outputPath: outputPath,
        );
        final fish = BundledFishEnrichment.fromJson(output).apply(_base);
        expect(fish.descriptionSourceUrl, _mbris);
        expect(fish.habitat, _base.habitat);
        expect(
          (output['records'] as List).single,
          isNot(contains('habitatProvenance')),
        );
      },
    );

    test(
      'failure and noData never overwrite known fields or produce an empty asset',
      () async {
        final valid = await _writeReport(directory, 'valid', [
          _reportRow(_complete()),
        ]);
        final failures = await _writeReport(directory, 'failures', [
          {..._reportRow(_complete()), 'outcome': 'noData'},
          {..._reportRow(_complete()), 'outcome': 'failure'},
          {..._reportRow(_complete()), 'outcome': 'notChecked'},
        ]);
        final output = await buildFishEnrichment(
          reportPaths: [valid, failures],
          catalogPath: catalogPath,
          outputPath: outputPath,
        );
        expect(BundledFishEnrichment.fromJson(output).length, 1);
        final saved = await File(outputPath).readAsString();
        await expectLater(
          buildFishEnrichment(
            reportPaths: [failures],
            catalogPath: catalogPath,
            outputPath: outputPath,
          ),
          throwsFormatException,
        );
        expect(await File(outputPath).readAsString(), saved);
        expect(
          directory.listSync().where((item) => item.path.endsWith('.tmp')),
          isEmpty,
        );
      },
    );

    test(
      'identity mismatch aborts before replacing a useful existing output',
      () async {
        await File(outputPath).writeAsString('existing output');
        final report = await _writeReport(directory, 'mismatch', [
          _reportRow({..._complete(), 'scientificName': 'Validus alius'}),
        ]);
        await expectLater(
          buildFishEnrichment(
            reportPaths: [report],
            catalogPath: catalogPath,
            outputPath: outputPath,
          ),
          throwsFormatException,
        );
        expect(await File(outputPath).readAsString(), 'existing output');
      },
    );
  });
}

Map<String, Object?> _description() => {
  ..._base.toJson(),
  'feature': '몸길이는 약 30cm이다.',
  'descriptionSourceUrl': _mbris,
  'descriptionAttribution': '국립해양생물자원관 MBRIS',
};
Map<String, Object?> _photo() => {
  ..._base.toJson(),
  'imageUrl':
      'https://upload.wikimedia.org/wikipedia/commons/a/ab/Validus_testus.jpg',
  'photoSourceUrl':
      'https://commons.wikimedia.org/wiki/File:Validus_testus.jpg',
  'photoAttribution': 'Test photographer · CC BY 4.0',
  'photoLicenseUrl': 'https://creativecommons.org/licenses/by/4.0/',
};
Map<String, Object?> _complete() => {
  ..._photo(),
  ..._description(),
  'imageUrl': _photo()['imageUrl'],
  'photoSourceUrl': _photo()['photoSourceUrl'],
  'photoAttribution': _photo()['photoAttribution'],
  'photoLicenseUrl': _photo()['photoLicenseUrl'],
};
const _habitatProvenance = {
  'field': 'HABI',
  'sourceUrl': _mbris,
  'attribution': '국립해양생물자원관 MBRIS',
};
Map<String, Object?> _entry(Map<String, Object?> result) => {
  'checkedAt': _checked,
  'result': result,
};
Map<String, dynamic> _asset(List<Map<String, Object?>> records) => {
  'version': 1,
  'recordCount': records.length,
  'dataUpdatedAt': _checked,
  'records': records,
};
Map<String, Object?> _reportRow(
  Map<String, Object?> result, {
  String checkedAt = _checked,
}) => {
  'id': _base.id,
  'name': _base.name,
  'scientificName': _base.scientificName,
  'outcome': 'success',
  'checkedAt': checkedAt,
  'result': result,
};
Future<String> _writeReport(
  Directory directory,
  String name,
  List<Map<String, Object?>> rows,
) async {
  final file = File('${directory.path}/$name.json');
  await file.writeAsString(jsonEncode({'version': 1, 'records': rows}));
  return file.path;
}
