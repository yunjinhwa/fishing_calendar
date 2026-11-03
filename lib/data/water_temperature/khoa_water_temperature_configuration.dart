/// Public-data portal credentials for KHOA measured water temperatures.
class KhoaWaterTemperatureConfiguration {
  const KhoaWaterTemperatureConfiguration({
    this.serviceKey = const String.fromEnvironment(
      'KHOA_WATER_TEMPERATURE_SERVICE_KEY',
      defaultValue: String.fromEnvironment('KHOA_SERVICE_KEY'),
    ),
  });

  final String serviceKey;

  String get endpoint =>
      'https://apis.data.go.kr/1192136/surveyWaterTemp/'
      'GetSurveyWaterTempApiService';

  /// Decode the portal's encoded format once; Dio supplies URL encoding.
  /// A literal `+` in a decoded key must remain a `+`.
  String? get normalizedServiceKey {
    var key = serviceKey.trim();
    if (key.contains('%')) {
      try {
        key = Uri.decodeComponent(key);
      } on ArgumentError {
        return null;
      } on FormatException {
        return null;
      }
    }
    if (key.isEmpty ||
        key.length > 1024 ||
        RegExp(r'\s|[\x00-\x1f\x7f]').hasMatch(key)) {
      return null;
    }
    return key;
  }

  bool get isConfigured => normalizedServiceKey != null;

  @override
  String toString() =>
      'KhoaWaterTemperatureConfiguration(configured: $isConfigured)';
}
