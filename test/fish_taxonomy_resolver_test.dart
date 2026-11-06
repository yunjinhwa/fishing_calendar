import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fishing_build/data/fish/fish_catalog_service.dart';
import 'package:fishing_build/data/fish/fish_taxonomy_resolver.dart';
import 'package:fishing_build/data/models/fish_species.dart';
import 'package:flutter_test/flutter_test.dart';

const _fish = FishSpecies(
  id: 'nifs:chankaensis',
  name: '가시납지리',
  scientificName: 'Acheilognathus chankaensis',
  family: '잉어과',
);
const _original = 'Acheilognathus chankaensis';
const _accepted = 'Acanthorhodeus chankaensis';

void main() {
  late _Adapter adapter;
  late Dio dio;
  late DateTime now;
  late GbifFishTaxonomyResolver resolver;
  setUp(() {
    now = DateTime.utc(2026, 11, 5);
    adapter = _Adapter(_response);
    dio = Dio()..httpClientAdapter = adapter;
    resolver = GbifFishTaxonomyResolver(dio: dio, clock: () => now);
  });
  tearDown(() => dio.close(force: true));

  test(
    'explicit COL XR synonym is independently confirmed before returning an alternative',
    () async {
      // Actual public v2 schema observed 2026-11-05, explicit current COL XR:
      // https://api.gbif.org/v2/species/match?scientificName=Acheilognathus%20chankaensis&taxonRank=SPECIES&kingdom=Animalia&phylum=Chordata&strict=true&verbose=true&checklistKey=7ddf754f-d193-4cc9-b351-99906754a03b
      final result = await resolver.resolve(_fish);
      expect(result.originalScientificName, _original);
      expect(result.alternatives, hasLength(1));
      final alternative = result.alternatives.single;
      expect(alternative.scientificName, _accepted);
      expect(alternative.originalUsageKey, '96GH');
      expect(alternative.acceptedUsageKey, '8ZS2');
      expect(alternative.familyScientificName, 'Cyprinidae');
      expect(alternative.sourceUrl, 'https://www.gbif.org/taxon/8ZS2');
      expect(alternative.checklistKey, GbifFishTaxonomyResolver.checklistKey);
      expect(alternative.commonNameConfirmed, isFalse);
      expect(result.resolvedAt, now);
      expect(_fish.scientificName, _original);
      expect(
        () => result.alternatives.add(alternative),
        throwsUnsupportedError,
      );
      expect(adapter.calls, hasLength(2));
      expect(adapter.calls.last.queryParameters['scientificName'], _accepted);
      for (final call in adapter.calls) {
        expect(call.uri.scheme, 'https');
        expect(call.uri.host, 'api.gbif.org');
        expect(call.followRedirects, isFalse);
        expect(call.queryParameters['taxonRank'], 'SPECIES');
        expect(call.queryParameters['strict'], isTrue);
        expect(
          call.queryParameters['checklistKey'],
          GbifFishTaxonomyResolver.checklistKey,
        );
        expect(
          call.queryParameters.keys.any(
            (key) => ['key', 'apiKey', 'serviceKey'].contains(key),
          ),
          isFalse,
        );
      }
    },
  );

  test('exact accepted species is a verified no-op', () async {
    const accepted = FishSpecies(
      id: 'accepted',
      name: '가시납지리',
      scientificName: _accepted,
    );
    final result = await resolver.resolve(accepted);
    expect(result.alternatives, isEmpty);
    expect(result.familyScientificName, 'Cyprinidae');
    expect(result.sourceUrl, 'https://www.gbif.org/taxon/8ZS2');
    expect(adapter.calls, hasLength(1));
  });

  test(
    'fuzzy, higher-rank, absent and low-confidence matches cannot resolve',
    () async {
      for (final type in ['FUZZY', 'HIGHERRANK', 'NONE']) {
        adapter.respond = (_) => _match(matchType: type);
        await expectLater(
          resolver.resolve(_fish),
          _failure(FishCatalogFailure.noData),
        );
      }
      adapter.respond = (_) => _match(confidence: 94);
      await expectLater(
        resolver.resolve(_fish),
        _failure(FishCatalogFailure.noData),
      );
      expect(adapter.calls, hasLength(4));
    },
  );

  test(
    'an exact diagnostic does not excuse a different canonical name',
    () async {
      adapter.respond = (_) => _match(original: 'Acheilognathus other');
      await expectLater(
        resolver.resolve(_fish),
        _failure(FishCatalogFailure.noData),
      );
    },
  );

  test('species and subspecies cannot be automatically collapsed', () async {
    for (final rank in ['SUBSPECIES', 'GENUS']) {
      final data = _match();
      (data['usage'] as Map)['rank'] = rank;
      adapter.respond = (_) => data;
      await expectLater(
        resolver.resolve(_fish),
        _failure(FishCatalogFailure.noData),
      );
    }
    final target = _match();
    (target['acceptedUsage'] as Map)['rank'] = 'SUBSPECIES';
    adapter.respond = (_) => target;
    await expectLater(
      resolver.resolve(_fish),
      _failure(FishCatalogFailure.noData),
    );
    const subspecies = FishSpecies(
      id: 'subspecies',
      name: '아종',
      scientificName: 'Acheilognathus chankaensis chankaensis',
    );
    await expectLater(
      resolver.resolve(subspecies),
      _failure(FishCatalogFailure.noData),
    );
    expect(adapter.calls, hasLength(3));
  });

  test(
    'animal chordates alone are insufficient without a fish class',
    () async {
      for (final fishClass in ['Aves', 'Mammalia', '']) {
        adapter.respond = (_) => _match(fishClass: fishClass);
        await expectLater(
          resolver.resolve(_fish),
          _failure(FishCatalogFailure.noData),
        );
      }
      adapter.respond = (_) => _match(kingdom: 'Plantae');
      await expectLater(
        resolver.resolve(_fish),
        _failure(FishCatalogFailure.noData),
      );
    },
  );

  test(
    'an explicit Latin family hint must agree and Korean families are not guessed',
    () async {
      expect(
        (await resolver.resolve(
          _fish,
          expectedScientificFamily: 'Cyprinidae',
        )).alternatives,
        hasLength(1),
      );
      expect(adapter.calls.first.queryParameters['family'], 'Cyprinidae');
      await expectLater(
        resolver.resolve(_fish, expectedScientificFamily: 'Sparidae'),
        _failure(FishCatalogFailure.noData),
      );
      expect(adapter.calls, hasLength(3));
      await expectLater(
        resolver.resolve(_fish, expectedScientificFamily: '잉어과'),
        _failure(FishCatalogFailure.noData),
      );
      expect(adapter.calls, hasLength(3));
    },
  );

  test(
    'a Latin family already supplied on the catalog is also checked',
    () async {
      const mismatched = FishSpecies(
        id: 'same',
        name: '가시납지리',
        scientificName: _original,
        family: 'Sparidae',
      );
      await expectLater(
        resolver.resolve(mismatched),
        _failure(FishCatalogFailure.noData),
      );
    },
  );

  test(
    'homonym and ambiguity diagnostics are conservatively rejected',
    () async {
      for (final note in [
        '2 synonym homonyms',
        'ambiguous name',
        'multiple equal matches',
        'classification mismatch',
      ]) {
        adapter.respond = (_) => _match(note: note);
        await expectLater(
          resolver.resolve(_fish),
          _failure(FishCatalogFailure.noData),
        );
      }
    },
  );

  test(
    'different accepted targets among exact alternatives are ambiguous',
    () async {
      final data = _match();
      final other = _match(targetKey: 'OTHER');
      (data['diagnostics'] as Map)['alternatives'] = [other];
      adapter.respond = (_) => data;
      await expectLater(
        resolver.resolve(_fish),
        _failure(FishCatalogFailure.noData),
      );
    },
  );

  test(
    'duplicate usages with the same explicit accepted target need not invent another alternative',
    () async {
      adapter.respond = (call) {
        final data = _response(call) as Map<String, Object?>;
        if (call.queryParameters['scientificName'] == _original) {
          (data['diagnostics'] as Map)['alternatives'] = [_match()];
        }
        return data;
      };
      expect((await resolver.resolve(_fish)).alternatives, hasLength(1));
    },
  );

  test(
    'accepted target must confirm the same key and cannot chain to another synonym',
    () async {
      adapter.respond = (call) =>
          call.queryParameters['scientificName'] == _original
          ? _match()
          : _match(
              original: _accepted,
              usageKey: 'DIFFERENT',
              targetKey: 'DIFFERENT',
              synonym: false,
            );
      await expectLater(
        resolver.resolve(_fish),
        _failure(FishCatalogFailure.noData),
      );
      adapter.respond = (call) =>
          call.queryParameters['scientificName'] == _original
          ? _match()
          : _match(
              original: _accepted,
              usageKey: '8ZS2',
              target: 'Acanthorhodeus other',
              targetKey: 'OTHER',
            );
      await expectLater(
        resolver.resolve(_fish),
        _failure(FishCatalogFailure.noData),
      );
      expect(adapter.calls, hasLength(4));
    },
  );

  test(
    'family disagreements between the original and accepted lookup reject the relationship',
    () async {
      adapter.respond = (call) =>
          call.queryParameters['scientificName'] == _original
          ? _match()
          : _match(
              original: _accepted,
              usageKey: '8ZS2',
              targetKey: '8ZS2',
              synonym: false,
              family: 'Sparidae',
            );
      await expectLater(
        resolver.resolve(_fish),
        _failure(FishCatalogFailure.noData),
      );
    },
  );

  test(
    'contradictory synonym flags and terminal classification are rejected',
    () async {
      final contradictory = _match();
      contradictory['synonym'] = false;
      adapter.respond = (_) => contradictory;
      await expectLater(
        resolver.resolve(_fish),
        _failure(FishCatalogFailure.noData),
      );
      final terminal = _match();
      ((terminal['classification'] as List).last as Map)['key'] = 'OTHER';
      adapter.respond = (_) => terminal;
      await expectLater(
        resolver.resolve(_fish),
        _failure(FishCatalogFailure.noData),
      );
    },
  );

  test('cache has a TTL, supports forced refresh and is bounded', () async {
    final bounded = GbifFishTaxonomyResolver(
      dio: dio,
      clock: () => now,
      maxCachedEntries: 1,
    );
    await bounded.resolve(_fish);
    await bounded.resolve(_fish);
    expect(adapter.calls, hasLength(2));
    await bounded.resolve(_fish, forceRefresh: true);
    expect(adapter.calls, hasLength(4));
    now = now.add(const Duration(hours: 25));
    await bounded.resolve(_fish);
    expect(adapter.calls, hasLength(6));
    const other = FishSpecies(
      id: 'other',
      name: '가시납지리',
      scientificName: _original,
    );
    await bounded.resolve(other);
    await bounded.resolve(_fish);
    expect(adapter.calls, hasLength(10));
  });

  test(
    'concurrent callers share a single pair of verification requests',
    () async {
      final gate = Completer<Object>();
      adapter.respond = (call) =>
          call.queryParameters['scientificName'] == _original
          ? gate.future
          : _response(call);
      final first = resolver.resolve(_fish);
      final second = resolver.resolve(_fish);
      await adapter.started.future;
      expect(adapter.calls, hasLength(1));
      gate.complete(_match());
      expect(await first, same(await second));
      expect(adapter.calls, hasLength(2));
    },
  );

  test(
    'typed service failures are sanitized and never cached as missing taxonomy',
    () async {
      adapter.status = 429;
      await expectLater(
        resolver.resolve(_fish),
        _failure(FishCatalogFailure.rateLimited),
      );
      adapter.status = 302;
      await expectLater(
        resolver.resolve(_fish),
        _failure(FishCatalogFailure.network),
      );
      adapter.status = 403;
      await expectLater(
        resolver.resolve(_fish),
        _failure(FishCatalogFailure.unauthorized),
      );
      adapter.status = 200;
      expect((await resolver.resolve(_fish)).alternatives, hasLength(1));
      expect(adapter.calls, hasLength(5));
      expect(
        const FishCatalogException(FishCatalogFailure.network).toString(),
        isNot(contains('http')),
      );
    },
  );

  test(
    'malformed and oversized payloads are rejected before producing alternatives',
    () async {
      adapter.respond = (_) => '<html>error</html>';
      await expectLater(
        resolver.resolve(_fish),
        _failure(FishCatalogFailure.invalidResponse),
      );
      adapter.respond = (_) => ' ' * (1024 * 1024 + 1);
      await expectLater(
        resolver.resolve(_fish),
        _failure(FishCatalogFailure.invalidResponse),
      );
      adapter.respond = (_) => <String, Object?>{};
      await expectLater(
        resolver.resolve(_fish),
        _failure(FishCatalogFailure.invalidResponse),
      );
    },
  );

  test('overall deadline cancels a stalled request', () async {
    adapter.respond = (_) => Completer<Object>().future;
    final limited = GbifFishTaxonomyResolver(
      dio: dio,
      requestTimeout: const Duration(seconds: 1),
      totalTimeout: const Duration(milliseconds: 25),
    );
    final elapsed = Stopwatch()..start();
    await expectLater(
      limited.resolve(_fish),
      _failure(FishCatalogFailure.timedOut),
    );
    await adapter.cancelled.future.timeout(const Duration(milliseconds: 200));
    expect(elapsed.elapsed, lessThan(const Duration(milliseconds: 500)));
    expect(adapter.calls, hasLength(1));
  });

  test(
    'serial verification shares one deadline and never starts a third request',
    () async {
      adapter.respond = (call) async {
        await Future<void>.delayed(const Duration(milliseconds: 45));
        return _response(call);
      };
      final limited = GbifFishTaxonomyResolver(
        dio: dio,
        requestTimeout: const Duration(seconds: 1),
        totalTimeout: const Duration(milliseconds: 70),
      );
      await expectLater(
        limited.resolve(_fish),
        _failure(FishCatalogFailure.timedOut),
      );
      final stoppedAt = adapter.calls.length;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(adapter.calls, hasLength(stoppedAt));
      expect(stoppedAt, lessThanOrEqualTo(2));
    },
  );
}

