import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

class AppInfoDetails {
  const AppInfoDetails({required this.version, required this.buildNumber});

  final String version;
  final String buildNumber;

  String get displayVersion =>
      buildNumber.isEmpty ? version : '$version ($buildNumber)';
}

abstract interface class AppInfoGateway {
  Future<AppInfoDetails> load();
}

class AppInfoLoadException implements Exception {
  const AppInfoLoadException();

  String get message => '앱 버전 정보를 불러오지 못했어요.';

  @override
  String toString() => message;
}

class PackageAppInfoGateway implements AppInfoGateway {
  const PackageAppInfoGateway();

  @override
  Future<AppInfoDetails> load() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final version = info.version.trim();
      if (version.isEmpty) throw const AppInfoLoadException();
      return AppInfoDetails(
        version: version,
        buildNumber: info.buildNumber.trim(),
      );
    } catch (_) {
      // Platform errors may contain local paths or configuration details.
      throw const AppInfoLoadException();
    }
  }
}

typedef AppInfoLinkLauncher = Future<bool> Function(Uri uri);

/// Parses a public source or attribution link without retaining unsafe input.
Uri? parsePublicAppInfoUri(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  final uri = Uri.tryParse(value.trim());
  return uri != null && isSafePublicAppInfoUri(uri) ? uri : null;
}

/// A guard for curated public source and attribution links, with no DNS lookup.
bool isSafePublicAppInfoUri(Uri uri) {
  try {
    if (uri.scheme != 'https' ||
        !uri.hasAuthority ||
        uri.userInfo.isNotEmpty ||
        uri.authority.contains('@') ||
        uri.port != 443) {
      return false;
    }

    final host = uri.host.toLowerCase();
    final labels = host.split('.');
    if (labels.length < 2 ||
        !RegExp(r'^[a-z][a-z0-9-]*$').hasMatch(labels.last) ||
        labels.any(
          (label) =>
              !RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$').hasMatch(label),
        ) ||
        const {
          'localhost',
          'local',
          'internal',
          'lan',
          'home',
          'localdomain',
          'test',
          'invalid',
          'example',
        }.contains(labels.last) ||
        host == 'home.arpa' ||
        host.endsWith('.home.arpa')) {
      return false;
    }

    if (RegExp(
      r'[\x00-\x1f\x7f\\]',
    ).hasMatch(Uri.decodeComponent(uri.toString()))) {
      return false;
    }

    if (uri.queryParametersAll.keys.any(_isCredentialParameter)) return false;
    // Public fragments such as #Licensing remain valid; token fragments do not.
    if (uri.fragment.contains('=') &&
        Uri.splitQueryString(uri.fragment).keys.any(_isCredentialParameter)) {
      return false;
    }
    return true;
  } on FormatException {
    return false;
  }
}

bool _isCredentialParameter(String name) {
  final normalized = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  return const {
    'key',
    'apikey',
    'servicekey',
    'token',
    'accesstoken',
    'refreshtoken',
    'idtoken',
    'authtoken',
    'bearer',
    'auth',
    'authorization',
    'password',
    'passwd',
    'secret',
    'clientsecret',
    'credential',
    'credentials',
    'signature',
    'sig',
    'session',
    'sessionid',
    'xgoogapikey',
    'xamzcredential',
    'xamzsignature',
    'xamzsecuritytoken',
  }.contains(normalized);
}

Future<bool> launchAppInfoLink(Uri uri, {AppInfoLinkLauncher? launcher}) async {
  if (!isSafePublicAppInfoUri(uri)) return false;
  try {
    return await (launcher ?? _launchExternalAppInfoLink)(uri);
  } catch (_) {
    return false;
  }
}

Future<bool> _launchExternalAppInfoLink(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);
