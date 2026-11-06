import '../models/fish_species.dart';
import 'fish_catalog_service.dart';
import 'mbris_fish_detail_provider.dart';
import 'wikimedia_fish_detail_provider.dart';

/// Combine independent, verified fields without letting one outage erase another.
class CompositeFishDetailProvider
    implements
        FishDetailProvider,
        FishDetailCachePolicy,
        FishDetailDeadlineProvider {
  CompositeFishDetailProvider({
    FishDetailProvider? wikimedia,
    FishDetailProvider? korean,
    bool? enableKorean,
  }) : _wikimedia = wikimedia ?? WikimediaFishDetailProvider.instance,
       _korean = korean ?? MbrisFishDetailProvider.instance,
       _enableKorean =
           enableKorean ??
           (korean != null || MbrisFishDetailProvider.instance.isConfigured);

  static final instance = CompositeFishDetailProvider();
  final FishDetailProvider _wikimedia;
  final FishDetailProvider _korean;
  final bool _enableKorean;

  @override
  CompositeFishDetailProvider withDeadline(Duration timeout) {
    FishDetailProvider scoped(FishDetailProvider provider) =>
        provider is FishDetailDeadlineProvider
        ? (provider as FishDetailDeadlineProvider).withDeadline(timeout)
        : provider;
    return CompositeFishDetailProvider(
      wikimedia: scoped(_wikimedia),
      korean: scoped(_korean),
      enableKorean: _enableKorean,
    );
  }

  @override
  String get detailCacheNamespace =>
      'wikimedia-v4;mbris-v2:${_enableKorean ? 'enabled' : 'disabled'}';

  @override
  Future<FishSpecies> fetchDetail(
    FishSpecies species, {
    bool forceRefresh = false,
  }) async {
    Future<_Outcome> get(FishDetailProvider provider) async {
      try {
        final value = await provider.fetchDetail(
          species,
          forceRefresh: forceRefresh,
        );
        if (value.id != species.id ||
            value.name != species.name ||
            value.scientificName != species.scientificName) {
          return const _Outcome.failure(FishCatalogFailure.invalidResponse);
        }
        return _Outcome.success(value);
      } on Object catch (error) {
        return _Outcome.failure(
          error is FishCatalogException
              ? error.reason
              : FishCatalogFailure.invalidResponse,
        );
      }
    }

    final results = await Future.wait([
      get(_wikimedia),
      if (_enableKorean) get(_korean),
    ]);
    final wiki = results.first.fish;
    final korean = results.length > 1 ? results[1].fish : null;
    final valid = results.map((value) => value.fish).whereType<FishSpecies>();
    if (valid.isEmpty) {
      // Service failures must not be reported as a non-existent species.
      for (final reason in [
        FishCatalogFailure.rateLimited,
        FishCatalogFailure.timedOut,
        FishCatalogFailure.network,
        FishCatalogFailure.unauthorized,
        FishCatalogFailure.invalidResponse,
        FishCatalogFailure.configuration,
      ]) {
        if (results.any((value) => value.failure == reason)) {
          throw FishCatalogException(reason);
        }
      }
      throw const FishCatalogException(FishCatalogFailure.noData);
    }
    final description = korean?.feature.trim().isNotEmpty == true
        ? korean
        : wiki?.feature.trim().isNotEmpty == true
        ? wiki
        : null;
    final photo = wiki?.imageUrl?.trim().isNotEmpty == true
        ? wiki
        : korean?.imageUrl?.trim().isNotEmpty == true
        ? korean
        : null;
    final size = korean?.maxSize.trim().isNotEmpty == true
        ? korean
        : wiki?.maxSize.trim().isNotEmpty == true
        ? wiki
        : null;
    final retry = results.any(
      (value) => {
        FishCatalogFailure.network,
        FishCatalogFailure.timedOut,
        FishCatalogFailure.rateLimited,
      }.contains(value.failure),
    );
    final sources = <String>{
      ...species.sourceName.split(' · ').where((value) => value.isNotEmpty),
      for (final fish in [description, photo, size].whereType<FishSpecies>())
        ...fish.sourceName.split(' · ').where((value) => value.isNotEmpty),
    };
    return FishSpecies(
      id: species.id,
      name: species.name,
      scientificName: species.scientificName,
      category: species.category,
      family: species.family,
      habitat: species.habitat,
      aliases: species.aliases,
      maxSize: size?.maxSize ?? species.maxSize,
      feature: description?.feature ?? species.feature,
      imageUrl: photo?.imageUrl ?? species.imageUrl,
      photoAttribution: photo?.photoAttribution ?? species.photoAttribution,
      photoSourceUrl: photo?.photoSourceUrl ?? species.photoSourceUrl,
      photoLicenseUrl: photo?.photoLicenseUrl ?? species.photoLicenseUrl,
      descriptionSourceUrl:
          description?.descriptionSourceUrl ?? species.descriptionSourceUrl,
      descriptionAttribution:
          description?.descriptionAttribution ?? species.descriptionAttribution,
      detailNeedsRetry: retry || valid.any((fish) => fish.detailNeedsRetry),
      sourceName: sources.join(' · '),
      sourceUrl:
          description?.sourceUrl ?? photo?.sourceUrl ?? species.sourceUrl,
    );
  }
}

class _Outcome {
  const _Outcome.success(this.fish) : failure = null;
  const _Outcome.failure(this.failure) : fish = null;
  final FishSpecies? fish;
  final FishCatalogFailure? failure;
}
