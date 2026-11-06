/// Credentials issued separately by NIFS and NARIS, supplied at build time.
class FishApiConfiguration {
  const FishApiConfiguration({
    this.nifsApiKey = const String.fromEnvironment('NIFS_SPECIES_API_KEY'),
    this.narisApiKey = const String.fromEnvironment('NARIS_API_KEY'),
  });

  final String nifsApiKey;
  final String narisApiKey;

  String? get normalizedNifsApiKey => _normalize(nifsApiKey);
  String? get normalizedNarisApiKey => _normalize(narisApiKey);
  bool get isCatalogConfigured => normalizedNifsApiKey != null;
  bool get isDetailConfigured => normalizedNarisApiKey != null;

  static String? _normalize(String raw) {
    final key = raw.trim();
    if (key.isEmpty ||
        key.length > 1024 ||
        RegExp(r'\s|[\x00-\x1f\x7f]').hasMatch(key)) {
      return null;
    }
    // These are issuer credentials, not data.go.kr encoded service keys.
    return key;
  }

  @override
  String toString() =>
      'FishApiConfiguration(catalog: $isCatalogConfigured, '
      'detail: $isDetailConfigured)';
}
