import 'dart:convert';
import 'dart:io';

import 'package:fishing_build/data/fish/bundled_fish_enrichment.dart';
import 'package:fishing_build/data/models/fish_species.dart';

const _usage =
    '''Usage: dart run tool/build_fish_enrichment.dart --report=PATH [--report=PATH...]
Reads existing public reports only; never calls an API or reads configuration.
Writes validated public fallback data to assets/data/fish_enrichment.json.
Report order chooses the first verified photo; verified MBRIS descriptions
take priority over Wiki descriptions. Failure/no-data records are ignored.''';

Future<void> main(List<String> arguments) async {
  try {
    if (arguments.length == 1 && {'--help', '-h'}.contains(arguments.single)) {
      stdout.writeln(_usage);
      return;
    }
    final reports = <String>[];
    for (final argument in arguments) {
      if (!argument.startsWith('--report=') || argument.length <= 9) {
        throw const FormatException('Invalid public report option.');
      }
      reports.add(argument.substring(9));
    }
    if (reports.isEmpty || reports.length > 16) {
      throw const FormatException('Provide one to sixteen public reports.');
    }
    final result = await buildFishEnrichment(reportPaths: reports);
    stdout.writeln(
      jsonEncode({
        'records': result['recordCount'],
        'dataUpdatedAt': result['dataUpdatedAt'],
        'output': 'assets/data/fish_enrichment.json',
      }),
    );
  } on Object {
    // A path, raw exception or rejected JSON could contain private material.
    stderr.writeln(
      'Public enrichment could not be built; existing output is unchanged.',
    );
    stderr.writeln('Use --help and supply compatible public audit reports.');
    exitCode = 1;
  }
}

