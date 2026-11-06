import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../models/fish_species.dart';
import 'fish_api_configuration.dart';
import 'fish_catalog_service.dart';

/// NIFS supplies fish identities; NARIS enriches one exact scientific name.
/// Provider errors and request URLs never escape this class because they can
/// include credentials. No undocumented paging or habitat-code mapping is used.
class NifsNarisFishService implements FishCatalogService {
  NifsNarisFishService({
    Dio? dio,
    DateTime Function()? clock,
    this.configuration = const FishApiConfiguration(),
    this.requestTimeout = const Duration(seconds: 12),
    this.catalogTimeout = const Duration(seconds: 45),
    this.catalogCacheTtl = const Duration(hours: 24),
    this.detailCacheTtl = const Duration(days: 30),
    this.maxCatalogRequests = 48,
    this.maxCachedDetails = 128,
    this.maxConcurrentDetails = 8,
  }) : _dio = dio ?? Dio(),
       _clock = clock ?? DateTime.now {
    if (requestTimeout <= Duration.zero ||
        catalogTimeout <= Duration.zero ||
        catalogCacheTtl <= Duration.zero ||
        detailCacheTtl <= Duration.zero ||
        maxCatalogRequests < 2 ||
        maxCatalogRequests > 128 ||
        maxCachedDetails < 1 ||
        maxConcurrentDetails < 1) {
      throw ArgumentError('Fish request and cache limits must be positive.');
    }
  }

  static final NifsNarisFishService instance = NifsNarisFishService();
  static const nifsSourceUrl =
      'https://www.nifs.go.kr/openApi/actionOpenapiInfoList.do';
  static const narisSourceUrl =
      'https://naris.science.go.kr/intd/sym/selectOpenApiIntroduce.do';
  static const _nifsEndpoint = 'https://www.nifs.go.kr/api/OpenAPI_json';
  static const _narisEndpoint =
      'https://naris.science.go.kr/openapi/selectSpeciesList.do';
  static const _maxResponseBytes = 4 * 1024 * 1024;
  static const _maxCatalogEntries = 10000;

  final Dio _dio;
  final DateTime Function() _clock;
  final FishApiConfiguration configuration;
  final Duration requestTimeout;
  final Duration catalogTimeout;
  final Duration catalogCacheTtl;
  final Duration detailCacheTtl;
  final int maxCatalogRequests;
  final int maxCachedDetails;
  final int maxConcurrentDetails;
  _CacheEntry<List<FishSpecies>>? _catalog;
  Future<List<FishSpecies>>? _catalogInFlight;
  final _details = <String, _CacheEntry<FishSpecies>>{};
  final _detailInFlight = <String, Future<FishSpecies>>{};

  @override
  Future<List<FishSpecies>> fetchCatalog({bool forceRefresh = false}) async {
    final key = configuration.normalizedNifsApiKey;
    if (key == null) _fail(FishCatalogFailure.configuration);
    final cached = _catalog;
    if (!forceRefresh && cached != null && _fresh(cached, catalogCacheTtl)) {
      return cached.value;
    }
    final active = _catalogInFlight;
    if (active != null) return active;
    final pending = _loadCatalog(key);
    _catalogInFlight = pending;
    try {
      final value = await pending;
      _catalog = _CacheEntry(value, _clock().toUtc());
      return value;
    } finally {
      _catalogInFlight = null;
    }
  }

