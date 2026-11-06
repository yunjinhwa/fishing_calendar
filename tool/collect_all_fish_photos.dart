import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import 'package:fishing_build/data/fish/fish_catalog_service.dart';
import 'package:fishing_build/data/fish/fish_photo_validation.dart';
import 'package:fishing_build/data/fish/inaturalist_fish_photo_provider.dart';
import 'package:fishing_build/data/fish/reviewed_fish_photos.dart';
import 'package:fishing_build/data/models/fish_species.dart';

const _mode =
    'all800-inaturalist-curated-photos-v1;strict-catalog-identity;no-implicit-synonyms';
const _outputPath = '.dart_tool/fish_all_public_photos.json';
const _transient = {'network', 'timedOut', 'rateLimited'};

/// Whole-catalog photo collection. No credential file or Wikimedia API is used.
Future<void> main(List<String> args) async {
  if (args.contains('--help')) {
    stdout.writeln(
      'dart run tool/collect_all_fish_photos.dart [--retry-transient]\n'
      'Checks all catalog species sequentially; resumes compatible records.\n'
      'Output: $_outputPath. Minimum API spacing:1.1 seconds.\n'
      'Retry-After is honored; repeated throttling exits with a resumable checkpoint.',
    );
    return;
  }
  if (args.any((arg) => arg != '--retry-transient')) {
    stderr.writeln('Unknown option. Use --help.');
    exitCode = 64;
    return;
  }
  final dio = Dio();
  try {
    await _collect(dio, retryTransient: args.contains('--retry-transient'));
  } on Object {
    stderr.writeln(
      'Collection interrupted. Resume from the last public checkpoint.',
    );
    exitCode = 1;
  } finally {
    dio.close(force: true);
  }
}

