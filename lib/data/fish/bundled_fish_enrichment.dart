import 'dart:convert';

import '../models/fish_species.dart';
import 'fish_photo_validation.dart';
import 'fish_size_summary.dart';

/// A public, reviewed fallback. It does not mark remote caches as refreshed.
class BundledFishEnrichment {
  const BundledFishEnrichment.empty()
    : _entries = const {},
      dataUpdatedAt = null;

  BundledFishEnrichment._(this._entries, this.dataUpdatedAt);

  factory BundledFishEnrichment.fromJson(Map<String, dynamic> json) {
    _keys(json, {'version', 'recordCount', 'dataUpdatedAt', 'records'});
    if (utf8.encode(jsonEncode(json)).length > 4 * 1024 * 1024 ||
        json['version'] != 1 ||
        json['recordCount'] is! int ||
        json['records'] is! List) {
      _invalid();
    }
    final updated = _date(json['dataUpdatedAt']);
    final rows = json['records'] as List;
    if (rows.length > 800 || json['recordCount'] != rows.length) _invalid();
    final entries = <String, _Entry>{};
    final ids = <String>{};
    for (final value in rows) {
      final row = _map(value);
      _keys(row, {
        'checkedAt',
        'result',
        'habitatProvenance',
        'sizeProvenance',
      });
      final checked = _date(row['checkedAt']);
      if (checked.isAfter(updated)) _invalid();
      final result = _map(row['result']);
      _checkResult(result);
      final fish = FishSpecies.fromJson(result);
      if (!ids.add(fish.id)) _invalid();
      final description = _description(fish);
      final photo = _photo(fish);
      final habitat = _habitat(fish, row['habitatProvenance']);
      final sizeEvidence = _sizeEvidence(fish, row['sizeProvenance']);
      if (description == null &&
          photo == null &&
          habitat == null &&
          sizeEvidence == null) {
        continue;
      }
      entries[fish.id] = _Entry(
        fish: fish,
        checkedAt: checked,
        description: description,
        photo: photo,
        habitat: habitat,
        sizeEvidence: sizeEvidence,
        habitatProvider:
            row['habitatProvenance'] is Map &&
                (row['habitatProvenance'] as Map)['field'] == 'HABI'
            ? '국립해양생물자원관 MBRIS'
            : description?.provider,
      );
    }
    return BundledFishEnrichment._(Map.unmodifiable(entries), updated);
  }

  final Map<String, _Entry> _entries;
  final DateTime? dataUpdatedAt;
  int get length => _entries.length;

  DateTime? checkedAtFor(FishSpecies fish) {
    final entry = _entries[fish.id];
    return entry != null &&
            entry.fish.name == fish.name &&
            entry.fish.scientificName == fish.scientificName
        ? entry.checkedAt
        : null;
  }

  bool hasCompleteProfileFor(FishSpecies fish) {
    final entry = _entries[fish.id];
    return entry != null &&
        entry.fish.name == fish.name &&
        entry.fish.scientificName == fish.scientificName &&
        entry.description != null &&
        entry.photo != null;
  }

  FishSpecies apply(FishSpecies base) {
    final entry = _entries[base.id];
    if (entry == null ||
        entry.fish.name != base.name ||
        entry.fish.scientificName != base.scientificName) {
      return base.withDerivedSize();
    }
    final description = base.feature.trim().isEmpty ? entry.description : null;
    final photo = hasUsableFishPhoto(base) ? null : entry.photo;
    final habitat = _genericHabitat(base.habitat) ? entry.habitat : null;
    final existingSize = base.sizeDescription;
    final size = existingSize.isNotEmpty
        ? existingSize
        : extractFishSizeSummary(
            entry.sizeEvidence?.text ?? entry.description?.text ?? '',
          );
    if (description == null &&
        photo == null &&
        habitat == null &&
        size == base.maxSize) {
      return base;
    }
    return FishSpecies.fromJson({
      ...base.toJson(),
      'maxSize': size,
      if (description != null) ...{
        'feature': description.text,
        'descriptionSourceUrl': description.source,
        'descriptionAttribution': description.attribution,
      },
      if (photo != null) ...{
        'imageUrl': photo.url,
        'photoSourceUrl': photo.source,
        'photoAttribution': photo.attribution,
        'photoLicenseUrl': photo.license,
      },
      'habitat': ?habitat,
      'sourceName': {
        ...base.sourceName.split(' · ').where((value) => value.isNotEmpty),
        if (description != null) entry.description!.provider,
        if (existingSize.isEmpty && size.isNotEmpty)
          (entry.sizeEvidence ?? entry.description)!.provider,
        if (photo != null) photo.provider,
        if (habitat != null && entry.habitatProvider != null)
          entry.habitatProvider!,
      }.join(' · '),
    });
  }