  Future<List<FishSpecies>> _loadCatalog(String key) async {
    final stopwatch = Stopwatch()..start();
    void checkDeadline() {
      if (stopwatch.elapsed >= catalogTimeout) {
        _fail(FishCatalogFailure.timedOut);
      }
    }

    var requestCount = 0;
    Future<Map<String, dynamic>> request(String id, _ClassPath path) async {
      checkDeadline();
      if (++requestCount > maxCatalogRequests) {
        _fail(FishCatalogFailure.invalidResponse);
      }
      final remaining = catalogTimeout - stopwatch.elapsed;
      final data = await _requestJson(
        _nifsEndpoint,
        {'id': id, 'key': key, ...path.parameters},
        naris: false,
        timeout: remaining < requestTimeout ? remaining : requestTimeout,
      );
      checkDeadline();
      return data;
    }

    // Discover the issuer's current codes from names, never hard-code IDs or
    // consider the entire vertebrate/chordate group to be fish.
    final queue = <_ClassPath>[const _ClassPath()];
    final visited = <String>{};
    final fishPaths = <String, _ClassPath>{};
    while (queue.isNotEmpty) {
      final path = queue.removeAt(0);
      if (!visited.add(path.key)) continue;
      final data = await request('frcenterCode2', path);
      for (final candidate in _classPaths(data, path)) {
        checkDeadline();
        final fish = candidate.fishAncestor;
        if (fish != null) {
          fishPaths[fish.key] = fish;
        } else if (!candidate.childrenExpanded &&
            candidate.depth < 3 &&
            candidate.depth > path.depth) {
          queue.add(candidate);
        }
      }
    }
    if (fishPaths.isEmpty) _fail(FishCatalogFailure.noData);
    // A broad fish branch already covers any fish sub-branches it contains.
    final selected = fishPaths.values.where(
      (candidate) => !fishPaths.values.any(
        (other) => other.depth < candidate.depth && other.contains(candidate),
      ),
    );
    final species = <String, FishSpecies>{};
    for (final path in selected) {
      final data = await request('frcenterInfo2', path);
      for (final row in _maps(data)) {
        checkDeadline();
        if (!_has(row, 'mf_tax_id')) continue;
        final fish = _fishFromNifs(row);
        if (fish != null) species[fish.id] = fish;
        if (species.length > _maxCatalogEntries) {
          _fail(FishCatalogFailure.invalidResponse);
        }
      }
    }
    if (species.isEmpty) _fail(FishCatalogFailure.noData);
    final result = species.values.toList()
      ..sort((a, b) {
        final names = a.name.compareTo(b.name);
        return names == 0 ? a.id.compareTo(b.id) : names;
      });
    checkDeadline();
    return List.unmodifiable(result);
  }

  @override
  Future<FishSpecies> fetchDetail(
    FishSpecies species, {
    bool forceRefresh = false,
  }) async {
    final key = configuration.normalizedNarisApiKey;
    if (key == null) _fail(FishCatalogFailure.configuration);
    final scientificName = _clean(species.scientificName, 255);
    if (scientificName.isEmpty) _fail(FishCatalogFailure.noData);
    final cacheKey = '${species.id}|${_scientificKey(scientificName)}';
    final cached = _details[cacheKey];
    if (!forceRefresh && cached != null && _fresh(cached, detailCacheTtl)) {
      return cached.value;
    }
    final active = _detailInFlight[cacheKey];
    if (active != null) return active;
    if (_detailInFlight.length >= maxConcurrentDetails) {
      _fail(FishCatalogFailure.rateLimited);
    }
    final pending = _loadDetail(species, scientificName, key);
    _detailInFlight[cacheKey] = pending;
    try {
      final value = await pending;
      _details.remove(cacheKey);
      while (_details.length >= maxCachedDetails) {
        _details.remove(_details.keys.first);
      }
      _details[cacheKey] = _CacheEntry(value, _clock().toUtc());
      return value;
    } finally {
      _detailInFlight.remove(cacheKey);
    }
  }

  Future<FishSpecies> _loadDetail(
    FishSpecies base,
    String scientificName,
    String key,
  ) async {
    final data = await _requestJson(_narisEndpoint, {
      'apiKey': key,
      'nameOfSpecies': scientificName,
      'pageNo': 1,
      'recordCount': 50,
    }, naris: true);
    final matches = _maps(data).where(
      (row) =>
          _has(row, 'scientificName') &&
          _scientificKey(_text(row, 'scientificName')) ==
              _scientificKey(scientificName),
    );
    if (matches.isEmpty) _fail(FishCatalogFailure.noData);
    final row = matches.first;
    final general = _plainText(_text(row, 'generalSpftrKor'));
    final ecology = _plainText(_text(row, 'ecologySpftrKor'));
    final description = [
      general,
      ecology,
    ].where((value) => value.isNotEmpty).toSet().join('\n\n');
    final image = _photoUrl(_text(row, 'representationImage'));
    if (description.isEmpty && image == null) {
      _fail(FishCatalogFailure.noData);
    }
    return FishSpecies(
      id: base.id,
      name: base.name,
      category: base.category,
      family: base.family,
      habitat: base.habitat,
      maxSize: base.maxSize,
      feature: description.isEmpty ? base.feature : description,
      scientificName: base.scientificName,
      imageUrl: image,
      photoAttribution: image == null
          ? null
          : '국립중앙과학관 국가자연사연구종합정보(NARIS) · 공공누리 제3유형',
      sourceName: '국립수산과학원 · 국립중앙과학관 NARIS',
      sourceUrl: narisSourceUrl,
      aliases: base.aliases,
    );
  }

