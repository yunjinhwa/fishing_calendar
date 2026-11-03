/// Credentials for the public-data portal's KHOA tide prediction API.
class KhoaTideConfiguration {
  const KhoaTideConfiguration({
    this.serviceKey = const String.fromEnvironment('KHOA_SERVICE_KEY'),
  });

  final String serviceKey;

  String get endpoint =>
      'https://apis.data.go.kr/1192136/tideFcstHghLw/'
      'GetTideFcstHghLwApiService';

  /// Accepts either portal key format. Decode once, without treating `+` as a
  /// space; Dio performs the one required URL encoding when sending the key.
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
  String toString() => 'KhoaTideConfiguration(configured: $isConfigured)';
}
