import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fishing_build/data/fish/fish_catalog_service.dart';
import 'package:fishing_build/data/fish/wikimedia_fish_detail_provider.dart';
import 'package:fishing_build/data/models/fish_species.dart';
import 'package:flutter_test/flutter_test.dart';

const _fish = FishSpecies(
  id: 'nifs:flounder',
  name: '넙치',
  scientificName: 'Paralichthys olivaceus',
  category: FishCategory.sea,
  family: '넙치과',
  habitat: '해수',
  aliases: ['광어'],
  sourceName: '국립수산과학원',
);
const _file = 'Paralichthys-olivaceus-Federal-Way-3583.jpg';

void main() {
  // Explicit opt-in only; regular tests never depend on public API availability.
  if (const bool.fromEnvironment('RUN_WIKIMEDIA_LIVE_PROBE')) {
    test(
      'live public Wikimedia provider probe',
      () async {
        final originalOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        final liveDio = Dio();
        final liveProvider = WikimediaFishDetailProvider(dio: liveDio);
        try {
          for (final base in const [
            FishSpecies(
              id: 'live-black-porgy',
              name: '감성돔',
              scientificName: 'Acanthopagrus schlegelii',
            ),
            FishSpecies(
              id: 'live-goby',
              name: '줄망둑',
              scientificName: 'Acentrogobius pflaumii',
              aliases: ['줄망둥어', '퉁눈매지'],
            ),
            FishSpecies(
              id: 'live-flounder',
              name: '넙치',
              scientificName: 'Paralichthys olivaceus',
            ),
          ]) {
            final elapsed = Stopwatch()..start();
            final report = <String, Object?>{
              'scientificName': base.scientificName,
            };
            try {
              final result = await liveProvider.fetchDetail(base);
              report.addAll({
                'description': result.feature.isNotEmpty,
                'photo': result.imageUrl != null,
                'attribution': result.photoAttribution,
                'photoSourceUrl': result.photoSourceUrl,
                'photoLicenseUrl': result.photoLicenseUrl,
                'detailNeedsRetry': result.detailNeedsRetry,
              });
              if (result.imageUrl != null) {
                final token = CancelToken();
                try {
                  final image = await liveDio.get<ResponseBody>(
                    result.imageUrl!,
                    cancelToken: token,
                    options: Options(
                      responseType: ResponseType.stream,
                      followRedirects: false,
                      receiveTimeout: const Duration(seconds: 8),
                      headers: {
                        'User-Agent':
                            'FishingBuild/1.0 (+https://fishingbuild.firebaseapp.com)',
                        'Range': 'bytes=0-2047',
                      },
                      validateStatus: (_) => true,
                    ),
                  );
                  report['imageStatus'] = image.statusCode;
                  report['imageMime'] = image.headers.value(
                    Headers.contentTypeHeader,
                  );
                  if (image.data != null) await image.data!.stream.first;
                } on Object catch (error) {
                  report['imageFailure'] = error.runtimeType.toString();
                } finally {
                  token.cancel();
                }
              }
            } on FishCatalogException catch (error) {
              report['failure'] = error.reason.name;
            }
            report['latencyMs'] = elapsed.elapsedMilliseconds;
            stdout.writeln(jsonEncode(report));
          }
        } finally {
          liveDio.close(force: true);
          HttpOverrides.global = originalOverrides;
        }
      },
      timeout: const Timeout(Duration(seconds: 100)),
    );
  }
  late _Adapter adapter;
  late Dio dio;
  late WikimediaFishDetailProvider provider;
  setUp(() {
    adapter = _Adapter(_response);
    dio = Dio()..httpClientAdapter = adapter;
    provider = WikimediaFishDetailProvider(dio: dio);
  });
  tearDown(() => dio.close(force: true));

  test(
    'an explicitly drawn P18 image is excluded without losing prose',
    () async {
      const file = 'Species_drawing.jpg';
      adapter.respond = (call) {
        if (call.queryParameters['action'] == 'wbgetentities') {
          return _entities({'Q1322753': _entity(file: file)});
        }
        if (call.uri.host == 'commons.wikimedia.org') {
          return _photo(title: 'File:$file');
        }
        return _response(call);
      };
      final result = await provider.fetchDetail(_fish);
      expect(result.imageUrl, isNull);
      expect(result.photoAttribution, isNull);
      expect(result.feature, isNotEmpty);
      expect(result.detailNeedsRetry, isFalse);
    },
  );

  test(
    'generic filenames cannot hide drawings identified in Commons metadata',
    () async {
      for (final field in ['ObjectName', 'ImageDescription', 'Categories']) {
        adapter.respond = (call) {
          if (call.uri.host == 'commons.wikimedia.org') {
            return _photo(
              objectName: field == 'ObjectName' ? 'Fish drawing' : '',
              imageDescription: field == 'ImageDescription'
                  ? '<div>A pencil drawing of the fish</div>'
                  : '',
              categories: field == 'Categories'
                  ? 'Fish drawings|Pencil drawings'
                  : '',
            );
          }
          return _response(call);
        };
        final result = await provider.fetchDetail(_fish, forceRefresh: true);
        expect(result.imageUrl, isNull, reason: field);
        expect(result.feature, isNotEmpty);
      }
      final photoRequest = adapter.calls.firstWhere(
        (call) => call.uri.host == 'commons.wikimedia.org',
      );
      final fields =
          (photoRequest.queryParameters['iiextmetadatafilter'] as String).split(
            '|',
          );
      expect(
        fields,
        containsAll(['ObjectName', 'ImageDescription', 'Categories']),
      );
    },
  );

  test(
    'a real museum specimen photograph with radiograph remains usable',
    () async {
      const specimen = FishSpecies(
        id: 'specimen',
        name: '가시가자미',
        scientificName: 'Acanthopsetta nadeshnyi',
      );
      const file = 'Acanthopsetta nadeshnyi.png';
      adapter.respond = (call) {
        if (call.queryParameters['action'] == 'wbsearchentities') {
          return {
            'search': [
              {'id': 'Q1097177'},
            ],
          };
        }
        if (call.queryParameters['action'] == 'wbgetentities') {
          return _entities({
            'Q1097177': _entity(
              scientific: specimen.scientificName,
              title: specimen.name,
              file: file,
            ),
          });
        }
        if (call.uri.host == 'ko.wikipedia.org') {
          return _page(id: 'Q1097177', title: specimen.name);
        }
        return _photo(
          title: 'File:$file',
          author: 'Voronina, Elena P.; Volkova, Galina A.',
          license: 'CC BY 4.0',
          licenseUrl: 'https://creativecommons.org/licenses/by/4.0/',
          sourceUrl:
              'https://commons.wikimedia.org/wiki/File:Acanthopsetta_nadeshnyi.png',
          objectName: 'Acanthopsetta nadeshnyi',
          imageDescription:
              'Syntypes ZIN 12345, photograph (A) and radiograph (B).',
          categories: 'Photographs of fish|X-ray images of fish',
        );
      };
      final result = await provider.fetchDetail(specimen);
      expect(result.imageUrl, isNotNull);
      expect(
        result.photoAttribution,
        'Voronina, Elena P.; Volkova, Galina A. · CC BY 4.0',
      );
      expect(
        result.photoLicenseUrl,
        'https://creativecommons.org/licenses/by/4.0/',
      );
    },
  );

  test(
    'a linked category supplies a photo only after exact MediaInfo depicts verification',
    () async {
      for (final useSitelink in [false, true]) {
        adapter.respond = (call) => _categoryResponse(
          call,
          category: useSitelink ? '' : 'Paralichthys olivaceus',
          commonsTitle: useSitelink ? 'Category:Paralichthys olivaceus' : '',
        );
        final result = await provider.fetchDetail(_fish, forceRefresh: true);
        expect(result.imageUrl, 'https://upload.wikimedia.org/fallback.jpg');
        expect(
          result.photoSourceUrl,
          'https://commons.wikimedia.org/wiki/File:Verified_fish.jpg',
        );
        expect(result.photoAttribution, 'User:Vmenkov · CC BY-SA 3.0');
        expect(
          result.photoLicenseUrl,
          'https://creativecommons.org/licenses/by-sa/3.0/',
        );
        expect(result.feature, isNotEmpty);
        expect(result.detailNeedsRetry, isFalse);
      }
      final entityRequest = adapter.calls.firstWhere(
        (call) => call.queryParameters['action'] == 'wbgetentities',
      );
      expect(entityRequest.queryParameters['sitefilter'], 'kowiki|commonswiki');
      expect(adapter.calls, hasLength(10));
    },
  );

  test(
    'wrong, mixed, missing, deprecated and mismatched MediaInfo identities are rejected',
    () async {
      for (final media in [
        _mediaInfo(depicts: ['Q1']),
        _mediaInfo(depicts: ['Q1322753', 'Q1']),
        _mediaInfo(depicts: []),
        _mediaInfo(rank: 'deprecated'),
        _mediaInfo(id: 'M999'),
      ]) {
        adapter.respond = (call) => _categoryResponse(call, media: media);
        final result = await provider.fetchDetail(_fish, forceRefresh: true);
        expect(result.imageUrl, isNull);
        expect(result.feature, isNotEmpty);
        expect(result.detailNeedsRetry, isFalse);
      }
    },
  );

  test(
    'category candidates retain license, author and safe URL guards',
    () async {
      final rejected = [
        _categoryFile(license: 'All rights reserved'),
        _categoryFile(author: 'Unknown author'),
        _categoryFile(imageUrl: 'http://upload.wikimedia.org/fish.jpg'),
        _categoryFile(sourceUrl: 'https://evil.example/file'),
        _categoryFile(title: 'File:Species_distribution_map.png'),
      ];
      for (final file in rejected) {
        final before = adapter.calls.length;
        adapter.respond = (call) => _categoryResponse(call, files: [file]);
        final result = await provider.fetchDetail(_fish, forceRefresh: true);
        expect(result.imageUrl, isNull);
        expect(result.feature, isNotEmpty);
        expect(
          adapter.calls
              .skip(before)
              .any(
                (call) =>
                    call.uri.host == 'commons.wikimedia.org' &&
                    call.queryParameters['action'] == 'wbgetentities',
              ),
          isFalse,
        );
      }
    },
  );

  test(
    'unusable P18 falls back within four files and never follows category continuation',
    () async {
      adapter.respond = (call) {
        if (call.uri.host == 'www.wikidata.org' &&
            call.queryParameters['action'] == 'wbgetentities') {
          return _entities({
            'Q1322753': _entity(category: 'Paralichthys olivaceus'),
          });
        }
        if (call.uri.host == 'commons.wikimedia.org') {
          if (call.queryParameters['generator'] == 'categorymembers') {
            return {
              'continue': {'gcmcontinue': 'ignored'},
              'query': {
                'pages': [
                  for (var id = 91; id < 101; id++) _categoryFile(id: id),
                ],
              },
            };
          }
          if (call.queryParameters['action'] == 'wbgetentities') {
            return _entities({
              for (var id = 91; id < 101; id++)
                'M$id': _mediaInfo(
                  id: 'M$id',
                  depicts: id == 94 ? ['Q1322753'] : ['Q1'],
                ),
            });
          }
          return _photo(license: 'All rights reserved');
        }
        return _response(call);
      };
      final result = await provider.fetchDetail(_fish);
      expect(result.imageUrl, isNotNull);
      expect(adapter.calls, hasLength(6));
      final categories = adapter.calls.where(
        (call) => call.queryParameters['generator'] == 'categorymembers',
      );
      expect(categories, hasLength(1));
      expect(categories.single.queryParameters['gcmtype'], 'file');
      expect(categories.single.queryParameters['gcmlimit'], 4);
      expect(
        adapter.calls.any(
          (call) => call.queryParameters.containsKey('gcmcontinue'),
        ),
        isFalse,
      );
      expect(adapter.calls.last.queryParameters['ids'], 'M91|M92|M93|M94');
    },
  );

  test(
    'unlinked gallery names and malformed categories never trigger category search',
    () async {
      for (final category in ['', 'unsafe|other', 'unsafe#fragment']) {
        adapter.respond = (call) => _categoryResponse(
          call,
          category: category,
          commonsTitle: 'Paralichthys olivaceus',
        );
        final result = await provider.fetchDetail(_fish, forceRefresh: true);
        expect(result.imageUrl, isNull);
        expect(result.feature, isNotEmpty);
      }
      expect(
        adapter.calls.any((call) => call.uri.host == 'commons.wikimedia.org'),
        isFalse,
      );
    },
  );

  test(
    'category failure keeps prose retryable and never enters the success cache',
    () async {
      adapter.respond = (call) {
        if (call.queryParameters['generator'] == 'categorymembers') {
          throw DioException(
            requestOptions: call,
            type: DioExceptionType.connectionError,
          );
        }
        return _categoryResponse(call);
      };
      for (var attempt = 0; attempt < 2; attempt++) {
        final result = await provider.fetchDetail(_fish);
        expect(result.feature, isNotEmpty);
        expect(result.imageUrl, isNull);
        expect(result.detailNeedsRetry, isTrue);
      }
      expect(adapter.calls, hasLength(8));
      adapter.respond = _categoryResponse;
      expect((await provider.fetchDetail(_fish)).imageUrl, isNotNull);
      expect(adapter.calls, hasLength(13));
      await provider.fetchDetail(_fish);
      expect(adapter.calls, hasLength(13));
    },
  );

  test(
    'category outage without usable prose remains a rate limit rather than noData',
    () async {
      adapter.respond = (call) {
        adapter.status = call.queryParameters['generator'] == 'categorymembers'
            ? 429
            : 200;
        if (call.uri.host == 'ko.wikipedia.org') return _page(extract: '');
        return _categoryResponse(call);
      };
      await expectLater(
        provider.fetchDetail(_fish),
        _failure(FishCatalogFailure.rateLimited),
      );
      expect(adapter.calls, hasLength(4));
    },
  );

  test(
    'nominate fallback verifies the selected subspecies and stays within seven calls',
    () async {
      const base = FishSpecies(
        id: 'black-porgy-fallback',
        name: '감성돔',
        scientificName: 'Acanthopagrus schlegelii',
      );
      adapter.respond = (call) {
        if (call.uri.host == 'www.wikidata.org' &&
            call.queryParameters['ids'] == 'Q1072544') {
          return _entities({
            'Q1072544': _entity(
              scientific: 'Acanthopagrus schlegelii schlegelii',
              title: '감성돔',
              parent: 'Q10398535',
              category: 'Acanthopagrus schlegelii schlegelii',
            ),
          });
        }
        if (call.uri.host == 'commons.wikimedia.org') {
          if (call.queryParameters['generator'] == 'categorymembers') {
            return {
              'query': {
                'pages': [_categoryFile()],
              },
            };
          }
          if (call.queryParameters['action'] == 'wbgetentities') {
            return _entities({
              'M91': _mediaInfo(depicts: ['Q1072544']),
            });
          }
          return _photo(license: 'All rights reserved');
        }
        return _nominateResponse(call);
      };
      final result = await provider.fetchDetail(base);
      expect(result.imageUrl, isNotNull);
      expect(result.sourceUrl, 'https://www.wikidata.org/wiki/Q1072544');
      expect(adapter.calls, hasLength(7));
    },
  );

  test(
    'list and detail callers share an in-flight lookup while keeping caller fields',
    () async {
      final firstSearch = Completer<Object>();
      adapter.respond = (call) {
        if (call.queryParameters['action'] == 'wbsearchentities') {
          return firstSearch.future;
        }
        if (call.uri.host == 'ko.wikipedia.org') return _page(extract: '');
        return _response(call);
      };
      final thumbnail = provider.fetchDetail(_fish);
      const base = FishSpecies(
        id: 'nifs:flounder',
        name: '넙치',
        scientificName: 'Paralichthys olivaceus',
        aliases: ['광어'],
        feature: 'MBRIS 설명',
        maxSize: '50 cm',
        descriptionSourceUrl: 'https://www.mbris.kr/species',
      );
      final detail = provider.fetchDetail(base);
      await adapter.started.future;
      expect(adapter.calls, hasLength(1));
      firstSearch.complete({
        'search': [
          {'id': 'Q1322753'},
        ],
      });
      expect((await thumbnail).imageUrl, isNotNull);
      final result = await detail;
      expect(result.feature, base.feature);
      expect(result.maxSize, base.maxSize);
      expect(result.descriptionSourceUrl, base.descriptionSourceUrl);
      expect(adapter.calls, hasLength(4));
    },
  );

  test('short success cache expires and force bypasses it', () async {
    var now = DateTime.utc(2026, 11, 5);
    final cached = WikimediaFishDetailProvider(dio: dio, clock: () => now);
    await cached.fetchDetail(_fish);
    await cached.fetchDetail(_fish);
    expect(adapter.calls, hasLength(4));
    now = now.add(const Duration(minutes: 6));
    await cached.fetchDetail(_fish);
    expect(adapter.calls, hasLength(8));
    await cached.fetchDetail(_fish, forceRefresh: true);
    expect(adapter.calls, hasLength(12));
  });

  test(
    'success RAM cache is bounded and includes common-name identity',
    () async {
      final cached = WikimediaFishDetailProvider(dio: dio, maxCachedEntries: 1);
      await cached.fetchDetail(_fish);
      const second = FishSpecies(
        id: 'second',
        name: '넙치',
        scientificName: 'Paralichthys olivaceus',
      );
      await cached.fetchDetail(second);
      await cached.fetchDetail(_fish);
      expect(adapter.calls, hasLength(12));
      adapter.respond = (call) {
        if (call.queryParameters['action'] == 'wbgetentities') {
          return _entities({'Q1322753': _entity(title: '광어')});
        }
        if (call.uri.host == 'ko.wikipedia.org') return _page(title: '광어');
        return _response(call);
      };
      await cached.fetchDetail(_fish, forceRefresh: true);
      const noAlias = FishSpecies(
        id: 'nifs:flounder',
        name: '넙치',
        scientificName: 'Paralichthys olivaceus',
      );
      await expectLater(
        cached.fetchDetail(noAlias),
        _failure(FishCatalogFailure.noData),
      );
    },
  );

  test(
    'transient partials do not hide a later retry behind the success cache',
    () async {
      adapter.respond = (call) {
        if (call.uri.host == 'ko.wikipedia.org') {
          return {
            'error': {'code': 'maxlag'},
          };
        }
        return _response(call);
      };
      expect((await provider.fetchDetail(_fish)).detailNeedsRetry, isTrue);
      adapter.respond = _response;
      expect((await provider.fetchDetail(_fish)).detailNeedsRetry, isFalse);
      expect(adapter.calls, hasLength(8));
    },
  );

  test(
    'keyless exact match preserves identity and includes licensed sources',
    () async {
      final result = await provider.fetchDetail(_fish);
      expect(result.id, _fish.id);
      expect(result.name, _fish.name);
      expect(result.scientificName, _fish.scientificName);
      expect(result.family, _fish.family);
      expect(result.category, _fish.category);
      expect(result.habitat, _fish.habitat);
      expect(result.aliases, _fish.aliases);
      expect(result.feature, '넙치의 한국어 설명입니다.');
      expect(result.imageUrl, 'https://upload.wikimedia.org/photo.jpg');
      expect(result.photoAttribution, 'User:Vmenkov · CC BY-SA 3.0');
      expect(
        result.photoSourceUrl,
        contains('commons.wikimedia.org/wiki/File:'),
      );
      expect(
        result.photoLicenseUrl,
        'https://creativecommons.org/licenses/by-sa/3.0/',
      );
      expect(Uri.parse(result.descriptionSourceUrl!).host, 'ko.wikipedia.org');
      expect(
        result.descriptionAttribution,
        contains('https://creativecommons.org/licenses/by-sa/4.0/'),
      );
      expect(result.sourceName, contains('국립수산과학원'));
      expect(result.sourceName, contains('Wikimedia Commons'));
      expect(adapter.calls, hasLength(4));
      for (final call in adapter.calls) {
        expect(call.uri.scheme, 'https');
        expect(call.followRedirects, isFalse);
        expect(
          call.headers['User-Agent'],
          'FishingBuild/1.0 (+https://fishingbuild.firebaseapp.com)',
        );
        expect(call.headers.containsKey('Authorization'), isFalse);
        expect(
          call.queryParameters.keys.any(
            (key) => ['key', 'apiKey', 'serviceKey'].contains(key),
          ),
          isFalse,
        );
      }
    },
  );

  test(
    'scientific claims must match exactly even when the common name agrees',
    () async {
      adapter.respond = (call) =>
          call.queryParameters['action'] == 'wbgetentities'
          ? _entities({
              'Q1322753': _entity(scientific: 'Paralichthys californicus'),
            })
          : _response(call);
      await expectLater(
        provider.fetchDetail(_fish),
        _failure(FishCatalogFailure.noData),
      );
      expect(adapter.calls, hasLength(2));
    },
  );

  test(
    'an exact result is selected after an unrelated search result',
    () async {
      adapter.respond = (call) {
        if (call.queryParameters['action'] == 'wbsearchentities') {
          return {
            'search': [
              {'id': 'Q1'},
              {'id': 'Q1322753'},
            ],
          };
        }
        if (call.queryParameters['action'] == 'wbgetentities') {
          return _entities({
            'Q1': _entity(scientific: 'Unrelated cell line'),
            'Q1322753': _entity(),
          });
        }
        return _response(call);
      };
      expect((await provider.fetchDetail(_fish)).feature, isNotEmpty);
      expect(adapter.calls[1].queryParameters['ids'], 'Q1|Q1322753');
    },
  );

  test('deprecated scientific claims cannot establish identity', () async {
    final entity = _entity();
    ((entity['claims'] as Map)['P225'] as List).first['rank'] = 'deprecated';
    adapter.respond = (call) =>
        call.queryParameters['action'] == 'wbgetentities'
        ? _entities({'Q1322753': entity})
        : _response(call);
    await expectLater(
      provider.fetchDetail(_fish),
      _failure(FishCatalogFailure.noData),
    );
  });

  test('Korean aliases and a final title parenthetical can agree', () async {
    adapter.respond = (call) {
      if (call.queryParameters['action'] == 'wbgetentities') {
        return _entities({'Q1322753': _entity(title: '광어 (어류)')});
      }
      if (call.uri.host == 'ko.wikipedia.org') return _page(title: '광어 (어류)');
      return _response(call);
    };
    final result = await provider.fetchDetail(_fish);
    expect(result.name, '넙치');
    expect(result.feature, isNotEmpty);
  });

  test(
    'Carassius auratus cannot attach a goldfish article to NIFS 붕어',
    () async {
      const base = FishSpecies(
        id: 'crucian',
        name: '붕어',
        scientificName: 'Carassius auratus',
      );
      adapter.respond = (call) =>
          call.queryParameters['action'] == 'wbgetentities'
          ? _entities({
              'Q1322753': _entity(
                scientific: 'Carassius auratus',
                title: '금붕어',
                file: 'Goldfish3.jpg',
              ),
            })
          : _response(call);
      await expectLater(
        provider.fetchDetail(base),
        _failure(FishCatalogFailure.noData),
      );
      expect(adapter.calls, hasLength(2));
      expect(
        adapter.calls.any((call) => call.uri.host == 'commons.wikimedia.org'),
        isFalse,
      );
    },
  );

  test(
    'a unique species can supply a licensed photo without a Korean article',
    () async {
      adapter.respond = (call) {
        if (call.queryParameters['action'] == 'wbgetentities') {
          return _entities({'Q1322753': _entity(title: '', koreanLabel: '넙치')});
        }
        if (call.uri.host == 'ko.wikipedia.org') return _missingPage();
        return _response(call);
      };
      final result = await provider.fetchDetail(_fish);
      expect(result.feature, isEmpty);
      expect(result.descriptionSourceUrl, isNull);
      expect(result.imageUrl, isNotNull);
      expect(result.photoAttribution, contains('CC BY-SA'));
      expect(result.photoLicenseUrl, isNotNull);
      expect(result.detailNeedsRetry, isFalse);
      expect(adapter.calls, hasLength(4));
    },
  );

  test(
    'missing Korean labels do not suppress an exactly identified species photo',
    () async {
      adapter.respond = (call) {
        if (call.queryParameters['action'] == 'wbgetentities') {
          return _entities({'Q1322753': _entity(title: '')});
        }
        if (call.uri.host == 'ko.wikipedia.org') return _missingPage();
        return _response(call);
      };
      final result = await provider.fetchDetail(_fish);
      expect(result.imageUrl, isNotNull);
      expect(result.feature, isEmpty);
    },
  );

  test(
    'a conflicting Korean label rejects a photo even without a Korean article',
    () async {
      adapter.respond = (call) =>
          call.queryParameters['action'] == 'wbgetentities'
          ? _entities({'Q1322753': _entity(title: '', koreanLabel: '금붕어')})
          : _response(call);
      await expectLater(
        provider.fetchDetail(_fish),
        _failure(FishCatalogFailure.noData),
      );
      expect(adapter.calls, hasLength(2));
    },
  );

  test(
    'a Korean Wikidata alias can confirm the name when its label differs',
    () async {
      adapter.respond = (call) {
        if (call.queryParameters['action'] == 'wbgetentities') {
          return _entities({
            'Q1322753': _entity(
              title: '',
              koreanLabel: '광어',
              koreanAliases: ['넙치'],
            ),
          });
        }
        if (call.uri.host == 'ko.wikipedia.org') return _missingPage();
        return _response(call);
      };
      expect((await provider.fetchDetail(_fish)).imageUrl, isNotNull);
      expect(
        adapter.calls[1].queryParameters['props'],
        contains('labels|aliases'),
      );
      expect(adapter.calls[1].queryParameters['languages'], 'ko');
    },
  );

  test(
    'a photo without a Korean article needs an explicit species rank',
    () async {
      for (final rank in ['', 'Q68947']) {
        adapter.respond = (call) {
          if (call.queryParameters['action'] == 'wbgetentities') {
            return _entities({'Q1322753': _entity(title: '', rank: rank)});
          }
          if (call.uri.host == 'ko.wikipedia.org') return _missingPage();
          return _response(call);
        };
        await expectLater(
          provider.fetchDetail(_fish),
          _failure(FishCatalogFailure.noData),
        );
      }
      expect(
        adapter.calls.any((call) => call.uri.host == 'commons.wikimedia.org'),
        isFalse,
      );
    },
  );

  test(
    'multiple exact species entities do not establish an unambiguous photo',
    () async {
      adapter.respond = (call) {
        if (call.queryParameters['action'] == 'wbsearchentities') {
          return {
            'search': [
              {'id': 'Q1'},
              {'id': 'Q1322753'},
            ],
          };
        }
        if (call.queryParameters['action'] == 'wbgetentities') {
          return _entities({
            'Q1': _entity(title: ''),
            'Q1322753': _entity(title: ''),
          });
        }
        return _response(call);
      };
      await expectLater(
        provider.fetchDetail(_fish),
        _failure(FishCatalogFailure.noData),
      );
      expect(adapter.calls, hasLength(2));
    },
  );

  test(
    'a transient article failure still returns a separately verified photo',
    () async {
      adapter.respond = (call) {
        if (call.queryParameters['action'] == 'wbgetentities') {
          return _entities({'Q1322753': _entity(title: '')});
        }
        if (call.uri.host == 'ko.wikipedia.org') {
          return {
            'error': {'code': 'maxlag'},
          };
        }
        return _response(call);
      };
      final result = await provider.fetchDetail(_fish);
      expect(result.imageUrl, isNotNull);
      expect(result.feature, isEmpty);
      expect(result.detailNeedsRetry, isTrue);
    },
  );

  test(
    'transient missing details propagate their real failure instead of noData',
    () async {
      for (final (type, reason) in [
        (DioExceptionType.connectionError, FishCatalogFailure.network),
        (DioExceptionType.receiveTimeout, FishCatalogFailure.timedOut),
      ]) {
        adapter.respond = (call) {
          if (call.queryParameters['action'] == 'wbgetentities') {
            return _entities({'Q1322753': _entity(file: '')});
          }
          if (call.uri.host == 'ko.wikipedia.org') {
            throw DioException(requestOptions: call, type: type);
          }
          return _response(call);
        };
        await expectLater(provider.fetchDetail(_fish), _failure(reason));
      }
      adapter.respond = (call) {
        if (call.queryParameters['action'] == 'wbgetentities') {
          return _entities({'Q1322753': _entity(file: '')});
        }
        if (call.uri.host == 'ko.wikipedia.org') {
          return {
            'error': {'code': 'maxlag'},
          };
        }
        return _response(call);
      };
      await expectLater(
        provider.fetchDetail(_fish),
        _failure(FishCatalogFailure.rateLimited),
      );
    },
  );

  test(
    'a photo metadata failure propagates when Korean prose is truly absent',
    () async {
      adapter.respond = (call) {
        if (call.uri.host == 'ko.wikipedia.org') return _page(extract: '');
        if (call.uri.host == 'commons.wikimedia.org') {
          throw DioException(
            requestOptions: call,
            type: DioExceptionType.connectionError,
          );
        }
        return _response(call);
      };
      await expectLater(
        provider.fetchDetail(_fish),
        _failure(FishCatalogFailure.network),
      );
    },
  );

  test(
    'confirmed absence remains noData without a retryable failure',
    () async {
      adapter.respond = (call) {
        if (call.queryParameters['action'] == 'wbgetentities') {
          return _entities({'Q1322753': _entity(title: '', file: '')});
        }
        if (call.uri.host == 'ko.wikipedia.org') return _missingPage();
        return _response(call);
      };
      await expectLater(
        provider.fetchDetail(_fish),
        _failure(FishCatalogFailure.noData),
      );
      expect(adapter.calls, hasLength(3));
    },
  );

  test(
    'a successful full refresh clears a prior transient retry flag',
    () async {
      const retrying = FishSpecies(
        id: 'same',
        name: '넙치',
        scientificName: 'Paralichthys olivaceus',
        detailNeedsRetry: true,
      );
      expect(
        (await provider.fetchDetail(
          retrying,
          forceRefresh: true,
        )).detailNeedsRetry,
        isFalse,
      );
    },
  );

  test(
    'an unauthorized optional article does not mark a valid photo transient',
    () async {
      adapter.respond = (call) {
        adapter.status = call.uri.host == 'ko.wikipedia.org' ? 403 : 200;
        return _response(call);
      };
      final result = await provider.fetchDetail(_fish);
      expect(result.imageUrl, isNotNull);
      expect(result.feature, isEmpty);
      expect(result.detailNeedsRetry, isFalse);
    },
  );

  test(
    'verified nominate subspecies supplies 감성돔 details in five requests',
    () async {
      // Live-verified Wikidata relationships: Q1072544 P225 is the repeated
      // epithet and P171 points directly to exact binomial Q10398535.
      const base = FishSpecies(
        id: 'black-porgy',
        name: '감성돔',
        scientificName: 'Acanthopagrus schlegelii',
      );
      adapter.respond = _nominateResponse;
      final result = await provider.fetchDetail(base);
      expect(result.id, base.id);
      expect(result.scientificName, base.scientificName);
      expect(result.feature, isNotEmpty);
      expect(result.sourceUrl, 'https://www.wikidata.org/wiki/Q1072544');
      expect(adapter.calls, hasLength(5));
    },
  );

  test(
    'a subspecies requires both repeated epithet and the exact direct parent',
    () async {
      const base = FishSpecies(
        id: 'black-porgy',
        name: '감성돔',
        scientificName: 'Acanthopagrus schlegelii',
      );
      for (final badParent in [false, true]) {
        adapter.respond = (call) {
          if (call.queryParameters['action'] == 'wbgetentities' &&
              call.queryParameters['ids'] == 'Q1072544') {
            return _entities({
              'Q1072544': _entity(
                scientific: badParent
                    ? 'Acanthopagrus schlegelii schlegelii'
                    : 'Acanthopagrus schlegelii other',
                title: '감성돔',
                parent: badParent ? 'Q1' : 'Q10398535',
              ),
            });
          }
          return _nominateResponse(call);
        };
        await expectLater(
          provider.fetchDetail(base),
          _failure(FishCatalogFailure.noData),
        );
      }
      expect(
        adapter.calls.any((call) => call.uri.host == 'commons.wikimedia.org'),
        isFalse,
      );
    },
  );

  test(
    'a changed Korean page entity cannot supply text, but verified photo survives',
    () async {
      adapter.respond = (call) => call.uri.host == 'ko.wikipedia.org'
          ? _page(id: 'Q1')
          : _response(call);
      final result = await provider.fetchDetail(_fish);
      expect(result.feature, isEmpty);
      expect(result.descriptionSourceUrl, isNull);
      expect(result.imageUrl, isNotNull);
    },
  );

  test('a different returned Korean title cannot supply text', () async {
    adapter.respond = (call) => call.uri.host == 'ko.wikipedia.org'
        ? _page(title: '다른 물고기')
        : _response(call);
    final result = await provider.fetchDetail(_fish);
    expect(result.feature, isEmpty);
    expect(result.imageUrl, isNotNull);
  });

  test('Commons metadata must describe a requested P18 file', () async {
    adapter.respond = (call) => call.uri.host == 'commons.wikimedia.org'
        ? _photo(title: 'File:unrelated.jpg')
        : _response(call);
    final result = await provider.fetchDetail(_fish);
    expect(result.feature, isNotEmpty);
    expect(result.imageUrl, isNull);
    expect(result.detailNeedsRetry, isFalse);
  });

  test(
    'unlicensed, noncommercial and no-derivatives photos are excluded',
    () async {
      for (final license in [
        '',
        'All rights reserved',
        'CC BY-NC 4.0',
        'CC BY-ND 4.0',
        'CC BY-NC-SA 4.0',
      ]) {
        adapter.respond = (call) => call.uri.host == 'commons.wikimedia.org'
            ? _photo(license: license)
            : _response(call);
        final result = await provider.fetchDetail(_fish);
        expect(result.imageUrl, isNull);
        expect(result.photoAttribution, isNull);
        expect(result.feature, isNotEmpty);
      }
    },
  );

  test(
    'CC BY, CC BY-SA, CC0 and public-domain metadata are accepted explicitly',
    () async {
      final licenses = [
        ('CC BY 4.0', 'https://creativecommons.org/licenses/by/4.0/', 'True'),
        (
          'CC BY-SA 3.0',
          'http://creativecommons.org/licenses/by-sa/3.0/',
          'True',
        ),
        ('CC0', '', 'False'),
        ('Public domain', '', 'False'),
      ];
      for (final (label, url, copyrighted) in licenses) {
        adapter.respond = (call) => call.uri.host == 'commons.wikimedia.org'
            ? _photo(license: label, licenseUrl: url, copyrighted: copyrighted)
            : _response(call);
        final result = await provider.fetchDetail(_fish, forceRefresh: true);
        expect(result.imageUrl, isNotNull);
        expect(result.photoAttribution, contains(label));
        expect(
          result.photoLicenseUrl,
          startsWith('https://creativecommons.org/'),
        );
      }
    },
  );

  test('missing or inferred authors are excluded', () async {
    for (final author in [
      '',
      'Unknown author',
      'No machine-readable author provided. Alice assumed',
    ]) {
      adapter.respond = (call) => call.uri.host == 'commons.wikimedia.org'
          ? _photo(author: author)
          : _response(call);
      expect((await provider.fetchDetail(_fish)).imageUrl, isNull);
    }
  });

  test('license URL must agree with the declared license', () async {
    for (final url in [
      'https://evil.example/licenses/by-sa/3.0/',
      'https://creativecommons.org/licenses/by-nc/3.0/',
      'javascript:alert(1)',
    ]) {
      adapter.respond = (call) => call.uri.host == 'commons.wikimedia.org'
          ? _photo(licenseUrl: url)
          : _response(call);
      expect((await provider.fetchDetail(_fish)).imageUrl, isNull);
    }
  });

  test('photo and file source URLs must use trusted HTTPS origins', () async {
    for (final url in [
      'http://upload.wikimedia.org/fish.jpg',
      'https://user:secret@upload.wikimedia.org/fish.jpg',
      'https://evil.example/fish.jpg',
      'data:image/png;base64,AA',
    ]) {
      adapter.respond = (call) => call.uri.host == 'commons.wikimedia.org'
          ? _photo(imageUrl: url)
          : _response(call);
      expect((await provider.fetchDetail(_fish)).imageUrl, isNull);
    }
    adapter.respond = (call) => call.uri.host == 'commons.wikimedia.org'
        ? _photo(sourceUrl: 'https://evil.example/file')
        : _response(call);
    expect((await provider.fetchDetail(_fish)).imageUrl, isNull);
  });

  test('photo failure preserves a real licensed Korean description', () async {
    adapter.respond = (call) {
      if (call.uri.host == 'commons.wikimedia.org') {
        throw DioException(
          requestOptions: call,
          type: DioExceptionType.connectionError,
        );
      }
      return _response(call);
    };
    final result = await provider.fetchDetail(_fish);
    expect(result.feature, isNotEmpty);
    expect(result.imageUrl, isNull);
    expect(result.descriptionAttribution, contains('CC BY-SA 4.0'));
    expect(result.detailNeedsRetry, isTrue);
  });

  test('description failure preserves a licensed photo', () async {
    adapter.respond = (call) {
      if (call.uri.host == 'ko.wikipedia.org') {
        throw DioException(
          requestOptions: call,
          type: DioExceptionType.connectionError,
        );
      }
      return _response(call);
    };
    final result = await provider.fetchDetail(_fish);
    expect(result.feature, isEmpty);
    expect(result.imageUrl, isNotNull);
    expect(result.detailNeedsRetry, isTrue);
    expect(result.photoSourceUrl, isNotNull);
  });

  test('missing text and rejected photo return noData', () async {
    adapter.respond = (call) {
      if (call.uri.host == 'ko.wikipedia.org') return _page(extract: '');
      if (call.uri.host == 'commons.wikimedia.org') {
        return _photo(license: 'All rights reserved');
      }
      return _response(call);
    };
    await expectLater(
      provider.fetchDetail(_fish),
      _failure(FishCatalogFailure.noData),
    );
  });

  test('text requires the returned Wikipedia license and is bounded', () async {
    adapter.respond = (call) => call.uri.host == 'ko.wikipedia.org'
        ? _page(extract: '가' * 2000)
        : _response(call);
    expect((await provider.fetchDetail(_fish)).feature.length, 1000);
    adapter.respond = (call) => call.uri.host == 'ko.wikipedia.org'
        ? _page(rightsUrl: 'https://evil.example/license')
        : _response(call);
    expect(
      (await provider.fetchDetail(_fish, forceRefresh: true)).feature,
      isEmpty,
    );
  });

  test(
    'empty identities make no call and repository controls refresh caching',
    () async {
      await expectLater(
        provider.fetchDetail(const FishSpecies(id: 'empty', name: '넙치')),
        _failure(FishCatalogFailure.noData),
      );
      expect(adapter.calls, isEmpty);
      await provider.fetchDetail(_fish);
      await provider.fetchDetail(_fish, forceRefresh: true);
      expect(adapter.calls, hasLength(8));
    },
  );

  test(
    'HTTP redirects, limits and malformed responses remain sanitized',
    () async {
      adapter.status = 302;
      await expectLater(
        provider.fetchDetail(_fish),
        _failure(FishCatalogFailure.network),
      );
      adapter.status = 429;
      await expectLater(
        provider.fetchDetail(_fish),
        _failure(FishCatalogFailure.rateLimited),
      );
      adapter.status = 200;
      adapter.respond = (_) => {
        'error': {'code': 'maxlag', 'info': 'private provider text'},
      };
      await expectLater(
        provider.fetchDetail(_fish),
        _failure(FishCatalogFailure.rateLimited),
      );
      adapter.respond = (_) => '<html>unavailable</html>';
      await expectLater(
        provider.fetchDetail(_fish),
        _failure(FishCatalogFailure.invalidResponse),
      );
      expect(
        const FishCatalogException(FishCatalogFailure.network).toString(),
        isNot(contains('provider text')),
      );
    },
  );

  test('response size is capped at one MiB', () async {
    adapter.respond = (_) => ' ' * (1024 * 1024 + 1);
    await expectLater(
      provider.fetchDetail(_fish),
      _failure(FishCatalogFailure.invalidResponse),
    );
    expect(adapter.calls, hasLength(1));
  });

  test(
    'total deadline cancels a stalled request before the per-call timeout',
    () async {
      adapter.respond = (_) => Completer<Object>().future;
      final limited = WikimediaFishDetailProvider(
        dio: dio,
        requestTimeout: const Duration(seconds: 1),
        totalTimeout: const Duration(seconds: 2),
      ).withDeadline(const Duration(milliseconds: 25));
      final elapsed = Stopwatch()..start();
      await expectLater(
        limited.fetchDetail(_fish),
        _failure(FishCatalogFailure.timedOut),
      );
      await adapter.cancelled.future.timeout(const Duration(milliseconds: 200));
      expect(elapsed.elapsed, lessThan(const Duration(milliseconds: 500)));
      expect(adapter.calls, hasLength(1));
      expect(
        adapter.calls.single.receiveTimeout,
        lessThanOrEqualTo(const Duration(milliseconds: 25)),
      );
    },
  );

  test(
    'serial work shares the overall deadline and starts no later requests',
    () async {
      adapter.respond = (call) async {
        await Future<void>.delayed(const Duration(milliseconds: 35));
        return _response(call);
      };
      final limited = WikimediaFishDetailProvider(
        dio: dio,
        requestTimeout: const Duration(seconds: 1),
        totalTimeout: const Duration(milliseconds: 80),
      );
      await expectLater(
        limited.fetchDetail(_fish),
        throwsA(isA<FishCatalogException>()),
      );
      final count = adapter.calls.length;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(adapter.calls, hasLength(count));
      expect(count, lessThanOrEqualTo(3));
    },
  );
}

