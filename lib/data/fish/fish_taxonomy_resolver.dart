import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../models/fish_species.dart';
import 'fish_catalog_service.dart';

abstract interface class FishTaxonomyResolver {
  Future<FishTaxonomyResolution> resolve(
    FishSpecies species, {
    bool forceRefresh = false,
  });
}

/// An explicit synonym relationship, not permission to change the catalog's
/// identity or attach a photo without the caller's Korean common-name check.
class FishTaxonomyAlternative {
  const FishTaxonomyAlternative({
    required this.scientificName,
    required this.sourceUrl,
    this.sourceName = 'GBIF · Catalogue of Life XR',
    this.originalUsageKey = '',
    this.acceptedUsageKey = '',
    this.checklistKey = '',
    this.familyScientificName = '',
    this.commonNameConfirmed = false,
  });

  final String scientificName;
  final String sourceUrl;
  final String sourceName;
  final String originalUsageKey;
  final String acceptedUsageKey;
  final String checklistKey;
  final String familyScientificName;
  final bool commonNameConfirmed;
}

class FishTaxonomyResolution {
  const FishTaxonomyResolution({
    required this.originalScientificName,
    this.alternatives = const [],
    this.sourceUrl = '',
    this.familyScientificName = '',
    this.resolvedAt,
  });

  final String originalScientificName;
  final List<FishTaxonomyAlternative> alternatives;
  final String sourceUrl;
  final String familyScientificName;
  final DateTime? resolvedAt;
}

/// Matches the current COL XR explicitly: GBIF's unqualified default still
/// targets its discontinued legacy backbone. Both the old name and the
/// accepted target must independently match exactly at species rank.
/// https://techdocs.gbif.org/en/data-processing/taxonomy-interpretation
class GbifFishTaxonomyResolver implements FishTaxonomyResolver {
  GbifFishTaxonomyResolver({
    Dio? dio,
    DateTime Function()? clock,
    this.requestTimeout = const Duration(seconds: 6),
    this.totalTimeout = const Duration(seconds: 12),
    this.cacheTtl = const Duration(hours: 24),
    this.maxCachedEntries = 128,
  }) : _dio = dio ?? Dio(),
       _clock = clock ?? DateTime.now {
    if (requestTimeout <= Duration.zero ||
        totalTimeout <= Duration.zero ||
        cacheTtl <= Duration.zero ||
        maxCachedEntries < 1) {
      throw ArgumentError(
        'Taxonomy request and cache limits must be positive.',
      );
    }
  }

  static final instance = GbifFishTaxonomyResolver();
  static const checklistKey = '7ddf754f-d193-4cc9-b351-99906754a03b';
  static const _endpoint = 'https://api.gbif.org/v2/species/match';
  static const _maxBytes = 1024 * 1024;
  static const _agent =
      'FishingBuild/1.0 (+https://fishingbuild.firebaseapp.com)';
  static const _isWeb = bool.fromEnvironment('dart.library.js_interop');
  final Dio _dio;
  final DateTime Function() _clock;
  final Duration requestTimeout;
  final Duration totalTimeout;
  final Duration cacheTtl;
  final int maxCachedEntries;
  final _cache = <String, ({FishTaxonomyResolution result, DateTime at})>{};
  final _flights = <String, Future<FishTaxonomyResolution>>{};

  @override
  Future<FishTaxonomyResolution> resolve(
    FishSpecies species, {
    bool forceRefresh = false,
    String? expectedScientificFamily,
  }) async {
    final original = species.scientificName.trim();
    if (!_binomial(original)) _fail(FishCatalogFailure.noData);
    var expected = expectedScientificFamily?.trim() ?? '';
    if (expected.isEmpty &&
        RegExp(r'^[A-Za-z]+idae$').hasMatch(species.family.trim())) {
      expected = species.family.trim();
    }
    if (expected.isNotEmpty && !RegExp(r'^[A-Za-z]+idae$').hasMatch(expected)) {
      _fail(FishCatalogFailure.noData);
    }
    final key = jsonEncode([
      species.id,
      species.name,
      _name(original),
      _name(expected),
    ]);
    final cached = _cache[key];
    if (!forceRefresh && cached != null) {
      final age = _clock().toUtc().difference(cached.at);
      if (!age.isNegative && age < cacheTtl) {
        _cache.remove(key);
        _cache[key] = cached;
        return cached.result;
      }
    }
    final active = _flights[key];
    if (active != null) return active;
    if (_flights.length >= maxCachedEntries) {
      _fail(FishCatalogFailure.rateLimited);
    }
    final pending = _resolve(original, expected);
    _flights[key] = pending;
    try {
      final result = await pending;
      _cache.remove(key);
      while (_cache.length >= maxCachedEntries) {
        _cache.remove(_cache.keys.first);
      }
      _cache[key] = (result: result, at: _clock().toUtc());
      return result;
    } finally {
      if (identical(_flights[key], pending)) _flights.remove(key);
    }
  }

