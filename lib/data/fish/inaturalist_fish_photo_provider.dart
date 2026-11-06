import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../models/fish_species.dart';
import 'fish_catalog_service.dart';

/// A bounded, keyless fallback using curator-selected taxon photos only.
/// Descriptions, identity and sizes always remain those of the caller.
class InaturalistFishPhotoProvider implements FishDetailProvider {
  InaturalistFishPhotoProvider({
    Dio? dio,
    DateTime Function()? clock,
    this.requestTimeout = const Duration(seconds: 5),
    this.totalTimeout = const Duration(seconds: 10),
    this.requestSpacing = const Duration(seconds: 1),
    this.cacheTtl = const Duration(minutes: 5),
    this.maxCachedEntries = 128,
  }) : _dio = dio ?? Dio(),
       _clock = clock ?? DateTime.now {
    if (requestTimeout <= Duration.zero ||
        totalTimeout <= Duration.zero ||
        requestSpacing < Duration.zero ||
        cacheTtl <= Duration.zero ||
        maxCachedEntries < 1) {
      throw ArgumentError('Invalid iNaturalist request limits.');
    }
  }

  static final instance = InaturalistFishPhotoProvider();
  static const _endpoint = 'https://api.inaturalist.org/v1/taxa';
  static const _agent =
      'FishingBuild/1.0 (+https://fishingbuild.firebaseapp.com)';
  static const _isWeb = bool.fromEnvironment('dart.library.js_interop');
  static const _maxBytes = 1024 * 1024;
  final Dio _dio;
  final DateTime Function() _clock;
  final Duration requestTimeout;
  final Duration totalTimeout;
  final Duration requestSpacing;
  final Duration cacheTtl;
  final int maxCachedEntries;
  final _cache = <String, ({_Photo photo, DateTime at})>{};
  final _flights = <String, Future<_Photo>>{};
  Future<void> _requestTurn = Future<void>.value();
  DateTime? _lastRequestStarted;

  @override
  Future<FishSpecies> fetchDetail(
    FishSpecies species, {
    bool forceRefresh = false,
  }) async {
    final names = [
      species.name,
      ...species.aliases.take(64),
    ].where((name) => RegExp(r'[가-힣]').hasMatch(name)).map(_commonKey).toSet();
    final scientific = _scientificKey(species.scientificName);
    if (scientific.isEmpty || names.isEmpty) {
      _fail(FishCatalogFailure.noData);
    }
    final sortedNames = names.toList()..sort();
    final key = jsonEncode([species.id, species.name, scientific, sortedNames]);
    final cached = _cache[key];
    if (!forceRefresh && cached != null) {
      final age = _clock().toUtc().difference(cached.at);
      if (!age.isNegative && age < cacheTtl) {
        _cache.remove(key);
        _cache[key] = cached;
        return _merge(species, cached.photo);
      }
    }
    final pending = _flights[key];
    if (pending != null) return _merge(species, await pending);
    if (_flights.length >= maxCachedEntries) {
      _fail(FishCatalogFailure.rateLimited);
    }
    final request = _fetch(species.scientificName.trim(), names);
    _flights[key] = request;
    try {
      final photo = await request;
      _cache.remove(key);
      while (_cache.length >= maxCachedEntries) {
        _cache.remove(_cache.keys.first);
      }
      _cache[key] = (photo: photo, at: _clock().toUtc());
      return _merge(species, photo);
    } finally {
      if (identical(_flights[key], request)) _flights.remove(key);
    }
  }

  FishSpecies _merge(FishSpecies base, _Photo photo) => FishSpecies.fromJson({
    ...base.toJson(),
    'imageUrl': photo.url,
    'photoSourceUrl': photo.source,
    'photoAttribution': photo.attribution,
    'photoLicenseUrl': photo.license,
    'sourceName': {
      ...base.sourceName.split(' · ').where((value) => value.isNotEmpty),
      'iNaturalist',
    }.join(' · '),
  });

  Future<_Photo> _fetch(String scientific, Set<String> names) async {
    final token = CancelToken();
    final watch = Stopwatch()..start();
    Future<_Photo> lookup() async {
      final data = await _request(
        _endpoint,
        {
          'q': scientific,
          'rank': 'species',
          'is_active': 'true',
          'locale': 'ko',
          'per_page': 5,
        },
        watch,
        token,
      );
      final results = _results(data, max: 5);
      // A truncated search cannot establish a unique exact taxon.
      final count = data['total_results'];
      if (count is! int || count < 0 || count != results.length) {
        _fail(FishCatalogFailure.noData);
      }
      final exact = results
          .where(
            (row) =>
                _scientificKey(_text(row['name'])) ==
                _scientificKey(scientific),
          )
          .toList();
      if (exact.length != 1 || !_isTaxon(exact.single, scientific, names)) {
        _fail(FishCatalogFailure.noData);
      }
      final taxon = exact.single;
      final id = _id(taxon['id']);
      if (id == null) _fail(FishCatalogFailure.invalidResponse);
      final defaultPhoto = _photo(_map(taxon['default_photo']));
      if (defaultPhoto != null) return defaultPhoto;
      final detail = await _request(
        '$_endpoint/$id',
        {'locale': 'ko'},
        watch,
        token,
      );
      final rows = _results(detail, max: 1);
      if (rows.length != 1 ||
          _id(rows.single['id']) != id ||
          !_isTaxon(rows.single, scientific, names)) {
        _fail(FishCatalogFailure.noData);
      }
      final photos = rows.single['taxon_photos'];
      if (photos is! List) _fail(FishCatalogFailure.noData);
      for (final raw in photos.take(16)) {
        final row = _map(raw);
        final linked = _map(row?['taxon']);
        if (row == null ||
            _id(row['taxon_id']) != id ||
            linked == null ||
            _id(linked['id']) != id ||
            !_isTaxon(linked, scientific, names)) {
          continue;
        }
        final photo = _photo(_map(row['photo']));
        if (photo != null) return photo;
      }
      _fail(FishCatalogFailure.noData);
    }

    try {
      return await lookup().timeout(totalTimeout);
    } on TimeoutException {
      _fail(FishCatalogFailure.timedOut);
    } on DioException catch (error) {
      _fail(switch (error.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout => FishCatalogFailure.timedOut,
        _ => FishCatalogFailure.network,
      });
    } on FishCatalogException {
      rethrow;
    } on Object {
      _fail(FishCatalogFailure.invalidResponse);
    } finally {
      token.cancel();
    }
  }

