import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as path;

import 'package:fishing_build/data/fish/composite_fish_detail_provider.dart';
import 'package:fishing_build/data/fish/fish_catalog_service.dart';
import 'package:fishing_build/data/fish/mbris_fish_detail_provider.dart';
import 'package:fishing_build/data/fish/recovering_fish_detail_provider.dart';
import 'package:fishing_build/data/fish/wikimedia_fish_detail_provider.dart';
import 'package:fishing_build/data/models/fish_species.dart';

const _usage = '''Usage: dart run tool/audit_fish_details.dart [options]
  --limit=N       At most 800 catalog entries (default: 800).
  --offset=N      Zero-based catalog offset (default: 0).
  --output=PATH   Report beneath .dart_tool (default: .dart_tool/fish_detail_audit.json).
  --config=PATH   Optional approved local JSON; reads only MBRIS_SERVICE_KEY.
  --photos-only   Check photographs without reading a local key or calling MBRIS.
  --help          Show usage without reading configuration or making requests.

Wikimedia is preferred; verified Commons/iNaturalist photos, accepted names,
and bundled Korean summaries fill gaps. Entries are requested sequentially,
with one second between attempts. Compatible completed results resume automatically.
Three consecutive transient failures stop the run; unchecked entries stay unknown.''';

Future<void> main(List<String> arguments) async {
  Dio? client;
  try {
    final options = FishAuditOptions.parse(arguments);
    if (options.help) {
      stdout.writeln(_usage);
      return;
    }
    var mbrisKey = '';
    if (options.configPath != null && !options.photosOnly) {
      final settings = await _readJsonFile(
        File(options.configPath!),
        maxBytes: 64 * 1024,
        message: 'The local MBRIS configuration cannot be read.',
      );
      final value = settings['MBRIS_SERVICE_KEY'];
      if (value is! String || value.trim().isEmpty) {
        throw const FishAuditInputException(
          'The local MBRIS configuration is invalid.',
        );
      }
      mbrisKey = value;
    }
    client = Dio();
    final korean = MbrisFishDetailProvider(dio: client, serviceKey: mbrisKey);
    final enableKorean = options.configPath != null && !options.photosOnly;
    if (enableKorean && !korean.isConfigured) {
      throw const FishAuditInputException(
        'The local MBRIS configuration is invalid.',
      );
    }
    final provider = RecoveringFishDetailProvider(
      photoOnly: options.photosOnly,
      primary: options.photosOnly
          ? WikimediaFishDetailProvider(dio: client)
          : CompositeFishDetailProvider(
              wikimedia: WikimediaFishDetailProvider(dio: client),
              korean: korean,
              enableKorean: enableKorean,
            ),
    );
    await auditFishDetails(
      options: options,
      provider: provider,
      sourceMode: provider.detailCacheNamespace,
      log: stdout.writeln,
    );
  } on FishAuditInputException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln('Use --help for audit options.');
    exitCode = 64;
  } on Object {
    // Never expose request URLs, credentials, or raw provider/file exceptions.
    stderr.writeln(
      'The audit could not finish. Its last saved report is unchanged.',
    );
    exitCode = 1;
  } finally {
    client?.close(force: true);
  }
}

class FishAuditInputException implements Exception {
  const FishAuditInputException(this.message);
  final String message;
}

class FishAuditOptions {
  const FishAuditOptions._({
    required this.workspacePath,
    required this.outputPath,
    this.configPath,
    this.limit = 800,
    this.offset = 0,
    this.help = false,
    this.photosOnly = false,
  });

