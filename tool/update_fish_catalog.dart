import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import 'package:fishing_build/data/fish/fish_api_configuration.dart';
import 'package:fishing_build/data/fish/fish_catalog_service.dart';
import 'package:fishing_build/data/fish/nifs_naris_fish_service.dart';

/// Refresh the public snapshot without copying credentials into app assets.
Future<void> main() async {
  final client = Dio();
  try {
    final settings =
        jsonDecode(await File('fish.local.json').readAsString())
            as Map<String, dynamic>;
    final service = NifsNarisFishService(
      dio: client,
      configuration: FishApiConfiguration(
        nifsApiKey: settings['NIFS_SPECIES_API_KEY'] as String? ?? '',
      ),
    );
    final fish = await service.fetchCatalog(forceRefresh: true);
    final snapshot = {
      'version': 1,
      'dataUpdatedAt': DateTime.now().toUtc().toIso8601String(),
      'sourceName': '국립수산과학원 생물종정보',
      'sourceUrl': NifsNarisFishService.nifsSourceUrl,
      'recordCount': fish.length,
      'species': fish.map((item) => item.toJson()).toList(),
    };
    final target = File('assets/data/fish_catalog.json');
    await target.parent.create(recursive: true);
    await target.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(snapshot)}\n',
    );
    stdout.writeln('Updated public fish catalog: ${fish.length} species.');
  } on FishCatalogException catch (error) {
    stderr.writeln('Catalog update failed: ${error.reason.name}.');
    exitCode = 1;
  } on Object {
    stderr.writeln('Catalog update failed. Check the local configuration.');
    exitCode = 1;
  } finally {
    client.close(force: true);
  }
}
