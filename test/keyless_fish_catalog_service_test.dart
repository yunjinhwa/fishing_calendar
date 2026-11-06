import 'dart:convert';
import 'dart:io';

import 'package:fishing_build/data/fish/fish_catalog_service.dart';
import 'package:fishing_build/data/fish/keyless_fish_catalog_service.dart';
import 'package:fishing_build/data/models/fish_species.dart';
import 'package:fishing_build/data/repositories/fish_species_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _fish = FishSpecies(
  id: 'nifs:1',
  name: '감성돔',
  scientificName: 'Acanthopagrus schlegelii',
);
const _newFish = FishSpecies(id: 'nifs:2', name: '넙치');
const _licensed = FishSpecies(
  id: 'nifs:1',
  name: '감성돔',
  scientificName: 'Acanthopagrus schlegelii',
  feature: '몸은 은회색이며 연안에 서식한다. 몸길이는 최대 50cm이다.',
  imageUrl: 'https://upload.wikimedia.org/wikipedia/commons/a/aa/Fish.jpg',
  photoSourceUrl: 'https://commons.wikimedia.org/wiki/File:Fish.jpg',
  photoAttribution: 'Fixture photographer · CC BY 4.0',
  photoLicenseUrl: 'https://creativecommons.org/licenses/by/4.0/',
  descriptionSourceUrl:
      'https://ko.wikipedia.org/wiki/%EA%B0%90%EC%84%B1%EB%8F%94',
  descriptionAttribution:
      '한국어 위키백과 기여자 · CC BY-SA 4.0 · '
      'https://creativecommons.org/licenses/by-sa/4.0/',
);

Map<String, Object?> _enrichment({DateTime? checkedAt}) => {
  'version': 1,
  'recordCount': 1,
  'dataUpdatedAt': '2026-11-06T00:00:00Z',
  'records': [
    {
      'checkedAt': (checkedAt ?? DateTime.utc(2026, 11, 5)).toIso8601String(),
      'result': _licensed.toJson(),
    },
  ],
};

class _Remote implements FishCatalogService {
  int calls = 0;
  bool fails = false;
  @override
  Future<List<FishSpecies>> fetchCatalog({bool forceRefresh = false}) async {
    calls++;
    if (fails) {
      throw const FishCatalogException(FishCatalogFailure.unauthorized);
    }
    return [_fish, _newFish];
  }

  @override
  Future<FishSpecies> fetchDetail(
    FishSpecies fish, {
    bool forceRefresh = false,
  }) => throw StateError('NARIS must not be called.');
}

class _Detail implements FishDetailProvider {
  int calls = 0;
  final forces = <bool>[];
  final inputs = <FishSpecies>[];
  @override
  Future<FishSpecies> fetchDetail(
    FishSpecies fish, {
    bool forceRefresh = false,
  }) async {
    calls++;
    forces.add(forceRefresh);
    inputs.add(fish);
    return fish;
  }
}

class _Bundle extends CachingAssetBundle {
  _Bundle({this.broken = false, this.enrichment});
  final bool broken;
  final Object? enrichment;
  final loads = <String, int>{};
  final stringLoads = <String, int>{};
  @override
  Future<String> loadString(String key, {bool cache = true}) {
    stringLoads.update(key, (count) => count + 1, ifAbsent: () => 1);
    return super.loadString(key, cache: cache);
  }