  Future<Map<String, dynamic>> _requestJson(
    String endpoint,
    Map<String, Object> parameters, {
    required bool naris,
    Duration? timeout,
  }) async {
    final effectiveTimeout = timeout ?? requestTimeout;
    if (effectiveTimeout <= Duration.zero) _fail(FishCatalogFailure.timedOut);
    final cancel = CancelToken();
    try {
      return await _readJson(
        endpoint,
        parameters,
        cancel,
        naris: naris,
        timeout: effectiveTimeout,
      ).timeout(
        effectiveTimeout,
        onTimeout: () {
          cancel.cancel();
          _fail(FishCatalogFailure.timedOut);
        },
      );
    } on FishCatalogException {
      cancel.cancel();
      rethrow;
    } on DioException catch (error) {
      cancel.cancel();
      if ({
        DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
      }.contains(error.type)) {
        _fail(FishCatalogFailure.timedOut);
      }
      _fail(FishCatalogFailure.network);
    } on TimeoutException {
      cancel.cancel();
      _fail(FishCatalogFailure.timedOut);
    } on FormatException {
      cancel.cancel();
      _fail(FishCatalogFailure.invalidResponse);
    } on Object {
      cancel.cancel();
      _fail(FishCatalogFailure.invalidResponse);
    }
  }

  Future<Map<String, dynamic>> _readJson(
    String endpoint,
    Map<String, Object> parameters,
    CancelToken cancel, {
    required bool naris,
    required Duration timeout,
  }) async {
    final response = await _dio.get<ResponseBody>(
      endpoint,
      queryParameters: parameters,
      cancelToken: cancel,
      options: Options(
        responseType: ResponseType.stream,
        followRedirects: false,
        maxRedirects: 0,
        sendTimeout: timeout,
        receiveTimeout: timeout,
        validateStatus: (_) => true,
      ),
    );
    final status = response.statusCode ?? 0;
    if (status == 401 || status == 403) _fail(FishCatalogFailure.unauthorized);
    if (status == 429) _fail(FishCatalogFailure.rateLimited);
    if (status < 200 || status >= 300) _fail(FishCatalogFailure.network);
    final body = response.data;
    if (body == null) _fail(FishCatalogFailure.invalidResponse);
    final length = int.tryParse(
      response.headers.value(Headers.contentLengthHeader) ?? '',
    );
    if (length != null && length > _maxResponseBytes) {
      cancel.cancel();
      _fail(FishCatalogFailure.invalidResponse);
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in body.stream) {
      if (bytes.length + chunk.length > _maxResponseBytes) {
        cancel.cancel();
        _fail(FishCatalogFailure.invalidResponse);
      }
      bytes.add(chunk);
    }
    final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
    if (decoded is! Map<String, dynamic>) {
      _fail(FishCatalogFailure.invalidResponse);
    }
    final data = decoded;
    Map<String, dynamic>? header;
    for (final map in _maps(data)) {
      if (_has(map, 'resultCode')) {
        header = map;
        break;
      }
    }
    if (header == null) _fail(FishCatalogFailure.invalidResponse);
    final code = _text(header, 'resultCode');
    if (!{'00', '0000', '0'}.contains(code)) {
      final message =
          '${_text(header, 'resultMsg')} '
                  '${_text(header, 'resultMessage')}'
              .toLowerCase();
      if ((naris && code == 'E01') || (!naris && code == '02')) {
        _fail(FishCatalogFailure.unauthorized);
      }
      if (RegExp(
        r'quota|rate.?limit|limit exceeded|호출.*초과|요청.*초과',
      ).hasMatch(message)) {
        _fail(FishCatalogFailure.rateLimited);
      }
      _fail(FishCatalogFailure.invalidResponse);
    }
    return data;
  }

