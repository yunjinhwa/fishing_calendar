import 'dart:async';

import 'package:fishing_build/data/fish/bundled_fish_descriptions.dart';
import 'package:fishing_build/data/fish/fish_catalog_service.dart';
import 'package:fishing_build/data/fish/fish_taxonomy_resolver.dart';
import 'package:fishing_build/data/fish/recovering_fish_detail_provider.dart';
import 'package:fishing_build/data/models/fish_species.dart';
import 'package:flutter_test/flutter_test.dart';

const _base = FishSpecies(
  id: 'nifs:test',
  name: '가시납지리',
  scientificName: 'Acheilognathus chankaensis',
  category: FishCategory.freshwater,
  family: '잉어과',
);
const _accepted = 'Acanthorhodeus chankaensis';
const _photo = 'https://static.inaturalist.org/photos/1/medium.jpg';

FishSpecies _copy(FishSpecies fish, Map<String, Object?> changes) =>
    FishSpecies.fromJson({...fish.toJson(), ...changes});

class _Provider implements FishDetailProvider {
  _Provider(this.reply);
  final Future<FishSpecies> Function(FishSpecies) reply;
  final calls = <FishSpecies>[];
  final forces = <bool>[];
  @override
  Future<FishSpecies> fetchDetail(
    FishSpecies fish, {
    bool forceRefresh = false,
  }) {
    calls.add(fish);
    forces.add(forceRefresh);
    return reply(fish);
  }
}

class _Taxonomy implements FishTaxonomyResolver {
  _Taxonomy({this.alternatives = const [], this.reply});
  final List<FishTaxonomyAlternative> alternatives;
  final Future<FishTaxonomyResolution> Function(FishSpecies)? reply;
  int calls = 0;
  final forces = <bool>[];
  @override
  Future<FishTaxonomyResolution> resolve(
    FishSpecies species, {
    bool forceRefresh = false,
  }) async {
    calls++;
    forces.add(forceRefresh);
    return reply != null
        ? await reply!(species)
        : FishTaxonomyResolution(
            originalScientificName: species.scientificName,
            alternatives: alternatives,
          );
  }
}

const _alternative = FishTaxonomyAlternative(
  scientificName: _accepted,
  sourceUrl: 'https://www.checklistbank.org/dataset/309180/taxon/8ZS2',
);
_Provider _missing() => _Provider(
  (_) async => throw const FishCatalogException(FishCatalogFailure.noData),
);
Matcher _failure(FishCatalogFailure reason) => throwsA(
  isA<FishCatalogException>().having((value) => value.reason, 'reason', reason),
);

