enum WaterArea {
  unknown,
  marine,
  freshwater,
  inland;

  bool get providesMarineData => this == marine;

  String get label => switch (this) {
    unknown => '판별되지 않음',
    marine => '바다',
    freshwater => '민물',
    inland => '내륙',
  };
}