Object _response(RequestOptions call) {
  if (call.queryParameters['action'] == 'wbsearchentities') {
    return {
      'search': [
        {'id': 'Q1322753'},
      ],
      'success': 1,
    };
  }
  if (call.queryParameters['action'] == 'wbgetentities') {
    return _entities({'Q1322753': _entity()});
  }
  if (call.uri.host == 'ko.wikipedia.org') return _page();
  return _photo();
}

Object _categoryResponse(
  RequestOptions call, {
  String category = 'Paralichthys olivaceus',
  String commonsTitle = '',
  Map<String, Object?>? media,
  List<Map<String, Object?>>? files,
}) {
  if (call.uri.host == 'www.wikidata.org' &&
      call.queryParameters['action'] == 'wbgetentities') {
    return _entities({
      'Q1322753': _entity(
        file: '',
        category: category,
        commonsTitle: commonsTitle,
      ),
    });
  }
  if (call.uri.host == 'commons.wikimedia.org') {
    if (call.queryParameters['generator'] == 'categorymembers') {
      return {
        'query': {
          'pages': files ?? [_categoryFile()],
        },
      };
    }
    if (call.queryParameters['action'] == 'wbgetentities') {
      return _entities({'M91': media ?? _mediaInfo()});
    }
  }
  return _response(call);
}