Object _response(RequestOptions call) =>
    call.queryParameters['scientificName'] == _original
    ? _match()
    : _match(
        original: _accepted,
        usageKey: '8ZS2',
        targetKey: '8ZS2',
        synonym: false,
      );
Map<String, Object?> _usage(String name, String key, {String? status}) => {
  'key': key,
  'name': '$name (Dybowski, 1872)',
  'canonicalName': name,
  'rank': 'SPECIES',
  'type': 'SCIENTIFIC',
  'code': 'ZOOLOGICAL',
  'status': ?status,
};
Map<String, Object?> _match({
  String original = _original,
  String target = _accepted,
  String usageKey = '96GH',
  String targetKey = '8ZS2',
  bool synonym = true,
  String matchType = 'EXACT',
  int confidence = 100,
  String note = 'singleMatch=5',
  String family = 'Cyprinidae',
  String fishClass = 'Teleostei',
  String kingdom = 'Animalia',
}) {
  final acceptedName = synonym ? target : original;
  final acceptedKey = synonym ? targetKey : usageKey;
  return {
    'usage': _usage(
      original,
      usageKey,
      status: synonym ? 'SYNONYM' : 'ACCEPTED',
    ),
    if (synonym) 'acceptedUsage': _usage(target, targetKey),
    'synonym': synonym,
    'classification': [
      {'key': 'N', 'name': kingdom, 'rank': 'KINGDOM'},
      {'key': 'CH2', 'name': 'Chordata', 'rank': 'PHYLUM'},
      if (fishClass.isNotEmpty)
        {'key': '8V4VD', 'name': fishClass, 'rank': 'CLASS'},
      {'key': 'KV2GM', 'name': family, 'rank': 'FAMILY'},
      {'key': acceptedKey, 'name': acceptedName, 'rank': 'SPECIES'},
    ],
    'diagnostics': {
      'matchType': matchType,
      'confidence': confidence,
      'note': note,
    },
  };
}

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