  factory FishAuditOptions.parse(
    List<String> arguments, {
    String? workspacePath,
  }) {
    final workspace = path.normalize(path.absolute(workspacePath ?? '.'));
    var limit = 800;
    var offset = 0;
    var output = '.dart_tool/fish_detail_audit.json';
    String? config;
    var help = false;
    var photosOnly = false;
    final seen = <String>{};
    for (final argument in arguments) {
      if (argument == '--help' || argument == '-h') {
        help = true;
        continue;
      }
      if (argument == '--photos-only') {
        if (!seen.add(argument)) {
          throw const FishAuditInputException('Audit options must be unique.');
        }
        photosOnly = true;
        continue;
      }
      final separator = argument.indexOf('=');
      if (separator < 0) {
        throw const FishAuditInputException('Invalid audit option.');
      }
      final name = argument.substring(0, separator);
      final value = argument.substring(separator + 1);
      if (value.isEmpty || !seen.add(name)) {
        throw const FishAuditInputException(
          'Audit options must be nonempty and unique.',
        );
      }
      switch (name) {
        case '--limit':
          limit = int.tryParse(value) ?? -1;
        case '--offset':
          offset = int.tryParse(value) ?? -1;
        case '--output':
          output = value;
        case '--config':
          config = path.normalize(path.join(workspace, value));
        default:
          throw const FishAuditInputException('Unknown audit option.');
      }
    }
    if (limit < 1 || limit > 800 || offset < 0 || offset >= 800) {
      throw const FishAuditInputException(
        'Limit must be 1..800 and offset 0..799.',
      );
    }
    final outputPath = path.normalize(path.join(workspace, output));
    if (!path.isWithin(path.join(workspace, '.dart_tool'), outputPath)) {
      throw const FishAuditInputException(
        'Audit reports must be written beneath .dart_tool.',
      );
    }
    return FishAuditOptions._(
      workspacePath: workspace,
      outputPath: outputPath,
      configPath: config,
      limit: limit,
      offset: offset,
      help: help,
      photosOnly: photosOnly,
    );
  }

  final String workspacePath;
  final String outputPath;
  final String? configPath;
  final int limit;
  final int offset;
  final bool help;
  final bool photosOnly;
}

