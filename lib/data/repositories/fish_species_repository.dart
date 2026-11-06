import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../fish/fish_catalog_service.dart';
import '../fish/fish_photo_validation.dart';
import '../fish/keyless_fish_catalog_service.dart';
import '../models/fish_species.dart';

class FishCatalogSnapshot {
  const FishCatalogSnapshot({
    required this.items,
    required this.fetchedAt,
    this.isFromCache = false,
    this.isStale = false,
    this.failure,
    this.isBundled = false,
    this.dataUpdatedAt,
  });
  final List<FishSpecies> items;
  final DateTime fetchedAt;
  final bool isFromCache;
  final bool isStale;
  final FishCatalogFailure? failure;
  final bool isBundled;
  final DateTime? dataUpdatedAt;
}

/// Public encyclopedia data is cached independently of account-owned records.
class FishSpeciesRepository {
  FishSpeciesRepository({
    FishCatalogService? service,
    Future<SharedPreferences> Function()? preferences,
    DateTime Function()? clock,
    this.catalogTtl = const Duration(days: 1),
    this.detailTtl = const Duration(days: 30),
    this.partialDetailTtl = const Duration(hours: 6),
    this.transientDetailTtl = const Duration(seconds: 30),
    this.maxDetails = 128,
    this.maxStoredBytes = 4 * 1024 * 1024,
  }) : _service = service ?? KeylessFishCatalogService.instance,
       _preferences = preferences ?? SharedPreferences.getInstance,
       _clock = clock ?? DateTime.now {
    if (catalogTtl <= Duration.zero ||
        detailTtl <= Duration.zero ||
        partialDetailTtl <= Duration.zero ||
        transientDetailTtl <= Duration.zero ||
        maxDetails < 1 ||
        maxStoredBytes < 1) {
      throw ArgumentError('Fish cache limits must be positive.');
    }
  }

  static final instance = FishSpeciesRepository();
  static const _cacheKey = 'fish_encyclopedia_cache_v1';
  final FishCatalogService _service;
  final Future<SharedPreferences> Function() _preferences;
  final DateTime Function() _clock;
  final Duration catalogTtl;
  final Duration detailTtl;
  final Duration partialDetailTtl;
  final Duration transientDetailTtl;
  final int maxDetails;
  final int maxStoredBytes;
  List<FishSpecies>? _catalog;
  DateTime? _catalogAt;
  DateTime? _catalogDataAt;
  bool _isBundled = false;
  final _details =
      <String, ({FishSpecies fish, DateTime at, String namespace})>{};
  final _detailFlights = <String, Future<FishSpecies>>{};
  final _thumbnails = <String, ({FishSpecies fish, DateTime at})>{};
  final _thumbnailMisses =
      <
        String,
        ({
          FishSpecies fish,
          DateTime at,
          FishCatalogFailure reason,
          String namespace,
        })
      >{};
  final _thumbnailFlights = <String, Future<FishSpecies>>{};
  Future<FishCatalogSnapshot>? _catalogFlight;
  Future<void>? _readFlight;
  Future<void> _writeTail = Future.value();

  BundledFishCatalogSource? get _bundledSource =>
      _service is BundledFishCatalogSource
      ? _service as BundledFishCatalogSource
      : null;

  BundledFishEnrichmentSource? get _enrichmentSource =>
      _service is BundledFishEnrichmentSource
      ? _service as BundledFishEnrichmentSource
      : null;

  FishSpecies _enrich(FishSpecies fish) =>
      _enrichmentSource?.enrichWithBundledData(fish) ?? fish;

  String get _detailNamespace => _service is FishDetailCachePolicy
      ? (_service as FishDetailCachePolicy).detailCacheNamespace
      : '';

  Duration _detailLifetime(FishSpecies fish) => fish.detailNeedsRetry
      ? transientDetailTtl
      : fish.feature.trim().isEmpty || (fish.imageUrl?.trim().isEmpty ?? true)
      ? partialDetailTtl
      : detailTtl;

  Future<FishCatalogSnapshot> load({
    bool forceRefresh = false,
    bool allowNetwork = true,
  }) async {
    await (_readFlight ??= _readDisk());
    if (!allowNetwork) {
      final source = _bundledSource;
      if (_catalog == null && source != null) {
        final fish = await source.loadBundledCatalog();
        _acceptCatalog(fish);
        await _persist();
      }
      if (_catalog == null) {
        throw const FishCatalogException(FishCatalogFailure.network);
      }
      return _snapshot(cached: true);
    }
    if (!forceRefresh && _catalog != null && _fresh(_catalogAt!, catalogTtl)) {
      return _snapshot(cached: true);
    }
    final pending = _catalogFlight;
    if (pending != null) return pending;
    final request = _refreshCatalog(forceRefresh);
    _catalogFlight = request;
    try {
      return await request;
    } finally {
      if (identical(_catalogFlight, request)) _catalogFlight = null;
    }
  }

