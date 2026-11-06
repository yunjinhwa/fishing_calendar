import 'dart:async';

import '../models/fish_species.dart';
import 'bundled_fish_descriptions.dart';
import 'composite_fish_detail_provider.dart';
import 'fish_catalog_service.dart';
import 'fish_photo_validation.dart';
import 'fish_taxonomy_resolver.dart';
import 'inaturalist_fish_photo_provider.dart';
import 'wikimedia_fish_detail_provider.dart';
import 'reviewed_fish_photos.dart';

/// Fill verified gaps without replacing existing fields or the catalog identity.
class RecoveringFishDetailProvider
    implements FishDetailProvider, FishDetailCachePolicy {
  RecoveringFishDetailProvider({
    required FishDetailProvider primary,
    FishDetailProvider? photoFallback,
    FishTaxonomyResolver? taxonomy,
    this.photoOnly = false,
    this.recoveryTimeout = const Duration(seconds: 12),
  }) : _primary = primary,
       _photos = photoFallback ?? InaturalistFishPhotoProvider.instance,
       _taxonomy = taxonomy ?? GbifFishTaxonomyResolver.instance {
    if (recoveryTimeout <= Duration.zero) {
      throw ArgumentError.value(recoveryTimeout, 'recoveryTimeout');
    }
  }

  static final instance = RecoveringFishDetailProvider(
    primary: CompositeFishDetailProvider.instance,
  );
  static final thumbnails = RecoveringFishDetailProvider(
    primary: WikimediaFishDetailProvider.instance,
    photoOnly: true,
  );
  final FishDetailProvider _primary;
  final FishDetailProvider _photos;
  final FishTaxonomyResolver _taxonomy;
  final bool photoOnly;
  final Duration recoveryTimeout;

  @override
  String get detailCacheNamespace {
    final primary = _primary;
    final namespace = primary is FishDetailCachePolicy
        ? (primary as FishDetailCachePolicy).detailCacheNamespace
        : 'primary-v1';
    return '$namespace;recovery-v2:actual-photos,'
        'reviewed-photos-v${ReviewedFishPhotos.revision},'
        'commons-depicts,inaturalist,gbif-colxr,'
        'korean-supplements-v1:${photoOnly ? 'photo' : 'detail'}';
  }

  @override
  Future<FishSpecies> fetchDetail(
    FishSpecies species, {
    bool forceRefresh = false,
  }) async {
    final failures = <FishCatalogFailure>[];
    var result = ReviewedFishPhotos.apply(withoutNonPhotographicImage(species));
    if (photoOnly && _hasPhoto(result)) return result;
    try {
      final first = await _primary.fetchDetail(
        result,
        forceRefresh: forceRefresh,
      );
      _checkIdentity(first, species);
      result = withoutNonPhotographicImage(first);
    } on Object catch (error) {
      failures.add(_reason(error));
    }
    if (!photoOnly) result = BundledFishDescriptions.apply(result);
    if (_complete(result)) {
      return FishSpecies.fromJson({
        ...result.toJson(),
        'detailNeedsRetry': false,
      });
    }

    final elapsed = Stopwatch()..start();
    var recoveryExpired = false;
    Future<T> withinBudget<T>(Future<T> Function() action) async {
      final remaining = recoveryTimeout - elapsed.elapsed;
      if (recoveryExpired || remaining <= Duration.zero) {
        throw const FishCatalogException(FishCatalogFailure.timedOut);
      }
      try {
        return await action().timeout(
          remaining,
          onTimeout: () {
            recoveryExpired = true;
            throw const FishCatalogException(FishCatalogFailure.timedOut);
          },
        );
      } on TimeoutException {
        throw const FishCatalogException(FishCatalogFailure.timedOut);
      }
    }

    // Missing prose needs taxonomy independently of the photo result. When
    // only a photo is missing, try the photo source before spending a taxonomy
    // request that a successful image would make unnecessary.
    final photo = !_hasPhoto(result)
        ? () async {
            try {
              final value = await withinBudget(
                () => _photos.fetchDetail(
                  _withoutDetails(species),
                  forceRefresh: forceRefresh,
                ),
              );
              _checkIdentity(value, species);
              return _photoOnly(value);
            } on Object catch (error) {
              failures.add(_reason(error));
              return null;
            }
          }()
        : Future<FishSpecies?>.value();
    Future<FishTaxonomyResolution?> resolve() async {
      try {
        final value = await withinBudget(
          () => _taxonomy.resolve(species, forceRefresh: forceRefresh),
        );
        if (value.originalScientificName.trim().toLowerCase() !=
            species.scientificName.trim().toLowerCase()) {
          throw const FishCatalogException(FishCatalogFailure.invalidResponse);
        }
        return value;
      } on Object catch (error) {
        failures.add(_reason(error));
        return null;
      }
    }

    final resolution = !photoOnly && result.feature.trim().isEmpty
        ? resolve()
        : null;
    final extraPhoto = await photo;
    if (extraPhoto != null) result = _mergeMissing(result, extraPhoto);
    if (_complete(result)) {
      return FishSpecies.fromJson({
        ...result.toJson(),
        'detailNeedsRetry': false,
      });
    }
    final names = await (resolution ?? resolve());
    if (!_complete(result) && names != null) {
      // The concrete resolver yields at most one explicitly verified accepted
      // species name. Cap injected implementations too; never fan out a search.
      for (final alternative in names.alternatives.take(1)) {
        final scientific = alternative.scientificName.trim();
        if (scientific.isEmpty ||
            scientific.toLowerCase() == species.scientificName.toLowerCase()) {
          continue;
        }
        final target = FishSpecies.fromJson({
          ..._withoutDetails(species).toJson(),
          'scientificName': scientific,
        });
        try {
          final recovered = await withinBudget(() {
            final remaining = recoveryTimeout - elapsed.elapsed;
            final primary = _primary;
            final scoped = primary is FishDetailDeadlineProvider
                ? (primary as FishDetailDeadlineProvider).withDeadline(
                    remaining,
                  )
                : primary;
            return scoped.fetchDetail(target, forceRefresh: forceRefresh);
          });
          _checkIdentity(recovered, target);
          // A taxonomy synonym is a candidate, not permission to ignore a
          // conflicting common name. Live Korean prose providers confirm both.
          if (!alternative.commonNameConfirmed && !_confirmsKorean(recovered)) {
            continue;
          }
          final restored = FishSpecies.fromJson({
            ...recovered.toJson(),
            'scientificName': species.scientificName,
            'sourceName': {
              ...recovered.sourceName.split(' · '),
              alternative.sourceName,
            }.where((value) => value.isNotEmpty).join(' · '),
          });
          result = _mergeMissing(result, restored);
        } on Object catch (error) {
          failures.add(_reason(error));
        }
      }
    }
    if (!_hasContent(result)) {
      for (final failure in [
        FishCatalogFailure.rateLimited,
        FishCatalogFailure.timedOut,
        FishCatalogFailure.network,
        FishCatalogFailure.unauthorized,
        FishCatalogFailure.invalidResponse,
        FishCatalogFailure.configuration,
      ]) {
        if (failures.contains(failure)) throw FishCatalogException(failure);
      }
      throw const FishCatalogException(FishCatalogFailure.noData);
    }
    return FishSpecies.fromJson({
      ...result.toJson(),
      'detailNeedsRetry':
          !_complete(result) &&
          (result.detailNeedsRetry ||
              failures.any(
                (reason) => {
                  FishCatalogFailure.network,
                  FishCatalogFailure.timedOut,
                  FishCatalogFailure.rateLimited,
                }.contains(reason),
              )),
    });
  }

  bool _complete(FishSpecies fish) =>
      _hasPhoto(fish) && (photoOnly || fish.feature.trim().isNotEmpty);

  bool _hasContent(FishSpecies fish) =>
      _hasPhoto(fish) || !photoOnly && fish.feature.trim().isNotEmpty;
}