/// Audit public provider results without writing app assets or account data.
/// Optional wait/clock/provider arguments let tests use only local fixtures.
Future<Map<String, Object?>> auditFishDetails({
  required FishAuditOptions options,
  required FishDetailProvider provider,
  required String sourceMode,
  Future<void> Function(Duration)? wait,
  DateTime Function()? clock,
  void Function(String)? log,
}) async {
  final pause = wait ?? Future<void>.delayed;
  final now = clock ?? DateTime.now;
  final catalogFile = File(
    path.join(options.workspacePath, 'assets', 'data', 'fish_catalog.json'),
  );
  List<int> bytes;
  Map<String, dynamic> catalog;
  try {
    if (await catalogFile.length() > 4 * 1024 * 1024) {
      throw const FormatException();
    }
    bytes = await catalogFile.readAsBytes();
    catalog = Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
  } on Object {
    throw const FishAuditInputException('The public catalog cannot be read.');
  }
  final rows = catalog['species'];
  if (catalog['version'] != 1 ||
      rows is! List ||
      rows.isEmpty ||
      rows.length > 800 ||
      catalog['recordCount'] != rows.length) {
    throw const FishAuditInputException(
      'The public catalog metadata is invalid.',
    );
  }
  final List<FishSpecies> fish;
  try {
    fish = [
      for (final row in rows)
        FishSpecies.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
    if (fish.map((item) => item.id).toSet().length != fish.length) {
      throw const FormatException();
    }
  } on Object {
    throw const FishAuditInputException(
      'The public catalog identities are invalid.',
    );
  }
  if (options.offset >= fish.length) {
    throw const FishAuditInputException(
      'The offset is outside the public catalog.',
    );
  }
  final catalogHash = sha256.convert(bytes).toString();
  final output = File(options.outputPath);
  await output.parent.create(recursive: true);
  final reportRoot = Directory(path.join(options.workspacePath, '.dart_tool'));
  final realRoot = await reportRoot.resolveSymbolicLinks();
  final realParent = await output.parent.resolveSymbolicLinks();
  if (!path.equals(realRoot, realParent) &&
      !path.isWithin(realRoot, realParent)) {
    throw const FishAuditInputException(
      'The audit report directory is invalid.',
    );
  }
  final previous = await _readPrevious(output);
  final compatible =
      previous?['version'] == 1 &&
      previous?['catalogSha256'] == catalogHash &&
      previous?['sourceEnabledMode'] == sourceMode;
  final saved = <String, Map<String, dynamic>>{};
  final previousRows = compatible ? previous!['records'] : null;
  if (previousRows is List) {
    for (final row in previousRows) {
      if (row is Map && row['id'] is String) {
        saved[row['id'] as String] = Map<String, dynamic>.from(row);
      }
    }
  }
  final records = <Map<String, Object?>>[
    for (final item in fish) _resumeRecord(item, saved[item.id]),
  ];
  final startedAt = compatible && previous?['startedAt'] is String
      ? previous!['startedAt'] as String
      : now().toUtc().toIso8601String();
  final report = <String, Object?>{
    'version': 1,
    'catalogSha256': catalogHash,
    'sourceEnabledMode': sourceMode,
    'catalogRecordCount': fish.length,
    'offset': options.offset,
    'limit': options.limit,
    'startedAt': startedAt,
    'updatedAt': startedAt,
    'stopReason': null,
    'attemptedThisRun': 0,
    'records': records,
  };
  Future<void> persist() async {
    report['updatedAt'] = now().toUtc().toIso8601String();
    report['summary'] = _summarize(records);
    await _atomicWrite(output, report);
  }

  await persist();
  var attempted = 0;
  var consecutiveTransient = 0;
  final end = (options.offset + options.limit).clamp(0, fish.length);
  for (var index = options.offset; index < end; index++) {
    final existing = records[index]['outcome'];
    final result = records[index]['result'];
    final needsRetry = result is Map && result['detailNeedsRetry'] == true;
    if (existing == 'noData' || (existing == 'success' && !needsRetry)) {
      continue;
    }
    final base = fish[index];
    final checkedAt = now().toUtc().toIso8601String();
    try {
      final detail = await provider.fetchDetail(base, forceRefresh: true);
      final clean = _publicFish(detail);
      if (!_sameIdentity(base, clean) || !_hasAnyField(clean)) {
        throw const FishCatalogException(FishCatalogFailure.invalidResponse);
      }
      records[index] = _successRecord(clean, checkedAt);
      consecutiveTransient = 0;
    } on Object catch (error) {
      final reason = error is FishCatalogException
          ? error.reason
          : FishCatalogFailure.invalidResponse;
      records[index] = _emptyRecord(
        base,
        checkedAt: checkedAt,
        outcome: reason == FishCatalogFailure.noData ? 'noData' : 'failure',
        reason: reason.name,
      );
      consecutiveTransient = _transient.contains(reason.name)
          ? consecutiveTransient + 1
          : 0;
    }
    attempted++;
    report['attemptedThisRun'] = attempted;
    if (consecutiveTransient >= 3) {
      report['stopReason'] = 'consecutiveTransientFailures';
    }
    await persist();
    if (attempted % 10 == 0) {
      log?.call(_summaryLine('Progress', _summarize(records)));
    }
    await pause(const Duration(seconds: 1));
    if (consecutiveTransient >= 3) break;
  }
  log?.call(_summaryLine('Audit complete', _summarize(records)));
  return report;
}

const _transient = {'rateLimited', 'network', 'timedOut'};

Map<String, Object?> _emptyRecord(
  FishSpecies fish, {
  String? checkedAt,
  String outcome = 'notChecked',
  String? reason,
}) => {
  'id': fish.id,
  'name': fish.name,
  'scientificName': fish.scientificName,
  'checkedAt': checkedAt,
  'outcome': outcome,
  'reason': reason,
  // Failures and unchecked entries are unknown, not missing provider data.
  'description': outcome == 'noData' ? false : null,
  'photo': outcome == 'noData' ? false : null,
  'size': outcome == 'noData' ? false : null,
};

Map<String, Object?> _successRecord(FishSpecies fish, String checkedAt) => {
  ..._emptyRecord(fish, checkedAt: checkedAt, outcome: 'success'),
  'description': fish.feature.trim().isNotEmpty,
  'photo': fish.imageUrl?.trim().isNotEmpty ?? false,
  'size': fish.maxSize.trim().isNotEmpty,
  'sourceName': fish.sourceName,
  'sourceUrl': fish.sourceUrl,
  'photoSourceUrl': fish.photoSourceUrl,
  'photoLicenseUrl': fish.photoLicenseUrl,
  'photoAttribution': fish.photoAttribution,
  'descriptionSourceUrl': fish.descriptionSourceUrl,
  'descriptionAttribution': fish.descriptionAttribution,
  'result': fish.toJson(),
};

Map<String, Object?> _resumeRecord(
  FishSpecies base,
  Map<String, dynamic>? saved,
) {
  if (saved == null ||
      saved['scientificName'] != base.scientificName ||
      saved['checkedAt'] is! String ||
      DateTime.tryParse(saved['checkedAt'] as String) == null) {
    return _emptyRecord(base);
  }
  if (saved['outcome'] == 'success' && saved['result'] is Map) {
    try {
      final detail = _publicFish(
        FishSpecies.fromJson(Map<String, dynamic>.from(saved['result'] as Map)),
      );
      if (_sameIdentity(base, detail) && _hasAnyField(detail)) {
        return _successRecord(detail, saved['checkedAt'] as String);
      }
    } on Object {
      // A broken saved record is rechecked rather than treated as missing.
    }
  }
  final reason = saved['reason'];
  if ((saved['outcome'] == 'noData' && reason == 'noData') ||
      (saved['outcome'] == 'failure' &&
          FishCatalogFailure.values.any((value) => value.name == reason))) {
    return _emptyRecord(
      base,
      checkedAt: saved['checkedAt'] as String,
      outcome: saved['outcome'] as String,
      reason: reason as String,
    );
  }
  return _emptyRecord(base);
}

FishSpecies _publicFish(FishSpecies fish) {
  final json = fish.toJson();
  for (final key in [
    'imageUrl',
    'sourceUrl',
    'photoSourceUrl',
    'photoLicenseUrl',
    'descriptionSourceUrl',
  ]) {
    final value = json[key];
    if (value is String && !_publicUrl(value)) {
      json[key] = null;
    }
  }
  return FishSpecies.fromJson(json);
}

bool _publicUrl(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return false;
  }
  const privateParameters = {
    'key',
    'apikey',
    'api_key',
    'servicekey',
    'token',
    'access_token',
    'password',
    'authorization',
    'signature',
    'client_secret',
  };
  return !uri.queryParameters.keys.any(
    (key) => privateParameters.contains(key.toLowerCase()),
  );
}