Map<String, Object?> _categoryFile({
  int id = 91,
  String title = 'File:Verified_fish.jpg',
  String license = 'CC BY-SA 3.0',
  String author = 'User:Vmenkov',
  String imageUrl = 'https://upload.wikimedia.org/fallback.jpg',
  String? sourceUrl,
}) {
  final data = _photo(
    title: title,
    license: license,
    author: author,
    imageUrl: imageUrl,
    sourceUrl: sourceUrl ?? 'https://commons.wikimedia.org/wiki/$title',
  );
  final page = ((data['query'] as Map)['pages'] as List).single as Map;
  return {...Map<String, Object?>.from(page), 'pageid': id};
}

Map<String, Object?> _mediaInfo({
  String id = 'M91',
  List<String> depicts = const ['Q1322753'],
  String rank = 'normal',
}) => {
  'id': id,
  'type': 'mediainfo',
  'statements': {
    'P180': [
      for (final taxon in depicts)
        {
          'rank': rank,
          'mainsnak': {
            'snaktype': 'value',
            'property': 'P180',
            'datavalue': {
              'type': 'wikibase-entityid',
              'value': {'entity-type': 'item', 'id': taxon},
            },
          },
        },
    ],
  },
};

Object _nominateResponse(RequestOptions call) {
  if (call.queryParameters['action'] == 'wbsearchentities') {
    return {
      'search': [
        {'id': 'Q10398535'},
      ],
    };
  }
  if (call.queryParameters['action'] == 'wbgetentities') {
    if (call.queryParameters['ids'] == 'Q1072544') {
      return _entities({
        'Q1072544': _entity(
          scientific: 'Acanthopagrus schlegelii schlegelii',
          title: '감성돔',
          parent: 'Q10398535',
        ),
      });
    }
    return _entities({
      'Q10398535': _entity(scientific: 'Acanthopagrus schlegelii', title: ''),
    });
  }
  if (call.uri.host == 'ko.wikipedia.org') {
    return _page(id: 'Q1072544', title: '감성돔');
  }
  return _photo();
}