  Future<FishTaxonomyResolution> _resolve(
    String original,
    String expectedFamily,
  ) async {
    final timer = Stopwatch()..start();
    var calls = 0;
    Future<_Match> match(String name) async {
      final remaining = totalTimeout - timer.elapsed;
      if (remaining <= Duration.zero) _fail(FishCatalogFailure.timedOut);
      if (++calls > 2) _fail(FishCatalogFailure.invalidResponse);
      final json = await _request(
        name,
        expectedFamily,
        remaining < requestTimeout ? remaining : requestTimeout,
      );
      if (timer.elapsed >= totalTimeout) _fail(FishCatalogFailure.timedOut);
      return _parse(json, name, expectedFamily);
    }

    final first = await match(original);
    final source = _sourceUrl(first.targetKey);
    if (!first.synonym) {
      return FishTaxonomyResolution(
        originalScientificName: original,
        sourceUrl: source,
        familyScientificName: first.family,
        resolvedAt: _clock().toUtc(),
      );
    }
    if (_name(first.targetName) == _name(original)) {
      _fail(FishCatalogFailure.noData);
    }
    final accepted = await match(first.targetName);
    if (accepted.synonym ||
        accepted.usageKey != first.targetKey ||
        _name(accepted.targetName) != _name(first.targetName) ||
        _name(accepted.family) != _name(first.family)) {
      _fail(FishCatalogFailure.noData);
    }
    return FishTaxonomyResolution(
      originalScientificName: original,
      sourceUrl: source,
      familyScientificName: accepted.family,
      resolvedAt: _clock().toUtc(),
      alternatives: List.unmodifiable([
        FishTaxonomyAlternative(
          scientificName: accepted.targetName,
          sourceUrl: source,
          originalUsageKey: first.usageKey,
          acceptedUsageKey: accepted.usageKey,
          checklistKey: checklistKey,
          familyScientificName: accepted.family,
          // GBIF taxonomy alone is not positive Korean name confirmation.
          commonNameConfirmed: false,
        ),
      ]),
    );
  }

  Future<Map<String, dynamic>> _request(
    String name,
    String family,
    Duration timeout,
  ) async {
    final token = CancelToken();
    Future<Map<String, dynamic>> read() async {
      final response = await _dio.get<ResponseBody>(
        _endpoint,
        queryParameters: {
          'scientificName': name,
          'taxonRank': 'SPECIES',
          'kingdom': 'Animalia',
          'phylum': 'Chordata',
          'strict': true,
          'verbose': true,
          'checklistKey': checklistKey,
          if (family.isNotEmpty) 'family': family,
        },
        cancelToken: token,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: false,
          maxRedirects: 0,
          receiveTimeout: timeout,
          sendTimeout: timeout,
          validateStatus: (_) => true,
          headers: {if (!_isWeb) 'User-Agent': _agent},
        ),
      );
      final status = response.statusCode ?? 0;
      if (status == 429) _fail(FishCatalogFailure.rateLimited);
      if (status == 401 || status == 403) {
        _fail(FishCatalogFailure.unauthorized);
      }
      if (status < 200 || status >= 300) _fail(FishCatalogFailure.network);
      final body = response.data;
      if (body == null) _fail(FishCatalogFailure.invalidResponse);
      final declared = int.tryParse(
        response.headers.value(Headers.contentLengthHeader) ?? '',
      );
      if (declared != null && declared > _maxBytes) {
        _fail(FishCatalogFailure.invalidResponse);
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in body.stream) {
        if (bytes.length + chunk.length > _maxBytes) {
          _fail(FishCatalogFailure.invalidResponse);
        }
        bytes.add(chunk);
      }
      final data = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (data is! Map<String, dynamic>) {
        _fail(FishCatalogFailure.invalidResponse);
      }
      if (data.containsKey('error')) _fail(FishCatalogFailure.invalidResponse);
      return data;
    }

    try {
      return await read().timeout(
        timeout,
        onTimeout: () {
          token.cancel();
          _fail(FishCatalogFailure.timedOut);
        },
      );
    } on FishCatalogException {
      token.cancel();
      rethrow;
    } on DioException catch (error) {
      token.cancel();
      if ({
        DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
      }.contains(error.type)) {
        _fail(FishCatalogFailure.timedOut);
      }
      _fail(FishCatalogFailure.network);
    } on Object {
      token.cancel();
      _fail(FishCatalogFailure.invalidResponse);
    }
  }
}