/// Pure report-to-asset build. Optional paths support isolated local fixtures.
/// No credentials or report envelope metadata are copied into the output.
Future<Map<String, Object?>> buildFishEnrichment({
  required List<String> reportPaths,
  String catalogPath = 'assets/data/fish_catalog.json',
  String outputPath = 'assets/data/fish_enrichment.json',
}) async {
  if (reportPaths.isEmpty || reportPaths.length > 16) _invalid();
  final rawCatalog = await _read(catalogPath, maxBytes: 4 * 1024 * 1024);
  final species = rawCatalog['species'];
  if (rawCatalog['version'] != 1 ||
      species is! List ||
      species.isEmpty ||
      species.length > 800 ||
      rawCatalog['recordCount'] != species.length) {
    _invalid();
  }
  final catalog = <String, FishSpecies>{};
  for (final value in species) {
    final fish = FishSpecies.fromJson(_map(value));
    if (fish.scientificName.trim().isEmpty || catalog.containsKey(fish.id)) {
      _invalid();
    }
    catalog[fish.id] = fish;
  }

  final selected = <String, _Selected>{};
  for (final reportPath in reportPaths) {
    final report = await _read(reportPath);
    final records = report['records'];
    if (report['version'] != 1 || records is! List || records.length > 800) {
      _invalid();
    }
    final ids = <String>{};
    for (final value in records) {
      final row = _map(value);
      // Failure or unqueried rows never remove a valid field from an earlier report.
      if (!{'success', 'partial'}.contains(row['outcome'])) continue;
      final candidateJson = _map(row['result']);
      final id = candidateJson['id'];
      if (id is! String || !ids.add(id)) _invalid();
      final base = catalog[id];
      if (base == null ||
          candidateJson['name'] != base.name ||
          candidateJson['scientificName'] != base.scientificName ||
          row['id'] != base.id ||
          row['name'] != base.name ||
          row['scientificName'] != base.scientificName) {
        _invalid();
      }
      final checked = _date(row['checkedAt']);
      final rawProvenance = row['habitatProvenance'];
      Map<String, Object?>? habitatProvenance;
      if (rawProvenance is Map) {
        // Collector reports may carry extra evidence. Retain only provenance
        // understood by the runtime component, never the report envelope.
        habitatProvenance = {
          'field': rawProvenance['field'],
          'sourceUrl': rawProvenance['sourceUrl'],
          'attribution': rawProvenance['attribution'],
        };
      }
      final record = <String, Object?>{
        'checkedAt': checked.toIso8601String(),
        'result': candidateJson,
        'habitatProvenance': ?habitatProvenance,
      };
      final verified = BundledFishEnrichment.fromJson({
        'version': 1,
        'recordCount': 1,
        'dataUpdatedAt': checked.toIso8601String(),
        'records': [record],
      });
      if (verified.length == 0) continue;
      final cleanBase = _empty(base);
      final clean = verified.apply(cleanBase);
      final entry = selected.putIfAbsent(id, () => _Selected(cleanBase));
      if (clean.feature.isNotEmpty &&
          (entry.description == null ||
              _descriptionRank(clean) > _descriptionRank(entry.description!))) {
        entry.description = clean;
        entry.descriptionAt = checked;
      }
      if (clean.imageUrl?.isNotEmpty == true && entry.photo == null) {
        entry.photo = clean;
        entry.photoAt = checked;
      }
      if (clean.maxSize.isNotEmpty &&
          (entry.size == null ||
              _descriptionRank(clean) > _descriptionRank(entry.size!))) {
        entry.size = clean;
        entry.sizeAt = checked;
      }
      if (habitatProvenance != null &&
          clean.habitat != cleanBase.habitat &&
          (entry.habitat == null ||
              habitatProvenance['field'] == 'HABI' &&
                  entry.habitatProvenance?['field'] != 'HABI')) {
        entry.habitat = clean.habitat;
        entry.habitatAt = checked;
        entry.habitatProvenance = habitatProvenance;
      }
    }
  }
  final records = <Map<String, Object?>>[];
  DateTime? updatedAt;
  // Catalog order gives reproducible output independently of map insertion order.
  for (final base in catalog.values) {
    final entry = selected[base.id];
    if (entry == null) continue;
    final description = entry.description;
    final photo = entry.photo;
    // A reviewed habitat must stay tied to the selected licensed description.
    // Explicit MBRIS HABI fields are independent of description selection.
    if (entry.habitatProvenance?['field'] == 'reviewedDescription' &&
        (entry.habitatProvenance?['sourceUrl'] !=
                description?.descriptionSourceUrl ||
            entry.habitatProvenance?['attribution'] !=
                description?.descriptionAttribution)) {
      entry.habitat = null;
      entry.habitatAt = null;
      entry.habitatProvenance = null;
    }
    if (description == null && photo == null && entry.habitat == null) continue;
    final dates = [
      entry.descriptionAt,
      entry.photoAt,
      entry.habitatAt,
      entry.sizeAt,
    ].whereType<DateTime>().toList()..sort();
    // A complete profile is only as fresh as its oldest selected field.
    final checked = dates.first;
    final latest = dates.last;
    if (updatedAt == null || latest.isAfter(updatedAt)) updatedAt = latest;
    final fish = FishSpecies.fromJson({
      ...entry.base.toJson(),
      if (description != null) ...{
        'feature': description.feature,
        'descriptionSourceUrl': description.descriptionSourceUrl,
        'descriptionAttribution': description.descriptionAttribution,
      },
      'maxSize': entry.size?.maxSize ?? '',
      if (photo != null) ...{
        'imageUrl': photo.imageUrl,
        'photoSourceUrl': photo.photoSourceUrl,
        'photoAttribution': photo.photoAttribution,
        'photoLicenseUrl': photo.photoLicenseUrl,
      },
      'habitat': ?entry.habitat,
      'sourceName': {
        ...entry.base.sourceName
            .split(' · ')
            .where((value) => value.isNotEmpty),
        if (description != null)
          ...description.sourceName
              .split(' · ')
              .where((value) => value.isNotEmpty),
        if (photo != null)
          ...photo.sourceName.split(' · ').where((value) => value.isNotEmpty),
        if (entry.size != null)
          ...entry.size!.sourceName
              .split(' · ')
              .where((value) => value.isNotEmpty),
        if (entry.habitat != null &&
            entry.habitatProvenance?['field'] == 'HABI')
          '국립해양생물자원관 MBRIS',
      }.join(' · '),
    });
    records.add({
      'checkedAt': checked.toIso8601String(),
      'result': fish.toJson(),
      'habitatProvenance': ?entry.habitatProvenance,
      if (entry.size != null)
        'sizeProvenance': {
          'text': entry.size!.maxSize,
          'sourceUrl': entry.size!.descriptionSourceUrl,
          'attribution': entry.size!.descriptionAttribution,
        },
    });
  }
  // An all-failed input must not replace an existing useful asset with emptiness.
  if (records.isEmpty || updatedAt == null) _invalid();
  final output = <String, Object?>{
    'version': 1,
    'recordCount': records.length,
    'dataUpdatedAt': updatedAt.toIso8601String(),
    'records': records,
  };
  final verified = BundledFishEnrichment.fromJson(output);
  if (verified.length != records.length) _invalid();
  final encoded = '${const JsonEncoder.withIndent('  ').convert(output)}\n';
  if (utf8.encode(encoded).length > 4 * 1024 * 1024) _invalid();
  final target = File(outputPath);
  final temporary = File('$outputPath.$pid.tmp');
  try {
    await target.parent.create(recursive: true);
    await temporary.writeAsString(encoded, flush: true);
    await temporary.rename(outputPath);
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
  return output;
}

FishSpecies _empty(FishSpecies base) => FishSpecies(
  id: base.id,
  name: base.name,
  scientificName: base.scientificName,
  category: base.category,
  family: base.family,
  habitat: base.habitat,
  aliases: base.aliases,
  sourceName: base.sourceName,
  // The bundled NIFS catalog uses a public information page, never an API key.
  sourceUrl: _catalogSource(base.sourceUrl),
);

String? _catalogSource(String? value) {
  final uri = Uri.tryParse(value ?? '');
  return uri != null &&
          uri.scheme == 'https' &&
          uri.userInfo.isEmpty &&
          uri.host == 'www.nifs.go.kr' &&
          uri.path == '/openApi/actionOpenapiInfoList.do' &&
          !uri.hasQuery &&
          !uri.hasFragment
      ? uri.toString()
      : null;
}

int _descriptionRank(FishSpecies fish) =>
    Uri.tryParse(fish.descriptionSourceUrl ?? '')?.host == 'www.data.go.kr'
    ? 2
    : 1;

Future<Map<String, dynamic>> _read(
  String path, {
  int maxBytes = 32 * 1024 * 1024,
}) async {
  final file = File(path);
  // Full-library reports retain evidence and checkpoints. Only selected public
  // fields enter the independently bounded 4 MiB app asset.
  if (!await file.exists() || await file.length() > maxBytes) _invalid();
  return _map(jsonDecode(await file.readAsString()));
}

Map<String, dynamic> _map(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) _invalid();
  return Map<String, dynamic>.from(value);
}

DateTime _date(Object? value) {
  final result = value is String ? DateTime.tryParse(value) : null;
  if (result == null || !result.isUtc) _invalid();
  return result;
}

Never _invalid() =>
    throw const FormatException('Invalid public enrichment input.');

class _Selected {
  _Selected(this.base);
  final FishSpecies base;
  FishSpecies? description;
  FishSpecies? photo;
  FishSpecies? size;
  String? habitat;
  Map<String, Object?>? habitatProvenance;
  DateTime? descriptionAt;
  DateTime? photoAt;
  DateTime? sizeAt;
  DateTime? habitatAt;
}
