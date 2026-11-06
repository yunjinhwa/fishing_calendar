import '../models/fish_species.dart';

/// Reject explicitly identified artwork; a file extension does not prove a photo.
bool isNonPhotographicFishImage(Iterable<String> labels) {
  final text = labels
      .map((label) {
        if (!label.contains('%')) return label;
        try {
          return Uri.decodeComponent(label);
        } on FormatException {
          return label;
        } on ArgumentError {
          return label;
        }
      })
      .join(' ')
      .replaceAll('_', ' ');
  return RegExp(
    r'\b(illustrations?|drawings?|paintings?|water[ -]?colou?rs?|'
    r'engravings?|lithographs?|pencil|sketch(es)?|diagrams?|maps?|icons?|logos?|'
    r'distribution[ -]?maps?|range[ -]?maps?|locator[ -]?maps?|'
    r'ai[ -]?generated|generative[ -]?ai)\b|삽화|일러스트|수채화|소묘|분포도',
    caseSensitive: false,
  ).hasMatch(text);
}

bool hasUsableFishPhoto(FishSpecies fish) {
  final uri = Uri.tryParse(fish.imageUrl?.trim() ?? '');
  return uri != null &&
      uri.scheme == 'https' &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      !isNonPhotographicFishImage([
        fish.imageUrl ?? '',
        fish.photoSourceUrl ?? '',
      ]);
}

FishSpecies withoutNonPhotographicImage(FishSpecies fish) =>
    isNonPhotographicFishImage([fish.imageUrl ?? '', fish.photoSourceUrl ?? ''])
    ? FishSpecies.fromJson({
        ...fish.toJson(),
        'imageUrl': null,
        'photoAttribution': null,
        'photoSourceUrl': null,
        'photoLicenseUrl': null,
      })
    : fish;