  Future<FishCatalogSnapshot> _refreshCatalog(bool force) async {
    try {
      final fish = await _service.fetchCatalog(forceRefresh: force);
      _acceptCatalog(fish);
      await _persist();
      return _snapshot(failure: _bundledSource?.catalogRefreshFailure);
    } on Object catch (error) {
      final failure = error is FishCatalogException
          ? error.reason
          : FishCatalogFailure.invalidResponse;
      if (_catalog != null) return _snapshot(cached: true, failure: failure);
      throw FishCatalogException(failure);
    }
  }

  void _acceptCatalog(List<FishSpecies> fish) {
    _validateCatalog(fish);
    _catalog = List.unmodifiable(fish.map((item) => item.withDerivedSize()));
    _catalogAt = _clock().toUtc();
    final source = _bundledSource;
    _isBundled = source?.usesBundledCatalog ?? false;
    _catalogDataAt = source?.catalogDataUpdatedAt ?? _catalogAt;
  }

  Future<FishSpecies> detail(
    FishSpecies fish, {
    bool forceRefresh = false,
    bool allowNetwork = true,
  }) async {
    await (_readFlight ??= _readDisk());
    final cached = _details[fish.id];
    final sameIdentity = cached != null && _sameSpecies(cached.fish, fish);
    if (sameIdentity &&
        (!allowNetwork ||
            (!forceRefresh &&
                cached.namespace == _detailNamespace &&
                _fresh(cached.at, _detailLifetime(cached.fish))))) {
      _details.remove(fish.id);
      _details[fish.id] = cached;
      return _thumbnails.containsKey(fish.id)
          ? _displayFish(fish)
          : _enrich(cached.fish);
    }
    if (!allowNetwork) {
      final local = _enrich(fish);
      if (_enrichmentSource != null &&
          (local.feature.trim().isNotEmpty || _hasPhoto(local))) {
        return local;
      }
      throw const FishCatalogException(FishCatalogFailure.network);
    }
    final key = '${fish.id}|${fish.scientificName}';
    final pending = _detailFlights[key];
    if (pending != null) return pending;
    final request = _refreshDetail(fish, forceRefresh);
    _detailFlights[key] = request;
    try {
      return await request;
    } finally {
      if (identical(_detailFlights[key], request)) _detailFlights.remove(key);
    }
  }

  Future<FishSpecies> _refreshDetail(FishSpecies base, bool force) async {
    try {
      final fish = (await _service.fetchDetail(
        _displayFish(base),
        forceRefresh: force,
      )).withDerivedSize();
      if (!_sameSpecies(base, fish)) {
        throw const FishCatalogException(FishCatalogFailure.invalidResponse);
      }
      _details.remove(fish.id);
      _details[fish.id] = (
        fish: fish,
        at: _clock().toUtc(),
        namespace: _detailNamespace,
      );
      while (_details.length > maxDetails) {
        _details.remove(_details.keys.first);
      }
      await _persist();
      return _thumbnails.containsKey(base.id)
          ? _displayFish(base)
          : _enrich(fish);
    } on Object catch (error) {
      final cached = _details[base.id];
      if (cached != null && _sameSpecies(cached.fish, base)) {
        return _thumbnails.containsKey(base.id)
            ? _displayFish(base)
            : _enrich(cached.fish);
      }
      throw FishCatalogException(
        error is FishCatalogException
            ? error.reason
            : FishCatalogFailure.invalidResponse,
      );
    }
  }

