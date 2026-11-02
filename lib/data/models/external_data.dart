class ExternalData {
  const ExternalData({
    required this.locationName,
    required this.latitude,
    required this.longitude,
    this.weather,
    this.airTemperature,
    this.tide,
    this.waterTemperature,
    required this.gridX,
    required this.gridY,
    required this.issuedAt,
    required this.validAt,
    required this.fetchedAt,
    this.sourceName = '기상청 초단기예보',
  });

  final String locationName;
  final double latitude;
  final double longitude;
  final String? weather;
  final double? airTemperature;
  final String? tide;
  final double? waterTemperature;
  final int gridX;
  final int gridY;
  final DateTime issuedAt;
  final DateTime validAt;
  final DateTime fetchedAt;
  final String sourceName;

  bool appliesToRecord({
    required DateTime startAt,
    required String locationName,
    double? latitude,
    double? longitude,
  }) {
    final instant = startAt.toUtc();
    final validFrom = validAt.toUtc();
    return locationName.trim() == this.locationName.trim() &&
        latitude == this.latitude &&
        longitude == this.longitude &&
        !instant.isBefore(validFrom) &&
        instant.isBefore(validFrom.add(const Duration(hours: 1)));
  }
}
