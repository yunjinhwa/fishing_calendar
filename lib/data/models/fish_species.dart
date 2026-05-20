enum FishCategory {
  sea,
  freshwater,
}

class FishSpecies {
  final String id;
  final String name;
  final FishCategory category;
  final String family;
  final String habitat;
  final String maxSize;
  final String feature;
  final bool hasClosedSeason;
  final String closedSeasonText;
  final String imageDescription;

  const FishSpecies({
    required this.id,
    required this.name,
    required this.category,
    required this.family,
    required this.habitat,
    required this.maxSize,
    required this.feature,
    required this.hasClosedSeason,
    required this.closedSeasonText,
    required this.imageDescription,
  });

  String get categoryLabel {
    switch (category) {
      case FishCategory.sea:
        return '바다';
      case FishCategory.freshwater:
        return '민물';
    }
  }
}