  /// Obtain a list photo without refreshing the full description-provider chain.
  Future<FishSpecies> thumbnail(
    FishSpecies fish, {
    bool allowNetwork = true,
    bool forceRefresh = false,
  }) async {
    await (_readFlight ??= _readDisk());
    final displayed = _displayFish(fish);
    final detail = _details[fish.id];
    final thumb = _thumbnails[fish.id];
    final freshDetail =
        detail != null &&
        _sameSpecies(detail.fish, fish) &&
        _hasPhoto(detail.fish) &&
        _fresh(detail.at, _detailLifetime(detail.fish));
    final freshThumb =
        thumb != null &&
        _sameSpecies(thumb.fish, fish) &&
        _hasPhoto(thumb.fish) &&
        _fresh(thumb.at, detailTtl);
    if ((!allowNetwork || !forceRefresh && (freshDetail || freshThumb)) &&
        _hasPhoto(displayed)) {
      return displayed;
    }
    if (!allowNetwork) {
      throw const FishCatalogException(FishCatalogFailure.network);
    }
    final miss = _thumbnailMisses[fish.id];
    if (!forceRefresh &&
        miss != null &&
        _sameSpecies(miss.fish, fish) &&
        miss.namespace == _detailNamespace &&
        _fresh(
          miss.at,
          miss.reason == FishCatalogFailure.noData
              ? partialDetailTtl
              : transientDetailTtl,
        )) {
      if (_hasPhoto(displayed)) return displayed;
      throw FishCatalogException(miss.reason);
    }
    final key = jsonEncode([fish.id, fish.name, fish.scientificName]);
    final pending = _thumbnailFlights[key];
    if (pending != null) return pending;
    final request = _refreshThumbnail(fish, forceRefresh);
    _thumbnailFlights[key] = request;
    try {
      return await request;
    } finally {
      if (identical(_thumbnailFlights[key], request)) {
        _thumbnailFlights.remove(key);
      }
    }
  }

  Future<FishSpecies> _refreshThumbnail(FishSpecies base, bool force) async {
    try {
      final source = _service;
      if (source is! FishThumbnailSource) {
        throw const FishCatalogException(FishCatalogFailure.configuration);
      }
      final result = await (source as FishThumbnailSource).fetchThumbnail(
        // Existing photos are intentionally omitted so a failed forced lookup
        // cannot refresh their age merely by returning its input unchanged.
        _withoutPhoto(_displayFish(base)),
        forceRefresh: force,
      );
      if (!_sameSpecies(base, result)) {
        throw const FishCatalogException(FishCatalogFailure.invalidResponse);
      }
      if (!_hasPhoto(result)) {
        if (result.imageUrl?.trim().isNotEmpty == true) {
          throw const FishCatalogException(FishCatalogFailure.invalidResponse);
        }
        throw FishCatalogException(
          result.detailNeedsRetry
              ? FishCatalogFailure.network
              : FishCatalogFailure.noData,
        );
      }
      final photo = FishSpecies(
        id: base.id,
        name: base.name,
        scientificName: base.scientificName,
        imageUrl: result.imageUrl?.trim(),
        photoAttribution: result.photoAttribution,
        photoSourceUrl: result.photoSourceUrl,
        photoLicenseUrl: result.photoLicenseUrl,
        sourceName:
            Uri.tryParse(result.photoSourceUrl ?? '')?.host ==
                'www.inaturalist.org'
            ? 'iNaturalist'
            : 'Wikidata · Wikimedia Commons',
        sourceUrl: result.photoSourceUrl,
      );
      _thumbnails.remove(base.id);
      _thumbnails[base.id] = (fish: photo, at: _clock().toUtc());
      _thumbnailMisses.remove(base.id);
      _trimThumbnailCaches();
      await _persist();
      return _displayFish(base);
    } on Object catch (error) {
      final reason = error is FishCatalogException
          ? error.reason
          : FishCatalogFailure.invalidResponse;
      _thumbnailMisses.remove(base.id);
      _thumbnailMisses[base.id] = (
        fish: _identityOnly(base),
        at: _clock().toUtc(),
        reason: reason,
        namespace: _detailNamespace,
      );
      _trimThumbnailCaches();
      await _persist();
      final known = _displayFish(base);
      if (_hasPhoto(known)) return known;
      throw FishCatalogException(reason);
    }
  }

  void _trimThumbnailCaches() {
    while (_thumbnails.length > maxDetails) {
      _thumbnails.remove(_thumbnails.keys.first);
    }
    while (_thumbnailMisses.length > maxDetails) {
      _thumbnailMisses.remove(_thumbnailMisses.keys.first);
    }
  }

  bool _hasPhoto(FishSpecies fish) => hasUsableFishPhoto(fish);

