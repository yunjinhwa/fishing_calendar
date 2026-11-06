import 'dart:convert';
import 'dart:io';
import 'package:fishing_build/data/fish/bundled_fish_enrichment.dart';
import 'package:fishing_build/data/fish/bundled_fish_descriptions.dart';
import 'package:fishing_build/data/fish/reviewed_fish_photos.dart';
import 'package:fishing_build/data/models/fish_species.dart';

Future<Map<String, dynamic>> read(String p) async =>
    Map<String, dynamic>.from(jsonDecode(await File(p).readAsString()) as Map);

Future<void> main() async {
  final catalog = await read('assets/data/fish_catalog.json');
  final enrichmentJson = await read('assets/data/fish_enrichment.json');
  final enrichment = BundledFishEnrichment.fromJson(enrichmentJson);
  final sources = <String, Map<String, dynamic>>{};
  final checked = <String, Set<String>>{};
  final outcomes = <String, Map<String, Object?>>{};
  final identities = <String, FishSpecies>{
    for (final r in catalog['species'] as List)
      (r as Map)['id'] as String: FishSpecies.fromJson(
        Map<String, dynamic>.from(r),
      ),
  };
  for (final lane in {
    'mbris': 'fish_all_mbris_content',
    'wikimedia': 'fish_all_wiki_content',
    'englishPhotographs': 'fish_all_english_photos',
    'photographs': 'fish_all_public_photos',
    'nifsPublicPhotos': 'fish_nifs_public_photos',
  }.entries) {
    final report = await read('.dart_tool/${lane.value}.json');
    final ids = <String>{};
    for (final r in report['records'] as List) {
      final base = identities[r['id']];
      if (base == null ||
          !ids.add(base.id) ||
          r['name'] != base.name ||
          r['scientificName'] != base.scientificName ||
          r['checkedAt'] == null ||
          r['outcome'] == 'notChecked') {
        throw StateError('Every source must finish every catalog identity.');
      }
      outcomes.putIfAbsent(base.id, () => {})[lane.key] = {
        'outcome': r['outcome'],
        if (r['reason'] != null) 'reason': r['reason'],
      };
    }
    if (ids.length != identities.length) throw StateError('Incomplete scope.');
    checked[lane.key] = ids;
    sources[lane.key] = {
      'checkedCount': ids.length,
      'summary': report['summary'],
    };
  }
  final records = <Map<String, Object?>>[];
  for (final base in identities.values) {
    final fish = ReviewedFishPhotos.apply(
      BundledFishDescriptions.apply(enrichment.apply(base)),
    );
    final detailedHabitat = !{
      '',
      '해수',
      '육상담수',
      '담수',
      '민물',
      '바다',
    }.contains(fish.habitat.replaceAll(RegExp(r'\s+'), ''));
    records.add({
      'id': fish.id,
      'name': fish.name,
      'scientificName': fish.scientificName,
      'descriptionAvailable': fish.feature.trim().isNotEmpty,
      'photoAvailable': fish.imageUrl?.isNotEmpty == true,
      'sizeAvailable': fish.sizeDescription.isNotEmpty,
      'detailedHabitatAvailable': detailedHabitat,
      'checkedBy': checked.keys
          .where((s) => checked[s]!.contains(base.id))
          .toList(),
      'sourceOutcomes': outcomes[base.id],
    });
  }
  final summary = {
    'catalog': records.length,
    'checked': records.length,
    'description': records
        .where((r) => r['descriptionAvailable'] == true)
        .length,
    'photo': records.where((r) => r['photoAvailable'] == true).length,
    'size': records.where((r) => r['sizeAvailable'] == true).length,
    'detailedHabitat': records
        .where((r) => r['detailedHabitatAvailable'] == true)
        .length,
  };
  final output = {
    'version': 1,
    'dataUpdatedAt': enrichmentJson['dataUpdatedAt'],
    'summary': summary,
    'sources': sources,
    'missingMeaning':
        'No verified field was obtained from the checked sources; this does not establish that no source has such information. Wikimedia optional photo failures cannot be reconstructed retrospectively.',
    'records': records,
  };
  await File(
    'docs/fish_enrichment_inventory.json',
  ).writeAsString('${const JsonEncoder.withIndent('  ').convert(output)}\n');
  stdout.writeln(jsonEncode(summary));
}
