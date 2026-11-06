import '../fish/fish_size_summary.dart';

enum FishCategory { sea, freshwater, unknown }

class FishSpecies {
  final String id;
  final String name;
  final FishCategory category;
  final String family;
  final String habitat;
  // Legacy cache key; the text preserves ordinary/maximum length qualifiers.
  final String maxSize;
  final String feature;
  final String scientificName;
  final String? imageUrl;
  final String? photoAttribution;
  final String? photoSourceUrl;
  final String? photoLicenseUrl;
  final String? descriptionSourceUrl;
  final String? descriptionAttribution;
  final bool detailNeedsRetry;
  final String sourceName;
  final String? sourceUrl;
  final List<String> aliases;

  const FishSpecies({
    required this.id,
    required this.name,
    this.category = FishCategory.unknown,
    this.family = '',
    this.habitat = '',
    this.maxSize = '',
    this.feature = '',
    this.scientificName = '',
    this.imageUrl,
    this.photoAttribution,
    this.photoSourceUrl,
    this.photoLicenseUrl,
    this.descriptionSourceUrl,
    this.descriptionAttribution,
    this.detailNeedsRetry = false,
    this.sourceName = '',
    this.sourceUrl,
    this.aliases = const [],
  });

  String get categoryLabel {
    switch (category) {
      case FishCategory.sea:
        return '바다';
      case FishCategory.freshwater:
        return '민물';
      case FishCategory.unknown:
        return '서식 수역 정보 없음';
    }
  }

  String get sizeDescription =>
      maxSize.trim().isNotEmpty ? maxSize : extractFishSizeSummary(feature);

  FishSpecies withDerivedSize() {
    if (maxSize.trim().isNotEmpty) return this;
    final size = extractFishSizeSummary(feature);
    return size.isEmpty
        ? this
        : FishSpecies.fromJson({...toJson(), 'maxSize': size});
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'category': category.name,
    'family': family,
    'habitat': habitat,
    'maxSize': maxSize,
    'feature': feature,
    'scientificName': scientificName,
    'imageUrl': imageUrl,
    'photoAttribution': photoAttribution,
    'photoSourceUrl': photoSourceUrl,
    'photoLicenseUrl': photoLicenseUrl,
    'descriptionSourceUrl': descriptionSourceUrl,
    'descriptionAttribution': descriptionAttribution,
    'detailNeedsRetry': detailNeedsRetry,
    'sourceName': sourceName,
    'sourceUrl': sourceUrl,
    'aliases': aliases,
  };

  factory FishSpecies.fromJson(Map<String, dynamic> json) {
    String text(String key) => json[key] is String ? json[key] as String : '';
    final id = text('id').trim();
    final name = text('name').trim();
    if (id.isEmpty || id.length > 200 || name.isEmpty || name.length > 200) {
      throw const FormatException('Invalid cached fish identity.');
    }
    return FishSpecies(
      id: id,
      name: name,
      category: FishCategory.values.firstWhere(
        (value) => value.name == text('category'),
        orElse: () => FishCategory.unknown,
      ),
      family: text('family'),
      habitat: text('habitat'),
      maxSize: text('maxSize').trim().isNotEmpty
          ? text('maxSize')
          : extractFishSizeSummary(text('feature')),
      feature: text('feature'),
      scientificName: text('scientificName'),
      imageUrl: json['imageUrl'] is String ? json['imageUrl'] as String : null,
      photoAttribution: json['photoAttribution'] is String
          ? json['photoAttribution'] as String
          : null,
      photoSourceUrl: json['photoSourceUrl'] is String
          ? json['photoSourceUrl'] as String
          : null,
      photoLicenseUrl: json['photoLicenseUrl'] is String
          ? json['photoLicenseUrl'] as String
          : null,
      descriptionSourceUrl: json['descriptionSourceUrl'] is String
          ? json['descriptionSourceUrl'] as String
          : null,
      descriptionAttribution: json['descriptionAttribution'] is String
          ? json['descriptionAttribution'] as String
          : null,
      detailNeedsRetry: json['detailNeedsRetry'] == true,
      sourceName: text('sourceName'),
      sourceUrl: json['sourceUrl'] is String
          ? json['sourceUrl'] as String
          : null,
      aliases: json['aliases'] is List
          ? List.unmodifiable((json['aliases'] as List).whereType<String>())
          : const [],
    );
  }
}
