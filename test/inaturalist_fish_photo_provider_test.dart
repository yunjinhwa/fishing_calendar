import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fishing_build/data/fish/fish_catalog_service.dart';
import 'package:fishing_build/data/fish/inaturalist_fish_photo_provider.dart';
import 'package:fishing_build/data/models/fish_species.dart';
import 'package:flutter_test/flutter_test.dart';

const _fish = FishSpecies(
  id: 'nifs:flounder',
  name: '넙치',
  scientificName: 'Paralichthys olivaceus',
  aliases: ['광어'],
  feature: '이미 검증한 설명',
  maxSize: '명시적 최대 길이',
  descriptionSourceUrl: 'https://www.mbris.kr/',
  sourceName: '국립수산과학원',
);

void main() {
  late _Adapter adapter;
  late Dio dio;
  late InaturalistFishPhotoProvider provider;
  setUp(() {
    adapter = _Adapter((_) => _envelope([_taxon()]));
    dio = Dio()..httpClientAdapter = adapter;
    provider = InaturalistFishPhotoProvider(
      dio: dio,
      requestSpacing: Duration.zero,
    );
  });
  tearDown(() => dio.close(force: true));

  test(
    'exact active species photo preserves all caller description and identity',
    () async {
      final result = await provider.fetchDetail(_fish);
      expect(result.id, _fish.id);
      expect(result.name, _fish.name);
      expect(result.scientificName, _fish.scientificName);
      expect(result.feature, _fish.feature);
      expect(result.maxSize, _fish.maxSize);
      expect(result.descriptionSourceUrl, _fish.descriptionSourceUrl);
      expect(
        result.imageUrl,
        'https://static.inaturalist.org/photos/45/medium.jpeg',
      );
      expect(result.photoSourceUrl, 'https://www.inaturalist.org/photos/45');
      expect(result.photoAttribution, 'Test photographer · CC BY 4.0');
      expect(
        result.photoLicenseUrl,
        'https://creativecommons.org/licenses/by/4.0/',
      );
      expect(result.sourceName, '국립수산과학원 · iNaturalist');
      expect(adapter.calls, hasLength(1));
      expect(adapter.calls.single.queryParameters['rank'], 'species');
      expect(adapter.calls.single.queryParameters['locale'], 'ko');
      expect(
        adapter.calls.single.headers.containsKey('Authorization'),
        isFalse,
      );
    },
  );

  for (final code in ['cc0', 'cc-by', 'cc-by-sa']) {
    test('allows only explicitly supported photo license $code', () async {
      adapter.respond = (_) =>
          _envelope([_taxon(photo: _photo(license: code))]);
      final result = await provider.fetchDetail(_fish);
      expect(
        result.photoLicenseUrl,
        startsWith('https://creativecommons.org/'),
      );
      expect(result.photoAttribution, contains('Test photographer'));
    });
  }

  test(
    'unlicensed default falls back to a matching taxon photo in one additional call',
    () async {
      adapter.respond = (call) => call.uri.path.endsWith('/361763')
          ? _envelope([
              _taxon(photos: [_linkedPhoto(_photo(license: 'cc-by-sa'))]),
            ])
          : _envelope([_taxon(photo: _photo(license: null))]);
      final result = await provider.fetchDetail(_fish);
      expect(result.photoAttribution, contains('CC BY-SA 4.0'));
      expect(adapter.calls, hasLength(2));
    },
  );

  test('rejects NC ND unknown and all-rights-reserved photos', () async {
    final rejected = [
      null,
      'cc-by-nc',
      'cc-by-nc-sa',
      'cc-by-nd',
      'cc-by-nc-nd',
      'gfdl',
      'C',
    ];
    adapter.respond = (_) => _envelope([
      _taxon(
        photo: _photo(license: null),
        photos: [
          for (final code in rejected) _linkedPhoto(_photo(license: code)),
        ],
      ),
    ]);
    await expectLater(
      provider.fetchDetail(_fish),
      _failure(FishCatalogFailure.noData),
    );
    expect(adapter.calls, hasLength(2));
  });

  test(
    'does not guess an ambiguous exact taxon or a truncated search',
    () async {
      adapter.respond = (_) => _envelope([_taxon(), _taxon(id: 999)]);
      await expectLater(
        provider.fetchDetail(_fish),
        _failure(FishCatalogFailure.noData),
      );
      expect(adapter.calls, hasLength(1));
      adapter.respond = (_) => {
        ..._envelope([_taxon()]),
        'total_results': 6,
      };
      await expectLater(
        provider.fetchDetail(_fish),
        _failure(FishCatalogFailure.noData),
      );
      expect(adapter.calls, hasLength(2));
    },
  );

  test('rejects fuzzy species names inactive taxa and subspecies', () async {
    for (final patch in [
      {'name': 'Paralichthys dentatus'},
      {'is_active': false},
      {'rank': 'subspecies'},
      {'provisional': true},
    ]) {
      adapter.respond = (_) => _envelope([
        {..._taxon(), ...patch},
      ]);
      await expectLater(
        provider.fetchDetail(_fish),
        _failure(FishCatalogFailure.noData),
      );
    }
    expect(adapter.calls, hasLength(4));
  });

  test(
    'Korean common-name conflict is rejected while caller alias is accepted',
    () async {
      adapter.respond = (_) => _envelope([
        {..._taxon(), 'preferred_common_name': '다른 어종'},
      ]);
      await expectLater(
        provider.fetchDetail(_fish),
        _failure(FishCatalogFailure.noData),
      );
      adapter.respond = (_) => _envelope([
        {..._taxon(), 'preferred_common_name': '광어'},
      ]);
      expect((await provider.fetchDetail(_fish)).imageUrl, isNotNull);
    },
  );

  test(
    'a verified exact species without Korean name may provide a photo',
    () async {
      adapter.respond = (_) => _envelope([
        {..._taxon(), 'preferred_common_name': 'Olive flounder'},
      ]);
      expect((await provider.fetchDetail(_fish)).imageUrl, isNotNull);
    },
  );

  test('detail identity and each embedded photo taxon must match', () async {
    final mutations = [
      {'taxon_id': 999},
      {
        'taxon': {..._taxon(), 'id': 999},
      },
      {
        'taxon': {..._taxon(), 'name': 'Another species'},
      },
      {
        'taxon': {..._taxon(), 'preferred_common_name': '다른 어종'},
      },
      {'taxon': null},
    ];
    adapter.respond = (_) => _envelope([
      _taxon(
        photo: _photo(license: null),
        photos: [
          for (final patch in mutations) {..._linkedPhoto(_photo()), ...patch},
        ],
      ),
    ]);
    await expectLater(
      provider.fetchDetail(_fish),
      _failure(FishCatalogFailure.noData),
    );
    expect(adapter.calls, hasLength(2));
  });

  test(
    'unsafe image URLs unknown authors and flagged photos are never used',
    () async {
      final invalid = [
        {
          ..._photo(),
          'medium_url': 'http://static.inaturalist.org/photos/45/medium.jpeg',
        },
        {
          ..._photo(),
          'medium_url':
              'https://static.inaturalist.org.evil.test/photos/45/medium.jpeg',
        },
        {
          ..._photo(),
          'medium_url':
              'https://user:secret@static.inaturalist.org/photos/45/medium.jpeg',
        },
        {
          ..._photo(),
          'medium_url': 'https://static.inaturalist.org/photos/999/medium.jpeg',
        },
        {
          ..._photo(),
          'medium_url': 'https://static.inaturalist.org/photos/45/medium.svg',
        },
        {
          ..._photo(),
          'medium_url':
              'https://static.inaturalist.org/photos/45/medium.jpeg?redirect=1',
        },
        {..._photo(), 'attribution_name': 'Unknown'},
        {..._photo(), 'attribution_name': ''},
        {
          ..._photo(),
          'flags': [{}],
        },
        {..._photo(), 'flags': null},
      ];
      adapter.respond = (_) => _envelope([
        _taxon(
          photo: _photo(license: null),
          photos: [for (final photo in invalid) _linkedPhoto(photo)],
        ),
      ]);
      await expectLater(
        provider.fetchDetail(_fish),
        _failure(FishCatalogFailure.noData),
      );
      expect(adapter.calls, hasLength(2));
    },
  );

  test(
    'bounded taxon photo scan does not inspect unlimited candidates',
    () async {
      adapter.respond = (_) => _envelope([
        _taxon(
          photo: _photo(license: null),
          photos: [
            for (var i = 0; i < 16; i++) _linkedPhoto(_photo(license: null)),
            _linkedPhoto(_photo()),
          ],
        ),
      ]);
      await expectLater(
        provider.fetchDetail(_fish),
        _failure(FishCatalogFailure.noData),
      );
      expect(adapter.calls, hasLength(2));
    },
  );

  test('S3-hosted licensed taxon image is accepted', () async {
    adapter.respond = (_) => _envelope([
      _taxon(
        photo: {
          ..._photo(),
          'medium_url':
              'https://inaturalist-open-data.s3.amazonaws.com/photos/45/medium.JPG',
        },
      ),
    ]);
    expect(
      (await provider.fetchDetail(_fish)).imageUrl,
      contains('s3.amazonaws.com'),
    );
  });

  test('no data remains no data and does not retry endlessly', () async {
    adapter.respond = (_) => _envelope([]);
    await expectLater(
      provider.fetchDetail(_fish),
      _failure(FishCatalogFailure.noData),
    );
    expect(adapter.calls, hasLength(1));
  });

  test(
    'malformed JSON envelope and oversized response are typed failures',
    () async {
      for (final value in [
        'not-json',
        {'results': 'wrong'},
        'x' * (1024 * 1024 + 1),
      ]) {
        adapter.respond = (_) => value;
        await expectLater(
          provider.fetchDetail(_fish),
          _failure(FishCatalogFailure.invalidResponse),
        );
      }
    },
  );

  for (final pair in [
    (429, FishCatalogFailure.rateLimited),
    (403, FishCatalogFailure.unauthorized),
    (404, FishCatalogFailure.noData),
    (503, FishCatalogFailure.network),
    (302, FishCatalogFailure.network),
  ]) {
    test('HTTP ${pair.$1} becomes ${pair.$2.name}', () async {
      adapter.status = pair.$1;
      await expectLater(provider.fetchDetail(_fish), _failure(pair.$2));
      expect(adapter.calls, hasLength(1));
      expect(adapter.calls.single.followRedirects, isFalse);
    });
  }

  test(
    'in-flight sharing and bounded success cache preserve latest caller fields',
    () async {
      var now = DateTime.utc(2026, 11, 5);
      provider = InaturalistFishPhotoProvider(
        dio: dio,
        clock: () => now,
        requestSpacing: Duration.zero,
        maxCachedEntries: 1,
      );
      final gate = Completer<Object>();
      adapter.respond = (_) => gate.future;
      final first = provider.fetchDetail(_fish);
      final changed = FishSpecies.fromJson({
        ..._fish.toJson(),
        'feature': '갱신된 설명',
      });
      final second = provider.fetchDetail(changed);
      await adapter.started.future;
      gate.complete(_envelope([_taxon()]));
      await first;
      expect((await second).feature, changed.feature);
      expect(adapter.calls, hasLength(1));
      expect((await provider.fetchDetail(changed)).feature, changed.feature);
      expect(adapter.calls, hasLength(1));
      adapter.respond = (_) => _envelope([_taxon()]);
      now = now.add(const Duration(minutes: 6));
      await provider.fetchDetail(_fish);
      await provider.fetchDetail(_fish, forceRefresh: true);
      expect(adapter.calls, hasLength(3));
      await provider.fetchDetail(
        FishSpecies.fromJson({..._fish.toJson(), 'id': 'second'}),
      );
      await provider.fetchDetail(_fish);
      expect(adapter.calls, hasLength(5));
    },
  );

  test(
    'total deadline cancels a slow request without starting a second lookup',
    () async {
      final gate = Completer<Object>();
      adapter.respond = (_) => gate.future;
      provider = InaturalistFishPhotoProvider(
        dio: dio,
        requestSpacing: Duration.zero,
        totalTimeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        provider.fetchDetail(_fish),
        _failure(FishCatalogFailure.timedOut),
      );
      await adapter.cancelled.future;
      gate.complete(_envelope([_taxon(photo: _photo(license: null))]));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(adapter.calls, hasLength(1));
    },
  );

  test(
    'request pacing spaces distinct API calls and includes waiting in deadline',
    () async {
      adapter.respond = (_) => _envelope([
        _taxon(photo: _photo(license: null), photos: [_linkedPhoto(_photo())]),
      ]);
      provider = InaturalistFishPhotoProvider(
        dio: dio,
        requestSpacing: const Duration(milliseconds: 30),
      );
      await provider.fetchDetail(_fish);
      expect(
        adapter.startedAt.last.difference(adapter.startedAt.first),
        greaterThanOrEqualTo(const Duration(milliseconds: 25)),
      );
    },
  );
}

