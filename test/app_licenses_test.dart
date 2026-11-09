import 'package:fishing_build/data/app_info/app_licenses.dart';
import 'package:fishing_build/data/app_info/fish_attribution_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'license notice preserves exact per-material attribution and changes',
    () {
      final notice = formatFishCopyrightNotice(const [
        FishAttribution(
          id: 'example',
          speciesName: '예시 어종',
          scientificName: 'Example species',
          entries: [
            FishAttributionEntry(
              kind: FishAttributionKind.photo,
              attribution: '사진 저작자 · CC BY 3.0',
              sourceUrl: 'https://commons.wikimedia.org/wiki/File:Example.jpg',
              licenseUrl: 'https://creativecommons.org/licenses/by/3.0/',
            ),
            FishAttributionEntry(
              kind: FishAttributionKind.description,
              attribution: '위키백과 기여자 · CC BY-SA 4.0 · 한국어 번역·요약',
              sourceUrl:
                  'https://en.wikipedia.org/w/index.php?title=Example&oldid=123',
              licenseUrl: 'https://creativecommons.org/licenses/by-sa/4.0/',
              notes: '검토한 원문에서 요약',
            ),
            FishAttributionEntry(
              kind: FishAttributionKind.size,
              attribution: '별도 크기 원문 저작자',
              sourceUrl: 'https://ko.wikipedia.org/wiki/Example',
              content: '출처 화면에는 불필요한 크기 수치',
              notes: '캐시 읽기 안내',
            ),
          ],
        ),
      ]);
      expect(notice, contains('예시 어종 (Example species)'));
      expect(notice, contains('사진 저작자 · CC BY 3.0'));
      expect(
        notice,
        contains('https://commons.wikimedia.org/wiki/File:Example.jpg'),
      );
      expect(notice, contains('https://creativecommons.org/licenses/by/3.0/'));
      expect(notice, contains('한국어 번역·요약'));
      expect(notice, contains('oldid=123'));
      expect(
        notice,
        contains('https://creativecommons.org/licenses/by-sa/4.0/'),
      );
      expect(notice, contains('검토한 원문에서 요약'));
      expect(notice, contains('별도 크기 원문 저작자'));
      expect(notice, isNot(contains('불필요한 크기 수치')));
      expect(notice, isNot(contains('캐시 읽기 안내')));
    },
  );

  test(
    'repeated registration keeps notices and all bundled species only once',
    () async {
      SharedPreferences.setMockInitialValues({});
      registerAppLicenses();
      registerAppLicenses();
      final entries = await LicenseRegistry.licenses.toList();
      final notices = entries
          .where((entry) => entry.packages.contains('어류 자료 저작권 고지'))
          .toList();
      expect(notices, hasLength(1));
      final text = notices
          .expand((entry) => entry.paragraphs)
          .map((p) => p.text)
          .join('\n');
      expect(text.contains('가는곰치 (Strophidon sathete)'), isTrue);
      expect(text.contains('국립수산과학원'), isTrue);
      expect(text.contains('creativecommons.org'), isTrue);
      for (final package in [
        'klc (Korean lunar calendar data)',
        'OpenFreeMap / OpenMapTiles / OpenStreetMap',
        'NIFS / Wikidata / Wikipedia / Wikimedia Commons / iNaturalist / GBIF',
      ]) {
        expect(
          entries.where((entry) => entry.packages.contains(package)),
          hasLength(1),
        );
      }
    },
  );
}
