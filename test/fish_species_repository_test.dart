import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fishing_build/data/fish/fish_catalog_service.dart';
import 'package:fishing_build/data/models/fish_species.dart';
import 'package:fishing_build/data/repositories/fish_species_repository.dart';

const _fish = FishSpecies(
  id: 'nifs:1',
  name: '감성돔',
  scientificName: 'Acanthopagrus schlegelii',
);
const _detail = FishSpecies(
  id: 'nifs:1',
  name: '감성돔',
  scientificName: 'Acanthopagrus schlegelii',
  feature: '공식 설명',
  imageUrl: 'https://naris.science.go.kr/fish.jpg',
  photoAttribution: 'Example Author · CC BY-SA 3.0',
  photoSourceUrl: 'https://commons.wikimedia.org/wiki/File:Fish.jpg',
  photoLicenseUrl: 'https://creativecommons.org/licenses/by-sa/3.0/',
  descriptionSourceUrl: 'https://ko.wikipedia.org/wiki/Fish',
  descriptionAttribution: '위키백과 기여자 · CC BY-SA 4.0',
);

Matcher _failure(FishCatalogFailure reason) => throwsA(
  isA<FishCatalogException>().having((error) => error.reason, 'reason', reason),
);

class _Service implements FishCatalogService, FishThumbnailSource {
  int catalogCalls = 0;
  int detailCalls = 0;
  int thumbnailCalls = 0;
  final thumbnailForces = <bool>[];
  Future<List<FishSpecies>> Function()? catalog;
  Future<FishSpecies> Function(FishSpecies)? details;
  Future<FishSpecies> Function(FishSpecies)? thumbnails;

  @override
  Future<FishSpecies> fetchThumbnail(
    FishSpecies species, {
    bool forceRefresh = false,
  }) async {
    thumbnailCalls++;
    thumbnailForces.add(forceRefresh);
    return thumbnails == null ? _detail : await thumbnails!(species);
  }

  @override
  Future<List<FishSpecies>> fetchCatalog({bool forceRefresh = false}) async {
    catalogCalls++;
    return catalog == null ? [_fish] : await catalog!();
  }

  @override
  Future<FishSpecies> fetchDetail(
    FishSpecies species, {
    bool forceRefresh = false,
  }) async {
    detailCalls++;
    return details == null ? _detail : await details!(species);
  }
}