Map<String, Object?> _entities(Map<String, Object?> rows) => {'entities': rows};
Map<String, Object?> _claim(Object value) => {
  'rank': 'normal',
  'mainsnak': {
    'datavalue': {'value': value},
  },
};
Map<String, Object?> _entity({
  String scientific = 'Paralichthys olivaceus',
  String title = '넙치',
  String file = _file,
  String? parent,
  String rank = 'Q7432',
  String koreanLabel = '',
  List<String> koreanAliases = const [],
  String category = '',
  String commonsTitle = '',
}) => {
  'claims': {
    'P225': [_claim(scientific)],
    'P18': [_claim(file)],
    if (category.isNotEmpty) 'P373': [_claim(category)],
    if (rank.isNotEmpty)
      'P105': [
        _claim({'id': rank}),
      ],
    if (parent != null)
      'P171': [
        _claim({'id': parent}),
      ],
  },
  'sitelinks': {
    if (title.isNotEmpty) 'kowiki': {'title': title},
    if (commonsTitle.isNotEmpty) 'commonswiki': {'title': commonsTitle},
  },
  'labels': {
    if (koreanLabel.isNotEmpty) 'ko': {'value': koreanLabel},
  },
  'aliases': {
    'ko': [
      for (final value in koreanAliases) {'value': value},
    ],
  },
};
Map<String, Object?> _missingPage() => {
  'query': {
    'pages': [
      {'title': '넙치', 'missing': true},
    ],
  },
};
Map<String, Object?> _page({
  String id = 'Q1322753',
  String title = '넙치',
  String extract = '넙치의 한국어 설명입니다.',
  String rightsUrl = 'https://creativecommons.org/licenses/by-sa/4.0/deed.ko',
}) => {
  'query': {
    'rightsinfo': {
      'url': rightsUrl,
      'text': 'Creative Commons Attribution-Share Alike 4.0',
    },
    'pages': [
      {
        'title': title,
        'pageid': 115819,
        'pageprops': {'wikibase_item': id},
        'extract': extract,
      },
    ],
  },
};
Map<String, Object?> _photo({
  String title = 'File:$_file',
  String license = 'CC BY-SA 3.0',
  String licenseUrl = 'https://creativecommons.org/licenses/by-sa/3.0/',
  String author =
      '<a href="//commons.wikimedia.org/wiki/User:Vmenkov">User:Vmenkov</a>',
  String copyrighted = 'True',
  String imageUrl = 'https://upload.wikimedia.org/photo.jpg',
  String sourceUrl = 'https://commons.wikimedia.org/wiki/File:$_file',
  String objectName = '',
  String imageDescription = '',
  String categories = '',
}) => {
  'query': {
    'pages': [
      {
        'title': title,
        'ns': 6,
        'imageinfo': [
          {
            'mime': 'image/jpeg',
            'thumburl': imageUrl,
            'descriptionurl': sourceUrl,
            'extmetadata': {
              'Artist': {'value': author},
              'LicenseShortName': {'value': license},
              'LicenseUrl': {'value': licenseUrl},
              'Copyrighted': {'value': copyrighted},
              'ObjectName': {'value': objectName},
              'ImageDescription': {'value': imageDescription},
              'Categories': {'value': categories},
            },
          },
        ],
      },
    ],
  },
};
Matcher _failure(FishCatalogFailure reason) => throwsA(
  isA<FishCatalogException>().having((error) => error.reason, 'reason', reason),
);

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  FutureOr<Object> Function(RequestOptions) respond;
  final calls = <RequestOptions>[];
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