void _checkIdentity(FishSpecies value, FishSpecies expected) {
  if (value.id != expected.id ||
      value.name != expected.name ||
      value.scientificName != expected.scientificName) {
    throw const FishCatalogException(FishCatalogFailure.invalidResponse);
  }
}

bool _confirmsKorean(FishSpecies fish) {
  if (!RegExp(r'[가-힣]').hasMatch(fish.feature)) return false;
  final source = Uri.tryParse(fish.descriptionSourceUrl ?? '');
  if (source == null ||
      source.scheme != 'https' ||
      source.userInfo.isNotEmpty) {
    return false;
  }
  return source.host == 'ko.wikipedia.org' ||
      source.host == 'www.data.go.kr' &&
          source.path == '/data/15094770/openapi.do' &&
          fish.descriptionAttribution == '국립해양생물자원관 MBRIS';
}

bool _hasPhoto(FishSpecies fish) => hasUsableFishPhoto(fish);

FishSpecies _withoutDetails(FishSpecies fish) => FishSpecies.fromJson({
  ...fish.toJson(),
  'feature': '',
  'maxSize': '',
  'imageUrl': null,
  'photoAttribution': null,
  'photoSourceUrl': null,
  'photoLicenseUrl': null,
  'descriptionSourceUrl': null,
  'descriptionAttribution': null,
  'detailNeedsRetry': false,
});

FishSpecies _photoOnly(FishSpecies fish) => FishSpecies.fromJson({
  ...fish.toJson(),
  'feature': '',
  'maxSize': '',
  'descriptionSourceUrl': null,
  'descriptionAttribution': null,
});

FishSpecies _mergeMissing(FishSpecies base, FishSpecies extra) {
  final text = base.feature.trim().isEmpty && extra.feature.trim().isNotEmpty;
  final photo = !_hasPhoto(base) && _hasPhoto(extra);
  final size = base.maxSize.trim().isEmpty && extra.maxSize.trim().isNotEmpty;
  if (!text && !photo && !size) return base;
  return FishSpecies.fromJson({
    ...base.toJson(),
    if (text) ...{
      'feature': extra.feature,
      'descriptionSourceUrl': extra.descriptionSourceUrl,
      'descriptionAttribution': extra.descriptionAttribution,
    },
    if (photo) ...{
      'imageUrl': extra.imageUrl,
      'photoAttribution': extra.photoAttribution,
      'photoSourceUrl': extra.photoSourceUrl,
      'photoLicenseUrl': extra.photoLicenseUrl,
    },
    if (size) 'maxSize': extra.maxSize,
    'detailNeedsRetry': base.detailNeedsRetry || extra.detailNeedsRetry,
    'sourceName': {
      ...base.sourceName.split(' · '),
      ...extra.sourceName.split(' · '),
    }.where((value) => value.isNotEmpty).join(' · '),
  });
}

FishCatalogFailure _reason(Object error) => error is FishCatalogException
    ? error.reason
    : FishCatalogFailure.invalidResponse;