  static void _checkResult(Map<String, dynamic> json) {
    const text = {
      'id',
      'name',
      'category',
      'family',
      'habitat',
      'maxSize',
      'feature',
      'scientificName',
      'sourceName',
    };
    const nullable = {
      'imageUrl',
      'photoAttribution',
      'photoSourceUrl',
      'photoLicenseUrl',
      'descriptionSourceUrl',
      'descriptionAttribution',
      'sourceUrl',
    };
    _keys(json, {...text, ...nullable, 'detailNeedsRetry', 'aliases'});
    for (final key in text) {
      if (json.containsKey(key) && json[key] is! String) _invalid();
    }
    for (final key in nullable) {
      if (json[key] != null && json[key] is! String) _invalid();
    }
    if (json.containsKey('detailNeedsRetry') &&
        json['detailNeedsRetry'] is! bool) {
      _invalid();
    }
    if (json.containsKey('category') &&
        !FishCategory.values.any((value) => value.name == json['category'])) {
      _invalid();
    }
    final aliases = json['aliases'];
    if (aliases != null &&
        (aliases is! List ||
            aliases.length > 64 ||
            aliases.any((value) => value is! String || value.length > 200))) {
      _invalid();
    }
    final id = _text(json['id']);
    final name = _text(json['name']);
    final scientific = _text(json['scientificName']);
    if (id.isEmpty ||
        id.length > 200 ||
        name.isEmpty ||
        name.length > 200 ||
        scientific.isEmpty ||
        scientific.length > 255 ||
        _text(json['feature']).length > 12000 ||
        _text(json['habitat']).length > 4000 ||
        _text(json['maxSize']).length > 1000) {
      _invalid();
    }
  }

  static _Description? _description(FishSpecies fish) {
    final text = fish.feature.trim();
    final attribution = fish.descriptionAttribution?.trim() ?? '';
    final source = _uri(fish.descriptionSourceUrl, allowFragment: true);
    if (text.isEmpty ||
        text.length > 12000 ||
        !RegExp(r'[가-힣]').hasMatch(text) ||
        attribution.isEmpty ||
        attribution.length > 2000 ||
        source == null) {
      return null;
    }
    if (_mbris(source, attribution)) {
      return _Description(text, _mbrisUrl, attribution, '국립해양생물자원관 MBRIS');
    }
    if (!{
          'en.wikipedia.org',
          'ko.wikipedia.org',
          'ko.wikisource.org',
        }.contains(source.host) ||
        !attribution.contains('CC BY-SA 4.0') ||
        !attribution.contains(
          'https://creativecommons.org/licenses/by-sa/4.0/',
        )) {
      return null;
    }
    final article =
        source.host != 'ko.wikisource.org' &&
        source.path.startsWith('/wiki/') &&
        source.path.length > '/wiki/'.length &&
        !source.hasQuery;
    final pinned =
        source.path == '/w/index.php' &&
        source.queryParameters.keys.toSet().difference({
          'title',
          'oldid',
        }).isEmpty &&
        (source.queryParameters['title']?.isNotEmpty ?? false) &&
        (int.tryParse(source.queryParameters['oldid'] ?? '') ?? 0) > 0;
    if (!article && !pinned) return null;
    return _Description(
      text,
      source.toString(),
      attribution,
      source.host == 'ko.wikisource.org'
          ? '한국어 위키문헌'
          : source.host == 'ko.wikipedia.org'
          ? '한국어 위키백과'
          : '영어 위키백과 한국어 번역·요약',
    );
  }

