import '../models/fish_species.dart';

abstract interface class FishCatalogService {
  Future<List<FishSpecies>> fetchCatalog({bool forceRefresh = false});
  Future<FishSpecies> fetchDetail(
    FishSpecies species, {
    bool forceRefresh = false,
  });
}

/// Optional metadata for a service that can read a shipped public catalog.
abstract interface class BundledFishCatalogSource {
  Future<List<FishSpecies>> loadBundledCatalog();
  bool get usesBundledCatalog;
  DateTime? get catalogDataUpdatedAt;
  FishCatalogFailure? get catalogRefreshFailure;
}

/// Local, verified field supplements; loading this source never makes requests.
abstract interface class BundledFishEnrichmentSource {
  Future<void> loadBundledEnrichment();
  FishSpecies enrichWithBundledData(FishSpecies fish);
}

abstract interface class FishDetailProvider {
  Future<FishSpecies> fetchDetail(
    FishSpecies species, {
    bool forceRefresh = false,
  });
}

/// Optional deadline scoping for providers whose own transport can cancel.
abstract interface class FishDetailDeadlineProvider {
  FishDetailProvider withDeadline(Duration timeout);
}

abstract interface class FishDetailCachePolicy {
  String get detailCacheNamespace;
}

/// A photo source that does not invoke the full description-provider chain.
abstract interface class FishThumbnailSource {
  Future<FishSpecies> fetchThumbnail(
    FishSpecies species, {
    bool forceRefresh = false,
  });
}

enum FishCatalogFailure {
  configuration,
  unauthorized,
  rateLimited,
  timedOut,
  network,
  noData,
  invalidResponse,
}

class FishCatalogException implements Exception {
  const FishCatalogException(this.reason);
  final FishCatalogFailure reason;

  @override
  String toString() => 'FishCatalogException(${reason.name})';
}