class _VersionedService extends _Service implements FishDetailCachePolicy {
  String namespace = 'v1';
  @override
  String get detailCacheNamespace => namespace;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'old cached descriptions show body length offline without refreshing their age',
    () async {
      var now = DateTime.utc(2026, 11, 6);
      final at = now.subtract(const Duration(days: 29));
      final raw = {
        ..._detail.toJson(),
        'feature': '등 쪽은 어둡다. 몸길이는 5~7cm이다. 수심은 30m이다.',
        'maxSize': '',
      };
      SharedPreferences.setMockInitialValues({
        'fish_encyclopedia_cache_v1': jsonEncode({
          'version': 1,
          'details': [
            {'fish': raw, 'at': at.toIso8601String(), 'namespace': 'v1'},
          ],
        }),
      });
      final service = _VersionedService()..details = (fish) async => fish;
      final repository = FishSpeciesRepository(
        service: service,
        clock: () => now,
      );
      final result = await repository.detail(_fish, allowNetwork: false);
      expect(result.maxSize, contains('5~7cm'));
      expect(result.maxSize, isNot(contains('30m')));
      expect(result.photoAttribution, _detail.photoAttribution);
      expect(service.detailCalls, 0);
      await repository.detail(_fish);
      expect(service.detailCalls, 0);
      now = now.add(const Duration(days: 2));
      await repository.detail(_fish);
      expect(service.detailCalls, 1);
    },
  );

  test(
    'fresh provider prose fills size and preserves the result through restart',
    () async {
      final service = _Service()
        ..details = (fish) async => FishSpecies.fromJson({
          ...fish.toJson(),
          'feature': '몸길이는 약 20cm이다.',
          'maxSize': '',
        });
      final repository = FishSpeciesRepository(service: service);
      expect((await repository.detail(_fish)).maxSize, contains('20cm'));
      final restored = await FishSpeciesRepository(
        service: service,
      ).detail(_fish, allowNetwork: false);
      expect(restored.maxSize, contains('20cm'));
      expect(service.detailCalls, 1);
    },
  );

  test(
    'new source namespace rechecks a persisted missing photo immediately',
    () async {
      final service = _VersionedService()..thumbnails = (fish) async => fish;
      await expectLater(
        FishSpeciesRepository(service: service).thumbnail(_fish),
        _failure(FishCatalogFailure.noData),
      );
      service.namespace = 'v2-added-photo-source';
      service.thumbnails = (_) async => _detail;
      final result = await FishSpeciesRepository(
        service: service,
      ).thumbnail(_fish);
      expect(result.imageUrl, _detail.imageUrl);
      expect(service.thumbnailCalls, 2);
    },
  );

  test(
    'secondary photo provenance survives restart without becoming Commons',
    () async {
      final service = _Service()
        ..thumbnails = (_) async => const FishSpecies(
          id: 'nifs:1',
          name: '감성돔',
          scientificName: 'Acanthopagrus schlegelii',
          imageUrl: 'https://static.inaturalist.org/photos/1/medium.jpg',
          photoSourceUrl: 'https://www.inaturalist.org/photos/1',
          photoAttribution: 'Photographer · CC BY 4.0',
          photoLicenseUrl: 'https://creativecommons.org/licenses/by/4.0/',
        );
      final repository = FishSpeciesRepository(service: service);
      await repository.thumbnail(_fish);
      final cached = await FishSpeciesRepository(
        service: service,
      ).thumbnail(_fish, allowNetwork: false);
      expect(cached.sourceName, contains('iNaturalist'));
      expect(cached.sourceName, isNot(contains('Commons')));
      expect(cached.photoAttribution, 'Photographer · CC BY 4.0');
      expect(service.thumbnailCalls, 1);
    },
  );

  test(
    'list thumbnail uses only photo source and survives an offline restart',
    () async {
      final service = _Service();
      final repository = FishSpeciesRepository(service: service);
      await repository.load();
      final photo = await repository.thumbnail(_fish);
      expect(photo.imageUrl, _detail.imageUrl);
      expect(photo.feature, isEmpty);
      expect(service.thumbnailCalls, 1);
      expect(service.detailCalls, 0);
      expect((await repository.load()).items.single.imageUrl, _detail.imageUrl);
      await repository.thumbnail(_fish);
      expect(service.thumbnailCalls, 1);
      final unused = _Service();
      final restarted = FishSpeciesRepository(service: unused);
      expect(
        (await restarted.thumbnail(_fish, allowNetwork: false)).imageUrl,
        _detail.imageUrl,
      );
      expect(
        unused.thumbnailCalls + unused.detailCalls + unused.catalogCalls,
        0,
      );
    },
  );

  test('a fresh detailed photo avoids another list lookup', () async {
    final service = _Service();
    final repository = FishSpeciesRepository(service: service);
    await repository.detail(_fish);
    final result = await repository.thumbnail(_fish);
    expect(result.feature, _detail.feature);
    expect(result.imageUrl, _detail.imageUrl);
    expect(service.thumbnailCalls, 0);
  });

  test(
    'a photo update preserves complete MBRIS fields and does not refresh their age',
    () async {
      var now = DateTime.utc(2026, 11, 5);
      const complete = FishSpecies(
        id: 'nifs:1',
        name: '감성돔',
        scientificName: 'Acanthopagrus schlegelii',
        feature: 'MBRIS 설명',
        maxSize: '50 cm',
        imageUrl: 'https://upload.wikimedia.org/old.jpg',
        descriptionSourceUrl: 'https://www.mbris.kr/species',
        descriptionAttribution: '국립해양생물자원관',
        sourceName: 'MBRIS',
      );
      final service = _Service()..details = (_) async => complete;
      service.thumbnails = (base) async {
        expect(base.feature, complete.feature);
        expect(base.maxSize, complete.maxSize);
        expect(base.imageUrl, isNull);
        return _detail;
      };
      final repository = FishSpeciesRepository(
        service: service,
        clock: () => now,
      );
      await repository.detail(_fish);
      now = now.add(const Duration(days: 29));
      final result = await repository.thumbnail(_fish, forceRefresh: true);
      expect(result.feature, complete.feature);
      expect(result.maxSize, complete.maxSize);
      expect(result.descriptionSourceUrl, complete.descriptionSourceUrl);
      expect(result.imageUrl, _detail.imageUrl);
      expect(service.thumbnailForces, [true]);
      expect(
        (await repository.detail(_fish, allowNetwork: false)).feature,
        complete.feature,
      );
      now = now.add(const Duration(days: 2));
      await repository.detail(_fish);
      expect(service.detailCalls, 2);
    },
  );

  test(
    'opening detail after a thumbnail still enriches the Korean description',
    () async {
      final service = _VersionedService();
      service.details = (base) async {
        expect(base.imageUrl, _detail.imageUrl);
        expect(base.feature, isEmpty);
        return const FishSpecies(
          id: 'nifs:1',
          name: '감성돔',
          scientificName: 'Acanthopagrus schlegelii',
          feature: '새 MBRIS 설명',
          maxSize: '60 cm',
        );
      };
      final repository = FishSpeciesRepository(service: service);
      await repository.thumbnail(_fish);
      final result = await repository.detail(_fish);
      expect(service.detailCalls, 1);
      expect(result.feature, '새 MBRIS 설명');
      expect(result.maxSize, '60 cm');
      expect(result.imageUrl, _detail.imageUrl);
    },
  );

  test(
    'confirmed missing thumbnails are held for six hours and force bypasses',
    () async {
      var now = DateTime.utc(2026, 11, 5);
      final service = _Service()..thumbnails = (_) async => _fish;
      final repository = FishSpeciesRepository(
        service: service,
        clock: () => now,
      );
      await expectLater(
        repository.thumbnail(_fish),
        _failure(FishCatalogFailure.noData),
      );
      now = now.add(const Duration(hours: 5));
      await expectLater(
        repository.thumbnail(_fish),
        _failure(FishCatalogFailure.noData),
      );
      expect(service.thumbnailCalls, 1);
      final restart = FishSpeciesRepository(service: service, clock: () => now);
      await expectLater(
        restart.thumbnail(_fish),
        _failure(FishCatalogFailure.noData),
      );
      expect(service.thumbnailCalls, 1);
      now = now.add(const Duration(hours: 2));
      await expectLater(
        repository.thumbnail(_fish),
        _failure(FishCatalogFailure.noData),
      );
      expect(service.thumbnailCalls, 2);
      service.thumbnails = (_) async => _detail;
      expect(
        (await repository.thumbnail(_fish, forceRefresh: true)).imageUrl,
        _detail.imageUrl,
      );
      expect(service.thumbnailForces, [false, false, true]);
    },
  );

  test(
    'transient thumbnail misses cool down briefly and forced retry is immediate',
    () async {
      var now = DateTime.utc(2026, 11, 5);
      final service = _Service()
        ..thumbnails = (_) async =>
            throw const FishCatalogException(FishCatalogFailure.rateLimited);
      final repository = FishSpeciesRepository(
        service: service,
        clock: () => now,
      );
      await expectLater(
        repository.thumbnail(_fish),
        _failure(FishCatalogFailure.rateLimited),
      );
      now = now.add(const Duration(seconds: 29));
      await expectLater(
        repository.thumbnail(_fish),
        _failure(FishCatalogFailure.rateLimited),
      );
      expect(service.thumbnailCalls, 1);
      now = now.add(const Duration(seconds: 2));
      await expectLater(
        repository.thumbnail(_fish),
        _failure(FishCatalogFailure.rateLimited),
      );
      expect(service.thumbnailCalls, 2);
      service.thumbnails = (_) async => _detail;
      await repository.thumbnail(_fish, forceRefresh: true);
      expect(service.thumbnailCalls, 3);
    },
  );

  test(
    'offline thumbnail requests never call a provider and retain old photos',
    () async {
      var now = DateTime.utc(2026, 11, 5);
      final service = _Service();
      final repository = FishSpeciesRepository(
        service: service,
        clock: () => now,
      );
      await expectLater(
        repository.thumbnail(_fish, allowNetwork: false),
        _failure(FishCatalogFailure.network),
      );
      expect(service.thumbnailCalls, 0);
      await repository.thumbnail(_fish);
      now = now.add(const Duration(days: 40));
      expect(
        (await repository.thumbnail(_fish, allowNetwork: false)).imageUrl,
        _detail.imageUrl,
      );
      expect(service.thumbnailCalls, 1);
    },
  );

  test(
    'identical pending thumbnail requests share one source lookup',
    () async {
      final pending = Completer<FishSpecies>();
      final service = _Service()..thumbnails = (_) => pending.future;
      final repository = FishSpeciesRepository(service: service);
      final first = repository.thumbnail(_fish);
      final second = repository.thumbnail(_fish);
      await Future<void>.delayed(Duration.zero);
      expect(service.thumbnailCalls, 1);
      pending.complete(_detail);
      expect((await first).imageUrl, (await second).imageUrl);
    },
  );

  test(
    'wrong thumbnail identity cannot be accepted or reused for another fish',
    () async {
      final service = _Service();
      final repository = FishSpeciesRepository(service: service);
      const other = FishSpecies(
        id: 'nifs:2',
        name: '참돔',
        scientificName: 'Pagrus major',
      );
      await expectLater(
        repository.thumbnail(other),
        _failure(FishCatalogFailure.invalidResponse),
      );
      await repository.thumbnail(_fish);
      const changed = FishSpecies(
        id: 'nifs:1',
        name: '다른 이름',
        scientificName: 'Other species',
      );
      await expectLater(
        repository.thumbnail(changed, allowNetwork: false),
        _failure(FishCatalogFailure.network),
      );
    },
  );

  test('thumbnail cache is bounded separately from complete details', () async {
    final service = _Service()
      ..thumbnails = (base) async => FishSpecies(
        id: base.id,
        name: base.name,
        scientificName: base.scientificName,
        imageUrl: _detail.imageUrl,
      );
    final repository = FishSpeciesRepository(service: service, maxDetails: 1);
    await repository.thumbnail(_fish);
    const other = FishSpecies(
      id: 'nifs:2',
      name: '참돔',
      scientificName: 'Pagrus major',
    );
    await repository.thumbnail(other);
    await expectLater(
      repository.thumbnail(_fish, allowNetwork: false),
      _failure(FishCatalogFailure.network),
    );
    expect(
      (await repository.thumbnail(other, allowNetwork: false)).imageUrl,
      _detail.imageUrl,
    );
  });

  test(
    'unsafe thumbnail URLs cannot become successful public cache entries',
    () async {
      final service = _Service();
      final repository = FishSpeciesRepository(service: service);
      for (final url in [
        'http://example.org/fish.jpg',
        '/fish.jpg',
        'data:image/png;base64,AA',
        'https://user:secret@example.org/fish.jpg',
      ]) {
        service.thumbnails = (_) async => FishSpecies(
          id: _fish.id,
          name: _fish.name,
          scientificName: _fish.scientificName,
          imageUrl: url,
        );
        await expectLater(
          repository.thumbnail(_fish, forceRefresh: true),
          _failure(FishCatalogFailure.invalidResponse),
        );
        await expectLater(
          repository.thumbnail(_fish, allowNetwork: false),
          _failure(FishCatalogFailure.network),
        );
      }
      expect(service.thumbnailCalls, 4);
    },
  );

  test(
    'adding a provider re-enriches even a fresh detail while retaining offline data',
    () async {
      final service = _VersionedService();
      final repository = FishSpeciesRepository(service: service);
      await repository.detail(_fish);
      service.namespace = 'v2';
      expect(
        (await repository.detail(_fish, allowNetwork: false)).feature,
        _detail.feature,
      );
      expect(service.detailCalls, 1);
      await repository.detail(_fish);
      expect(service.detailCalls, 2);
    },
  );

  test('a partial result is revisited sooner than a complete result', () async {
    var now = DateTime.utc(2026, 11, 5);
    final service = _Service()..details = (_) async => _fish;
    final repository = FishSpeciesRepository(
      service: service,
      clock: () => now,
    );
    await repository.detail(_fish);
    now = now.add(const Duration(hours: 5));
    await repository.detail(_fish);
    expect(service.detailCalls, 1);
    now = now.add(const Duration(hours: 2));
    await repository.detail(_fish);
    expect(service.detailCalls, 2);
  });

  test(
    'refresh supplies previously verified fields for partial-source fallback',
    () async {
      final service = _Service();
      final repository = FishSpeciesRepository(service: service);
      await repository.detail(_fish);
      service.details = (base) async {
        expect(base.feature, _detail.feature);
        expect(base.imageUrl, _detail.imageUrl);
        expect(base.photoLicenseUrl, _detail.photoLicenseUrl);
        return base;
      };
      final refreshed = await repository.detail(_fish, forceRefresh: true);
      expect(refreshed.feature, _detail.feature);
      expect(refreshed.imageUrl, _detail.imageUrl);
    },
  );

  test(
    'transient partial results are retained but become eligible again after 30 seconds',
    () async {
      var now = DateTime.utc(2026, 11, 5);
      const transient = FishSpecies(
        id: 'nifs:1',
        name: '감성돔',
        scientificName: 'Acanthopagrus schlegelii',
        feature: '확인된 설명',
        detailNeedsRetry: true,
      );
      final service = _Service()..details = (_) async => transient;
      final repository = FishSpeciesRepository(
        service: service,
        clock: () => now,
      );
      await repository.detail(_fish);
      now = now.add(const Duration(seconds: 29));
      await repository.detail(_fish);
      expect(service.detailCalls, 1);
      now = now.add(const Duration(seconds: 2));
      await repository.detail(_fish);
      expect(service.detailCalls, 2);
    },
  );

  test('offline restart restores catalog and enriched details', () async {
    final initial = FishSpeciesRepository(service: _Service());
    await initial.load();
    await initial.detail(_fish);
    final unused = _Service();
    final restored = FishSpeciesRepository(service: unused);
    final snapshot = await restored.load(allowNetwork: false);
    expect(snapshot.items.single.scientificName, _fish.scientificName);
    expect(snapshot.items.single.imageUrl, _detail.imageUrl);
    expect(snapshot.items.single.photoLicenseUrl, _detail.photoLicenseUrl);
    expect(
      snapshot.items.single.descriptionSourceUrl,
      _detail.descriptionSourceUrl,
    );
    expect(snapshot.isFromCache, isTrue);
    expect(
      (await restored.detail(_fish, allowNetwork: false)).imageUrl,
      _detail.imageUrl,
    );
    expect(
      (await restored.detail(
        _fish,
        allowNetwork: false,
      )).descriptionAttribution,
      _detail.descriptionAttribution,
    );
    expect(unused.catalogCalls, 0);
    expect(unused.detailCalls, 0);
  });

  test(
    'simultaneous callers share pending catalog and detail requests',
    () async {
      final catalog = Completer<List<FishSpecies>>();
      final details = Completer<FishSpecies>();
      final service = _Service();
      service.catalog = () => catalog.future;
      service.details = (_) => details.future;
      final repository = FishSpeciesRepository(service: service);
      final lists = [repository.load(), repository.load()];
      await Future<void>.delayed(Duration.zero);
      expect(service.catalogCalls, 1);
      catalog.complete([_fish]);
      await Future.wait(lists);
      final fish = [repository.detail(_fish), repository.detail(_fish)];
      await Future<void>.delayed(Duration.zero);
      expect(service.detailCalls, 1);
      details.complete(_detail);
      expect(await Future.wait(fish), everyElement(same(_detail)));
    },
  );

  test('expiry and force refresh trigger one new catalog request', () async {
    var now = DateTime.utc(2026, 11, 4);
    final service = _Service();
    final repository = FishSpeciesRepository(
      service: service,
      clock: () => now,
    );
    await repository.load();
    await repository.load();
    expect(service.catalogCalls, 1);
    now = now.add(const Duration(days: 1));
    await repository.load();
    expect(service.catalogCalls, 2);
    await repository.load(forceRefresh: true);
    expect(service.catalogCalls, 3);
  });

  test('failed refresh preserves stale catalog and reports failure', () async {
    var now = DateTime.utc(2026, 11, 4);
    final service = _Service();
    final repository = FishSpeciesRepository(
      service: service,
      clock: () => now,
    );
    await repository.load();
    now = now.add(const Duration(days: 2));
    service.catalog = () async =>
        throw const FishCatalogException(FishCatalogFailure.unauthorized);
    final snapshot = await repository.load();
    expect(snapshot.items.single.id, _fish.id);
    expect(snapshot.isFromCache, isTrue);
    expect(snapshot.isStale, isTrue);
    expect(snapshot.failure, FishCatalogFailure.unauthorized);
  });

  test('offline without cache fails without contacting provider', () async {
    final service = _Service();
    final repository = FishSpeciesRepository(service: service);
    await expectLater(
      repository.load(allowNetwork: false),
      throwsA(isA<FishCatalogException>()),
    );
    await expectLater(
      repository.detail(_fish, allowNetwork: false),
      throwsA(isA<FishCatalogException>()),
    );
    expect(service.catalogCalls + service.detailCalls, 0);
  });

  test('invalid disk cache does not prevent fresh online load', () async {
    SharedPreferences.setMockInitialValues({
      'fish_encyclopedia_cache_v1': '{broken',
      'unrelated': 'preserved',
    });
    final repository = FishSpeciesRepository(service: _Service());
    expect((await repository.load()).items.single.id, _fish.id);
    expect(
      (await SharedPreferences.getInstance()).getString('unrelated'),
      'preserved',
    );
  });

  test(
    'storage failure never converts successful provider data to failure',
    () async {
      final repository = FishSpeciesRepository(
        service: _Service(),
        preferences: () async => throw StateError('disk unavailable'),
      );
      expect((await repository.load()).items.single.id, _fish.id);
      expect((await repository.detail(_fish)).feature, '공식 설명');
    },
  );

  test(
    'missing detail key is not cached and a later retry can load detail',
    () async {
      final service = _Service()
        ..details = (_) async =>
            throw const FishCatalogException(FishCatalogFailure.configuration);
      final repository = FishSpeciesRepository(service: service);
      await expectLater(
        repository.detail(_fish),
        throwsA(isA<FishCatalogException>()),
      );
      service.details = (_) async => _detail;
      expect((await repository.detail(_fish)).imageUrl, _detail.imageUrl);
      expect(service.detailCalls, 2);
    },
  );

  test(
    'changed identity cannot reuse or accept another species detail',
    () async {
      final service = _Service();
      final repository = FishSpeciesRepository(service: service);
      await repository.detail(_fish);
      const renamed = FishSpecies(
        id: 'nifs:1',
        name: '다른 어종',
        scientificName: 'Other fish',
      );
      await expectLater(
        repository.detail(renamed, allowNetwork: false),
        throwsA(isA<FishCatalogException>()),
      );
      await expectLater(
        repository.detail(renamed),
        throwsA(isA<FishCatalogException>()),
      );
      expect(service.detailCalls, 2);
    },
  );

  test('detail cache is bounded and oldest entry is removed', () async {
    final service = _Service()..details = (fish) async => fish;
    final repository = FishSpeciesRepository(service: service, maxDetails: 1);
    await repository.detail(_fish);
    const other = FishSpecies(id: 'nifs:2', name: '참돔');
    await repository.detail(other);
    await expectLater(
      repository.detail(_fish, allowNetwork: false),
      throwsA(isA<FishCatalogException>()),
    );
    expect(await repository.detail(other, allowNetwork: false), same(other));
  });

  test(
    'duplicate species identifiers cannot replace a valid catalog',
    () async {
      final service = _Service();
      final repository = FishSpeciesRepository(service: service);
      await repository.load();
      service.catalog = () async => [_fish, _fish];
      final snapshot = await repository.load(forceRefresh: true);
      expect(snapshot.failure, FishCatalogFailure.invalidResponse);
      expect(snapshot.items, hasLength(1));
    },
  );
}
