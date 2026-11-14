/// A public, static attribution entry; it contains no credentials or user data.
class AppSource {
  const AppSource({
    required this.id,
    required this.category,
    required this.title,
    required this.provider,
    this.sourceUrl,
    this.licenseLabel,
    this.licenseUrl,
  });

  final String id;
  final String category;
  final String title;
  final String provider;

  /// An official documentation/source page, never an authenticated API request.
  /// Locally generated artwork may have no external source page.
  final String? sourceUrl;
  final String? licenseLabel;
  final String? licenseUrl;
}
