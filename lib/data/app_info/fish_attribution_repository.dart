import 'dart:convert';

import 'package:flutter/services.dart';

import '../fish/bundled_fish_descriptions.dart';
import '../fish/bundled_fish_enrichment.dart';
import '../fish/fish_photo_validation.dart';
import '../fish/fish_size_summary.dart';
import '../fish/reviewed_fish_photos.dart';
import '../models/fish_species.dart';
import '../repositories/fish_species_repository.dart';

enum FishAttributionKind {
  catalog('어종 목록·분류'),
  photo('사진'),
  description('설명'),
  habitat('서식지'),
  size('크기');

  const FishAttributionKind(this.label);
  final String label;
}

/// Credit for one selected field. Photo metadata always belongs to [resourceUrl].
class FishAttributionEntry {
  const FishAttributionEntry({
    required this.kind,
    required this.attribution,
    this.sourceUrl,
    this.licenseUrl,
    this.resourceUrl,
    this.content,
    this.notes,
  });

  final FishAttributionKind kind;
  String get title => kind.label;
  final String attribution;
  final String? sourceUrl;
  final String? licenseUrl;
  final String? resourceUrl;
  final String? content;
  final String? notes;
}

class FishAttribution {
  const FishAttribution({
    required this.id,
    required this.speciesName,
    required this.scientificName,
    required this.entries,
  });

  final String id;
  final String speciesName;
  final String scientificName;
  final List<FishAttributionEntry> entries;
}

/// Reads public bundled credits and the already available encyclopedia cache.
/// This class never requests a catalog, species detail, thumbnail, or image.
class FishAttributionRepository {
  FishAttributionRepository({
    AssetBundle? bundle,
    Future<List<FishSpecies>> Function()? cachedSpecies,
  }) : _bundle = bundle ?? rootBundle,
       _cachedSpecies =
           cachedSpecies ?? FishSpeciesRepository.instance.readCachedSpecies;

  static const catalogAssetPath = 'assets/data/fish_catalog.json';
  static const enrichmentAssetPath = 'assets/data/fish_enrichment.json';
  static final _bundled = Expando<Future<_BundledCredits>>();

  final AssetBundle _bundle;
  final Future<List<FishSpecies>> Function() _cachedSpecies;

  /// Bundled assets are parsed once per bundle; the cache is read on every open.
  Future<List<FishAttribution>> load({AssetBundle? bundle}) async {
    final assets = bundle ?? _bundle;
    final bundleData = _bundled[assets] ??= _readBundle(assets);
    final cache = _readCached();
    final data = await bundleData;
    final cached = await cache;
    final cachedById = {for (final fish in cached) fish.id: fish};
    final result = <FishAttribution>[];
    for (final base in data.catalog) {
      final candidate = cachedById.remove(base.id);
      final current = candidate != null && _sameSpecies(base, candidate)
          ? candidate
          : null;
      result.add(
        _credits(
          base,
          data.enrich(base),
          current,
          data.provenance[base.id],
          data.sourceName,
          data.sourceUrl,
        ),
      );
    }
    // A refreshed catalog may have additional species beyond the bundled list.
    for (final current in cachedById.values) {
      result.add(_credits(current, current, null, null, '', null));
    }
    result.sort((a, b) {
      final byName = a.speciesName.compareTo(b.speciesName);
      return byName != 0 ? byName : a.id.compareTo(b.id);
    });
    return List.unmodifiable(result);
  }

  Future<List<FishSpecies>> _readCached() async {
    try {
      return await _cachedSpecies();
    } on Object {
      // A missing public cache cannot hide the bundled attribution directory.
      return const [];
    }
  }