  FishSpecies _identityOnly(FishSpecies base) => FishSpecies(
    id: base.id,
    name: base.name,
    scientificName: base.scientificName,
  );
  FishSpecies _withoutPhoto(FishSpecies base) => FishSpecies(
    id: base.id,
    name: base.name,
    scientificName: base.scientificName,
    category: base.category,
    family: base.family,
    habitat: base.habitat,
    maxSize: base.maxSize,
    feature: base.feature,
    aliases: base.aliases,
    descriptionSourceUrl: base.descriptionSourceUrl,
    descriptionAttribution: base.descriptionAttribution,
    detailNeedsRetry: base.detailNeedsRetry,
    sourceName: base.sourceName,
    sourceUrl: base.sourceUrl,
  );
  FishSpecies _withPhoto(FishSpecies base, FishSpecies photo) => FishSpecies(
    id: base.id,
    name: base.name,
    scientificName: base.scientificName,
    category: base.category,
    family: base.family,
    habitat: base.habitat,
    maxSize: base.maxSize,
    feature: base.feature,
    aliases: base.aliases,
    imageUrl: photo.imageUrl,
    photoAttribution: photo.photoAttribution,
    photoSourceUrl: photo.photoSourceUrl,
    photoLicenseUrl: photo.photoLicenseUrl,
    descriptionSourceUrl: base.descriptionSourceUrl,
    descriptionAttribution: base.descriptionAttribution,
    detailNeedsRetry: base.detailNeedsRetry,
    sourceName: {
      ...base.sourceName.split(' · ').where((value) => value.isNotEmpty),
      ...photo.sourceName.split(' · ').where((value) => value.isNotEmpty),
    }.join(' · '),
    sourceUrl: base.sourceUrl ?? photo.sourceUrl,
  );

  bool _fresh(DateTime at, Duration ttl) {
    final age = _clock().toUtc().difference(at);
    return !age.isNegative && age < ttl;
  }

  FishCatalogSnapshot _snapshot({
    bool cached = false,
    FishCatalogFailure? failure,
  }) => FishCatalogSnapshot(
    items: List.unmodifiable(_catalog!.map(_displayFish)),
    fetchedAt: _catalogAt!,
    isFromCache: cached,
    isStale: !_fresh(_catalogAt!, catalogTtl),
    failure: failure,
    isBundled: _isBundled,
    dataUpdatedAt: _catalogDataAt,
  );

  bool _sameSpecies(FishSpecies a, FishSpecies b) =>
      a.id == b.id &&
      a.name == b.name &&
      a.scientificName.trim() == b.scientificName.trim();

  FishSpecies _displayFish(FishSpecies base) {
    final cached = _details[base.id];
    var displayed = _enrich(base);
    if (cached != null && _sameSpecies(base, cached.fish)) {
      final detail = cached.fish;
      final photo = _hasPhoto(detail) ? detail : displayed;
      final description = detail.feature.isNotEmpty ? detail : displayed;
      displayed = FishSpecies(
        id: base.id,
        name: base.name,
        category: base.category,
        family: base.family,
        habitat: displayed.habitat.isNotEmpty
            ? displayed.habitat
            : detail.habitat,
        maxSize: displayed.maxSize.trim().isNotEmpty
            ? displayed.maxSize
            : detail.maxSize,
        feature: description.feature,
        scientificName: base.scientificName,
        imageUrl: photo.imageUrl,
        photoAttribution: photo.photoAttribution,
        photoSourceUrl: photo.photoSourceUrl,
        photoLicenseUrl: photo.photoLicenseUrl,
        descriptionSourceUrl: description.descriptionSourceUrl,
        descriptionAttribution: description.descriptionAttribution,
        detailNeedsRetry: detail.detailNeedsRetry,
        sourceName: detail.sourceName.isEmpty
            ? base.sourceName
            : detail.sourceName,
        sourceUrl: detail.sourceUrl ?? base.sourceUrl,
        aliases: base.aliases,
      );
    }
    final thumbnail = _thumbnails[base.id];
    if (thumbnail != null &&
        _sameSpecies(base, thumbnail.fish) &&
        (!_hasPhoto(displayed) ||
            cached == null ||
            thumbnail.at.isAfter(cached.at))) {
      displayed = _withPhoto(displayed, thumbnail.fish);
    }
    return _enrich(displayed);
  }

  void _validateCatalog(List<FishSpecies> items) {
    if (items.isEmpty) {
      throw const FishCatalogException(FishCatalogFailure.noData);
    }
    if (items.length > 10000) {
      throw const FishCatalogException(FishCatalogFailure.invalidResponse);
    }
    final ids = <String>{};
    for (final fish in items) {
      if (fish.id.trim().isEmpty ||
          fish.id.length > 200 ||
          fish.name.trim().isEmpty ||
          fish.name.length > 200 ||
          !ids.add(fish.id)) {
        throw const FishCatalogException(FishCatalogFailure.invalidResponse);
      }
    }
  }

