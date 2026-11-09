import 'package:fishing_build/data/app_info/app_info_gateway.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('runtime version and build overrides are preserved', () async {
    PackageInfo.setMockInitialValues(
      appName: 'Build label',
      packageName: 'example.fishing',
      version: '7.8.9-rc.2',
      buildNumber: '4321',
      buildSignature: '',
    );

    final info = await const PackageAppInfoGateway().load();

    expect(info.version, '7.8.9-rc.2');
    expect(info.buildNumber, '4321');
    expect(info.displayVersion, '7.8.9-rc.2 (4321)');
  });

  test('missing runtime version reports a safe user-facing failure', () async {
    PackageInfo.setMockInitialValues(
      appName: 'Build label',
      packageName: 'example.fishing',
      version: '',
      buildNumber: '4321',
      buildSignature: '',
    );

    await expectLater(
      const PackageAppInfoGateway().load(),
      throwsA(
        isA<AppInfoLoadException>().having(
          (error) => error.toString(),
          'safe message',
          '앱 버전 정보를 불러오지 못했어요.',
        ),
      ),
    );
  });

  test('public revision, taxonomy, and attribution links remain usable', () {
    for (final value in [
      'https://ko.wikipedia.org/w/index.php?title=Fish&oldid=123456',
      'https://www.gbif.org/species/search?speciesKey=123&revision=2',
      'https://commons.wikimedia.org/wiki/File:Fish.jpg#Licensing',
      'https://commons.wikimedia.org/wiki/Special:FilePath/Fish.jpg?width=640',
    ]) {
      expect(parsePublicAppInfoUri(value), Uri.parse(value), reason: value);
    }
  });

  test('unsafe links never invoke the launcher', () async {
    var calls = 0;
    for (final value in [
      'http://example.com',
      'javascript:alert(1)',
      'file:///private/config.txt',
      '/relative/path',
      'https://localhost',
      'https://service.local/path',
      'https://service.internal/path',
      'https://service.home.arpa/path',
      'https://example.test/path',
      'https://127.0.0.1/path',
      'https://[::1]/path',
      'https://user:password@example.com',
      'https://user@example.com',
      'https://example.com:8443',
      'https://example.com/?api_key=secret',
      'https://example.com/?serviceKey=secret',
      'https://example.com/?access_token=secret',
      'https://example.com/?key=secret',
      'https://example.com/#token=secret',
      'https://example.com/%0Aprivate',
      'https://example.com/%5Cprivate',
    ]) {
      final launched = await launchAppInfoLink(
        Uri.parse(value),
        launcher: (_) async {
          calls++;
          return true;
        },
      );
      expect(launched, isFalse, reason: value);
      expect(parsePublicAppInfoUri(value), isNull, reason: value);
    }
    expect(calls, 0);
  });

  test('invalid and empty URL text is omitted', () {
    for (final value in <String?>[null, '', ' ', 'https://[bad', '%']) {
      expect(parsePublicAppInfoUri(value), isNull, reason: value);
    }
  });

  test(
    'launcher result and exceptions have a consistent bool result',
    () async {
      final uri = Uri.parse('https://example.com/public');
      final launchedUris = <Uri>[];
      expect(
        await launchAppInfoLink(
          uri,
          launcher: (value) async {
            launchedUris.add(value);
            return true;
          },
        ),
        isTrue,
      );
      expect(launchedUris, [uri]);
      expect(
        await launchAppInfoLink(uri, launcher: (_) async => false),
        isFalse,
      );
      expect(
        await launchAppInfoLink(
          uri,
          launcher: (_) => Future.error(StateError('platform unavailable')),
        ),
        isFalse,
      );
    },
  );
}