  static Future<_BundledCredits> _readBundle(AssetBundle bundle) async {
    try {
      final json = _map(
        jsonDecode(await bundle.loadString(catalogAssetPath, cache: false)),
      );
      final rows = json['species'];
      if (json['version'] != 1 ||
          rows is! List ||
          rows.isEmpty ||
          rows.length > 10000 ||
          json['recordCount'] != rows.length) {
        throw const FormatException(
          'Invalid bundled fish attribution catalog.',
        );
      }
      final catalog = [for (final row in rows) FishSpecies.fromJson(_map(row))];
      if (catalog.map((fish) => fish.id).toSet().length != catalog.length) {
        throw const FormatException('Duplicate bundled fish identity.');
      }
      var enrichment = const BundledFishEnrichment.empty();
      final provenance = <String, _FieldProvenance>{};
      try {
        final raw = _map(
          jsonDecode(
            await bundle.loadString(enrichmentAssetPath, cache: false),
          ),
        );
        enrichment = BundledFishEnrichment.fromJson(raw);
        for (final value in raw['records'] as List) {
          final record = _map(value);
          final fish = FishSpecies.fromJson(_map(record['result']));
          provenance[fish.id] = _FieldProvenance(
            fish,
            _optionalMap(record['habitatProvenance']),
            _optionalMap(record['sizeProvenance']),
          );
        }
      } on Object {
        // Match the encyclopedia: a damaged optional asset leaves the catalog.
        enrichment = const BundledFishEnrichment.empty();
        provenance.clear();
      }
      return _BundledCredits(
        catalog,
        enrichment,
        provenance,
        _text(json['sourceName']),
        _url(json['sourceUrl']),
      );
    } on Object {
      // Let a subsequent retry read the asset again after an initial failure.
      _bundled[bundle] = null;
      rethrow;
    }
  }

  static FishAttribution _credits(
    FishSpecies base,
    FishSpecies bundled,
    FishSpecies? cached,
    _FieldProvenance? evidence,
    String catalogSource,
    String? catalogUrl,
  ) {
    if (evidence != null && !_sameSpecies(base, evidence.fish)) evidence = null;
    final entries = <FishAttributionEntry>[
      FishAttributionEntry(
        kind: FishAttributionKind.catalog,
        attribution: _first([base.sourceName, catalogSource], '어종 자료'),
        sourceUrl: _url(base.sourceUrl) ?? catalogUrl,
      ),
    ];
    final selectedPhoto = cached != null && hasUsableFishPhoto(cached)
        ? cached
        : bundled;
    final photo = _withMatchingCredits(selectedPhoto, bundled);
    if (hasUsableFishPhoto(photo)) {
      entries.add(
        FishAttributionEntry(
          kind: FishAttributionKind.photo,
          attribution: _first([photo.photoAttribution], '저작자 정보 없음'),
          sourceUrl: _url(photo.photoSourceUrl),
          licenseUrl: _url(photo.photoLicenseUrl),
          resourceUrl: _url(photo.imageUrl),
          notes: _text(photo.photoAttribution).isEmpty
              ? '이 사진의 저작자 정보가 저장되어 있지 않습니다.'
              : null,
        ),
      );
    }
    final selectedDescription =
        cached != null && cached.feature.trim().isNotEmpty ? cached : bundled;
    final description = _withMatchingCredits(selectedDescription, bundled);
    if (description.feature.trim().isNotEmpty) {
      entries.add(_descriptionCredit(description));
    }
    final habitat = cached != null && !_genericHabitat(cached.habitat)
        ? cached
        : bundled;
    if (habitat.habitat.trim().isNotEmpty) {
      final proof = evidence?.habitat;
      final verified =
          proof != null &&
          evidence != null &&
          habitat.habitat == bundled.habitat &&
          habitat.habitat == evidence.fish.habitat &&
          _validHabitatProof(proof, evidence.fish) &&
          !_genericHabitat(habitat.habitat);
      entries.add(
        verified
            ? _proofCredit(
                FishAttributionKind.habitat,
                proof,
                habitat.habitat,
                notes: proof['field'] == 'HABI'
                    ? 'MBRIS 서식지(HABI) 항목'
                    : '검토한 설명에서 정리한 서식지',
              )
            : FishAttributionEntry(
                kind: FishAttributionKind.habitat,
                attribution: _genericHabitat(habitat.habitat)
                    ? _first([base.sourceName, catalogSource], '어종 자료')
                    : '저장된 어종 자료',
                sourceUrl: _genericHabitat(habitat.habitat)
                    ? _url(base.sourceUrl) ?? catalogUrl
                    : null,
                content: habitat.habitat,
                notes: _genericHabitat(habitat.habitat)
                    ? '어종 목록의 서식 수역 분류'
                    : '별도 서식지 출처가 캐시에 기록되어 있지 않습니다.',
              ),
      );
    }
    final selectedSize =
        cached != null && cached.sizeDescription.trim().isNotEmpty
        ? cached
        : bundled;
    final size = _withMatchingCredits(selectedSize, bundled);
    if (size.sizeDescription.trim().isNotEmpty) {
      final proof = evidence?.size;
      // The size evidence can come from a different article than the description.
      // Match its extracted content before assigning that article's credit.
      final proofSize = extractFishSizeSummary(_text(proof?['text']));
      final fromProof =
          proof != null &&
          _validTextProof(proof) &&
          proofSize.isNotEmpty &&
          proofSize == size.sizeDescription;
      if (fromProof) {
        entries.add(
          _proofCredit(FishAttributionKind.size, proof, size.sizeDescription),
        );
      } else if (extractFishSizeSummary(size.feature) == size.sizeDescription) {
        entries.add(_descriptionCredit(size, kind: FishAttributionKind.size));
      } else {
        entries.add(
          FishAttributionEntry(
            kind: FishAttributionKind.size,
            attribution: '저장된 어종 자료',
            content: size.sizeDescription,
            notes: '별도 크기 출처가 캐시에 기록되어 있지 않습니다.',
          ),
        );
      }
    }
    return FishAttribution(
      id: base.id,
      speciesName: base.name,
      scientificName: base.scientificName,
      entries: List.unmodifiable(entries),
    );
  }

