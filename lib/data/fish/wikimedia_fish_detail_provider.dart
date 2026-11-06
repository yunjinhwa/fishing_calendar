import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../models/fish_species.dart';
import 'fish_catalog_service.dart';
import 'fish_size_summary.dart';
import 'fish_photo_validation.dart';

/// Keyless, licensed details whose scientific and Korean identities agree.
/// A short shared cache joins list-photo and detail lookups; the repository
/// owns durable cache policy and the UI controls request concurrency.
class WikimediaFishDetailProvider
    implements FishDetailProvider, FishDetailDeadlineProvider {
  WikimediaFishDetailProvider({
    Dio? dio,
    DateTime Function()? clock,
    this.requestTimeout = const Duration(seconds: 8),
    this.totalTimeout = const Duration(seconds: 20),
    this.cacheTtl = const Duration(minutes: 5),
    this.maxCachedEntries = 128,
  }) : _dio = dio ?? Dio(),
       _clock = clock ?? DateTime.now {
    if (requestTimeout <= Duration.zero ||
        totalTimeout <= Duration.zero ||
        cacheTtl <= Duration.zero ||
        maxCachedEntries < 1) {
      throw ArgumentError('Wikimedia request deadlines must be positive.');
    }
  }

  static final WikimediaFishDetailProvider instance =
      WikimediaFishDetailProvider();

  @override
  WikimediaFishDetailProvider withDeadline(Duration timeout) =>
      WikimediaFishDetailProvider(
        dio: _dio,
        clock: _clock,
        requestTimeout: timeout < requestTimeout ? timeout : requestTimeout,
        totalTimeout: timeout < totalTimeout ? timeout : totalTimeout,
        cacheTtl: cacheTtl,
        maxCachedEntries: maxCachedEntries,
      );
  static const _agent =
      'FishingBuild/1.0 (+https://fishingbuild.firebaseapp.com)';
  static const _wikidata = 'https://www.wikidata.org/w/api.php';
  static const _wikipedia = 'https://ko.wikipedia.org/w/api.php';
  static const _commons = 'https://commons.wikimedia.org/w/api.php';
  static const _maxBytes = 1024 * 1024;
  static const _isWeb = bool.fromEnvironment('dart.library.js_interop');
  final Dio _dio;
  final DateTime Function() _clock;
  final Duration requestTimeout;
  final Duration totalTimeout;
  final Duration cacheTtl;
  final int maxCachedEntries;
  final _successes = <String, ({FishSpecies fish, DateTime at})>{};
  final _flights = <String, Future<FishSpecies>>{};

  @override
  Future<FishSpecies> fetchDetail(
    FishSpecies species, {
    bool forceRefresh = false,
  }) async {
    final aliases = species.aliases.map(_commonKey).toSet().toList()..sort();
    final key = jsonEncode([
      species.id,
      species.name,
      species.scientificName,
      aliases,
    ]);
    final cached = _successes[key];
    if (!forceRefresh && cached != null) {
      final age = _clock().toUtc().difference(cached.at);
      if (!age.isNegative && age < cacheTtl) {
        _successes.remove(key);
        _successes[key] = cached;
        return _rebase(cached.fish, species);
      }
    }
    final pending = _flights[key];
    if (pending != null) return _rebase(await pending, species);
    if (_flights.length >= maxCachedEntries) {
      _fail(FishCatalogFailure.rateLimited);
    }
    final request = _fetchUncached(species);
    _flights[key] = request;
    try {
      final result = await request;
      // A transient partial must be retriable after the repository cooldown,
      // rather than being hidden behind this longer success cache.
      if (!result.detailNeedsRetry) {
        _successes.remove(key);
        while (_successes.length >= maxCachedEntries) {
          _successes.remove(_successes.keys.first);
        }
        _successes[key] = (fish: result, at: _clock().toUtc());
      }
      return _rebase(result, species);
    } finally {
      if (identical(_flights[key], request)) _flights.remove(key);
    }
  }

  FishSpecies _rebase(FishSpecies data, FishSpecies base) {
    final photo =
        Uri.tryParse(data.photoSourceUrl ?? '')?.host ==
        'commons.wikimedia.org';
    final text =
        Uri.tryParse(data.descriptionSourceUrl ?? '')?.host ==
        'ko.wikipedia.org';
    return FishSpecies(
      id: base.id,
      name: base.name,
      scientificName: base.scientificName,
      category: base.category,
      family: base.family,
      habitat: base.habitat,
      maxSize: base.maxSize.trim().isNotEmpty
          ? base.maxSize
          : (text ? data.sizeDescription : base.sizeDescription),
      aliases: base.aliases,
      feature: text ? data.feature : base.feature,
      imageUrl: photo ? data.imageUrl : base.imageUrl,
      photoAttribution: photo ? data.photoAttribution : base.photoAttribution,
      photoSourceUrl: photo ? data.photoSourceUrl : base.photoSourceUrl,
      photoLicenseUrl: photo ? data.photoLicenseUrl : base.photoLicenseUrl,
      descriptionSourceUrl: text
          ? data.descriptionSourceUrl
          : base.descriptionSourceUrl,
      descriptionAttribution: text
          ? data.descriptionAttribution
          : base.descriptionAttribution,
      detailNeedsRetry: data.detailNeedsRetry,
      sourceName: {
        ...base.sourceName.split(' · ').where((value) => value.isNotEmpty),
        'Wikidata',
        if (text) '한국어 위키백과',
        if (photo) 'Wikimedia Commons',
      }.join(' · '),
      sourceUrl: data.sourceUrl ?? base.sourceUrl,
    );
  }

  Future<FishSpecies> _fetchUncached(FishSpecies species) async {
    final scientific = _text(species.scientificName, 255);
    final names = [species.name, ...species.aliases.take(64)]
        .where((value) => RegExp(r'[가-힣]').hasMatch(value))
        .map(_commonKey)
        .where((value) => value.isNotEmpty)
        .toSet();
    if (scientific.isEmpty || names.isEmpty) _fail(FishCatalogFailure.noData);
    final budget = _Budget(totalTimeout);
    Future<Map<String, dynamic>> request(
      String url,
      Map<String, Object> parameters,
    ) => _request(url, parameters, budget);

    final search = await request(_wikidata, {
      'action': 'wbsearchentities',
      'search': scientific,
      'language': 'en',
      'uselang': 'ko',
      'type': 'item',
      'limit': 5,
    });
    final ids = _list(search['search'])
        .map((value) => _map(value)?['id'])
        .whereType<String>()
        .where(_validId)
        .take(5)
        .toSet();
    if (ids.isEmpty) _fail(FishCatalogFailure.noData);
    final entities = await _entities(ids, request);
    final exact = entities
        .where(
          (value) => _claims(value.data, 'P225').any(
            (name) =>
                name is String &&
                _scientificKey(name) == _scientificKey(scientific),
          ),
        )
        .toList();
    if (exact.isEmpty) _fail(FishCatalogFailure.noData);
    FishCatalogException? optionalFailure;
    void rememberFailure(FishCatalogException error) {
      // A transient failure must not become a long-lived "no data" result.
      optionalFailure ??= error;
    }

    _Entity? selected;
    for (final entity in exact) {
      if (names.contains(_commonKey(entity.koreanTitle)) &&
          !entity.hasKoreanConflict(names)) {
        selected = entity;
        break;
      }
    }

    _KoreanPage? page;
    if (selected == null) {
      // A differently named Korean article (e.g. 금붕어 for 붕어) is a hard
      // mismatch. Never select its photo merely because the binomial agrees.
      if (exact.any(
        (value) =>
            value.koreanTitle.isNotEmpty || value.hasKoreanConflict(names),
      )) {
        _fail(FishCatalogFailure.noData);
      }
      // Missing Korean prose does not invalidate a separately identified photo.
      // Ambiguous exact entities and unconfirmed taxon ranks are never guessed.
      if (exact.length != 1) _fail(FishCatalogFailure.noData);
      final base = exact.single;
      if (base.isSpecies) selected = base;
      final words = scientific.trim().split(RegExp(r'\s+'));
      if (words.length == 2) {
        try {
          final candidate = await _koreanPage(species.name, names, request);
          if (candidate != null) {
            if (candidate.entityId == base.id) {
              selected = base;
              page = candidate;
            } else {
              final children = await _entities({candidate.entityId}, request);
              if (children.length != 1) _fail(FishCatalogFailure.noData);
              final child = children.single;
              final nominateName = '${words[0]} ${words[1]} ${words[1]}';
              final isNominate = _claims(child.data, 'P225').any(
                (name) =>
                    name is String &&
                    _scientificKey(name) == _scientificKey(nominateName),
              );
              final directParent = _claims(
                child.data,
                'P171',
              ).any((parent) => _map(parent)?['id'] == base.id);
              if (!isNominate ||
                  !directParent ||
                  child.hasKoreanConflict(names) ||
                  _commonKey(child.koreanTitle) !=
                      _commonKey(candidate.title)) {
                _fail(FishCatalogFailure.noData);
              }
              selected = child;
              page = candidate;
            }
          }
        } on FishCatalogException catch (error) {
          if (error.reason == FishCatalogFailure.noData) rethrow;
          rememberFailure(error);
        }
      }
    } else {
      try {
        final candidate = await _koreanPage(
          selected.koreanTitle,
          names,
          request,
        );
        if (candidate?.entityId == selected.id) page = candidate;
      } on FishCatalogException catch (error) {
        // The separately verified entity's photo can still be useful.
        rememberFailure(error);
      }
    }

    if (selected == null) {
      _fail(optionalFailure?.reason ?? FishCatalogFailure.noData);
    }
    _Photo? photo;
    try {
      photo = await _photo(selected, request);
    } on FishCatalogException catch (error) {
      // Keep a verified Korean description when image metadata is unavailable.
      rememberFailure(error);
    }
    final description = page?.description;
    if ((description == null || description.isEmpty) && photo == null) {
      _fail(optionalFailure?.reason ?? FishCatalogFailure.noData);
    }
    final sources = <String>{
      ...species.sourceName.split(' · ').where((value) => value.isNotEmpty),
      'Wikidata',
      if (description != null) '한국어 위키백과',
      if (photo != null) 'Wikimedia Commons',
    };
    return FishSpecies(
      id: species.id,
      name: species.name,
      scientificName: species.scientificName,
      category: species.category,
      family: species.family,
      habitat: species.habitat,
      maxSize: species.maxSize.trim().isNotEmpty
          ? species.maxSize
          : extractFishSizeSummary(description ?? species.feature),
      aliases: species.aliases,
      feature: description ?? species.feature,
      imageUrl: photo?.url ?? species.imageUrl,
      photoAttribution: photo?.attribution ?? species.photoAttribution,
      photoSourceUrl: photo?.sourceUrl ?? species.photoSourceUrl,
      photoLicenseUrl: photo?.licenseUrl ?? species.photoLicenseUrl,
      descriptionSourceUrl: description != null
          ? page!.sourceUrl
          : species.descriptionSourceUrl,
      descriptionAttribution: description != null
          ? '한국어 위키백과 기여자 · CC BY-SA 4.0 · '
                'https://creativecommons.org/licenses/by-sa/4.0/'
          : species.descriptionAttribution,
      sourceName: sources.join(' · '),
      sourceUrl: 'https://www.wikidata.org/wiki/${selected.id}',
      detailNeedsRetry:
          (description == null || photo == null) &&
          {
            FishCatalogFailure.network,
            FishCatalogFailure.timedOut,
            FishCatalogFailure.rateLimited,
          }.contains(optionalFailure?.reason),
    );
  }

  Future<List<_Entity>> _entities(Set<String> ids, _Request request) async {
    final data = await request(_wikidata, {
      'action': 'wbgetentities',
      'ids': ids.join('|'),
      'props': 'claims|sitelinks|labels|aliases',
      'languages': 'ko',
      'sitefilter': 'kowiki|commonswiki',
    });
    final entities = _map(data['entities']);
    if (entities == null) _fail(FishCatalogFailure.invalidResponse);
    return [
      for (final entry in entities.entries)
        if (ids.contains(entry.key) && _map(entry.value) != null)
          _Entity(entry.key, _map(entry.value)!),
    ];
  }

  Future<_KoreanPage?> _koreanPage(
    String title,
    Set<String> names,
    _Request request,
  ) async {
    final data = await request(_wikipedia, {
      'action': 'query',
      'titles': title,
      'prop': 'extracts|pageprops',
      'exintro': 1,
      'explaintext': 1,
      'exchars': 1000,
      'meta': 'siteinfo',
      'siprop': 'rightsinfo',
    });
    final query = _map(data['query']);
    final rights = _map(query?['rightsinfo']);
    final rightsUrl = _safeUrl(rights?['url'], {'creativecommons.org'});
    for (final value in _list(query?['pages'])) {
      final row = _map(value);
      if (row == null || row.containsKey('missing')) continue;
      final returnedTitle = _string(row['title']);
      final id = _string(_map(row['pageprops'])?['wikibase_item']);
      if (!names.contains(_commonKey(returnedTitle)) || !_validId(id)) continue;
      final description = _plain(_string(row['extract']), 1000);
      final licensed =
          rightsUrl != null &&
          Uri.parse(rightsUrl).path.startsWith('/licenses/by-sa/4.0/');
      return _KoreanPage(
        id,
        returnedTitle,
        description.isNotEmpty && licensed ? description : null,
      );
    }
    return null;
  }

  Future<_Photo?> _photo(_Entity entity, _Request request) async {
    final files = _claims(entity.data, 'P18')
        .whereType<String>()
        .where(
          (value) =>
              value.length <= 240 &&
              !RegExp(r'[|#<>\x00-\x1f]').hasMatch(value) &&
              RegExp(
                r'\.(jpe?g|png|webp|gif)$',
                caseSensitive: false,
              ).hasMatch(value),
        )
        .take(3)
        .toList();
    if (files.isNotEmpty) {
      final data = await request(_commons, {
        ..._imageInfo,
        'titles': files.map((name) => 'File:$name').join('|'),
      });
      final requested = files.map(_fileKey).toSet();
      for (final value in _list(_map(data['query'])?['pages'])) {
        final page = _map(value);
        if (page == null ||
            page.containsKey('missing') ||
            !requested.contains(_fileKey(_string(page['title'])))) {
          continue;
        }
        final photo = _licensedPhoto(page);
        if (photo != null) return photo;
      }
    }
    return _categoryPhoto(entity, request);
  }

  static const _imageInfo = {
    'action': 'query',
    'prop': 'imageinfo',
    'iiprop': 'url|mime|extmetadata',
    'iiurlwidth': 960,
    'iiextmetadatafilter':
        'Artist|LicenseShortName|LicenseUrl|Copyrighted|ObjectName|ImageDescription|Categories',
  };

  Future<_Photo?> _categoryPhoto(_Entity entity, _Request request) async {
    final category = entity.commonsCategory;
    if (category == null) return null;
    // One category, one page, four files; never follow subcategories/continuation.
    // Category membership only proposes files. Exact MediaInfo depicts is the proof.
    final data = await request(_commons, {
      ..._imageInfo,
      'generator': 'categorymembers',
      'gcmtitle': category,
      'gcmtype': 'file',
      'gcmlimit': 4,
    });
    final query = _map(data['query']);
    if (query == null && !data.containsKey('batchcomplete')) {
      _fail(FishCatalogFailure.invalidResponse);
    }
    final candidates = <int, _Photo>{};
    for (final value in _list(query?['pages']).take(4)) {
      final page = _map(value);
      if (page == null || page.containsKey('missing') || page['ns'] != 6) {
        continue;
      }
      final id = page['pageid'];
      final title = _string(page['title']);
      if (id is! int ||
          id <= 0 ||
          id > 999999999999 ||
          !_categoryPhotoTitle(title)) {
        continue;
      }
      final photo = _licensedPhoto(page);
      if (photo != null) candidates[id] = photo;
    }
    if (candidates.isEmpty) return null;
    final structured = await request(_commons, {
      'action': 'wbgetentities',
      'ids': candidates.keys.map((id) => 'M$id').join('|'),
      'props': 'claims',
    });
    final entities = _map(structured['entities']);
    if (entities == null) _fail(FishCatalogFailure.invalidResponse);
    for (final entry in candidates.entries) {
      final id = 'M${entry.key}';
      final media = _map(entities[id]);
      if (media != null && _depictsOnly(media, id, entity.id)) {
        return entry.value;
      }
    }
    return null;
  }

  _Photo? _licensedPhoto(Map<String, dynamic> page) {
    for (final value in _list(page['imageinfo'])) {
      final info = _map(value);
      if (info == null ||
          !{
            'image/jpeg',
            'image/png',
            'image/webp',
            'image/gif',
          }.contains(info['mime'])) {
        continue;
      }
      final metadata = _map(info['extmetadata']);
      String field(String key) => _string(_map(metadata?[key])?['value']);
      if (isNonPhotographicFishImage([
        _string(page['title']),
        _plain(field('ObjectName'), 4000),
        _plain(field('ImageDescription'), 4000),
        _plain(field('Categories'), 4000),
      ])) {
        continue;
      }
      final author = _plain(field('Artist'), 500);
      if (author.isEmpty ||
          RegExp(
            r'unknown|anonymous|assumed|no machine-readable|uncredited',
            caseSensitive: false,
          ).hasMatch(author)) {
        continue;
      }
      final license = _license(
        field('LicenseShortName'),
        field('LicenseUrl'),
        field('Copyrighted'),
      );
      final image = _safeUrl(info['thumburl'] ?? info['url'], {
        'upload.wikimedia.org',
        'thumb.wikimedia.org',
      });
      final source = _safeUrl(info['descriptionurl'], {
        'commons.wikimedia.org',
      });
      if (license == null || image == null || source == null) continue;
      return _Photo(image, '$author · ${license.name}', source, license.url);
    }
    return null;
  }

  Future<Map<String, dynamic>> _request(
    String url,
    Map<String, Object> parameters,
    _Budget budget,
  ) async {
    final remaining = budget.next();
    final timeout = remaining < requestTimeout ? remaining : requestTimeout;
    final token = CancelToken();
    Future<Map<String, dynamic>> read() async {
      final response = await _dio.get<ResponseBody>(
        url,
        queryParameters: {
          'format': 'json',
          'formatversion': 2,
          'maxlag': 10,
          'origin': '*',
          ...parameters,
        },
        cancelToken: token,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: false,
          maxRedirects: 0,
          receiveTimeout: timeout,
          sendTimeout: timeout,
          validateStatus: (_) => true,
          headers: {
            if (!_isWeb) 'User-Agent': _agent,
            'Api-User-Agent': _agent,
          },
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
      final size = int.tryParse(
        response.headers.value(Headers.contentLengthHeader) ?? '',
      );
      if (size != null && size > _maxBytes) {
        _fail(FishCatalogFailure.invalidResponse);
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in body.stream) {
        if (bytes.length + chunk.length > _maxBytes) {
          _fail(FishCatalogFailure.invalidResponse);
        }
        bytes.add(chunk);
      }
      final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (decoded is! Map<String, dynamic>) {
        _fail(FishCatalogFailure.invalidResponse);
      }
      final error = _map(decoded['error']);
      if (error != null) {
        if ({'maxlag', 'ratelimited'}.contains(error['code'])) {
          _fail(FishCatalogFailure.rateLimited);
        }
        _fail(FishCatalogFailure.invalidResponse);
      }
      return decoded;
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

typedef _Request =
    Future<Map<String, dynamic>> Function(String, Map<String, Object>);

class _Budget {
  _Budget(this.timeout);
  final Duration timeout;
  final stopwatch = Stopwatch()..start();
  int calls = 0;
  Duration next() {
    final remaining = timeout - stopwatch.elapsed;
    if (remaining <= Duration.zero) _fail(FishCatalogFailure.timedOut);
    if (++calls > 7) _fail(FishCatalogFailure.invalidResponse);
    return remaining;
  }
}

class _Entity {
  const _Entity(this.id, this.data);
  final String id;
  final Map<String, dynamic> data;
  String get koreanTitle =>
      _string(_map(_map(data['sitelinks'])?['kowiki'])?['title']);
  bool get isSpecies =>
      _claims(data, 'P105').any((rank) => _map(rank)?['id'] == 'Q7432');
  String? get commonsCategory {
    for (final value in _claims(data, 'P373').whereType<String>()) {
      final category = _categoryTitle(value);
      if (category != null) return category;
    }
    final title = _string(
      _map(_map(data['sitelinks'])?['commonswiki'])?['title'],
    );
    return title.startsWith('Category:') ? _categoryTitle(title) : null;
  }

  bool hasKoreanConflict(Set<String> names) {
    final label = _string(_map(_map(data['labels'])?['ko'])?['value']);
    final aliases = _list(
      _map(data['aliases'])?['ko'],
    ).map((value) => _string(_map(value)?['value']));
    final known = [label, ...aliases]
        .where((value) => RegExp(r'[가-힣]').hasMatch(value))
        .map(_commonKey)
        .where((value) => value.isNotEmpty)
        .toSet();
    return known.isNotEmpty && !known.any(names.contains);
  }
}

class _KoreanPage {
  const _KoreanPage(this.entityId, this.title, this.description);
  final String entityId;
  final String title;
  final String? description;
  String get sourceUrl =>
      Uri.https('ko.wikipedia.org', '/wiki/$title').toString();
}

class _Photo {
  const _Photo(this.url, this.attribution, this.sourceUrl, this.licenseUrl);
  final String url;
  final String attribution;
  final String sourceUrl;
  final String licenseUrl;
}

({String name, String url})? _license(
  String label,
  String rawUrl,
  String copyrighted,
) {
  final name = _plain(label, 100);
  final cc = RegExp(
    r'^CC BY(-SA)? (1\.0|2\.0|2\.5|3\.0|4\.0)$',
    caseSensitive: false,
  ).firstMatch(name);
  if (cc != null) {
    final type = cc.group(1) == null ? 'by' : 'by-sa';
    final version = cc.group(2)!;
    final url = _safeUrl(rawUrl, {
      'creativecommons.org',
    }, upgradeCreativeCommons: true);
    if (url == null ||
        !RegExp(
          '^/licenses/$type/${RegExp.escape(version)}/?\$',
        ).hasMatch(Uri.parse(url).path)) {
      return null;
    }
    return (name: name, url: url);
  }
  if (name.toLowerCase() == 'cc0') {
    return (
      name: name,
      url: 'https://creativecommons.org/publicdomain/zero/1.0/',
    );
  }
  if (name.toLowerCase() == 'public domain' &&
      copyrighted.toLowerCase() == 'false') {
    return (
      name: name,
      url: 'https://creativecommons.org/publicdomain/mark/1.0/',
    );
  }
  return null;
}

String? _safeUrl(
  Object? value,
  Set<String> hosts, {
  bool upgradeCreativeCommons = false,
}) {
  if (value is! String ||
      value.length > 4096 ||
      RegExp(r'[\s\x00-\x1f]').hasMatch(value)) {
    return null;
  }
  var uri = Uri.tryParse(value);
  if (uri == null ||
      uri.userInfo.isNotEmpty ||
      !hosts.contains(uri.host) ||
      (uri.hasPort && uri.port != 443)) {
    return null;
  }
  if (upgradeCreativeCommons &&
      uri.scheme == 'http' &&
      uri.host == 'creativecommons.org') {
    uri = uri.replace(scheme: 'https');
  }
  return uri.scheme == 'https' ? uri.toString() : null;
}

List<dynamic> _list(Object? value) => value is List ? value : const [];
Map<String, dynamic>? _map(Object? value) =>
    value is Map<String, dynamic> ? value : null;
String _string(Object? value) => value is String ? value : '';
String _text(String value, int max) {
  final clean = value
      .replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]'), '')
      .trim();
  return clean.length > max ? clean.substring(0, max) : clean;
}

String _plain(String value, int max) => _text(
  value
      .replaceAll(
        RegExp(r'<(script|style)\b[^>]*>[\s\S]*?</\1>', caseSensitive: false),
        '',
      )
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAllMapped(RegExp(r'&#(x[0-9a-fA-F]+|[0-9]+);'), (match) {
        final value = match.group(1)!;
        final number = int.tryParse(
          value.startsWith('x') ? value.substring(1) : value,
          radix: value.startsWith('x') ? 16 : 10,
        );
        return number != null &&
                number > 0 &&
                number <= 0x10ffff &&
                !(number >= 0xd800 && number <= 0xdfff)
            ? String.fromCharCode(number)
            : '';
      }),
  max,
);
String _commonKey(String value) => value
    .replaceAll(RegExp(r'\s*[（(][^()（）]*[)）]\s*$'), '')
    .replaceAll(RegExp(r'\s+'), '')
    .toLowerCase();
String _scientificKey(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
String _fileKey(String value) => value
    .replaceFirst(RegExp(r'^File:', caseSensitive: false), '')
    .replaceAll('_', ' ')
    .trim();
bool _validId(String value) => RegExp(r'^Q[1-9][0-9]{0,12}$').hasMatch(value);

String? _categoryTitle(String value) {
  final name = value
      .replaceFirst(RegExp(r'^Category:', caseSensitive: false), '')
      .trim();
  if (name.isEmpty ||
      name.length > 240 ||
      RegExp(r'[|#<>\x00-\x1f\x7f]').hasMatch(name)) {
    return null;
  }
  return 'Category:$name';
}

bool _categoryPhotoTitle(String title) {
  if (!title.startsWith('File:') ||
      _fileKey(title).length > 240 ||
      RegExp(r'[|#<>\x00-\x1f\x7f]').hasMatch(title) ||
      !RegExp(
        r'\.(jpe?g|png|webp|gif)$',
        caseSensitive: false,
      ).hasMatch(title)) {
    return false;
  }
  // An exact taxon tag can also annotate a range map; exclude explicit nonphotos.
  return !RegExp(
    r'(^|[ :_.-])(map|range|distribution|locator|phylogeny|diagram)([ _.:-]|$)',
    caseSensitive: false,
  ).hasMatch(title);
}

bool _depictsOnly(Map<String, dynamic> media, String mediaId, String taxonId) {
  if (media['id'] != mediaId ||
      media['type'] != 'mediainfo' ||
      media.containsKey('missing')) {
    return false;
  }
  final claims = _list(_map(media['statements'])?['P180']);
  var matched = false;
  for (final value in claims) {
    final claim = _map(value);
    if (claim?['rank'] == 'deprecated') continue;
    final snak = _map(claim?['mainsnak']);
    final datavalue = _map(snak?['datavalue']);
    final item = _map(datavalue?['value']);
    if (claim == null ||
        !{'normal', 'preferred'}.contains(claim['rank']) ||
        snak?['snaktype'] != 'value' ||
        snak?['property'] != 'P180' ||
        datavalue?['type'] != 'wikibase-entityid' ||
        item?['entity-type'] != 'item' ||
        item?['id'] != taxonId ||
        (item?['numeric-id'] != null &&
            item?['numeric-id'] != int.parse(taxonId.substring(1)))) {
      return false;
    }
    matched = true;
  }
  return matched;
}

Iterable<Object?> _claims(Map<String, dynamic> entity, String property) sync* {
  for (final value in _list(_map(entity['claims'])?[property])) {
    final claim = _map(value);
    if (claim == null || claim['rank'] == 'deprecated') continue;
    yield _map(_map(claim['mainsnak'])?['datavalue'])?['value'];
  }
}

Never _fail(FishCatalogFailure reason) => throw FishCatalogException(reason);
