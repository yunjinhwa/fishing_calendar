import 'dart:async';

import 'package:fishing_build/data/fish/composite_fish_detail_provider.dart';
import 'package:fishing_build/data/fish/fish_catalog_service.dart';
import 'package:fishing_build/data/models/fish_species.dart';
import 'package:flutter_test/flutter_test.dart';

const _base = FishSpecies(
  id: 'nifs:1',
  name: '넙치',
  scientificName: 'Paralichthys olivaceus',
  category: FishCategory.sea,
  family: '넙치과',
  habitat: '해수',
  sourceName: '국립수산과학원',
);
const _wiki = FishSpecies(
  id: 'nifs:1',
  name: '넙치',
  scientificName: 'Paralichthys olivaceus',
  feature: '위키 설명',
  imageUrl: 'https://upload.wikimedia.org/fish.jpg',
  photoAttribution: 'Author · CC BY 4.0',
  photoSourceUrl: 'https://commons.wikimedia.org/wiki/File:Fish.jpg',
  photoLicenseUrl: 'https://creativecommons.org/licenses/by/4.0/',
  descriptionSourceUrl: 'https://ko.wikipedia.org/wiki/Fish',
  descriptionAttribution: '위키 기여자',
  sourceName: 'Wikidata · Wikimedia Commons',
);
const _korean = FishSpecies(
  id: 'nifs:1',
  name: '넙치',
  scientificName: 'Paralichthys olivaceus',
  feature: '한국어 생태·형태 설명',
  descriptionSourceUrl: 'https://www.data.go.kr/data/15094770/openapi.do',
  descriptionAttribution: '국립해양생물자원관',
  sourceName: '국립해양생물자원관',
);

class _Provider implements FishDetailProvider {
  _Provider(this.reply);
  final Future<FishSpecies> Function() reply;
  final forces = <bool>[];
  @override
  Future<FishSpecies> fetchDetail(
    FishSpecies fish, {
    bool forceRefresh = false,
  }) {
    forces.add(forceRefresh);
    return reply();
  }
}

_Provider _value(FishSpecies fish) => _Provider(() async => fish);
_Provider _failure(FishCatalogFailure failure) =>
    _Provider(() async => throw FishCatalogException(failure));

void main() {
  test(
    'combines Korean description with independently licensed Commons photo',
    () async {
      final provider = CompositeFishDetailProvider(
        wikimedia: _value(_wiki),
        korean: _value(_korean),
      );
      final result = await provider.fetchDetail(_base);
      expect(result.id, _base.id);
      expect(result.family, _base.family);
      expect(result.category, _base.category);
      expect(result.feature, _korean.feature);
      expect(result.descriptionAttribution, _korean.descriptionAttribution);
      expect(result.imageUrl, _wiki.imageUrl);
      expect(result.photoLicenseUrl, _wiki.photoLicenseUrl);
      expect(result.detailNeedsRetry, isFalse);
    },
  );

  test(
    'an unavailable Korean provider does not discard valid Wiki content',
    () async {
      final result = await CompositeFishDetailProvider(
        wikimedia: _value(_wiki),
        korean: _failure(FishCatalogFailure.noData),
      ).fetchDetail(_base);
      expect(result.feature, _wiki.feature);
      expect(result.descriptionSourceUrl, _wiki.descriptionSourceUrl);
      expect(result.imageUrl, _wiki.imageUrl);
      expect(result.detailNeedsRetry, isFalse);
    },
  );

  test(
    'a transient photo provider outage retains Korean information and retries sooner',
    () async {
      final result = await CompositeFishDetailProvider(
        wikimedia: _failure(FishCatalogFailure.rateLimited),
        korean: _value(_korean),
      ).fetchDetail(_base);
      expect(result.feature, _korean.feature);
      expect(result.imageUrl, isNull);
      expect(result.detailNeedsRetry, isTrue);
    },
  );

  test(
    'transient preferred description failure does not discard complete Wiki information',
    () async {
      final result = await CompositeFishDetailProvider(
        wikimedia: _value(_wiki),
        korean: _failure(FishCatalogFailure.network),
      ).fetchDetail(_base);
      expect(result.feature, _wiki.feature);
      expect(result.detailNeedsRetry, isTrue);
    },
  );

  test('does not call an unconfigured optional provider', () async {
    final korean = _failure(FishCatalogFailure.configuration);
    final provider = CompositeFishDetailProvider(
      wikimedia: _value(_wiki),
      korean: korean,
      enableKorean: false,
    );
    expect((await provider.fetchDetail(_base)).feature, _wiki.feature);
    expect(korean.forces, isEmpty);
    expect(provider.detailCacheNamespace, contains('disabled'));
  });

  test(
    'service outage is preserved instead of claiming no species information exists',
    () async {
      final provider = CompositeFishDetailProvider(
        wikimedia: _failure(FishCatalogFailure.noData),
        korean: _failure(FishCatalogFailure.timedOut),
      );
      await expectLater(
        provider.fetchDetail(_base),
        throwsA(
          isA<FishCatalogException>().having(
            (value) => value.reason,
            'reason',
            FishCatalogFailure.timedOut,
          ),
        ),
      );
    },
  );

  test(
    'another species identity is never merged into a valid result',
    () async {
      const other = FishSpecies(
        id: 'other',
        name: '다른 종',
        scientificName: 'Different fish',
        feature: '잘못된 설명',
      );
      final result = await CompositeFishDetailProvider(
        wikimedia: _value(_wiki),
        korean: _value(other),
      ).fetchDetail(_base);
      expect(result.feature, _wiki.feature);
      expect(result.id, _base.id);
    },
  );

  test(
    'independent lookups run together and force refresh reaches both providers',
    () async {
      final a = Completer<FishSpecies>();
      final b = Completer<FishSpecies>();
      final wiki = _Provider(() => a.future);
      final korean = _Provider(() => b.future);
      final pending = CompositeFishDetailProvider(
        wikimedia: wiki,
        korean: korean,
      ).fetchDetail(_base, forceRefresh: true);
      expect(wiki.forces, [true]);
      expect(korean.forces, [true]);
      a.complete(_wiki);
      b.complete(_korean);
      expect((await pending).feature, _korean.feature);
    },
  );
}