  bool _fresh(_CacheEntry<Object> entry, Duration ttl) {
    final age = _clock().toUtc().difference(entry.fetchedAt);
    return !age.isNegative && age < ttl;
  }
}

FishSpecies? _fishFromNifs(Map<String, dynamic> row) {
  if (![
    'mf_l_cls_nm',
    'mf_m_cls_nm',
    'mf_s_cls_nm',
    'mf_kor_class',
    'mf_sci_class',
  ].any((key) => _isFishName(_text(row, key)))) {
    return null;
  }
  final rawId = _text(row, 'mf_tax_id').trim();
  final name = _clean(_text(row, 'mf_kor_nor'), 200);
  if (rawId.isEmpty || rawId.length > 180 || name.isEmpty) return null;
  final rawWater = _clean(_text(row, 'mf_water_kind'), 100);
  // NIFS's public species response explicitly labels these two codes. Other
  // codes remain unknown; mixed/brackish labels do not imply one water type.
  final water = switch (rawWater) {
    'BTBS-WK-01' => '해수',
    'BTBS-WK-02' => '육상 담수',
    _ => rawWater,
  };
  final category = switch (water.toLowerCase()) {
    '해수' || '해수어' || '바다' || '해양' || 'marine' => FishCategory.sea,
    '담수' || '담수어' || '육상 담수' || '민물' || 'freshwater' => FishCategory.freshwater,
    _ => FishCategory.unknown,
  };
  final aliases = <String>{};
  for (final key in ['mf_kor_equ', 'mf_kor_dia', 'mf_sci_equ']) {
    aliases.addAll(
      _text(row, key)
          .split(RegExp(r'[,;|\r\n]'))
          .map((value) => _clean(value, 255))
          .where((value) => value.isNotEmpty && value != name)
          .take(32),
    );
  }
  final koreanFamily = _clean(_text(row, 'mf_kor_family'), 255);
  return FishSpecies(
    id: 'nifs:$rawId',
    name: name,
    category: category,
    habitat: _namedWater(water),
    scientificName: _clean(_text(row, 'mf_sci_nor'), 255),
    family: koreanFamily.isNotEmpty
        ? koreanFamily
        : _clean(_text(row, 'mf_sci_family'), 255),
    sourceName: '국립수산과학원',
    sourceUrl: NifsNarisFishService.nifsSourceUrl,
    aliases: List.unmodifiable(aliases),
  );
}

class _ClassPath {
  const _ClassPath({
    this.codes = const [],
    this.names = const [],
    this.childrenExpanded = false,
  });
  final List<String> codes;
  final List<String> names;
  // A supplied next-rank array is complete even when empty. The live NIFS
  // response expands all ranks in one call; flat responses that omit arrays
  // can still use bounded discovery.
  final bool childrenExpanded;
  int get depth => codes.length;
  String get key => codes.join('/');
  Map<String, String> get parameters => {
    for (var i = 0; i < depth; i++)
      ['mf_l_cls_cd', 'mf_m_cls_cd', 'mf_s_cls_cd'][i]: codes[i],
  };
  bool contains(_ClassPath other) =>
      depth <= other.depth && key == other.codes.take(depth).join('/');
  _ClassPath? get fishAncestor {
    for (var i = 0; i < names.length; i++) {
      if (_isFishName(names[i])) {
        return _ClassPath(
          codes: codes.take(i + 1).toList(),
          names: names.take(i + 1).toList(),
        );
      }
    }
    return null;
  }
}

Iterable<_ClassPath> _classPaths(
  Map<String, dynamic> data,
  _ClassPath parent,
) sync* {
  final results = <String, _ClassPath>{};
  void visit(Object? object, _ClassPath inherited, int nesting) {
    if (nesting > 12) _fail(FishCatalogFailure.invalidResponse);
    if (object is List) {
      for (final child in object) {
        visit(child, inherited, nesting + 1);
      }
    } else if (object is Map<String, dynamic>) {
      final codes = inherited.codes.toList();
      final names = inherited.names.toList();
      for (var i = 0; i < 3; i++) {
        final rank = ['l', 'm', 's'][i];
        final code = _text(object, 'mf_${rank}_cls_cd').trim();
        final name = _clean(_text(object, 'mf_${rank}_cls_nm'), 255);
        if (code.isEmpty || name.isEmpty || i > codes.length) continue;
        if (!RegExp(r'^[A-Za-z0-9_-]{1,20}$').hasMatch(code)) {
          _fail(FishCatalogFailure.invalidResponse);
        }
        if (i < codes.length) {
          codes[i] = code;
          names[i] = name;
          codes.removeRange(i + 1, codes.length);
          names.removeRange(i + 1, names.length);
        } else {
          codes.add(code);
          names.add(name);
        }
        final path = _ClassPath(
          codes: codes.toList(),
          names: names.toList(),
          childrenExpanded: _childrenSupplied(object, codes.length),
        );
        results[path.key] = path;
      }
      final context = _ClassPath(codes: codes, names: names);
      for (final child in object.values) {
        if (child is Map || child is List) visit(child, context, nesting + 1);
      }
    }
  }

  visit(data, parent, 0);
  yield* results.values;
}