  static FishAttributionEntry _descriptionCredit(
    FishSpecies fish, {
    FishAttributionKind kind = FishAttributionKind.description,
  }) => FishAttributionEntry(
    kind: kind,
    attribution: _first([fish.descriptionAttribution], '저작자·제공기관 정보 없음'),
    sourceUrl: _url(fish.descriptionSourceUrl),
    licenseUrl: _licenseFrom(fish.descriptionAttribution),
    content: kind == FishAttributionKind.size ? fish.sizeDescription : null,
    notes: kind == FishAttributionKind.size ? '설명에서 추출한 크기 정보' : null,
  );

  static FishAttributionEntry _proofCredit(
    FishAttributionKind kind,
    Map<String, dynamic> proof,
    String content, {
    String? notes,
  }) => FishAttributionEntry(
    kind: kind,
    attribution: _first([proof['attribution']], '제공기관 정보 없음'),
    sourceUrl: _url(proof['sourceUrl']),
    licenseUrl: _licenseFrom(proof['attribution']),
    content: content,
    notes: notes,
  );

  static FishSpecies _withMatchingCredits(
    FishSpecies selected,
    FishSpecies bundled,
  ) {
    if (identical(selected, bundled)) return selected;
    final samePhoto =
        _url(selected.imageUrl) != null &&
        _url(selected.imageUrl) == _url(bundled.imageUrl);
    final sameDescription =
        selected.feature.trim().isNotEmpty &&
        selected.feature == bundled.feature;
    return FishSpecies.fromJson({
      ...selected.toJson(),
      if (samePhoto) ...{
        'photoAttribution': _text(selected.photoAttribution).isNotEmpty
            ? selected.photoAttribution
            : bundled.photoAttribution,
        'photoSourceUrl':
            _url(selected.photoSourceUrl) ?? bundled.photoSourceUrl,
        'photoLicenseUrl':
            _url(selected.photoLicenseUrl) ?? bundled.photoLicenseUrl,
      },
      if (sameDescription) ...{
        'descriptionAttribution':
            _text(selected.descriptionAttribution).isNotEmpty
            ? selected.descriptionAttribution
            : bundled.descriptionAttribution,
        'descriptionSourceUrl':
            _url(selected.descriptionSourceUrl) ?? bundled.descriptionSourceUrl,
      },
    });
  }