  static _Photo? _photo(FishSpecies fish) {
    if (!hasUsableFishPhoto(fish)) return null;
    final image = _uri(fish.imageUrl);
    final source = _uri(fish.photoSourceUrl);
    final license = _uri(fish.photoLicenseUrl);
    final attribution = fish.photoAttribution?.trim() ?? '';
    if (image == null ||
        source == null ||
        license == null ||
        attribution.isEmpty ||
        attribution.length > 2000 ||
        RegExp(r'^(?:[·|,;:]|CC(?:0| BY))').hasMatch(attribution) ||
        RegExp(
          r'unknown|anonymous|uncredited|no machine-readable|all rights reserved|'
          r'\bCC BY-(?:NC|ND)',
          caseSensitive: false,
        ).hasMatch(attribution) ||
        !RegExp(
          r'\.(?:jpe?g|png|gif|webp)$',
          caseSensitive: false,
        ).hasMatch(image.path)) {
      return null;
    }
    // Only the official page with per-species KOGL1 badges is supported.
    // A government domain or a footer policy alone does not license a photo.
    final nifs =
        source.toString() ==
            'https://www.nifs.go.kr/contents/actionContentsCons0088.do' &&
        license.toString() ==
            'https://www.nifs.go.kr/contents/actionContentsCons0001.do' &&
        attribution == '국립수산과학원 · 공공누리 제1유형(출처표시)' &&
        image.host == 'www.nifs.go.kr' &&
        !image.hasQuery &&
        RegExp(
          r'^/cmmn/images/MF[0-9A-Za-z_-]+\.(?:png|jpe?g)$',
          caseSensitive: false,
        ).hasMatch(image.path);
    if (nifs) {
      return _Photo(
        image.toString(),
        source.toString(),
        attribution,
        license.toString(),
        '국립수산과학원',
      );
    }
    if (license.host != 'creativecommons.org' ||
        license.hasQuery ||
        !RegExp(
          r'^/(?:licenses/(?:by|by-sa)/(?:1\.0|2\.0|2\.5|3\.0|4\.0)|'
          r'publicdomain/(?:zero|mark)/1\.0)/?$',
        ).hasMatch(license.path)) {
      return null;
    }
    final commons =
        source.host == 'commons.wikimedia.org' &&
        source.path.startsWith('/wiki/File:') &&
        !source.hasQuery &&
        {'upload.wikimedia.org', 'thumb.wikimedia.org'}.contains(image.host);
    final photoId = RegExp(
      r'^/photos/([1-9][0-9]*)/?$',
    ).firstMatch(source.path)?.group(1);
    final inat =
        source.host == 'www.inaturalist.org' &&
        photoId != null &&
        !source.hasQuery &&
        {
          'static.inaturalist.org',
          'inaturalist-open-data.s3.amazonaws.com',
        }.contains(image.host) &&
        image.path.startsWith('/photos/$photoId/');
    if (!commons && !inat) return null;
    // Known image endpoints need no query credentials or tracking parameters.
    final publicImage = image.toString().split('?').first;
    return _Photo(
      publicImage,
      source.toString(),
      attribution,
      license.toString(),
      commons ? 'Wikimedia Commons' : 'iNaturalist',
    );
  }

