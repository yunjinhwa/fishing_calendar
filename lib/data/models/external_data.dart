class ExternalData {
  final String locationName;
  final String weather;
  final double airTemperature;
  final String tide;
  final double waterTemperature;
  final String observationPointName;
  final DateTime observedAt;

  const ExternalData({
    required this.locationName,
    required this.weather,
    required this.airTemperature,
    required this.tide,
    required this.waterTemperature,
    required this.observationPointName,
    required this.observedAt,
  });
}