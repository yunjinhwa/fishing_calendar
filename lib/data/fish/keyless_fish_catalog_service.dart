import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/fish_species.dart';
import 'bundled_fish_descriptions.dart';
import 'bundled_fish_enrichment.dart';
import 'fish_api_configuration.dart';
import 'fish_catalog_service.dart';
import 'nifs_naris_fish_service.dart';
import 'recovering_fish_detail_provider.dart';
import 'reviewed_fish_photos.dart';

/// The released catalog works without network access or developer credentials.
class KeylessFishCatalogService
    implements
        FishCatalogService,
        BundledFishCatalogSource,
        BundledFishEnrichmentSource,
        FishDetailCachePolicy,
        FishThumbnailSource {
  KeylessFishCatalogService({
    AssetBundle? bundle,
    FishCatalogService? remoteCatalog,
    FishDetailProvider? detailProvider,
    FishDetailProvider? thumbnailProvider,
    bool? enableRemoteRefresh,
    DateTime Function()? clock,
  }) : _bundle = bundle ?? rootBundle,
       _remoteCatalog = remoteCatalog ?? NifsNarisFishService.instance,
       _detailProvider =
           detailProvider ?? RecoveringFishDetailProvider.instance,
       _thumbnailProvider =
           thumbnailProvider ?? RecoveringFishDetailProvider.thumbnails,
       _remoteEnabled =
           enableRemoteRefresh ??
           const FishApiConfiguration().isCatalogConfigured,
       _clock = clock ?? DateTime.now;

  static final instance = KeylessFishCatalogService();
  static const assetPath = 'assets/data/fish_catalog.json';
  static const enrichmentAssetPath = 'assets/data/fish_enrichment.json';
  final AssetBundle _bundle;
  final FishCatalogService _remoteCatalog;
  final FishDetailProvider _detailProvider;
  final FishDetailProvider _thumbnailProvider;
  final bool _remoteEnabled;
  final DateTime Function() _clock;
  Future<List<FishSpecies>>? _bundledFlight;
  Future<void>? _enrichmentFlight;
  BundledFishEnrichment _enrichment = const BundledFishEnrichment.empty();
  List<FishSpecies>? _remoteItems;
  DateTime? _bundledAt;
  DateTime? _remoteAt;
  bool _usesBundled = true;
  DateTime? _dataUpdatedAt;
  FishCatalogFailure? _refreshFailure;

  @override
  Future<void> loadBundledEnrichment() =>
      _enrichmentFlight ??= _readEnrichment();

  Future<void> _readEnrichment() async {
    try {
      final raw = await _bundle.loadString(enrichmentAssetPath);
      if (utf8.encode(raw).length > 4 * 1024 * 1024) return;
      _enrichment = BundledFishEnrichment.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } on Object {
      // An absent/damaged optional supplement cannot hide the basic catalog.
      _enrichment = const BundledFishEnrichment.empty();
    }
  }

  @override
  FishSpecies enrichWithBundledData(FishSpecies fish) =>
      ReviewedFishPhotos.apply(
        BundledFishDescriptions.apply(_enrichment.apply(fish)),
      );

  @override
  bool get usesBundledCatalog => _usesBundled;
  @override
  DateTime? get catalogDataUpdatedAt => _dataUpdatedAt;
  @override
  FishCatalogFailure? get catalogRefreshFailure => _refreshFailure;

  @override
  String get detailCacheNamespace {
    final provider = _detailProvider;
    return provider is FishDetailCachePolicy
        ? (provider as FishDetailCachePolicy).detailCacheNamespace
        : 'custom-v1';
  }

  @override
  Future<List<FishSpecies>> fetchCatalog({bool forceRefresh = false}) async {
    _refreshFailure = null;
    if (forceRefresh && _remoteEnabled) {
      try {
        final fetched = await _remoteCatalog.fetchCatalog(forceRefresh: true);
        await loadBundledEnrichment();
        final items = fetched.map(enrichWithBundledData).toList();
        if (items.isEmpty) {
          throw const FishCatalogException(FishCatalogFailure.noData);
        }
        _remoteItems = items;
        _usesBundled = false;
        _remoteAt = _clock().toUtc();
        _dataUpdatedAt = _remoteAt;
        return items;
      } on Object catch (error) {
        _refreshFailure = error is FishCatalogException
            ? error.reason
            : FishCatalogFailure.network;
        if (_remoteItems != null) return _useRemote();
      }
    }
    if (_remoteItems != null) return _useRemote();
    return loadBundledCatalog();
  }

  List<FishSpecies> _useRemote() {
    _usesBundled = false;
    _dataUpdatedAt = _remoteAt;
    return _remoteItems!;
  }

  @override
  Future<List<FishSpecies>> loadBundledCatalog() async {
    final items = await (_bundledFlight ??= _readBundle());
    _usesBundled = true;
    _dataUpdatedAt = _bundledAt;
    return items;
  }

  Future<List<FishSpecies>> _readBundle() async {
    try {
      await loadBundledEnrichment();
      final decoded = jsonDecode(await _bundle.loadString(assetPath));
      if (decoded is! Map ||
          decoded['version'] != 1 ||
          decoded['species'] is! List) {
        throw const FormatException('Invalid public fish catalog.');
      }
      final rows = decoded['species'] as List;
      final date = DateTime.tryParse('${decoded['dataUpdatedAt']}');
      if (rows.isEmpty ||
          rows.length > 10000 ||
          date == null ||
          decoded['recordCount'] != rows.length) {
        throw const FormatException('Invalid public catalog metadata.');
      }
      final ids = <String>{};
      final fish = [
        for (final row in rows)
          enrichWithBundledData(
            FishSpecies.fromJson(Map<String, dynamic>.from(row as Map)),
          ),
      ];
      if (fish.any((item) => !ids.add(item.id))) {
        throw const FormatException('Duplicate public fish identity.');
      }
      _bundledAt = date.toUtc();
      return List.unmodifiable(fish);
    } on Object {
      throw const FishCatalogException(FishCatalogFailure.invalidResponse);
    }
  }

  @override
  Future<FishSpecies> fetchDetail(
    FishSpecies species, {
    bool forceRefresh = false,
  }) async {
    await loadBundledEnrichment();
    final seed = enrichWithBundledData(species);
    final checkedAt = _enrichment.checkedAtFor(species);
    if (!forceRefresh &&
        checkedAt != null &&
        _enrichment.hasCompleteProfileFor(species)) {
      final age = _clock().toUtc().difference(checkedAt.toUtc());
      if (!age.isNegative && age < const Duration(days: 7)) return seed;
    }
    return enrichWithBundledData(
      await _detailProvider.fetchDetail(seed, forceRefresh: forceRefresh),
    );
  }

  @override
  Future<FishSpecies> fetchThumbnail(
    FishSpecies species, {
    bool forceRefresh = false,
  }) async {
    await loadBundledEnrichment();
    return enrichWithBundledData(
      await _thumbnailProvider.fetchDetail(
        enrichWithBundledData(species),
        forceRefresh: forceRefresh,
      ),
    );
  }
}