Future<void> _collect(Dio dio, {required bool retryTransient}) async {
  final bytes = await File('assets/data/fish_catalog.json').readAsBytes();
  final catalog = jsonDecode(utf8.decode(bytes)) as Map;
  final species = [
    for (final row in catalog['species'] as List)
      FishSpecies.fromJson(Map<String, dynamic>.from(row as Map)),
  ];
  if (species.length != 800 ||
      species.map((fish) => fish.id).toSet().length != 800) {
    throw const FormatException('Invalid public catalog.');
  }
  final hash = sha256.convert(bytes).toString();
  final output = File(_outputPath);
  await output.parent.create(recursive: true);
  final previous = await _read(output);
  final compatible =
      previous?['catalogSha256'] == hash &&
      previous?['sourceEnabledMode'] == _mode;
  final resumed = <String, Map<String, dynamic>>{};
  if (compatible && previous?['records'] is List) {
    for (final value in previous!['records'] as List) {
      final row = Map<String, dynamic>.from(value as Map);
      resumed[_key(row)] = row;
    }
  }
  final known = <String, FishSpecies>{};
  final provenance = <String, String>{};
  for (final filename in [
    'assets/data/fish_enrichment.json',
    '.dart_tool/fish_actual_photo_audit.json',
    '.dart_tool/fish_priority_public_content.json',
    '.dart_tool/fish_priority_extra_photos.json',
  ]) {
    final saved = await _read(File(filename));
    for (final value in saved?['records'] as List? ?? const []) {
      if (value is! Map || value['result'] is! Map) continue;
      try {
        final fish = FishSpecies.fromJson(
          Map<String, dynamic>.from(value['result'] as Map),
        );
        if (_validPhoto(fish)) {
          known[_fishKey(fish)] = fish;
          provenance[_fishKey(fish)] = filename;
        }
      } on Object {
        /* Invalid old records never establish a photographic match. */
      }
    }
  }
  final records = <Map<String, dynamic>>[];
  for (final base in species) {
    final key = _fishKey(base);
    final old = resumed[key];
    if (old != null &&
        old['outcome'] != 'notChecked' &&
        !(retryTransient && _transient.contains(old['reason']))) {
      if (old['outcome'] != 'success' || _validPhoto(_result(old))) {
        records.add(old);
        continue;
      }
    }
    final reviewed = ReviewedFishPhotos.apply(base);
    final cached = _validPhoto(reviewed) ? reviewed : known[key];
    records.add({
      'id': base.id,
      'name': base.name,
      'scientificName': base.scientificName,
      'checkedAt': cached == null
          ? null
          : DateTime.now().toUtc().toIso8601String(),
      'outcome': cached == null ? 'notChecked' : 'success',
      'reason': null,
      'photo': cached == null ? null : true,
      'result': _photoOnto(base, cached ?? base).toJson(),
      if (cached != null)
        'provenance': {
          'mode': 'reusedValidatedRealPhoto',
          'source': _validPhoto(reviewed)
              ? 'ReviewedFishPhotos'
              : provenance[key],
        },
    });
  }
  final report = <String, dynamic>{
    'version': 1,
    'catalogSha256': hash,
    'catalogRecordCount': 800,
    'sourceEnabledMode': _mode,
    'startedAt': compatible
        ? previous!['startedAt']
        : DateTime.now().toUtc().toIso8601String(),
    'updatedAt': null,
    'stopReason': null,
    'records': records,
    'requestCount': compatible ? previous!['requestCount'] ?? 0 : 0,
  };
  final pace = _Pace();
  if (compatible && previous?['cooldownUntil'] is String) {
    pace.notBefore = DateTime.tryParse(previous!['cooldownUntil'] as String);
  }
  final trace = <String, dynamic>{};
  dio.interceptors.add(
    QueuedInterceptorsWrapper(
      onRequest: (options, handler) async {
        if (options.uri.host != 'api.inaturalist.org') {
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.cancel,
            ),
          );
          return;
        }
        await pace.waitRequestStart();
        if (options.cancelToken?.isCancelled == true) {
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.cancel,
            ),
          );
          return;
        }
        report['requestCount'] = (report['requestCount'] as int) + 1;
        handler.next(options);
      },
      onResponse: (response, handler) async {
        pace.observe(response);
        (trace['httpStatuses'] as List<int>).add(response.statusCode ?? 0);
        final body = response.data;
        if (response.statusCode == 200 &&
            body is ResponseBody &&
            response.requestOptions.uri.path == '/v1/taxa') {
          final buffer = BytesBuilder(copy: false);
          await for (final chunk in body.stream) {
            if (buffer.length + chunk.length > 1024 * 1024) {
              handler.reject(
                DioException(
                  requestOptions: response.requestOptions,
                  type: DioExceptionType.badResponse,
                ),
              );
              return;
            }
            buffer.add(chunk);
          }
          final data = buffer.takeBytes();
          response.data = ResponseBody.fromBytes(
            data,
            response.statusCode!,
            headers: response.headers.map,
          );
          try {
            final json = jsonDecode(utf8.decode(data)) as Map;
            final rows = json['results'] as List;
            final exact = rows
                .where(
                  (row) =>
                      row is Map &&
                      _science(row['name']?.toString() ?? '') ==
                          trace['scientificKey'],
                )
                .toList();
            trace['exactTaxonCount'] = exact.length;
            trace['searchResultCount'] = rows.length;
            trace['searchComplete'] = json['total_results'] == rows.length;
            if (exact.length == 1) {
              final taxon = exact.single as Map;
              final common = taxon['preferred_common_name']?.toString() ?? '';
              final hasKorean = RegExp(r'[가-힣]').hasMatch(common);
              trace['koreanNameStatus'] = !hasKorean
                  ? 'absent'
                  : (trace['koreanKeys'] as Set<String>).contains(
                      _common(common),
                    )
                  ? 'matches'
                  : 'conflicts';
              trace['exactActiveSpecies'] =
                  taxon['rank'] == 'species' &&
                  taxon['is_active'] == true &&
                  taxon['provisional'] != true;
            }
          } on Object {
            trace['unreadableSearchMetadata'] = true;
          }
        }
        handler.next(response);
      },
    ),
  );
  final provider = InaturalistFishPhotoProvider(
    dio: dio,
    requestSpacing: const Duration(milliseconds: 1100),
  );
  final timer = Stopwatch()..start();
  var attempted = 0, consecutiveRate = 0, consecutiveTransient = 0;
  Future<void> save() async {
    report['updatedAt'] = DateTime.now().toUtc().toIso8601String();
    report['summary'] = _summary(records);
    report['attemptedThisRun'] = attempted;
    report['cooldownUntil'] = pace.notBefore?.toUtc().toIso8601String();
    final tmp = File('${output.path}.tmp.$pid');
    await tmp.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(report)}\n',
      flush: true,
    );
    await tmp.rename(output.path);
  }

  void progress() {
    final summary = _summary(records);
    final pending = summary['notChecked']!;
    final seconds = attempted == 0
        ? null
        : (timer.elapsedMilliseconds / 1000 / attempted * pending).round();
    stdout.writeln(
      jsonEncode({
        'progress': summary,
        'attemptedThisRun': attempted,
        'requests': report['requestCount'],
        'elapsedSeconds': timer.elapsed.inSeconds,
        'etaMinutes': seconds == null ? null : (seconds / 60).ceil(),
        'cooldownUntil': report['cooldownUntil'],
      }),
    );
  }

  await save();
  progress();
  for (var index = 0; index < records.length; index++) {
    if (records[index]['outcome'] != 'notChecked') continue;
    await pace.waitCooldown(() async {
      await save();
      progress();
    });
    final base = species[index];
    trace
      ..clear()
      ..addAll({
        'httpStatuses': <int>[],
        'scientificKey': _science(base.scientificName),
        'koreanKeys': [base.name, ...base.aliases].map(_common).toSet(),
      });
    final row = records[index];
    try {
      final photo = await provider.fetchDetail(base);
      if (_fishKey(photo) != _fishKey(base) || !_validPhoto(photo)) {
        throw const FishCatalogException(FishCatalogFailure.invalidResponse);
      }
      row.addAll({
        'checkedAt': DateTime.now().toUtc().toIso8601String(),
        'outcome': 'success',
        'reason': null,
        'photo': true,
        'result': _photoOnto(base, photo).toJson(),
        'provenance': {
          'mode': 'strictInaturalistCuratedPhoto',
          'source': photo.photoSourceUrl,
          'license': photo.photoLicenseUrl,
          'attribution': photo.photoAttribution,
        },
      });
      consecutiveRate = 0;
      consecutiveTransient = 0;
    } on Object catch (error) {
      final reason = error is FishCatalogException
          ? error.reason
          : FishCatalogFailure.invalidResponse;
      final confirmedIdentity =
          trace['searchComplete'] == true &&
          trace['exactTaxonCount'] == 1 &&
          trace['exactActiveSpecies'] == true &&
          trace['koreanNameStatus'] != 'conflicts' &&
          (trace['httpStatuses'] as List<int>).every((status) => status == 200);
      final genuineNoData =
          reason == FishCatalogFailure.noData && confirmedIdentity;
      final isTransient = _transient.contains(reason.name);
      row.addAll({
        'checkedAt': DateTime.now().toUtc().toIso8601String(),
        'outcome': genuineNoData
            ? 'noData'
            : isTransient
            ? 'failure'
            : 'unknown',
        'reason': genuineNoData
            ? 'noLicensedCuratedPhoto'
            : reason == FishCatalogFailure.noData
            ? 'taxonomyOrIdentityUnresolved'
            : reason.name,
        'photo': genuineNoData ? false : null,
        'identityEvidence': {
          for (final key in [
            'exactTaxonCount',
            'searchComplete',
            'exactActiveSpecies',
            'koreanNameStatus',
            'httpStatuses',
            'unreadableSearchMetadata',
          ])
            if (trace.containsKey(key)) key: trace[key],
        },
        'taxonomyFallback': 'notAttemptedWithoutPositiveKoreanIdentityProof',
      });
      consecutiveRate = reason == FishCatalogFailure.rateLimited
          ? consecutiveRate + 1
          : 0;
      consecutiveTransient = isTransient ? consecutiveTransient + 1 : 0;
      if (reason == FishCatalogFailure.unauthorized) {
        report['stopReason'] = 'publicApiAccessDenied';
      }
      if (consecutiveRate >= 3) {
        report['stopReason'] = 'repeatedRateLimitsResumeAfterCooldown';
      }
      if (consecutiveTransient >= 6) {
        report['stopReason'] = 'persistentTransportFailureResumeLater';
      }
      if (consecutiveTransient == 3 && report['stopReason'] == null) {
        pace.extendCooldown(const Duration(minutes: 2));
      }
    }
    attempted++;
    await save();
    if (attempted % 10 == 0 || report['stopReason'] != null) progress();
    if (report['stopReason'] != null) break;
  }
  report['completedAt'] = _summary(records)['notChecked'] == 0
      ? DateTime.now().toUtc().toIso8601String()
      : null;
  await save();
  progress();
}

