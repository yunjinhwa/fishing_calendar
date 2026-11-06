import 'package:fishing_build/data/fish/fish_catalog_service.dart';
import 'package:fishing_build/data/fish/fish_photo_validation.dart';
import 'package:fishing_build/data/fish/recovering_fish_detail_provider.dart';
import 'package:fishing_build/data/fish/reviewed_fish_photos.dart';
import 'package:fishing_build/data/models/fish_species.dart';
import 'package:flutter_test/flutter_test.dart';

const _mullet = FishSpecies(
  id: 'nifs:NS001822',
  name: '가숭어',
  scientificName: 'Planiliza haematocheilus',
  feature: '기존 한국어 설명',
  maxSize: '기존 크기',
);

class _UnusedProvider implements FishDetailProvider {
  int calls = 0;
  @override
  Future<FishSpecies> fetchDetail(
    FishSpecies species, {
    bool forceRefresh = false,
  }) async {
    calls++;
    throw const FishCatalogException(FishCatalogFailure.noData);
  }
}

void main() {
  test(
    'reviewed photo fills only an exact named species and preserves prose',
    () {
      final result = ReviewedFishPhotos.apply(_mullet);
      expect(hasUsableFishPhoto(result), isTrue);
      expect(result.photoAttribution, 'Jung-Goo MYOUNG · CC BY 3.0');
      expect(
        result.photoSourceUrl,
        endsWith('File:Planiliza_haematocheilus.png'),
      );
      expect(
        result.photoLicenseUrl,
        'https://creativecommons.org/licenses/by/3.0/',
      );
      expect(result.id, _mullet.id);
      expect(result.scientificName, _mullet.scientificName);
      expect(result.feature, _mullet.feature);
      expect(result.maxSize, _mullet.maxSize);
      final wrong = FishSpecies.fromJson({..._mullet.toJson(), 'name': '숭어'});
      expect(ReviewedFishPhotos.apply(wrong).imageUrl, isNull);
    },
  );

  test(
    'reviewed list photo needs no live metadata request or description',
    () async {
      final primary = _UnusedProvider();
      final photos = _UnusedProvider();
      final result = await RecoveringFishDetailProvider(
        primary: primary,
        photoFallback: photos,
        photoOnly: true,
      ).fetchDetail(_mullet, forceRefresh: true);
      expect(hasUsableFishPhoto(result), isTrue);
      expect(primary.calls + photos.calls, 0);
    },
  );

  test(
    'cached named watercolour is removed while description remains intact',
    () {
      final cached = FishSpecies.fromJson({
        ..._mullet.toJson(),
        'imageUrl': 'https://upload.wikimedia.org/fish.jpeg',
        'photoSourceUrl':
            'https://commons.wikimedia.org/wiki/File:Fish_pencil_drawing_%2D_water_colour.jpeg',
        'photoAttribution': 'Artist',
      });
      expect(hasUsableFishPhoto(cached), isFalse);
      final stripped = withoutNonPhotographicImage(cached);
      expect(stripped.imageUrl, isNull);
      expect(stripped.photoAttribution, isNull);
      expect(stripped.feature, _mullet.feature);
      expect(hasUsableFishPhoto(ReviewedFishPhotos.apply(stripped)), isTrue);
    },
  );

  test(
    'actual specimen photos and radiographs are allowed; explicit artwork is not',
    () {
      expect(
        isNonPhotographicFishImage(['actual fish photo and radiograph']),
        isFalse,
      );
      for (final label in [
        'pencil drawing',
        'water colour',
        'Scientific illustrations',
        'AI-generated fish',
        '분포도',
      ]) {
        expect(isNonPhotographicFishImage([label]), isTrue, reason: label);
      }
    },
  );
}
