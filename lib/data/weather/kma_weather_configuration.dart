class KmaWeatherConfiguration {
  const KmaWeatherConfiguration({
    this.serviceKey = const String.fromEnvironment('KMA_SERVICE_KEY'),
    this.provider = const String.fromEnvironment(
      'KMA_API_PROVIDER',
      defaultValue: 'apihub',
    ),
  });

  final String serviceKey;
  final String provider;

  String? get endpoint => switch (provider) {
    'apihub' =>
      'https://apihub.kma.go.kr/api/typ02/openApi/VilageFcstInfoService_2.0/getUltraSrtFcst',
    'data_go_kr' =>
      'https://apis.data.go.kr/1360000/VilageFcstInfoService_2.0/getUltraSrtFcst',
    _ => null,
  };

  String get authParameter => provider == 'apihub' ? 'authKey' : 'serviceKey';

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

  bool get isConfigured => endpoint != null && normalizedServiceKey != null;

  @override
  String toString() => 'KmaWeatherConfiguration(configured: $isConfigured)';
}
