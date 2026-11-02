import 'package:flutter/foundation.dart';

class KakaoMapConfiguration {
  const KakaoMapConfiguration({
    this.javascriptKey = const String.fromEnvironment('KAKAO_JAVASCRIPT_KEY'),
    this.baseUrl = const String.fromEnvironment(
      'KAKAO_MAP_BASE_URL',
      defaultValue: 'https://fishingbuild.firebaseapp.com',
    ),
  });

  final String javascriptKey;
  final String baseUrl;

  bool get isConfigured {
    final origin = Uri.tryParse(baseUrl);
    return RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(javascriptKey.trim()) &&
        origin != null &&
        origin.scheme == 'https' &&
        origin.host.isNotEmpty &&
        origin.userInfo.isEmpty &&
        origin.query.isEmpty &&
        origin.fragment.isEmpty &&
        (origin.path.isEmpty || origin.path == '/');
  }

  bool get supportsPlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
}