  bool _isTaxon(
    Map<String, dynamic> row,
    String scientific,
    Set<String> names,
  ) {
    if (_scientificKey(_text(row['name'])) != _scientificKey(scientific) ||
        row['rank'] != 'species' ||
        row['is_active'] != true ||
        row['provisional'] == true) {
      return false;
    }
    final preferred = _text(row['preferred_common_name']);
    return !RegExp(r'[가-힣]').hasMatch(preferred) ||
        names.contains(_commonKey(preferred));
  }

  _Photo? _photo(Map<String, dynamic>? row) {
    if (row == null ||
        row['flags'] is! List ||
        (row['flags'] as List).isNotEmpty) {
      return null;
    }
    final id = _id(row['id']);
    final author = _text(row['attribution_name']);
    if (id == null ||
        author.isEmpty ||
        author.length > 500 ||
        RegExp(
          r'[<>\x00-\x1f]|unknown|anonymous|uncredited',
          caseSensitive: false,
        ).hasMatch(author)) {
      return null;
    }
    // Mapping follows iNaturalist's own Shared::LicenseModule constants.
    final license = switch (row['license_code']) {
      'cc0' => (
        name: 'CC0 1.0',
        url: 'https://creativecommons.org/publicdomain/zero/1.0/',
      ),
      'cc-by' => (
        name: 'CC BY 4.0',
        url: 'https://creativecommons.org/licenses/by/4.0/',
      ),
      'cc-by-sa' => (
        name: 'CC BY-SA 4.0',
        url: 'https://creativecommons.org/licenses/by-sa/4.0/',
      ),
      _ => null,
    };
    if (license == null) return null;
    final image = _imageUrl(row['medium_url'] ?? row['large_url'], id);
    if (image == null) return null;
    return _Photo(
      image,
      'https://www.inaturalist.org/photos/$id',
      '$author · ${license.name}',
      license.url,
    );
  }

  String? _imageUrl(Object? value, int id) {
    if (value is! String || value.length > 2000) return null;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        !{
          'static.inaturalist.org',
          'inaturalist-open-data.s3.amazonaws.com',
        }.contains(uri.host) ||
        uri.hasQuery ||
        uri.hasFragment ||
        !RegExp(
          '^/photos/$id/(medium|large)\\.(jpe?g|png|webp|gif)\$',
          caseSensitive: false,
        ).hasMatch(uri.path)) {
      return null;
    }
    return uri.toString();
  }

  Future<void> _waitTurn(CancelToken token) async {
    final previous = _requestTurn;
    final done = Completer<void>();
    _requestTurn = done.future;
    try {
      await previous;
      if (token.isCancelled) _fail(FishCatalogFailure.timedOut);
      final last = _lastRequestStarted;
      if (last != null) {
        final delay = requestSpacing - DateTime.now().difference(last);
        if (delay > Duration.zero) await Future<void>.delayed(delay);
      }
      if (token.isCancelled) _fail(FishCatalogFailure.timedOut);
      _lastRequestStarted = DateTime.now();
    } finally {
      done.complete();
    }
  }

  Future<Map<String, dynamic>> _request(
    String url,
    Map<String, Object> parameters,
    Stopwatch watch,
    CancelToken token,
  ) async {
    await _waitTurn(token);
    final remaining = totalTimeout - watch.elapsed;
    if (remaining <= Duration.zero) _fail(FishCatalogFailure.timedOut);
    final timeout = remaining < requestTimeout ? remaining : requestTimeout;
    final response = await _dio.get<ResponseBody>(
      url,
      queryParameters: parameters,
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
    if (status == 404) _fail(FishCatalogFailure.noData);
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
    final result = _map(jsonDecode(utf8.decode(bytes.takeBytes())));
    if (result == null) _fail(FishCatalogFailure.invalidResponse);
    return result;
  }

  List<Map<String, dynamic>> _results(
    Map<String, dynamic> data, {
    required int max,
  }) {
    final rows = data['results'];
    if (rows is! List || rows.length > max || rows.any((row) => row is! Map)) {
      _fail(FishCatalogFailure.invalidResponse);
    }
    return rows.map((row) => Map<String, dynamic>.from(row as Map)).toList();
  }

  static Map<String, dynamic>? _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : null;
  static String _text(Object? value) => value is String ? value.trim() : '';
  static String _scientificKey(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  static String _commonKey(String value) =>
      value.replaceAll(RegExp(r'\s+'), '').toLowerCase();
  static int? _id(Object? value) =>
      value is int && value > 0 && value <= 9007199254740991 ? value : null;
  static Never _fail(FishCatalogFailure reason) =>
      throw FishCatalogException(reason);
}

class _Photo {
  const _Photo(this.url, this.source, this.attribution, this.license);
  final String url;
  final String source;
  final String attribution;
  final String license;
}
