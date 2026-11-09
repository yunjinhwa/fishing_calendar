import 'dart:io';

import 'package:fishing_build/data/app_info/app_source_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('current services and bundled sources have unique readable entries', () {
    final ids = appSourceCatalog.map((source) => source.id).toList();
    expect(ids.toSet(), hasLength(ids.length));
    expect(
      ids,
      containsAll(const [
        'firebase_auth',
        'cloud_firestore',
        'kakao_maps',
        'kakao_search',
        'device_location',
        'openfreemap',
        'openmaptiles',
        'openstreetmap',
        'kma_forecast',
        'kma_historical_weather',
        'kma_historical_stations',
        'khoa_tide_forecast',
        'khoa_tide_stations',
        'khoa_water_temperature',
        'khoa_water_temperature_stations',
        'korean_lunar_calendar',
        'kasi_calendar_reference',
        'tide_name_conventions',
        'nifs_species',
        'nifs_photos',
        'wikidata',
        'wikipedia_ko',
        'wikipedia_en',
        'wikisource_ko',
        'wikimedia_commons',
        'mbris',
        'gbif_taxonomy',
        'inaturalist_photos',
        'share_card_background',
      ]),
    );
    for (final source in appSourceCatalog) {
      expect(source.id, matches(RegExp(r'^[a-z][a-z0-9_]*$')));
      expect(source.category.trim(), isNotEmpty, reason: source.id);
      expect(source.title.trim(), isNotEmpty, reason: source.id);
      expect(source.provider.trim(), isNotEmpty, reason: source.id);
    }
  });

  test(
    'source and license links are public documentation without request data',
    () {
      const publicHosts = {
        'firebase.google.com',
        'apis.map.kakao.com',
        'developers.kakao.com',
        'pub.dev',
        'openfreemap.org',
        'openmaptiles.org',
        'github.com',
        'www.openstreetmap.org',
        'opendatacommons.org',
        'www.data.go.kr',
        'apihub.kma.go.kr',
        'astro.kasi.re.kr',
        'www.badatime.com',
        'www.nifs.go.kr',
        'www.wikidata.org',
        'creativecommons.org',
        'ko.wikipedia.org',
        'en.wikipedia.org',
        'ko.wikisource.org',
        'commons.wikimedia.org',
        'techdocs.gbif.org',
        'www.gbif.org',
        'www.inaturalist.org',
        'help.inaturalist.org',
      };
      const documentationParameters = {'apiSeq', 'seqApi', 'seqApiSub'};
      for (final source in appSourceCatalog) {
        for (final value in [source.sourceUrl, source.licenseUrl].nonNulls) {
          final uri = Uri.parse(value);
          expect(uri.scheme, 'https', reason: source.id);
          expect(uri.host, isIn(publicHosts), reason: value);
          expect(uri.userInfo, isEmpty, reason: value);
          expect(uri.hasPort, isFalse, reason: value);
          expect(
            uri.queryParameters.keys,
            everyElement(isIn(documentationParameters)),
            reason: value,
          );
          expect(uri.path, isNot(contains('/api/')), reason: value);
          expect(uri.path, isNot(contains('/users/')), reason: value);
          expect(uri.path, isNot(contains('/records/')), reason: value);
        }
      }
    },
  );

  test(
    'dormant NARIS and unused cloud photo storage are not active sources',
    () {
      for (final source in appSourceCatalog) {
        final identity = [
          source.id,
          source.title,
          source.provider,
          source.sourceUrl ?? '',
        ].join(' ').toLowerCase();
        expect(identity, isNot(contains('naris')), reason: source.id);
        expect(
          identity,
          isNot(contains('firebase storage')),
          reason: source.id,
        );
        expect(
          identity,
          isNot(contains('firebase_storage')),
          reason: source.id,
        );
        expect(identity, isNot(contains('cloud storage')), reason: source.id);
        expect(identity, isNot(contains('firebasestorage')), reason: source.id);
      }
    },
  );

  test(
    'local generated background does not claim an external image license',
    () {
      final background = appSourceCatalog.singleWhere(
        (source) => source.id == 'share_card_background',
      );
      expect(
        File('assets/images/share_record_background.png').existsSync(),
        isTrue,
      );
      expect(background.provider, contains('AI'));
      expect(background.sourceUrl, isNull);
      expect(background.licenseLabel, isNull);
      expect(background.licenseUrl, isNull);
      expect(
        appSourceCatalog.where((source) => source.sourceUrl == null),
        everyElement(same(background)),
      );
    },
  );

  test('individual photo licenses and translated text remain explicit', () {
    AppSource source(String id) =>
        appSourceCatalog.singleWhere((entry) => entry.id == id);

    expect(source('wikipedia_en').licenseLabel, contains('번역·요약'));
    expect(source('wikimedia_commons').licenseLabel, contains('개별 파일'));
    expect(source('inaturalist_photos').licenseLabel, contains('선택된 사진별'));
    expect(source('nifs_photos').licenseLabel, contains('개별 사진'));
  });
}