_Match _parse(
  Map<String, dynamic> data,
  String requested,
  String expectedFamily,
) {
  final diagnostics = _map(data['diagnostics']);
  if (diagnostics == null) _fail(FishCatalogFailure.invalidResponse);
  if (diagnostics['matchType'] != 'EXACT' ||
      diagnostics['confidence'] is! num ||
      (diagnostics['confidence'] as num) < 95 ||
      RegExp(
        r'ambigu|homonym|multiple equal|conflict|mismatch',
        caseSensitive: false,
      ).hasMatch(_string(diagnostics['note'])) ||
      _list(diagnostics['issues']).isNotEmpty ||
      _list(data['issues']).isNotEmpty) {
    _fail(FishCatalogFailure.noData);
  }
  final usage = _map(data['usage']);
  if (usage == null) _fail(FishCatalogFailure.noData);
  _checkUsage(usage);
  if (_name(_string(usage['canonicalName'])) != _name(requested)) {
    _fail(FishCatalogFailure.noData);
  }
  final synonym = data['synonym'];
  if (synonym is! bool) _fail(FishCatalogFailure.invalidResponse);
  final status = usage['status'];
  if (synonym ? status != 'SYNONYM' : status != 'ACCEPTED') {
    _fail(FishCatalogFailure.noData);
  }
  final accepted = synonym ? _map(data['acceptedUsage']) : usage;
  if (accepted == null) _fail(FishCatalogFailure.invalidResponse);
  _checkUsage(accepted);
  if (!synonym && _map(data['acceptedUsage']) != null) {
    _fail(FishCatalogFailure.noData);
  }
  final targetKey = _string(accepted['key']);
  final targetName = _string(accepted['canonicalName']);
  if (synonym && targetKey == usage['key']) _fail(FishCatalogFailure.noData);

  final lineage = _list(data['classification']);
  if (lineage.isEmpty || lineage.length > 64) _fail(FishCatalogFailure.noData);
  Map<String, dynamic> rank(String name) {
    final rows = lineage
        .map(_map)
        .whereType<Map<String, dynamic>>()
        .where((row) => row['rank'] == name)
        .toList();
    if (rows.length != 1) _fail(FishCatalogFailure.noData);
    return rows.single;
  }

  if (rank('KINGDOM')['name'] != 'Animalia' ||
      rank('PHYLUM')['name'] != 'Chordata' ||
      !const {
        'teleostei',
        'actinopterygii',
        'actinopteri',
        'chondrichthyes',
        'elasmobranchii',
        'holocephali',
        'sarcopterygii',
        'myxini',
        'petromyzontida',
        'cephalaspidomorphi',
        'hyperoartia',
        'dipnoi',
        'coelacanthi',
      }.contains(_name(_string(rank('CLASS')['name'])))) {
    _fail(FishCatalogFailure.noData);
  }
  final family = _string(rank('FAMILY')['name']);
  if (!RegExp(r'^[A-Za-z]+idae$').hasMatch(family) ||
      expectedFamily.isNotEmpty && _name(family) != _name(expectedFamily) ||
      rank('SPECIES')['key'] != targetKey ||
      _name(_string(rank('SPECIES')['name'])) != _name(targetName)) {
    _fail(FishCatalogFailure.noData);
  }
  final alternatives = _list(diagnostics['alternatives']);
  if (alternatives.length > 20) _fail(FishCatalogFailure.noData);
  for (final raw in alternatives) {
    final alternative = _map(raw);
    final other = _map(alternative?['usage']);
    if (other == null ||
        _name(_string(other['canonicalName'])) != _name(requested)) {
      continue;
    }
    final otherTarget = alternative?['synonym'] == true
        ? _map(alternative?['acceptedUsage'])
        : other;
    if (otherTarget == null ||
        otherTarget['key'] != targetKey ||
        otherTarget['rank'] != 'SPECIES') {
      _fail(FishCatalogFailure.noData);
    }
  }
  return _Match(_string(usage['key']), targetKey, targetName, family, synonym);
}

void _checkUsage(Map<String, dynamic> usage) {
  if (usage['rank'] != 'SPECIES' ||
      usage['type'] != 'SCIENTIFIC' ||
      usage['code'] != 'ZOOLOGICAL' ||
      !RegExp(
        r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$',
      ).hasMatch(_string(usage['key'])) ||
      !_binomial(_string(usage['canonicalName']))) {
    _fail(FishCatalogFailure.noData);
  }
}

class _Match {
  const _Match(
    this.usageKey,
    this.targetKey,
    this.targetName,
    this.family,
    this.synonym,
  );
  final String usageKey;
  final String targetKey;
  final String targetName;
  final String family;
  final bool synonym;
}

String _sourceUrl(String key) =>
    Uri.https('www.gbif.org', '/taxon/$key').toString();
bool _binomial(String value) =>
    value.length <= 255 &&
    RegExp(r'^[A-Z][a-zA-Z-]+ [a-z][a-z-]+$').hasMatch(value);
String _name(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
String _string(Object? value) => value is String ? value : '';
Map<String, dynamic>? _map(Object? value) =>
    value is Map<String, dynamic> ? value : null;
List<dynamic> _list(Object? value) => value is List ? value : const [];
Never _fail(FishCatalogFailure reason) => throw FishCatalogException(reason);