class _Pace {
  DateTime? lastStart;
  DateTime? notBefore;
  Future<void> waitRequestStart() async {
    final last = lastStart;
    if (last != null) {
      final remaining =
          const Duration(milliseconds: 1100) - DateTime.now().difference(last);
      if (remaining > Duration.zero) await Future<void>.delayed(remaining);
    }
    lastStart = DateTime.now();
  }

  void observe(Response<dynamic> response) {
    if (response.statusCode != 429 && response.statusCode != 503) return;
    final value = response.headers.value('retry-after');
    Duration? delay;
    final seconds = int.tryParse(value ?? '');
    if (seconds != null && seconds >= 0) delay = Duration(seconds: seconds);
    if (delay == null && value != null) {
      try {
        delay = HttpDate.parse(value).difference(DateTime.now().toUtc());
      } on Object {
        /* use safe fallback */
      }
    }
    extendCooldown(
      delay != null && delay > Duration.zero
          ? delay
          : const Duration(minutes: 1),
    );
  }

  void extendCooldown(Duration delay) {
    final target = DateTime.now().add(delay);
    if (notBefore == null || target.isAfter(notBefore!)) notBefore = target;
  }

  Future<void> waitCooldown(Future<void> Function() checkpoint) async {
    while (notBefore != null && notBefore!.isAfter(DateTime.now())) {
      await checkpoint();
      await Future<void>.delayed(
        Duration(
          milliseconds: math.min(
            55000,
            notBefore!
                .difference(DateTime.now())
                .inMilliseconds
                .clamp(1, 86400000),
          ),
        ),
      );
    }
  }
}