void main() {
  test('complete primary data makes no recovery requests', () async {
    final primary = _Provider(
      (fish) async => _copy(fish, {'feature': '공식 설명', 'imageUrl': _photo}),
    );
    final photos = _missing();
    final taxonomy = _Taxonomy();
    final provider = RecoveringFishDetailProvider(
      primary: primary,
      photoFallback: photos,
      taxonomy: taxonomy,
    );
    expect((await provider.fetchDetail(_base)).feature, '공식 설명');
    expect(photos.calls, isEmpty);
    expect(taxonomy.calls, 0);
  });

  test(
    'completed fallback content clears transient partial retry status',
    () async {
      final primary = _Provider(
        (fish) async =>
            _copy(fish, {'feature': '검증된 설명', 'detailNeedsRetry': true}),
      );
      final result = await RecoveringFishDetailProvider(
        primary: primary,
        photoFallback: _Provider(
          (fish) async => _copy(fish, {'imageUrl': _photo}),
        ),
        taxonomy: _Taxonomy(),
      ).fetchDetail(_base);
      expect(result.feature, '검증된 설명');
      expect(result.imageUrl, _photo);
      expect(result.detailNeedsRetry, isFalse);
    },
  );

  test(
    'photo fallback cannot overwrite Korean description or maximum size',
    () async {
      final primary = _Provider(
        (fish) async => _copy(fish, {
          'feature': '기존 한국어 설명',
          'maxSize': '12 cm',
          'descriptionSourceUrl': 'https://ko.wikipedia.org/wiki/Fish',
        }),
      );
      final photos = _Provider(
        (fish) async => _copy(fish, {
          'feature': '덮어쓰면 안 되는 설명',
          'maxSize': '900 cm',
          'imageUrl': _photo,
          'photoSourceUrl': 'https://www.inaturalist.org/photos/1',
          'photoLicenseUrl': 'https://creativecommons.org/licenses/by/4.0/',
          'photoAttribution': 'Photographer · CC BY 4.0',
        }),
      );
      final taxonomy = _Taxonomy();
      final result = await RecoveringFishDetailProvider(
        primary: primary,
        photoFallback: photos,
        taxonomy: taxonomy,
      ).fetchDetail(_base, forceRefresh: true);
      expect(result.feature, '기존 한국어 설명');
      expect(result.maxSize, '12 cm');
      expect(result.imageUrl, _photo);
      expect(result.photoAttribution, 'Photographer · CC BY 4.0');
      expect(result.scientificName, _base.scientificName);
      expect(primary.forces, [true]);
      expect(photos.forces, [true]);
      expect(taxonomy.forces, isEmpty);
    },
  );

  test(
    'explicit synonym with fresh Korean name confirmation restores catalog identity',
    () async {
      final primary = _Provider((fish) async {
        if (fish.scientificName != _accepted) {
          throw const FishCatalogException(FishCatalogFailure.noData);
        }
        expect(fish.name, _base.name);
        expect(fish.feature, isEmpty);
        expect(fish.imageUrl, isNull);
        return _copy(fish, {
          'feature': '가시납지리의 검증된 설명',
          'descriptionSourceUrl': 'https://ko.wikipedia.org/wiki/Fish',
          'imageUrl': _photo,
        });
      });
      final result = await RecoveringFishDetailProvider(
        primary: primary,
        photoFallback: _missing(),
        taxonomy: _Taxonomy(alternatives: [_alternative]),
      ).fetchDetail(_base);
      expect(result.id, _base.id);
      expect(result.name, _base.name);
      expect(result.scientificName, _base.scientificName);
      expect(result.family, _base.family);
      expect(result.category, _base.category);
      expect(result.imageUrl, _photo);
      expect(result.sourceName, contains('Catalogue of Life'));
      expect(primary.calls.map((fish) => fish.scientificName), [
        _base.scientificName,
        _accepted,
      ]);
    },
  );

  test(
    'a synonym photo without positive Korean proof is never attached',
    () async {
      final primary = _Provider((fish) async {
        if (fish.scientificName != _accepted) {
          throw const FishCatalogException(FishCatalogFailure.noData);
        }
        return _copy(fish, {'imageUrl': _photo});
      });
      await expectLater(
        RecoveringFishDetailProvider(
          primary: primary,
          photoFallback: _missing(),
          taxonomy: _Taxonomy(alternatives: [_alternative]),
        ).fetchDetail(_base),
        _failure(FishCatalogFailure.noData),
      );
    },
  );

  test(
    'inherited Korean text is not proof for a different accepted taxon',
    () async {
      final original = _copy(_base, {
        'feature': '기존 설명',
        'descriptionSourceUrl': 'https://ko.wikipedia.org/wiki/Original',
      });
      final primary = _Provider((fish) async {
        if (fish.scientificName == _accepted) {
          expect(fish.feature, isEmpty);
          return _copy(fish, {'imageUrl': _photo});
        }
        return fish;
      });
      final result = await RecoveringFishDetailProvider(
        primary: primary,
        photoFallback: _missing(),
        taxonomy: _Taxonomy(alternatives: [_alternative]),
      ).fetchDetail(original);
      expect(result.feature, '기존 설명');
      expect(result.imageUrl, isNull);
    },
  );

  test(
    'unverified resolver identity cannot trigger an alternate request',
    () async {
      final primary = _missing();
      final taxonomy = _Taxonomy(
        reply: (_) async => const FishTaxonomyResolution(
          originalScientificName: 'Unrelated species',
          alternatives: [_alternative],
        ),
      );
      await expectLater(
        RecoveringFishDetailProvider(
          primary: primary,
          photoFallback: _missing(),
          taxonomy: taxonomy,
        ).fetchDetail(_base),
        _failure(FishCatalogFailure.invalidResponse),
      );
      expect(primary.calls, hasLength(1));
    },
  );

  test(
    'partial recovery keeps prose and marks transient photo failures retriable',
    () async {
      final result = await RecoveringFishDetailProvider(
        primary: _Provider((fish) async => _copy(fish, {'feature': '설명'})),
        photoFallback: _Provider(
          (_) async =>
              throw const FishCatalogException(FishCatalogFailure.network),
        ),
        taxonomy: _Taxonomy(),
      ).fetchDetail(_base);
      expect(result.feature, '설명');
      expect(result.detailNeedsRetry, isTrue);
    },
  );

  test('lookup outages are not reported as nonexistent information', () async {
    await expectLater(
      RecoveringFishDetailProvider(
        primary: _missing(),
        photoFallback: _Provider(
          (_) async =>
              throw const FishCatalogException(FishCatalogFailure.rateLimited),
        ),
        taxonomy: _Taxonomy(),
      ).fetchDetail(_base),
      _failure(FishCatalogFailure.rateLimited),
    );
  });

  test('shared recovery deadline prevents a late synonym lookup', () async {
    final stalled = Completer<FishSpecies>();
    final primary = _missing();
    await expectLater(
      RecoveringFishDetailProvider(
        primary: primary,
        photoFallback: _Provider((_) => stalled.future),
        taxonomy: _Taxonomy(alternatives: [_alternative]),
        recoveryTimeout: const Duration(milliseconds: 15),
      ).fetchDetail(_base),
      _failure(FishCatalogFailure.timedOut),
    );
    expect(primary.calls, hasLength(1));
    stalled.complete(_base);
  });

  test(
    'wrong provider identity never attaches another species photo',
    () async {
      await expectLater(
        RecoveringFishDetailProvider(
          primary: _Provider(
            (fish) async => _copy(fish, {'name': '다른 어종', 'imageUrl': _photo}),
          ),
          photoFallback: _missing(),
          taxonomy: _Taxonomy(),
        ).fetchDetail(_base),
        _failure(FishCatalogFailure.invalidResponse),
      );
    },
  );

  test(
    'reviewed translated text is available when live description is missing',
    () async {
      const fish = FishSpecies(
        id: 'nifs:NS001041',
        name: '가시줄고기',
        scientificName: 'Hypsagonus corniger',
      );
      final result = await RecoveringFishDetailProvider(
        primary: _missing(),
        photoFallback: _missing(),
        taxonomy: _Taxonomy(),
      ).fetchDetail(fish);
      expect(result.feature, contains('18~105m'));
      expect(result.descriptionSourceUrl, contains('oldid=1271719228'));
      expect(result.descriptionAttribution, contains('번역'));
      expect(result.maxSize, contains('10cm'));
      expect(result.maxSize, contains('수컷'));
      expect(result.detailNeedsRetry, isFalse);
      await expectLater(
        RecoveringFishDetailProvider(
          primary: _missing(),
          photoFallback: _missing(),
          taxonomy: _Taxonomy(),
          photoOnly: true,
        ).fetchDetail(fish),
        _failure(FishCatalogFailure.noData),
      );
    },
  );

  test(
    'bundled translations require both original Korean and scientific names',
    () {
      const fish = FishSpecies(
        id: 'source-id',
        name: '가는곰치',
        scientificName: 'Strophidon sathete',
      );
      final result = BundledFishDescriptions.apply(fish);
      expect(result.feature, isNotEmpty);
      expect(result.id, fish.id);
      expect(result.imageUrl, isNull);
      expect(
        BundledFishDescriptions.apply(_copy(fish, {'name': '다른 곰치'})).feature,
        isEmpty,
      );
      final existing = _copy(fish, {'feature': '기관에서 받은 한국어 설명'});
      expect(BundledFishDescriptions.apply(existing), same(existing));
    },
  );
}
