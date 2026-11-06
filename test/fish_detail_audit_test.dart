import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fishing_build/data/fish/fish_catalog_service.dart';
import 'package:fishing_build/data/models/fish_species.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import '../tool/audit_fish_details.dart' as audit;

void main() {
  late Directory workspace;
  late File catalog;
  late List<FishSpecies> species;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp(
      'fish-detail-audit-test-',
    );
    catalog = File(
      path.join(workspace.path, 'assets', 'data', 'fish_catalog.json'),
    );
    await catalog.parent.create(recursive: true);
    species = [
      for (var index = 0; index < 6; index++)
        FishSpecies(
          id: 'fish-$index',
          name: '어종$index',
          scientificName: 'Genus species$index',
        ),
    ];
    await _writeCatalog(catalog, species);
  });

  tearDown(() async {
    // This directory is the exact temporary workspace created by this test.
    await workspace.delete(recursive: true);
  });

  audit.FishAuditOptions options([List<String> arguments = const []]) =>
      audit.FishAuditOptions.parse(arguments, workspacePath: workspace.path);

  test(
    'audit options enforce bounds and keep output inside the ignored directory',
    () {
      final defaults = options();
      expect(defaults.limit, 800);
      expect(defaults.offset, 0);
      expect(defaults.configPath, isNull);
      expect(defaults.photosOnly, isFalse);
      expect(options(['--photos-only']).photosOnly, isTrue);
      expect(
        defaults.outputPath,
        path.join(workspace.path, '.dart_tool', 'fish_detail_audit.json'),
      );
      expect(options(['--help']).help, isTrue);
      final configured = options([
        '--limit=20',
        '--offset=40',
        '--config=fish.local.json',
      ]);
      expect(configured.limit, 20);
      expect(configured.offset, 40);
      expect(
        configured.configPath,
        path.join(workspace.path, 'fish.local.json'),
      );
      for (final invalid in [
        ['--limit=0'],
        ['--limit=801'],
        ['--offset=-1'],
        ['--offset=800'],
        ['--limit=2', '--limit=3'],
        ['--photos-only', '--photos-only'],
        ['--output=assets/catalog.json'],
        ['--output=.dart_tool/../../escaped.json'],
        ['--unknown=value'],
      ]) {
        expect(
          () => options(invalid),
          throwsA(isA<audit.FishAuditInputException>()),
        );
      }
    },
  );

  test(
    'audit saves each public result sequentially and never exposes raw errors',
    () async {
      final pauses = <Duration>[];
      final log = <String>[];
      final output = File(options().outputPath);
      var active = 0;
      final provider = _Provider((fish, call) async {
        expect(++active, 1);
        if (call > 1) {
          final checkpoint = jsonDecode(await output.readAsString()) as Map;
          expect(checkpoint['attemptedThisRun'], call - 1);
        }
        await Future<void>.delayed(Duration.zero);
        active--;
        if (call == 2) {
          throw const FishCatalogException(FishCatalogFailure.noData);
        }
        if (call == 3) {
          throw StateError('private-request?serviceKey=NEVER_PRINT_ME');
        }
        return FishSpecies(
          id: fish.id,
          name: fish.name,
          scientificName: fish.scientificName,
          feature: '검증된 공개 설명',
          imageUrl: 'https://upload.wikimedia.org/example.jpg',
          photoAttribution: 'Public photo author · CC BY 4.0',
          photoSourceUrl: 'https://commons.wikimedia.org/wiki/File:Example.jpg',
          photoLicenseUrl: 'https://creativecommons.org/licenses/by/4.0/',
          sourceUrl: 'https://example.org/data?serviceKey=NEVER_PRINT_ME',
        );
      });
      final report = await audit.auditFishDetails(
        options: options(['--limit=3']),
        provider: provider,
        sourceMode: 'wiki-only-v1',
        wait: (duration) async => pauses.add(duration),
        log: log.add,
      );
      expect(provider.forceRefresh, everyElement(isTrue));
      expect(pauses, List.filled(3, const Duration(seconds: 1)));
      expect(
        report['catalogSha256'],
        sha256.convert(await catalog.readAsBytes()).toString(),
      );
      final summary = report['summary'] as Map;
      expect(summary, {
        'checked': 3,
        'success': 1,
        'noData': 1,
        'failure': 1,
        'transient': 0,
        'notChecked': 3,
        'description': 1,
        'photo': 1,
        'size': 0,
      });
      final records = report['records'] as List;
      final success = records.first as Map;
      expect(success['sourceUrl'], isNull);
      expect(
        success['photoLicenseUrl'],
        'https://creativecommons.org/licenses/by/4.0/',
      );
      final detail = FishSpecies.fromJson(
        Map<String, dynamic>.from(success['result'] as Map),
      );
      expect(detail.id, species.first.id);
      expect(detail.feature, '검증된 공개 설명');
      expect((records[2] as Map)['description'], isNull);
      expect((records[3] as Map)['outcome'], 'notChecked');
      expect((records[3] as Map)['photo'], isNull);
      expect(await output.readAsString(), isNot(contains('NEVER_PRINT_ME')));
      expect(log.join(), isNot(contains('private-request')));
      expect(log.single, contains('notChecked=3'));
      expect(
        await output.parent
            .list()
            .where((file) => file.path.contains('.tmp.'))
            .isEmpty,
        isTrue,
      );
    },
  );

  test(
    'three transient failures stop without calling unchecked species missing',
    () async {
      final reasons = [
        FishCatalogFailure.network,
        FishCatalogFailure.timedOut,
        FishCatalogFailure.rateLimited,
      ];
      final provider = _Provider(
        (fish, call) async => throw FishCatalogException(reasons[call - 1]),
      );
      var delays = 0;
      final report = await audit.auditFishDetails(
        options: options(),
        provider: provider,
        sourceMode: 'wiki-only-v1',
        wait: (_) async {
          delays++;
        },
      );
      expect(provider.calls, hasLength(3));
      expect(delays, 3);
      expect(report['stopReason'], 'consecutiveTransientFailures');
      final summary = report['summary'] as Map;
      expect(summary['checked'], 3);
      expect(summary['transient'], 3);
      expect(summary['noData'], 0);
      expect(summary['notChecked'], 3);
      expect(summary['description'], 0);
      for (final row in report['records'] as List) {
        expect((row as Map)['description'], isNull);
        expect(row['photo'], isNull);
        expect(row['size'], isNull);
      }
    },
  );

  test(
    'partial transient successes remain available but are rechecked on resume',
    () async {
      final provider = _Provider(
        (fish, call) async => FishSpecies(
          id: fish.id,
          name: fish.name,
          scientificName: fish.scientificName,
          feature: '유효한 공개 설명',
          detailNeedsRetry: call == 1,
        ),
      );
      Future<Map<String, Object?>> run() => audit.auditFishDetails(
        options: options(['--limit=1']),
        provider: provider,
        sourceMode: 'wiki-only-v1',
        wait: (_) async {},
      );
      final partial = await run();
      expect((partial['summary'] as Map)['success'], 1);
      expect((partial['summary'] as Map)['description'], 1);
      await run();
      expect(provider.calls, hasLength(2));
      await run();
      expect(provider.calls, hasLength(2));
    },
  );

  test(
    'resume requires matching mode, catalog hash, and species identity',
    () async {
      var calls = 0;
      final provider = _Provider((fish, _) async {
        calls++;
        if (fish.id == species[1].id) {
          throw const FishCatalogException(FishCatalogFailure.noData);
        }
        return FishSpecies(
          id: fish.id,
          name: fish.name,
          scientificName: fish.scientificName,
          feature: '공개 설명',
        );
      });
      Future<Map<String, Object?>> run(
        String mode, [
        List<String> args = const ['--limit=2'],
      ]) => audit.auditFishDetails(
        options: options(args),
        provider: provider,
        sourceMode: mode,
        wait: (_) async {},
      );

      await run('wiki-only-v1');
      expect(calls, 2);
      await run('wiki-only-v1');
      expect(calls, 2, reason: 'Completed compatible results are reused.');
      await run('wiki+mbris-v1');
      expect(
        calls,
        4,
        reason: 'Enabling another source invalidates prior negative results.',
      );
      final output = File(options().outputPath);
      final saved =
          jsonDecode(await output.readAsString()) as Map<String, dynamic>;
      ((saved['records'] as List).first as Map)['scientificName'] =
          'Different species';
      await output.writeAsString(jsonEncode(saved));
      await run('wiki+mbris-v1');
      expect(calls, 5, reason: 'An identity mismatch must be checked again.');
      await catalog.writeAsString('\n', mode: FileMode.append);
      await run('wiki+mbris-v1');
      expect(
        calls,
        7,
        reason: 'Changing source bytes changes the catalog hash.',
      );
      final extended = await run('wiki+mbris-v1', ['--limit=3']);
      expect(
        calls,
        8,
        reason: 'Only the previously unchecked selected entry is requested.',
      );
      expect((extended['summary'] as Map)['notChecked'], 3);
    },
  );
}

Future<void> _writeCatalog(File file, List<FishSpecies> species) => file
    .writeAsString(
      jsonEncode({
        'version': 1,
        'recordCount': species.length,
        'species': species.map((fish) => fish.toJson()).toList(),
      }),
    )
    .then((_) {});

class _Provider implements FishDetailProvider {
  _Provider(this.fetch);
  final Future<FishSpecies> Function(FishSpecies fish, int call) fetch;
  final calls = <String>[];
  final forceRefresh = <bool>[];

  @override
  Future<FishSpecies> fetchDetail(
    FishSpecies species, {
    bool forceRefresh = false,
  }) {
    calls.add(species.id);
    this.forceRefresh.add(forceRefresh);
    return fetch(species, calls.length);
  }
}
