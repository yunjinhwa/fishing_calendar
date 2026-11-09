import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'fish_attribution_repository.dart';

bool _appLicensesRegistered = false;

/// Adds bundled notices once, preserving licenses registered by Flutter.
void registerAppLicenses() {
  if (_appLicensesRegistered) return;
  _appLicensesRegistered = true;

  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'klc (Korean lunar calendar data)',
    ], await rootBundle.loadString('third_party/klc_LICENSE.txt'));
    yield LicenseEntryWithLineBreaks([
      'OpenFreeMap / OpenMapTiles / OpenStreetMap',
    ], await rootBundle.loadString('third_party/open_map_water_NOTICE.txt'));
    yield LicenseEntryWithLineBreaks([
      'NIFS / Wikidata / Wikipedia / Wikimedia Commons / iNaturalist / GBIF',
    ], await rootBundle.loadString('third_party/fish_encyclopedia_NOTICE.txt'));
    final fishCredits = await FishAttributionRepository().load();
    yield LicenseEntryWithLineBreaks([
      '어류 자료 저작권 고지',
    ], formatFishCopyrightNotice(fishCredits));
  });
}

/// Required material-level credit remains readable in the license notice when
/// the dedicated species attribution screens are not part of the app.
String formatFishCopyrightNotice(Iterable<FishAttribution> fishCredits) {
  final notice = StringBuffer();
  for (final fish in fishCredits) {
    notice.writeln('${fish.speciesName} (${fish.scientificName})');
    for (final entry in fish.entries) {
      notice.writeln('${entry.title}: ${entry.attribution}');
      if (entry.sourceUrl case final String source) {
        notice.writeln('원문: $source');
      }
      if (entry.licenseUrl case final String license) {
        notice.writeln('라이선스: $license');
      }
      if (entry.notes case final String note) {
        // Keep modification disclosures, excluding cache and usage guidance.
        if (['번역', '요약', '추출', '정리'].any(note.contains)) {
          notice.writeln(note);
        }
      }
      notice.writeln();
    }
    notice.writeln();
  }
  return notice.toString();
}
