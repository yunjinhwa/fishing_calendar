/// API Hub credentials for observed weather, separate from forecast selection.
class KmaHistoricalWeatherConfiguration {
  const KmaHistoricalWeatherConfiguration({
    this.serviceKey = const String.fromEnvironment(
      'KMA_HISTORY_SERVICE_KEY',
      defaultValue: String.fromEnvironment('KMA_SERVICE_KEY'),
    ),
    this.provider = const String.fromEnvironment(
      'KMA_HISTORY_API_PROVIDER',
      defaultValue: String.fromEnvironment(
        'KMA_API_PROVIDER',
        defaultValue: 'apihub',
      ),
    ),
  });

  final String serviceKey;
  final String provider;

  String? get observationsEndpoint => provider == 'apihub'
      ? 'https://apihub.kma.go.kr/api/typ01/url/kma_sfctm2.php'
      : null;

  String? get stationsEndpoint => provider == 'apihub'
      ? 'https://apihub.kma.go.kr/api/typ01/url/stn_inf.php'
      : null;

  String? get normalizedServiceKey {
    var key = serviceKey.trim();
    if (key.contains('%')) {
      try {
        key = Uri.decodeComponent(key);
      } on Object {
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

  bool get isConfigured =>
      observationsEndpoint != null && normalizedServiceKey != null;

  @override
  String toString() =>
      'KmaHistoricalWeatherConfiguration(configured: $isConfigured)';
}
