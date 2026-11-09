import 'dart:convert';
import 'dart:io';

import 'package:fishing_build/data/app_info/fish_attribution_repository.dart';
import 'package:fishing_build/data/fish/fish_catalog_service.dart';
import 'package:fishing_build/data/fish/fish_size_summary.dart';
import 'package:fishing_build/data/models/fish_species.dart';
import 'package:fishing_build/data/repositories/fish_species_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _mbris = 'https://www.data.go.kr/data/15094770/openapi.do';
const _wiki = 'https://en.wikipedia.org/w/index.php?title=Test_fish&oldid=42';
const _wikiCredit =
    '영어 위키백과 기여자 · 한국어 번역·요약 · CC BY-SA 4.0 · '
    'https://creativecommons.org/licenses/by-sa/4.0/';
const _base = FishSpecies(
  id: 'nifs:one',
  name: '검증어',
  scientificName: 'Validus testus',
  habitat: '해수',
  sourceName: '국립수산과학원',
  sourceUrl: 'https://www.nifs.go.kr/openApi/actionOpenapiInfoList.do',
);
const _enriched = FishSpecies(
  id: 'nifs:one',
  name: '검증어',
  scientificName: 'Validus testus',
  feature: '몸은 은백색이며 해안의 바위 지대에서 산다.',
  descriptionAttribution: '국립해양생물자원관 MBRIS',
  descriptionSourceUrl: _mbris,
  habitat: '해안의 바위 지대',
  imageUrl:
      'https://upload.wikimedia.org/wikipedia/commons/a/ab/Validus_testus.jpg',
  photoSourceUrl: 'https://commons.wikimedia.org/wiki/File:Validus_testus.jpg',
  photoLicenseUrl: 'https://creativecommons.org/licenses/by/4.0/',
  photoAttribution: 'Bundled photographer · CC BY 4.0',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'preserves independently sourced photo description habitat and size',
    () async {
      final bundle = _fixture();
      final result = await FishAttributionRepository(
        bundle: bundle,
        cachedSpecies: () async => [],
      ).load();

      expect(result.single.id, _base.id);
      expect(result.single.speciesName, _base.name);
      expect(result.single.scientificName, _base.scientificName);
      final credits = _entries(result.single);
      expect(credits.keys, containsAll(FishAttributionKind.values));
      expect(credits[FishAttributionKind.catalog]!.sourceUrl, _base.sourceUrl);
      expect(
        credits[FishAttributionKind.photo]!.attribution,
        _enriched.photoAttribution,
      );
      expect(
        credits[FishAttributionKind.photo]!.resourceUrl,
        _enriched.imageUrl,
      );
      expect(
        credits[FishAttributionKind.photo]!.licenseUrl,
        _enriched.photoLicenseUrl,
      );
      expect(credits[FishAttributionKind.description]!.sourceUrl, _mbris);
      expect(credits[FishAttributionKind.habitat]!.sourceUrl, _mbris);
      expect(credits[FishAttributionKind.habitat]!.content, _enriched.habitat);
      expect(credits[FishAttributionKind.habitat]!.notes, contains('HABI'));
      expect(credits[FishAttributionKind.size]!.sourceUrl, _wiki);
      expect(credits[FishAttributionKind.size]!.attribution, _wikiCredit);
      expect(
        credits[FishAttributionKind.size]!.licenseUrl,
        'https://creativecommons.org/licenses/by-sa/4.0/',
      );
      expect(credits[FishAttributionKind.size]!.content, contains('80cm'));
      expect(bundle.loads.keys, {
        FishAttributionRepository.catalogAssetPath,
        FishAttributionRepository.enrichmentAssetPath,
      });
    },
  );

  test(
    'cached selected photo and description retain their own credits only',
    () async {
      final cached = FishSpecies.fromJson({
        ..._enriched.toJson(),
        'feature': '새로 저장한 설명으로 몸은 붉은색이다.',
        'descriptionAttribution': _wikiCredit,
        'descriptionSourceUrl': _wiki,
        'maxSize': '몸길이는 최대 80cm이다.',
        'imageUrl': 'https://static.inaturalist.org/photos/123/large.jpg',
        'photoSourceUrl': 'https://www.inaturalist.org/photos/123',
        'photoAttribution': 'Cached photographer · CC BY-SA 4.0',
        'photoLicenseUrl': 'https://creativecommons.org/licenses/by-sa/4.0/',
      });
      final result = await FishAttributionRepository(
        bundle: _fixture(),
        cachedSpecies: () async => [cached],
      ).load();
      final credits = _entries(result.single);

      expect(
        credits[FishAttributionKind.photo]!.attribution,
        cached.photoAttribution,
      );
      expect(
        credits[FishAttributionKind.photo]!.sourceUrl,
        cached.photoSourceUrl,
      );
      expect(credits[FishAttributionKind.photo]!.resourceUrl, cached.imageUrl);
      expect(
        credits[FishAttributionKind.photo]!.licenseUrl,
        cached.photoLicenseUrl,
      );
      expect(credits[FishAttributionKind.description]!.sourceUrl, _wiki);
      expect(
        credits[FishAttributionKind.description]!.attribution,
        _wikiCredit,
      );
      expect(credits[FishAttributionKind.habitat]!.sourceUrl, _mbris);
      expect(credits[FishAttributionKind.size]!.sourceUrl, _wiki);
    },
  );

  test(
    'does not give a different cached photo the bundled author or license',
    () async {
      final cached = FishSpecies.fromJson({
        ..._base.toJson(),
        'imageUrl': 'https://static.inaturalist.org/photos/999/large.jpg',
        'photoSourceUrl': 'https://www.inaturalist.org/photos/999',
      });
      final result = await FishAttributionRepository(
        bundle: _fixture(),
        cachedSpecies: () async => [cached],
      ).load();
      final photo = _entries(result.single)[FishAttributionKind.photo]!;

      expect(photo.attribution, '저작자 정보 없음');
      expect(photo.licenseUrl, isNull);
      expect(photo.sourceUrl, cached.photoSourceUrl);
      expect(photo.resourceUrl, cached.imageUrl);
    },
  );

  test(
    'recovers bundled metadata only for exactly matching cached content',
    () async {
      final cached = FishSpecies.fromJson({
        ..._enriched.toJson(),
        'photoAttribution': null,
        'photoSourceUrl': null,
        'photoLicenseUrl': null,
        'descriptionAttribution': null,
        'descriptionSourceUrl': null,
      });
      final result = await FishAttributionRepository(
        bundle: _fixture(),
        cachedSpecies: () async => [cached],
      ).load();
      final credits = _entries(result.single);

      expect(
        credits[FishAttributionKind.photo]!.attribution,
        _enriched.photoAttribution,
      );
      expect(
        credits[FishAttributionKind.photo]!.licenseUrl,
        _enriched.photoLicenseUrl,
      );
      expect(credits[FishAttributionKind.description]!.sourceUrl, _mbris);
      expect(
        credits[FishAttributionKind.description]!.attribution,
        _enriched.descriptionAttribution,
      );
    },
  );

  test(
    'changed cached prose and derived size do not inherit the catalog source',
    () async {
      final cached = FishSpecies.fromJson({
        ..._base.toJson(),
        'feature': '새로 저장한 설명으로 몸은 붉은색이다. 몸길이는 최대 120cm이다.',
      });
      final result = await FishAttributionRepository(
        bundle: _fixture(),
        cachedSpecies: () async => [cached],
      ).load();
      final credits = _entries(result.single);

      expect(credits[FishAttributionKind.catalog]!.sourceUrl, _base.sourceUrl);
      for (final kind in [
        FishAttributionKind.description,
        FishAttributionKind.size,
      ]) {
        expect(credits[kind]!.attribution, '저작자·제공기관 정보 없음');
        expect(credits[kind]!.sourceUrl, isNull);
        expect(credits[kind]!.licenseUrl, isNull);
      }
      expect(credits[FishAttributionKind.size]!.content, contains('120cm'));
    },
  );

  test(
    'does not assign bundled habitat or size evidence to changed content',
    () async {
      final cached = FishSpecies.fromJson({
        ..._base.toJson(),
        'habitat': '외해의 모래 바닥',
        'maxSize': '몸길이는 최대 120cm이다.',
        'descriptionAttribution': _wikiCredit,
        'descriptionSourceUrl': _wiki,
      });
      final result = await FishAttributionRepository(
        bundle: _fixture(),
        cachedSpecies: () async => [cached],
      ).load();
      final credits = _entries(result.single);

      expect(credits[FishAttributionKind.habitat]!.sourceUrl, isNull);
      expect(credits[FishAttributionKind.habitat]!.content, cached.habitat);
      expect(credits[FishAttributionKind.size]!.sourceUrl, isNull);
      expect(credits[FishAttributionKind.size]!.content, cached.maxSize);
    },
  );

  test(
    'reads the cache each time and retains bundled species after cache failure',
    () async {
      final bundle = _fixture();
      var reads = 0;
      final repository = FishAttributionRepository(
        bundle: bundle,
        cachedSpecies: () async {
          reads++;
          if (reads == 1) throw StateError('Cache unavailable');
          return [
            FishSpecies.fromJson({
              ..._enriched.toJson(),
              'id': 'new:two',
              'name': '가나다어',
            }),
            FishSpecies.fromJson({..._enriched.toJson(), 'name': '다른 어종'}),
          ];
        },
      );

      expect((await repository.load()).single.speciesName, _base.name);
      final second = await repository.load();
      expect(second.map((fish) => fish.speciesName), ['가나다어', _base.name]);
      expect(reads, 2);
      expect(bundle.loads.values, everyElement(1));
      expect(() => second.add(second.first), throwsUnsupportedError);
      expect(() => second.first.entries.clear(), throwsUnsupportedError);
    },
  );

  test(
    'local repository snapshot reads disk without invoking any provider',
    () async {
      SharedPreferences.setMockInitialValues({
        'fish_encyclopedia_cache_v1': jsonEncode({
          'version': 1,
          'catalog': [_base.toJson()],
          'catalogAt': '2026-11-01T00:00:00Z',
          'details': [
            {'fish': _enriched.toJson(), 'at': '2026-11-01T00:00:00Z'},
          ],
        }),
      });
      final service = _NoNetworkService();
      final fishRepository = FishSpeciesRepository(
        service: service,
        clock: () => DateTime.utc(2026, 11, 9),
      );
      final before = (await SharedPreferences.getInstance()).getString(
        'fish_encyclopedia_cache_v1',
      );
      final result = await FishAttributionRepository(
        bundle: _fixture(),
        cachedSpecies: fishRepository.readCachedSpecies,
      ).load();

      expect(
        _entries(result.single)[FishAttributionKind.photo]!.attribution,
        _enriched.photoAttribution,
      );
      expect(service.calls, 0);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'fish_encyclopedia_cache_v1',
        ),
        before,
      );
    },
  );

  test(
    'all 800 bundled species and separately sourced size credits are readable offline',
    () async {
      final catalog =
          jsonDecode(
                File(
                  FishAttributionRepository.catalogAssetPath,
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final enrichment =
          jsonDecode(
                File(
                  FishAttributionRepository.enrichmentAssetPath,
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final bundle = _Bundle({
        FishAttributionRepository.catalogAssetPath: catalog,
        FishAttributionRepository.enrichmentAssetPath: enrichment,
      });
      final result = await FishAttributionRepository(
        bundle: bundle,
        cachedSpecies: () async => [],
      ).load();

      expect(result, hasLength(800));
      expect(result.map((fish) => fish.id).toSet(), hasLength(800));
      expect(
        result.every(
          (fish) => fish.entries.first.kind == FishAttributionKind.catalog,
        ),
        isTrue,
      );
      final independent = (enrichment['records'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere(
            (record) =>
                record['sizeProvenance'] is Map &&
                (record['sizeProvenance'] as Map)['sourceUrl'] !=
                    (record['result'] as Map)['descriptionSourceUrl'],
          );
      final rawFish = independent['result'] as Map;
      final proof = independent['sizeProvenance'] as Map;
      final fish = result.firstWhere((fish) => fish.id == rawFish['id']);
      final size = _entries(fish)[FishAttributionKind.size]!;
      expect(size.sourceUrl, proof['sourceUrl']);
      expect(size.attribution, proof['attribution']);
      expect(size.content, extractFishSizeSummary(proof['text'] as String));
      // These pinned Wikisource credits include a species section fragment.
      for (final name in ['붕어', '잉어']) {
        final record = (enrichment['records'] as List)
            .cast<Map<String, dynamic>>()
            .firstWhere((record) => (record['result'] as Map)['name'] == name);
        final proof = record['habitatProvenance'] as Map;
        final credit = _entries(
          result.firstWhere((fish) => fish.speciesName == name),
        )[FishAttributionKind.habitat]!;
        expect(Uri.parse(proof['sourceUrl'] as String).fragment, isNotEmpty);
        expect(credit.sourceUrl, proof['sourceUrl']);
        expect(credit.attribution, proof['attribution']);
        expect(
          credit.licenseUrl,
          'https://creativecommons.org/licenses/by-sa/4.0/',
        );
        expect(credit.notes, '검토한 설명에서 정리한 서식지');
      }
      expect(bundle.loads.keys, hasLength(2));
    },
  );

  test(
    'reviewed static supplemental photo and description retain credits',
    () async {
      final fish = [
        FishSpecies.fromJson({
          ..._base.toJson(),
          'id': 'nifs:photo',
          'name': '가라지',
          'scientificName': 'Decapterus maruadsi',
        }),
        FishSpecies.fromJson({
          ..._base.toJson(),
          'id': 'nifs:description',
          'name': '가는곰치',
          'scientificName': 'Strophidon sathete',
        }),
      ];
      final bundle = _Bundle({
        FishAttributionRepository.catalogAssetPath: _catalog(fish),
      });
      final result = await FishAttributionRepository(
        bundle: bundle,
        cachedSpecies: () async => [],
      ).load();

      final photo = _entries(
        result.firstWhere((entry) => entry.id == 'nifs:photo'),
      )[FishAttributionKind.photo]!;
      expect(photo.attribution, contains('re_nebel'));
      expect(photo.sourceUrl, contains('Decapterus_maruadsi.jpg'));
      expect(photo.licenseUrl, 'https://creativecommons.org/licenses/by/4.0/');
      final description = _entries(
        result.firstWhere((entry) => entry.id == 'nifs:description'),
      )[FishAttributionKind.description]!;
      expect(description.attribution, contains('한국어 번역·요약'));
      expect(description.sourceUrl, contains('oldid=1370178422'));
      expect(
        description.licenseUrl,
        'https://creativecommons.org/licenses/by-sa/4.0/',
      );
    },
  );
  test(
    'retries a failed catalog read without keeping the failed bundle future',
    () async {
      final bundle = _Bundle({FishAttributionRepository.catalogAssetPath: {}});
      final repository = FishAttributionRepository(
        bundle: bundle,
        cachedSpecies: () async => [],
      );

      await expectLater(repository.load(), throwsFormatException);
      bundle.assets[FishAttributionRepository.catalogAssetPath] = _catalog([
        _base,
      ]);
      expect((await repository.load()).single.speciesName, _base.name);
      expect(bundle.loads[FishAttributionRepository.catalogAssetPath], 2);
    },
  );
}

Map<FishAttributionKind, FishAttributionEntry> _entries(FishAttribution fish) =>
    {for (final entry in fish.entries) entry.kind: entry};

Map<String, Object?> _catalog(List<FishSpecies> fish) => {
  'version': 1,
  'recordCount': fish.length,
  'sourceName': _base.sourceName,
  'sourceUrl': _base.sourceUrl,
  'dataUpdatedAt': '2026-11-04T00:00:00Z',
  'species': fish.map((entry) => entry.toJson()).toList(),
};

_Bundle _fixture() => _Bundle({
  FishAttributionRepository.catalogAssetPath: _catalog([_base]),
  FishAttributionRepository.enrichmentAssetPath: {
    'version': 1,
    'recordCount': 1,
    'dataUpdatedAt': '2026-11-06T00:00:00Z',
    'records': [
      {
        'checkedAt': '2026-11-05T00:00:00Z',
        'result': _enriched.toJson(),
        'habitatProvenance': {
          'field': 'HABI',
          'sourceUrl': _mbris,
          'attribution': '국립해양생물자원관 MBRIS',
        },
        'sizeProvenance': {
          'text': '몸길이는 최대 80cm이다.',
          'sourceUrl': _wiki,
          'attribution': _wikiCredit,
        },
      },
    ],
  },
});

class _Bundle extends CachingAssetBundle {
  _Bundle(this.assets);
  final Map<String, Object?> assets;
  final loads = <String, int>{};

  @override
  Future<ByteData> load(String key) async {
    loads.update(key, (count) => count + 1, ifAbsent: () => 1);
    if (!assets.containsKey(key)) throw StateError('Missing local asset: $key');
    return ByteData.sublistView(
      Uint8List.fromList(utf8.encode(jsonEncode(assets[key]))),
    );
  }
}

class _NoNetworkService implements FishCatalogService {
  int calls = 0;

  @override
  Future<List<FishSpecies>> fetchCatalog({bool forceRefresh = false}) async {
    calls++;
    throw StateError('No API requests are allowed.');
  }

  @override
  Future<FishSpecies> fetchDetail(
    FishSpecies species, {
    bool forceRefresh = false,
  }) async {
    calls++;
    throw StateError('No API requests are allowed.');
  }
}