  static bool _validHabitatProof(Map<String, dynamic> proof, FishSpecies fish) {
    if (proof['field'] == 'HABI') {
      return _mbrisProof(proof);
    }
    return proof['field'] == 'reviewedDescription' &&
        proof['sourceUrl'] == fish.descriptionSourceUrl &&
        proof['attribution'] == fish.descriptionAttribution &&
        _validTextProof({...proof, 'text': fish.feature});
  }

  static bool _mbrisProof(Map<String, dynamic> proof) {
    final source = Uri.tryParse(_text(proof['sourceUrl']));
    return source != null &&
        _url(source.toString()) != null &&
        source.scheme == 'https' &&
        !source.hasPort &&
        !source.hasFragment &&
        source.host == 'www.data.go.kr' &&
        source.path == '/data/15094770/openapi.do' &&
        source.queryParameters.keys.toSet().difference({'format'}).isEmpty &&
        proof['attribution'] == '국립해양생물자원관 MBRIS';
  }

  static bool _validTextProof(Map<String, dynamic> proof) {
    final source = Uri.tryParse(_text(proof['sourceUrl']));
    final attribution = _text(proof['attribution']);
    final text = _text(proof['text']);
    if (source == null ||
        _url(source.toString()) == null ||
        source.scheme != 'https' ||
        source.hasPort ||
        text.isEmpty ||
        text.length > 12000 ||
        attribution.isEmpty ||
        attribution.length > 2000 ||
        !RegExp(r'[가-힣]').hasMatch(text)) {
      return false;
    }
    if (_mbrisProof(proof)) return true;
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
    return {
          'en.wikipedia.org',
          'ko.wikipedia.org',
          'ko.wikisource.org',
        }.contains(source.host) &&
        (article || pinned) &&
        attribution.contains('CC BY-SA 4.0') &&
        _licenseFrom(attribution) ==
            'https://creativecommons.org/licenses/by-sa/4.0/';
  }

  static bool _sameSpecies(FishSpecies a, FishSpecies b) =>
      a.id == b.id &&
      a.name == b.name &&
      a.scientificName.trim() == b.scientificName.trim();

  static bool _genericHabitat(String habitat) => {
    '',
    '해수',
    '육상담수',
    '민물',
    '담수',
    '바다',
  }.contains(habitat.replaceAll(RegExp(r'\s+'), ''));

  static String _text(Object? value) => value is String ? value.trim() : '';

  static String _first(List<Object?> values, String fallback) => values
      .map(_text)
      .firstWhere((value) => value.isNotEmpty, orElse: () => fallback);

  static String? _url(Object? value) {
    final text = _text(value);
    if (text.isEmpty || RegExp(r'[\x00-\x20]').hasMatch(text)) return null;
    final uri = Uri.tryParse(text);
    return uri != null &&
            {'http', 'https'}.contains(uri.scheme) &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty
        ? text
        : null;
  }

  static String? _licenseFrom(Object? attribution) {
    final match = RegExp(
      r'https://creativecommons\.org/(?:licenses|publicdomain)/[^\s·|]+',
    ).firstMatch(_text(attribution));
    return _url(match?.group(0));
  }

  static Map<String, dynamic> _map(Object? value) =>
      Map<String, dynamic>.from(value as Map);

  static Map<String, dynamic>? _optionalMap(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : null;
}

class _BundledCredits {
  const _BundledCredits(
    this.catalog,
    this.enrichment,
    this.provenance,
    this.sourceName,
    this.sourceUrl,
  );

  final List<FishSpecies> catalog;
  final BundledFishEnrichment enrichment;
  final Map<String, _FieldProvenance> provenance;
  final String sourceName;
  final String? sourceUrl;

  FishSpecies enrich(FishSpecies base) => ReviewedFishPhotos.apply(
    BundledFishDescriptions.apply(enrichment.apply(base)),
  );
}

class _FieldProvenance {
  const _FieldProvenance(this.fish, this.habitat, this.size);
  final FishSpecies fish;
  final Map<String, dynamic>? habitat;
  final Map<String, dynamic>? size;
}