bool _sameIdentity(FishSpecies base, FishSpecies detail) =>
    base.id == detail.id &&
    base.name == detail.name &&
    base.scientificName == detail.scientificName;

bool _hasAnyField(FishSpecies fish) =>
    fish.feature.trim().isNotEmpty ||
    fish.maxSize.trim().isNotEmpty ||
    (fish.imageUrl?.trim().isNotEmpty ?? false);

Map<String, int> _summarize(List<Map<String, Object?>> records) => {
  'checked': records.where((row) => row['outcome'] != 'notChecked').length,
  'success': records.where((row) => row['outcome'] == 'success').length,
  'noData': records.where((row) => row['outcome'] == 'noData').length,
  'failure': records.where((row) => row['outcome'] == 'failure').length,
  'transient': records
      .where(
        (row) =>
            row['outcome'] == 'failure' && _transient.contains(row['reason']),
      )
      .length,
  'notChecked': records.where((row) => row['outcome'] == 'notChecked').length,
  'description': records.where((row) => row['description'] == true).length,
  'photo': records.where((row) => row['photo'] == true).length,
  'size': records.where((row) => row['size'] == true).length,
};

String _summaryLine(String prefix, Map<String, int> summary) =>
    '$prefix: checked=${summary['checked']} success=${summary['success']} '
    'noData=${summary['noData']} failure=${summary['failure']} '
    'transient=${summary['transient']} '
    'notChecked=${summary['notChecked']} description=${summary['description']} '
    'photo=${summary['photo']} size=${summary['size']}.';

Future<Map<String, dynamic>> _readJsonFile(
  File file, {
  required int maxBytes,
  required String message,
}) async {
  try {
    if (await file.length() > maxBytes) throw const FormatException();
    return Map<String, dynamic>.from(
      jsonDecode(await file.readAsString()) as Map,
    );
  } on Object {
    throw FishAuditInputException(message);
  }
}

Future<Map<String, dynamic>?> _readPrevious(File file) async {
  if (!await file.exists()) return null;
  // Do not silently overwrite an unreadable checkpoint with an empty report.
  return _readJsonFile(
    file,
    maxBytes: 32 * 1024 * 1024,
    message: 'The saved audit report is invalid. Choose a new output file.',
  );
}

Future<void> _atomicWrite(File output, Map<String, Object?> report) async {
  final temporary = File('${output.path}.tmp.$pid');
  try {
    await temporary.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(report)}\n',
      flush: true,
    );
    await temporary.rename(output.path);
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
}