bool _childrenSupplied(Map<String, dynamic> row, int depth) {
  if (depth >= 3) return true;
  final key = depth == 1 ? 'item2' : 'item3';
  return row.entries.any(
    (entry) => entry.key.toLowerCase() == key && entry.value is List,
  );
}

bool _isFishName(String value) => const {
  '어류',
  '경골어류',
  '연골어류',
  '조기어류',
  '육기어류',
  '원구류',
  '먹장어류',
  '칠성장어류',
  '경골어강',
  '연골어강',
  '조기어강',
  '육기어강',
  'osteichthyes',
  'chondrichthyes',
  'actinopterygii',
  'sarcopterygii',
  'myxini',
  'petromyzontida',
  'cyclostomata',
  'pisces',
}.contains(value.replaceAll(RegExp(r'\s+'), '').toLowerCase());

Iterable<Map<String, dynamic>> _maps(Object? root) sync* {
  var visited = 0;
  Iterable<Map<String, dynamic>> walk(Object? object, int depth) sync* {
    if (++visited > 50000 || depth > 12) {
      _fail(FishCatalogFailure.invalidResponse);
    }
    if (object is Map<String, dynamic>) {
      yield object;
      for (final child in object.values) {
        if (child is Map || child is List) yield* walk(child, depth + 1);
      }
    } else if (object is List) {
      for (final child in object) {
        yield* walk(child, depth + 1);
      }
    }
  }

  yield* walk(root, 0);
}

bool _has(Map<String, dynamic> row, String key) =>
    row.keys.any((candidate) => candidate.toLowerCase() == key.toLowerCase());
String _text(Map<String, dynamic> row, String key) {
  for (final entry in row.entries) {
    if (entry.key.toLowerCase() == key.toLowerCase()) {
      final value = entry.value;
      return value is String || value is num ? value.toString() : '';
    }
  }
  return '';
}

String _clean(String raw, int limit) {
  final value = raw
      .replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]'), '')
      .trim();
  return value.length > limit ? value.substring(0, limit) : value;
}

String _plainText(String value) => _clean(
  value
      .replaceAll(RegExp(r'<\s*br\s*/?\s*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'"),
  20000,
);
String _scientificKey(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
String _namedWater(String value) {
  const names = {
    '해수',
    '해수어',
    '바다',
    '해양',
    '담수',
    '담수어',
    '육상 담수',
    '민물',
    '기수',
    '기수어',
    'marine',
    'freshwater',
    'brackish',
  };
  final parts = value.toLowerCase().split(RegExp(r'[,;/|·]'));
  return parts.isNotEmpty && parts.every((part) => names.contains(part.trim()))
      ? value
      : '';
}

String? _photoUrl(String value) {
  if (value.trim().isEmpty || value.length > 2048) return null;
  final parsed = Uri.tryParse(value.trim());
  if (parsed == null) return null;
  var uri = Uri.parse('https://naris.science.go.kr/').resolveUri(parsed);
  if (uri.scheme == 'http' &&
      const {
        'naris.science.go.kr',
        'www.naris.science.go.kr',
      }.contains(uri.host)) {
    uri = uri.replace(scheme: 'https');
  }
  if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri.toString();
}

Never _fail(FishCatalogFailure reason) => throw FishCatalogException(reason);

class _CacheEntry<T> {
  const _CacheEntry(this.value, this.fetchedAt);
  final T value;
  final DateTime fetchedAt;
}