  static _Description? _sizeEvidence(FishSpecies fish, Object? value) {
    if (value == null) return null;
    final proof = _map(value);
    _keys(proof, {'text', 'sourceUrl', 'attribution'});
    final description = _description(
      FishSpecies.fromJson({
        ...fish.toJson(),
        'feature': _text(proof['text']),
        'maxSize': '',
        'descriptionSourceUrl': proof['sourceUrl'],
        'descriptionAttribution': proof['attribution'],
      }),
    );
    return description != null &&
            extractFishSizeSummary(description.text).isNotEmpty
        ? description
        : null;
  }

  static String? _habitat(FishSpecies fish, Object? value) {
    if (value == null) return null;
    final provenance = _map(value);
    _keys(provenance, {'field', 'sourceUrl', 'attribution'});
    final fromMbris =
        provenance['field'] == 'HABI' &&
        _mbris(_uri(provenance['sourceUrl']), _text(provenance['attribution']));
    final description = _description(fish);
    final fromReviewedDescription =
        provenance['field'] == 'reviewedDescription' &&
        description != null &&
        provenance['sourceUrl'] == description.source &&
        provenance['attribution'] == description.attribution;
    if (!fromMbris && !fromReviewedDescription) {
      return null;
    }
    final habitat = fish.habitat.trim();
    return habitat.isNotEmpty &&
            !_genericHabitat(habitat) &&
            habitat.length <= 4000 &&
            RegExp(r'[가-힣]').hasMatch(habitat)
        ? habitat
        : null;
  }

  static const _mbrisUrl = 'https://www.data.go.kr/data/15094770/openapi.do';
  static bool _mbris(Uri? uri, String attribution) =>
      uri != null &&
      uri.host == 'www.data.go.kr' &&
      uri.path == '/data/15094770/openapi.do' &&
      uri.queryParameters.keys.toSet().difference({'format'}).isEmpty &&
      attribution == '국립해양생물자원관 MBRIS';
  static bool _genericHabitat(String habitat) => {
    '',
    '해수',
    '육상담수',
    '민물',
    '담수',
    '바다',
  }.contains(habitat.replaceAll(RegExp(r'\s+'), ''));
  static Uri? _uri(Object? value, {bool allowFragment = false}) {
    if (value is! String ||
        value.isEmpty ||
        value.length > 2000 ||
        RegExp(r'[\x00-\x20]').hasMatch(value)) {
      return null;
    }
    final uri = Uri.tryParse(value);
    return uri != null &&
            uri.scheme == 'https' &&
            uri.userInfo.isEmpty &&
            uri.host.isNotEmpty &&
            !uri.hasPort &&
            (allowFragment || !uri.hasFragment)
        ? uri
        : null;
  }

  static DateTime _date(Object? value) {
    final date = value is String && value.length <= 64
        ? DateTime.tryParse(value)
        : null;
    if (date == null || !date.isUtc) _invalid();
    return date;
  }

  static Map<String, dynamic> _map(Object? value) {
    if (value is! Map || value.keys.any((key) => key is! String)) _invalid();
    return Map<String, dynamic>.from(value);
  }

  static void _keys(Map<String, dynamic> map, Set<String> allowed) {
    if (map.keys.any((key) => !allowed.contains(key))) _invalid();
  }

  static String _text(Object? value) => value is String ? value.trim() : '';
  static Never _invalid() =>
      throw const FormatException('Invalid public fish enrichment.');
}

class _Entry {
  const _Entry({
    required this.fish,
    required this.checkedAt,
    this.description,
    this.photo,
    this.habitat,
    this.habitatProvider,
    this.sizeEvidence,
  });
  final FishSpecies fish;
  final DateTime checkedAt;
  final _Description? description;
  final _Photo? photo;
  final String? habitat;
  final String? habitatProvider;
  final _Description? sizeEvidence;
}

class _Description {
  const _Description(this.text, this.source, this.attribution, this.provider);
  final String text;
  final String source;
  final String attribution;
  final String provider;
}

class _Photo {
  const _Photo(
    this.url,
    this.source,
    this.attribution,
    this.license,
    this.provider,
  );
  final String url;
  final String source;
  final String attribution;
  final String license;
  final String provider;
}