Future<Map<String, dynamic>?> _read(File file) async {
  if (!await file.exists()) return null;
  if (await file.length() > 32 * 1024 * 1024) return null;
  return Map<String, dynamic>.from(
    jsonDecode(await file.readAsString()) as Map,
  );
}

String _science(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
String _common(String value) =>
    value.replaceAll(RegExp(r'\s+'), '').toLowerCase();
String _fishKey(FishSpecies fish) =>
    jsonEncode([fish.id, fish.name, fish.scientificName]);
String _key(Map row) =>
    jsonEncode([row['id'], row['name'], row['scientificName']]);
FishSpecies _result(Map row) =>
    FishSpecies.fromJson(Map<String, dynamic>.from(row['result'] as Map));
FishSpecies _photoOnto(FishSpecies base, FishSpecies photo) =>
    FishSpecies.fromJson({
      ...base.toJson(),
      if (_validPhoto(photo)) ...{
        'imageUrl': photo.imageUrl,
        'photoSourceUrl': photo.photoSourceUrl,
        'photoAttribution': photo.photoAttribution,
        'photoLicenseUrl': photo.photoLicenseUrl,
      },
    });
bool _validPhoto(FishSpecies fish) {
  if (!hasUsableFishPhoto(fish) ||
      (fish.photoAttribution?.trim().isEmpty ?? true)) {
    return false;
  }
  final source = Uri.tryParse(fish.photoSourceUrl ?? '');
  final license = Uri.tryParse(fish.photoLicenseUrl ?? '');
  if (source == null ||
      license == null ||
      source.scheme != 'https' ||
      source.userInfo.isNotEmpty ||
      license.scheme != 'https' ||
      license.host != 'creativecommons.org' ||
      license.userInfo.isNotEmpty ||
      !RegExp(
        r'^/(licenses/(by|by-sa)/(1\.0|2\.0|2\.5|3\.0|4\.0)|publicdomain/(zero|mark)/1\.0)/?$',
      ).hasMatch(license.path)) {
    return false;
  }
  return source.host == 'commons.wikimedia.org' &&
          source.path.startsWith('/wiki/File:') ||
      source.host == 'www.inaturalist.org' &&
          RegExp(r'^/photos/[1-9][0-9]*/?$').hasMatch(source.path);
}

Map<String, int> _summary(List<Map<String, dynamic>> rows) => {
  'total': rows.length,
  'checked': rows.where((row) => row['outcome'] != 'notChecked').length,
  'validPhoto': rows.where((row) => row['outcome'] == 'success').length,
  'genuineNoData': rows.where((row) => row['outcome'] == 'noData').length,
  'identityUnknown': rows.where((row) => row['outcome'] == 'unknown').length,
  'transient': rows
      .where(
        (row) =>
            row['outcome'] == 'failure' && _transient.contains(row['reason']),
      )
      .length,
  'notChecked': rows.where((row) => row['outcome'] == 'notChecked').length,
};