  Future<void> _readDisk() async {
    try {
      await _enrichmentSource?.loadBundledEnrichment();
    } on Object {
      // Optional public supplements must not prevent reading a usable cache.
    }
    try {
      final raw = (await _preferences()).getString(_cacheKey);
      if (raw == null || utf8.encode(raw).length > maxStoredBytes) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['version'] != 1) return;
      final catalog = decoded['catalog'];
      final at = DateTime.tryParse('${decoded['catalogAt']}');
      if (catalog is List &&
          at != null &&
          !at.isAfter(_clock().toUtc()) &&
          catalog.length <= 10000) {
        final fish = [
          for (final item in catalog)
            FishSpecies.fromJson(Map<String, dynamic>.from(item as Map)),
        ];
        _validateCatalog(fish);
        _catalog = List.unmodifiable(fish);
        _catalogAt = at.toUtc();
        _isBundled = decoded['isBundled'] == true;
        _catalogDataAt = DateTime.tryParse(
          '${decoded['catalogDataAt']}',
        )?.toUtc();
      }
      final details = decoded['details'];
      for (final rawDetail
          in details is List ? details.take(maxDetails) : const []) {
        if (rawDetail is! Map || rawDetail['fish'] is! Map) continue;
        final at = DateTime.tryParse('${rawDetail['at']}');
        if (at == null || at.isAfter(_clock().toUtc())) continue;
        final fish = FishSpecies.fromJson(
          Map<String, dynamic>.from(rawDetail['fish'] as Map),
        );
        _details[fish.id] = (
          fish: fish,
          at: at.toUtc(),
          namespace: rawDetail['namespace'] is String
              ? rawDetail['namespace'] as String
              : '',
        );
      }
      final thumbnails = decoded['thumbnails'];
      for (final row
          in thumbnails is List ? thumbnails.take(maxDetails) : const []) {
        if (row is! Map || row['fish'] is! Map) continue;
        final at = DateTime.tryParse('${row['at']}');
        if (at == null || at.isAfter(_clock().toUtc())) continue;
        final fish = FishSpecies.fromJson(
          Map<String, dynamic>.from(row['fish'] as Map),
        );
        if (_hasPhoto(fish)) {
          _thumbnails[fish.id] = (fish: fish, at: at.toUtc());
        }
      }
      final misses = decoded['thumbnailMisses'];
      for (final row in misses is List ? misses.take(maxDetails) : const []) {
        if (row is! Map || row['fish'] is! Map) continue;
        final at = DateTime.tryParse('${row['at']}');
        if (at == null || at.isAfter(_clock().toUtc())) continue;
        final reason = FishCatalogFailure.values
            .where((value) => value.name == row['reason'])
            .firstOrNull;
        if (reason == null) continue;
        final fish = FishSpecies.fromJson(
          Map<String, dynamic>.from(row['fish'] as Map),
        );
        _thumbnailMisses[fish.id] = (
          fish: fish,
          at: at.toUtc(),
          reason: reason,
          namespace: row['namespace'] is String
              ? row['namespace'] as String
              : '',
        );
      }
    } on Object {
      // A broken public cache must not block an online encyclopedia request.
    }
  }

  Future<void> _persist() {
    final task = _writeTail.then((_) async {
      try {
        Map<String, Object?> contents() => {
          'version': 1,
          'catalogAt': _catalogAt?.toIso8601String(),
          'catalogDataAt': _catalogDataAt?.toIso8601String(),
          'isBundled': _isBundled,
          'catalog': _catalog?.map((item) => item.toJson()).toList(),
          'details': [
            for (final entry in _details.values)
              {
                'at': entry.at.toIso8601String(),
                'fish': entry.fish.toJson(),
                'namespace': entry.namespace,
              },
          ],
          'thumbnails': [
            for (final entry in _thumbnails.values)
              {'at': entry.at.toIso8601String(), 'fish': entry.fish.toJson()},
          ],
          'thumbnailMisses': [
            for (final entry in _thumbnailMisses.values)
              {
                'at': entry.at.toIso8601String(),
                'fish': entry.fish.toJson(),
                'reason': entry.reason.name,
                'namespace': entry.namespace,
              },
          ],
        };
        var raw = jsonEncode(contents());
        while (utf8.encode(raw).length > maxStoredBytes &&
            (_details.isNotEmpty ||
                _thumbnails.isNotEmpty ||
                _thumbnailMisses.isNotEmpty)) {
          if (_thumbnailMisses.isNotEmpty) {
            _thumbnailMisses.remove(_thumbnailMisses.keys.first);
          } else if (_thumbnails.isNotEmpty) {
            _thumbnails.remove(_thumbnails.keys.first);
          } else {
            _details.remove(_details.keys.first);
          }
          raw = jsonEncode(contents());
        }
        if (utf8.encode(raw).length > maxStoredBytes) return;
        await (await _preferences()).setString(_cacheKey, raw);
      } on Object {
        // Successfully fetched data stays usable if device cache storage fails.
      }
    });
    _writeTail = task;
    return task;
  }
}