Map<String, Object?> _taxon({
  int id = 361763,
  Map<String, Object?>? photo,
  List<Object?>? photos,
}) => {
  'id': id,
  'name': 'Paralichthys olivaceus',
  'rank': 'species',
  'is_active': true,
  'preferred_common_name': '넙치',
  'default_photo': photo ?? _photo(),
  'taxon_photos': ?photos,
};
Map<String, Object?> _photo({String? license = 'cc-by'}) => {
  'id': 45,
  'license_code': license,
  'attribution_name': 'Test photographer',
  'flags': <Object>[],
  'medium_url': 'https://static.inaturalist.org/photos/45/medium.jpeg',
};
Map<String, Object?> _linkedPhoto(Map<String, Object?> photo) => {
  'taxon_id': 361763,
  'taxon': _taxon(),
  'photo': photo,
};
Map<String, Object?> _envelope(List<Map<String, Object?>> rows) => {
  'total_results': rows.length,
  'results': rows,
};
Matcher _failure(FishCatalogFailure reason) => throwsA(
  isA<FishCatalogException>().having((error) => error.reason, 'reason', reason),
);

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  FutureOr<Object> Function(RequestOptions) respond;
  final calls = <RequestOptions>[];
  final startedAt = <DateTime>[];
  final started = Completer<void>();
  final cancelled = Completer<void>();
  int status = 200;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(options);
    startedAt.add(DateTime.now());
    if (!started.isCompleted) started.complete();
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