  @override
  Future<ByteData> load(String key) async {
    loads.update(key, (count) => count + 1, ifAbsent: () => 1);
    if (key == KeylessFishCatalogService.enrichmentAssetPath) {
      if (enrichment == null) {
        throw StateError('Optional fixture asset is absent.');
      }
      return ByteData.sublistView(
        Uint8List.fromList(
          utf8.encode(
            enrichment is String
                ? enrichment as String
                : jsonEncode(enrichment),
          ),
        ),
      );
    }
    return ByteData.sublistView(
      Uint8List.fromList(
        utf8.encode(
          broken
              ? '{}'
              : jsonEncode({
                  'version': 1,
                  'recordCount': 1,
                  'dataUpdatedAt': '2026-11-04T00:00:00Z',
                  'species': [_fish.toJson()],
                }),
        ),
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'offline cold start exposes licensed bundled fields without remote providers',
    () async {
      final remote = _Remote();
      final detail = _Detail();
      final thumbnail = _Detail();
      final repository = FishSpeciesRepository(
        service: KeylessFishCatalogService(
          bundle: _Bundle(enrichment: _enrichment()),
          remoteCatalog: remote,
          detailProvider: detail,
          thumbnailProvider: thumbnail,
          enableRemoteRefresh: true,
        ),
      );
      final snapshot = await repository.load(allowNetwork: false);
      final fish = snapshot.items.single;
      expect(fish.id, _fish.id);
      expect(fish.feature, _licensed.feature);
      expect(fish.imageUrl, _licensed.imageUrl);
      expect(fish.photoSourceUrl, _licensed.photoSourceUrl);
      expect(fish.photoLicenseUrl, _licensed.photoLicenseUrl);
      expect(fish.descriptionAttribution, _licensed.descriptionAttribution);
      expect(snapshot.isBundled, isTrue);
      expect(
        (await repository.detail(_fish, allowNetwork: false)).feature,
        _licensed.feature,
      );
      expect(
        (await repository.thumbnail(_fish, allowNetwork: false)).imageUrl,
        _licensed.imageUrl,
      );
      expect(remote.calls, 0);
      expect(detail.calls, 0);
      expect(thumbnail.calls, 0);
    },
  );

  test(
    'old persisted catalog and empty detail cannot hide new bundled photo and prose',
    () async {
      final now = DateTime.utc(2026, 11, 6);
      final previous = now.subtract(const Duration(days: 1));
      SharedPreferences.setMockInitialValues({
        'fish_encyclopedia_cache_v1': jsonEncode({
          'version': 1,
          'catalog': [_fish.toJson()],
          'catalogAt': previous.toIso8601String(),
          'isBundled': true,
          'catalogDataAt': previous.toIso8601String(),
          'details': [
            {
              'fish': _fish.toJson(),
              'at': now.subtract(const Duration(minutes: 1)).toIso8601String(),
              'namespace': 'custom-v1',
            },
          ],
        }),
      });
      final bundle = _Bundle(enrichment: _enrichment());
      final remote = _Remote();
      final detail = _Detail();
      final service = KeylessFishCatalogService(
        bundle: bundle,
        remoteCatalog: remote,
        detailProvider: detail,
        enableRemoteRefresh: false,
      );
      final repository = FishSpeciesRepository(
        service: service,
        clock: () => now,
      );
      final restored = await repository.load(allowNetwork: false);
      expect(restored.items.single.feature, _licensed.feature);
      expect(restored.items.single.imageUrl, _licensed.imageUrl);
      final cachedDetail = await repository.detail(_fish, allowNetwork: false);
      expect(cachedDetail.feature, _licensed.feature);
      expect(cachedDetail.imageUrl, _licensed.imageUrl);
      expect(
        (await repository.thumbnail(_fish, allowNetwork: false)).imageUrl,
        _licensed.imageUrl,
      );
      expect(
        restored.fetchedAt,
        previous,
        reason: 'Bundled fields do not refresh the old cache age.',
      );
      expect(bundle.loads[KeylessFishCatalogService.enrichmentAssetPath], 1);
      expect(remote.calls, 0);
      expect(detail.calls, 0);
    },
  );

  test(
    'fresh complete bundled profile avoids detail provider until explicitly forced',
    () async {
      final detail = _Detail();
      final service = KeylessFishCatalogService(
        bundle: _Bundle(enrichment: _enrichment()),
        detailProvider: detail,
        clock: () => DateTime.utc(2026, 11, 6),
        enableRemoteRefresh: false,
      );
      final local = await service.fetchDetail(_fish);
      expect(local.feature, _licensed.feature);
      expect(local.imageUrl, _licensed.imageUrl);
      expect(detail.calls, 0);
      final forced = await service.fetchDetail(_fish, forceRefresh: true);
      expect(detail.calls, 1);
      expect(detail.forces, [true]);
      expect(detail.inputs.single.feature, _licensed.feature);
      expect(detail.inputs.single.imageUrl, _licensed.imageUrl);
      expect(forced.feature, _licensed.feature);
    },
  );

  test(
    'stale complete bundled profile remains a seed and permits detail refresh',
    () async {
      final detail = _Detail();
      final service = KeylessFishCatalogService(
        bundle: _Bundle(
          enrichment: _enrichment(checkedAt: DateTime.utc(2026, 10, 28)),
        ),
        detailProvider: detail,
        clock: () => DateTime.utc(2026, 11, 6),
        enableRemoteRefresh: false,
      );
      final result = await service.fetchDetail(_fish);
      expect(detail.calls, 1);
      expect(detail.forces, [false]);
      expect(detail.inputs.single.feature, _licensed.feature);
      expect(detail.inputs.single.imageUrl, _licensed.imageUrl);
      expect(result.feature, _licensed.feature);
    },
  );

  test(
    'invalid optional enrichment never prevents the basic offline catalog',
    () async {
      for (final invalid in [
        '{broken',
        {
          'version': 1,
          'recordCount': 1,
          'dataUpdatedAt': '2026-11-06T00:00:00Z',
          'records': [],
        },
      ]) {
        SharedPreferences.setMockInitialValues({});
        final remote = _Remote();
        final repository = FishSpeciesRepository(
          service: KeylessFishCatalogService(
            bundle: _Bundle(enrichment: invalid),
            remoteCatalog: remote,
            enableRemoteRefresh: true,
          ),
        );
        final result = await repository.load(allowNetwork: false);
        expect(result.items.single.id, _fish.id);
        expect(result.items.single.feature, isEmpty);
        expect(result.items.single.imageUrl, isNull);
        expect(result.failure, isNull);
        expect(remote.calls, 0);
      }
    },
  );

  test(
    'concurrent catalog and detail callers load each shipped asset only once',
    () async {
      final bundle = _Bundle(enrichment: _enrichment());
      final detail = _Detail();
      final service = KeylessFishCatalogService(
        bundle: bundle,
        detailProvider: detail,
        clock: () => DateTime.utc(2026, 11, 6),
        enableRemoteRefresh: false,
      );
      await Future.wait<Object?>([
        service.fetchCatalog(),
        service.fetchCatalog(forceRefresh: true),
        service.loadBundledEnrichment(),
        service.fetchDetail(_fish),
      ]);
      await service.loadBundledCatalog();
      await service.fetchDetail(_fish);
      expect(bundle.stringLoads[KeylessFishCatalogService.assetPath], 1);
      expect(
        bundle.stringLoads[KeylessFishCatalogService.enrichmentAssetPath],
        1,
      );
      expect(bundle.loads[KeylessFishCatalogService.assetPath], 1);
      expect(bundle.loads[KeylessFishCatalogService.enrichmentAssetPath], 1);
      expect(detail.calls, 0);
    },
  );

  test(
    'first use and refresh need no credential or remote catalog request',
    () async {
      final remote = _Remote();
      final service = KeylessFishCatalogService(
        bundle: _Bundle(),
        remoteCatalog: remote,
        enableRemoteRefresh: false,
      );
      expect((await service.fetchCatalog()).single.name, _fish.name);
      expect(
        (await service.fetchCatalog(forceRefresh: true)).single.id,
        _fish.id,
      );
      expect(remote.calls, 0);
      expect(service.usesBundledCatalog, isTrue);
      expect(service.catalogDataUpdatedAt, DateTime.utc(2026, 11, 4));
    },
  );

  test('configured key is used only for an explicit remote refresh', () async {
    final remote = _Remote();
    final service = KeylessFishCatalogService(
      bundle: _Bundle(),
      remoteCatalog: remote,
      enableRemoteRefresh: true,
      clock: () => DateTime.utc(2026, 11, 5),
    );
    expect(await service.fetchCatalog(), hasLength(1));
    expect(remote.calls, 0);
    expect(await service.fetchCatalog(forceRefresh: true), hasLength(2));
    expect(service.usesBundledCatalog, isFalse);
    expect(service.catalogDataUpdatedAt, DateTime.utc(2026, 11, 5));
    expect(await service.fetchCatalog(), hasLength(2));
    expect(remote.calls, 1);
  });

  test('failed optional refresh still exposes the bundled catalog', () async {
    final remote = _Remote()..fails = true;
    final service = KeylessFishCatalogService(
      bundle: _Bundle(),
      remoteCatalog: remote,
      enableRemoteRefresh: true,
    );
    final repository = FishSpeciesRepository(service: service);
    final snapshot = await repository.load(forceRefresh: true);
    expect(snapshot.items.single.id, _fish.id);
    expect(snapshot.isBundled, isTrue);
    expect(snapshot.failure, FishCatalogFailure.unauthorized);
    expect(snapshot.dataUpdatedAt, DateTime.utc(2026, 11, 4));
  });

  test(
    'offline first installation reads bundled catalog with an empty device cache',
    () async {
      final remote = _Remote();
      final repository = FishSpeciesRepository(
        service: KeylessFishCatalogService(
          bundle: _Bundle(),
          remoteCatalog: remote,
          enableRemoteRefresh: true,
        ),
      );
      final snapshot = await repository.load(allowNetwork: false);
      expect(snapshot.items.single.name, _fish.name);
      expect(snapshot.isBundled, isTrue);
      expect(snapshot.dataUpdatedAt, DateTime.utc(2026, 11, 4));
      expect(remote.calls, 0);
    },
  );

  test('bundle provenance and source date survive a device restart', () async {
    FishSpeciesRepository create() => FishSpeciesRepository(
      service: KeylessFishCatalogService(bundle: _Bundle()),
    );
    await create().load(allowNetwork: false);
    final restored = await create().load(allowNetwork: false);
    expect(restored.isBundled, isTrue);
    expect(restored.dataUpdatedAt, DateTime.utc(2026, 11, 4));
  });

  test(
    'a failed later refresh retains the last successful remote catalog',
    () async {
      final remote = _Remote();
      final service = KeylessFishCatalogService(
        bundle: _Bundle(),
        remoteCatalog: remote,
        enableRemoteRefresh: true,
      );
      await service.fetchCatalog(forceRefresh: true);
      remote.fails = true;
      expect(await service.fetchCatalog(forceRefresh: true), hasLength(2));
      expect(service.usesBundledCatalog, isFalse);
      expect(service.catalogRefreshFailure, FishCatalogFailure.unauthorized);
      await service.loadBundledCatalog();
      expect(service.usesBundledCatalog, isTrue);
      expect(await service.fetchCatalog(), hasLength(2));
      expect(service.usesBundledCatalog, isFalse);
    },
  );

  test(
    'detail requests use the keyless provider rather than the NARIS service',
    () async {
      final detail = _Detail();
      final service = KeylessFishCatalogService(
        bundle: _Bundle(),
        remoteCatalog: _Remote(),
        detailProvider: detail,
      );
      expect(await service.fetchDetail(_fish), same(_fish));
      expect(detail.calls, 1);
    },
  );

  test(
    'list thumbnails use the photo path without the composite description provider',
    () async {
      final full = _Detail();
      final wiki = _Detail();
      final service = KeylessFishCatalogService(
        bundle: _Bundle(),
        remoteCatalog: _Remote(),
        detailProvider: full,
        thumbnailProvider: wiki,
      );
      expect(await service.fetchThumbnail(_fish), same(_fish));
      expect(wiki.calls, 1);
      expect(full.calls, 0);
    },
  );

  test(
    'damaged shipped catalog is reported safely rather than inventing data',
    () async {
      final service = KeylessFishCatalogService(bundle: _Bundle(broken: true));
      await expectLater(
        service.fetchCatalog(),
        throwsA(isA<FishCatalogException>()),
      );
    },
  );

  test(
    'released public snapshot contains the actual 800 classified fish without secrets',
    () async {
      final service = KeylessFishCatalogService(enableRemoteRefresh: false);
      final fish = await service.fetchCatalog();
      expect(fish, hasLength(800));
      expect(fish.map((item) => item.id).toSet(), hasLength(800));
      expect(
        fish.where((item) => item.category == FishCategory.sea),
        hasLength(673),
      );
      expect(
        fish.where((item) => item.category == FishCategory.freshwater),
        hasLength(127),
      );
      expect(fish.where((item) => item.scientificName.isEmpty), isEmpty);
      final translated = fish.where(
        (item) => item.descriptionAttribution?.contains('번역') ?? false,
      );
      expect(translated, isNotEmpty);
      final photographed = fish.where((item) => item.imageUrl != null).toList();
      expect(
        photographed.map((item) => item.name),
        containsAll(['가라지', '가숭어', '가시가자미']),
      );
      final inventory =
          jsonDecode(
                await File(
                  'docs/fish_enrichment_inventory.json',
                ).readAsString(),
              )
              as Map;
      final summary = inventory['summary'] as Map;
      expect(summary['catalog'], 800);
      expect(summary['checked'], 800);
      expect(photographed, hasLength(summary['photo'] as int));
      expect(
        fish.where((item) => item.feature.isNotEmpty),
        hasLength(summary['description'] as int),
      );
      expect(
        fish.where((item) => item.sizeDescription.isNotEmpty),
        hasLength(summary['size'] as int),
      );
      final auditRows = {
        for (final row in inventory['records'] as List) (row as Map)['id']: row,
      };
      expect(auditRows, hasLength(800));
      for (final item in fish) {
        final audit = auditRows[item.id] as Map;
        expect(audit['name'], item.name);
        expect(audit['scientificName'], item.scientificName);
        expect(
          audit['checkedBy'],
          containsAll([
            'mbris',
            'wikimedia',
            'englishPhotographs',
            'photographs',
          ]),
        );
        expect(audit['descriptionAvailable'], item.feature.trim().isNotEmpty);
        expect(audit['photoAvailable'], item.imageUrl?.isNotEmpty == true);
        expect(audit['sizeAvailable'], item.sizeDescription.isNotEmpty);
      }
      final flounder = fish.singleWhere((item) => item.name == '넙치');
      expect(flounder.imageUrl, isNotNull);
      expect(flounder.feature, isNotEmpty);
      expect(flounder.habitat, isNot('해수'));
      final cutlassfish = fish.singleWhere((item) => item.name == '갈치');
      expect(cutlassfish.scientificName, 'Trichiurus japonicus');
      expect(
        cutlassfish.imageUrl,
        startsWith('https://www.nifs.go.kr/cmmn/images/MF'),
      );
      expect(cutlassfish.photoAttribution, contains('공공누리 제1유형'));
      expect(
        cutlassfish.photoSourceUrl,
        'https://www.nifs.go.kr/contents/actionContentsCons0088.do',
      );
      final crucian = fish.singleWhere((item) => item.name == '붕어');
      expect(crucian.scientificName, 'Carassius auratus');
      expect(crucian.descriptionSourceUrl, contains('ko.wikisource.org'));
      expect(crucian.feature, isNotEmpty);
      expect(crucian.habitat, isNot('육상 담수'));
      expect(crucian.sizeDescription, contains('10-20'));
      expect(
        translated.every(
          (item) => item.descriptionSourceUrl!.contains('oldid='),
        ),
        isTrue,
      );
      final decoded =
          jsonDecode(
                await rootBundle.loadString(
                  KeylessFishCatalogService.assetPath,
                ),
              )
              as Map;
      expect(decoded.keys, isNot(contains('key')));
      expect(decoded.keys, isNot(contains('NIFS_SPECIES_API_KEY')));
    },
  );
}
