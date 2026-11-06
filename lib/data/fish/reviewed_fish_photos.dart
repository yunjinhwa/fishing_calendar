import '../models/fish_species.dart';
import 'fish_photo_validation.dart';

/// Photographic files whose subject and license were reviewed on 2026-11-05.
/// An absent structured Wikidata link does not imply the photo does not exist.
class ReviewedFishPhotos {
  static const revision = 2;
  static const _entries =
      <
        String,
        ({
          String name,
          String image,
          String file,
          String author,
          String license,
        })
      >{
        'decapterus maruadsi': (
          name: '가라지',
          image:
              'https://thumb.wikimedia.org/wikipedia/commons/thumb/a/a8/'
              'Decapterus_maruadsi.jpg/960px-Decapterus_maruadsi.jpg',
          file: 'Decapterus_maruadsi.jpg',
          author: 're_nebel · CC BY 4.0',
          license: 'https://creativecommons.org/licenses/by/4.0/',
        ),
        'planiliza haematocheilus': (
          name: '가숭어',
          image:
              'https://upload.wikimedia.org/wikipedia/commons/7/79/'
              'Planiliza_haematocheilus.png',
          file: 'Planiliza_haematocheilus.png',
          author: 'Jung-Goo MYOUNG · CC BY 3.0',
          license: 'https://creativecommons.org/licenses/by/3.0/',
        ),
        'acanthopsetta nadeshnyi': (
          name: '가시가자미',
          image:
              'https://thumb.wikimedia.org/wikipedia/commons/thumb/8/84/'
              'Acanthopsetta_nadeshnyi.png/960px-Acanthopsetta_nadeshnyi.png',
          file: 'Acanthopsetta_nadeshnyi.png',
          // The original figure shows an actual type specimen and its radiograph.
          author:
              'Voronina, Elena P.; Volkova, Galina A. · '
              'CC BY 4.0 · 표본 사진 및 방사선 사진',
          license: 'https://creativecommons.org/licenses/by/4.0/',
        ),
      };

  static FishSpecies apply(FishSpecies fish) {
    if (hasUsableFishPhoto(fish)) return fish;
    final entry = _entries[fish.scientificName.trim().toLowerCase()];
    if (entry == null || entry.name != fish.name.trim()) return fish;
    return FishSpecies.fromJson({
      ...fish.toJson(),
      'imageUrl': entry.image,
      'photoSourceUrl': 'https://commons.wikimedia.org/wiki/File:${entry.file}',
      'photoAttribution': entry.author,
      'photoLicenseUrl': entry.license,
      'sourceName': {
        ...fish.sourceName.split(' · ').where((name) => name.isNotEmpty),
        'Wikimedia Commons',
      }.join(' · '),
    });
  }
}
