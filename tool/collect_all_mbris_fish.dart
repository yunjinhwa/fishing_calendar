import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:fishing_build/data/fish/fish_catalog_service.dart';
import 'package:fishing_build/data/fish/fish_size_summary.dart';
import 'package:fishing_build/data/fish/mbris_fish_detail_provider.dart';
import 'package:fishing_build/data/models/fish_species.dart';
import 'package:xml/xml.dart';

const _outputPath = '.dart_tool/fish_all_mbris_content.json';
const _endpoint = 'https://apis.data.go.kr/B553482/mbrisdataview3/taxonlist3';
const _source = MbrisFishDetailProvider.sourceUrl;
const _credit = '국립해양생물자원관 MBRIS';
const _timeout = Duration(seconds: 20);
const _spacing = Duration(milliseconds: 1100);
const _maxBytes = 16 * 1024 * 1024;
const _requestedRows = 500;
const _transient = {
  FishCatalogFailure.network,
  FishCatalogFailure.timedOut,
  FishCatalogFailure.rateLimited,
};
const _license = {
  'name': '이용허락범위 제한 없음',
  'url': 'https://www.data.go.kr/ugs/selectPortalPolicyView.do',
  'evidenceUrl': _source,
};

/// Collect all 800 exact catalog identities, without modifying shipped data.
///
/// The official portal marks scientific/common/family searches optional, so an
/// unfiltered paginated snapshot is tried first. Returned pagination is checked
/// at every page. Only a COMPLETE snapshot may establish an absent species.
/// Existing MbrisFishDetailProvider validates exact identity, accepted-name
/// conflicts and disagreeing rows through a local snapshot adapter; that
/// adapter does not make another network request or claim a new API source.
Future<void> main(List<String> arguments) async {
  final client = Dio();
  try {
    if (arguments.any(
          (argument) =>
              !{'--probe-only', '--reprocess-only'}.contains(argument),
        ) ||
        arguments.length > 1) {
      throw const FormatException('Unsupported collection option.');
    }
    final bytes = await File('assets/data/fish_catalog.json').readAsBytes();
    final catalog = jsonDecode(utf8.decode(bytes)) as Map;
    final fish = (catalog['species'] as List)
        .map(
          (row) => _catalogBase(
            FishSpecies.fromJson(Map<String, dynamic>.from(row as Map)),
          ),
        )
        .toList();
    if (fish.length != 800 ||
        fish.map((item) => item.id).toSet().length != 800) {
      throw const FormatException('Unexpected catalog identities.');
    }
    final catalogHash = sha256.convert(bytes).toString();
    var key = '';
    if (!arguments.contains('--reprocess-only')) {
      final settings =
          jsonDecode(
                (await File(
                  'fish.local.json',
                ).readAsString()).replaceFirst(RegExp(r'^\uFEFF'), ''),
              )
              as Map;
      key = _key(settings['MBRIS_SERVICE_KEY']);
    }
    final collector = _Collector(client, key, fish, catalogHash);
    await collector.load();
    await collector.run(
      probeOnly: arguments.contains('--probe-only'),
      reprocessOnly: arguments.contains('--reprocess-only'),
    );
  } on FishCatalogException catch (error) {
    stderr.writeln(
      'Collection stopped: ${error.reason.name}. Checkpoint retained.',
    );
    exitCode = 1;
  } on Object {
    // Never print raw provider/config/file errors: requests contain a key.
    stderr.writeln(
      'Collection stopped: sanitized input or processing failure. Checkpoint retained.',
    );
    exitCode = 1;
  } finally {
    client.close(force: true);
  }
}

class _Collector {
  _Collector(this.client, this.key, this.fish, this.catalogHash);
  final Dio client;
  final String key;
  final List<FishSpecies> fish;
  final String catalogHash;
  final output = File(_outputPath);
  final records = <Map<String, dynamic>>[];
  final matchingRows = <Map<String, String>>[];
  final fieldCounts = <String, int>{};
  final matchedFieldCounts = <String, int>{};
  final pageHashes = <String>{};
  final progressClock = Stopwatch()..start();
  late Map<String, dynamic> report;
  var requests = 0;
  var retries = 0;
  var nextPage = 1;
  var scanned = 0;
  int? total;
  int? pageSize;
  var bulkComplete = false;
  DateTime? lastRequestFinished;

  Future<void> load() async {
    if (await output.exists()) {
      if (await output.length() > 48 * 1024 * 1024) {
        throw const FormatException();
      }
      report = Map<String, dynamic>.from(
        jsonDecode(await output.readAsString()) as Map,
      );
      if (report['version'] != 1 || report['catalogSha256'] != catalogHash) {
        throw const FormatException('Checkpoint catalog mismatch.');
      }
      final saved = report['records'] as List;
      if (saved.length != fish.length) throw const FormatException();
      for (var index = 0; index < fish.length; index++) {
        final row = Map<String, dynamic>.from(saved[index] as Map);
        if (!_sameIdentity(fish[index], row)) throw const FormatException();
        records.add(row);
      }
      final bulk = Map<String, dynamic>.from(report['bulk'] as Map? ?? {});
      nextPage = bulk['nextPage'] as int? ?? 1;
      scanned = bulk['rowsScanned'] as int? ?? 0;
      total = bulk['totalCount'] as int?;
      pageSize = bulk['pageSize'] as int?;
      bulkComplete = bulk['complete'] == true;
      for (final row in bulk['matchingRows'] as List? ?? []) {
        matchingRows.add(Map<String, String>.from(row as Map));
      }
      fieldCounts.addAll(
        Map<String, int>.from(bulk['nonemptyFieldCounts'] as Map? ?? {}),
      );
      matchedFieldCounts.addAll(
        Map<String, int>.from(bulk['matchedNonemptyFieldCounts'] as Map? ?? {}),
      );
      pageHashes.addAll((bulk['pageHashes'] as List? ?? []).cast<String>());
      requests = report['networkRequests'] as int? ?? 0;
      retries = report['retryRequests'] as int? ?? 0;
      return;
    }
    report = {
      'version': 1,
      'catalogSha256': catalogHash,
      'catalogRecordCount': fish.length,
      'startedAt': _now(),
      'sourceEnabledMode': 'mbris-complete-snapshot-exact-identity-v1',
      'sourceContractUrl': _source,
      'license': _license,
      'networkPolicy':
          'One request at a time; >=1100ms after preceding completion; bounded retries with backoff. No images or Wikimedia requests. No credentials or request URLs logged.',
      'stopReason': null,
    };
    final known = <String, Map<String, dynamic>>{};
    for (final path in [
      '.dart_tool/fish_priority_korean_content.json',
      '.dart_tool/fish_detail_audit_recovery.json',
      '.dart_tool/fish_detail_audit_mbris.json',
    ]) {
      if (!await File(path).exists()) continue;
      final cached = jsonDecode(await File(path).readAsString()) as Map;
      for (final raw in cached['records'] as List? ?? []) {
        if (raw is! Map) continue;
        final row = Map<String, dynamic>.from(raw);
        if (row['outcome'] == 'success' && row['result'] is Map) {
          final result = row['result'] as Map;
          if (result['descriptionSourceUrl'] == _source &&
              '${result['descriptionAttribution'] ?? ''}'.contains('MBRIS') &&
              '${result['feature'] ?? ''}'.trim().isNotEmpty) {
            row['cacheFile'] = path;
            known.putIfAbsent('${row['id']}', () => row);
          }
        } else if (path.endsWith('fish_priority_korean_content.json') &&
            row['outcome'] == 'noData' &&
            row['origin'] == 'mbrisLive') {
          row['cacheFile'] = path;
          known.putIfAbsent('${row['id']}', () => row);
        }
      }
    }
    for (final base in fish) {
      final saved = known[base.id];
      if (saved != null && _sameIdentity(base, saved)) {
        if (saved['outcome'] == 'success') {
          final detail = FishSpecies.fromJson(
            Map<String, dynamic>.from(saved['result'] as Map),
          );
          records.add(
            _success(
              base,
              detail,
              [],
              'cachedVerifiedMbris',
              '${saved['fetchedAt'] ?? saved['checkedAt'] ?? _now()}',
              cacheFile: saved['cacheFile'] as String?,
            ),
          );
        } else {
          records.add(
            _empty(
              base,
              'noData',
              reason: 'noData',
              checkedAt: '${saved['checkedAt'] ?? _now()}',
              origin: 'cachedVerifiedMbris',
            ),
          );
        }
      } else {
        records.add(_empty(base, 'notChecked'));
      }
    }
    await persist();
  }

  Future<void> run({
    required bool probeOnly,
    bool reprocessOnly = false,
  }) async {
    if (reprocessOnly) {
      if (!bulkComplete || matchingRows.isEmpty) {
        throw const FormatException('A completed public snapshot is required.');
      }
      // Re-run the imported production provider against public cached rows.
      // This mode neither reads configuration nor calls the network. Direct
      // checks for the source-page gap remain authoritative and are retained.
      await _resolveCompleteSnapshot(preserveDirect: true);
      report['lastOfflineReprocessedAt'] = _now();
      report['complete'] = records.every(
        (row) => {'success', 'noData'}.contains(row['outcome']),
      );
      report['allCatalogRowsChecked'] = records.every(
        (row) => row['outcome'] != 'notChecked',
      );
      await persist();
      _log('Offline reprocessing finished');
      return;
    }
    if (records.every(
          (row) => {'success', 'noData'}.contains(row['outcome']),
        ) &&
        report['complete'] == true) {
      _log('Already complete');
      return;
    }
    report['stopReason'] = null;
    _log('Starting');
    var useIndividual = false;
    if (!useIndividual && !bulkComplete) {
      final names = fish.map((item) => _science(item.scientificName)).toSet();
      try {
        while (total == null || (nextPage - 1) * pageSize! < total!) {
          final page = await _bulkPage(nextPage);
          total ??= page.total;
          pageSize ??= page.pageSize;
          if (page.total != total ||
              page.pageSize != pageSize ||
              page.page != nextPage ||
              page.rows.length >
                  (total! - (nextPage - 1) * pageSize!).clamp(0, pageSize!)) {
            throw const FishCatalogException(
              FishCatalogFailure.invalidResponse,
            );
          }
          final hash = sha256
              .convert(utf8.encode(jsonEncode(page.rows)))
              .toString();
          if (page.rows.isNotEmpty && !pageHashes.add(hash)) {
            stdout.writeln(
              jsonEncode({
                'diagnostic': 'repeatedBulkPage',
                'page': nextPage,
                'returnedPage': page.page,
                'pageSize': page.pageSize,
                'rows': page.rows.length,
              }),
            );
            throw const FishCatalogException(
              FishCatalogFailure.invalidResponse,
            );
          }
          for (final row in page.rows) {
            _countFields(fieldCounts, row);
            final canonical = _science(
              row['SpcScitfNmShort']?.trim().isNotEmpty == true
                  ? row['SpcScitfNmShort']!
                  : row['SpcScitfNm'] ?? '',
            );
            if (names.contains(canonical)) {
              matchingRows.add(row);
              _countFields(matchedFieldCounts, row);
            }
          }
          scanned += page.rows.length;
          nextPage++;
          await persist();
          if (nextPage == 2 ||
              progressClock.elapsed > const Duration(seconds: 25)) {
            _log('Bulk progress');
          }
          if (probeOnly) {
            stdout.writeln(
              jsonEncode({
                'probe': 'verified',
                'totalCount': total,
                'returnedPageSize': pageSize,
                'rowsReceived': page.rows.length,
                'responseBytes': page.bytes,
                'fieldNames': page.rows.isEmpty
                    ? []
                    : page.rows.first.keys.toList(),
              }),
            );
            return;
          }
          // The full list is less efficient than checking remaining catalog
          // fish if the service imposes a very small page-size cap.
          if (nextPage == 2 && total! ~/ pageSize! > 800) {
            useIndividual = true;
            report['bulkFallbackReason'] =
                'providerPageSizeWouldExceed800Pages';
            break;
          }
        }
        bulkComplete = total != null && (nextPage - 1) * pageSize! >= total!;
      } on FishCatalogException catch (error) {
        if ({
          FishCatalogFailure.unauthorized,
          FishCatalogFailure.configuration,
        }.contains(error.reason)) {
          report['stopReason'] = error.reason.name;
          await persist();
          rethrow;
        }
        report['bulkFallbackReason'] = error.reason.name;
        useIndividual = true;
        _log('Bulk unavailable; checking remaining fish individually');
      }
    }
    if (bulkComplete && !useIndividual) {
      report['collectionMode'] = 'completePaginatedSnapshot';
      await _resolveCompleteSnapshot();
      if ((report['bulkPageFailures'] as List? ?? []).isNotEmpty) {
        // A documented provider-row gap cannot establish an absent catalog
        // species. Resolve every missing identity with its own exact query.
        report['collectionMode'] = 'paginatedSnapshotWithDirectGapChecks';
        await _individual();
      }
    } else {
      report['collectionMode'] = 'individual';
      await _individual();
    }
    report['complete'] = records.every(
      (row) => {'success', 'noData'}.contains(row['outcome']),
    );
    report['allCatalogRowsChecked'] = records.every(
      (row) => row['outcome'] != 'notChecked',
    );
    if (report['complete'] != true && report['stopReason'] == null) {
      report['stopReason'] = 'providerFailuresRemainAfterBoundedRetries';
    }
    await persist();
    _log('Collection finished');
  }

  Future<void> _resolveCompleteSnapshot({bool preserveDirect = false}) async {
    final byScience = <String, List<Map<String, String>>>{};
    for (final row in matchingRows) {
      final canonical = _science(
        row['SpcScitfNmShort']?.trim().isNotEmpty == true
            ? row['SpcScitfNmShort']!
            : row['SpcScitfNm'] ?? '',
      );
      byScience.putIfAbsent(canonical, () => []).add(row);
    }
    final local = Dio()..httpClientAdapter = _SnapshotAdapter(byScience);
    final validator = MbrisFishDetailProvider(
      dio: local,
      serviceKey: 'offline-public-snapshot',
      maxPages: 5,
    );
    final checkedAt = _now();
    try {
      for (var index = 0; index < fish.length; index++) {
        final base = fish[index];
        if (preserveDirect &&
            records[index]['origin'] == 'individualProviderExactMatch' &&
            {'success', 'noData'}.contains(records[index]['outcome'])) {
          continue;
        }
        final verifiedAt = preserveDirect
            ? '${records[index]['fetchedAt'] ?? records[index]['checkedAt'] ?? checkedAt}'
            : checkedAt;
        try {
          final detail = await validator.fetchDetail(base);
          records[index] = _success(
            base,
            detail,
            byScience[_science(base.scientificName)] ?? [],
            'completeProviderSnapshotExactMatch',
            verifiedAt,
          );
        } on FishCatalogException catch (error) {
          final candidates = byScience[_science(base.scientificName)] ?? [];
          final acceptedNames = [
            base.name,
            ...base.aliases.take(64),
          ].map(_name).toSet();
          final hasExactIdentity = candidates.any(
            (row) => acceptedNames.contains(_name(row['CommKorNm'] ?? '')),
          );
          final needsDirectCheck =
              !hasExactIdentity &&
              (report['bulkPageFailures'] as List? ?? []).isNotEmpty;
          records[index] = _empty(
            base,
            needsDirectCheck
                ? 'notChecked'
                : error.reason == FishCatalogFailure.noData
                ? 'noData'
                : 'failure',
            reason: needsDirectCheck
                ? 'sourceSnapshotGapRequiresDirectLookup'
                : error.reason.name,
            checkedAt: needsDirectCheck ? null : verifiedAt,
            origin: 'completeProviderSnapshotExactMatch',
          );
        }
        if ((index + 1) % 100 == 0) await persist();
      }
    } finally {
      local.close(force: true);
    }
  }

  Future<_Page> _bulkPage(int page) async {
    try {
      final response = await _retryPage(page, _requestedRows);
      if ((total != null && response.total != total) ||
          (pageSize != null && response.pageSize != pageSize) ||
          response.page != page ||
          response.rows.length !=
              (response.total - (page - 1) * response.pageSize).clamp(
                0,
                response.pageSize,
              )) {
        stdout.writeln(
          jsonEncode({
            'diagnostic': 'bulkPagination',
            'page': page,
            'returnedPage': response.page,
            'pageSize': response.pageSize,
            'rows': response.rows.length,
            'bodyTotal': response.total,
            'expectedTotal': total,
            'rowsAlreadyScanned': scanned,
          }),
        );
        _fail(FishCatalogFailure.invalidResponse);
      }
      return response;
    } on FishCatalogException catch (error) {
      if (error.reason != FishCatalogFailure.invalidResponse) rethrow;
      // Same documented offset, smaller payload: page28 of500 is pages
      // 136..140 of100. Never skip the failed range or declare it empty.
      final combined = <Map<String, String>>[];
      int? expected;
      var bytes = 0;
      final parts = <Map<String, int>>[];
      for (var part = 0; part < 5; part++) {
        final subPage = (page - 1) * 5 + part + 1;
        final response = await _retryPage(subPage, 100);
        expected ??= response.total;
        if (response.total != expected ||
            response.page != subPage ||
            response.pageSize != 100) {
          _fail(FishCatalogFailure.invalidResponse);
        }
        combined.addAll(response.rows);
        bytes += response.bytes;
        parts.add({
          'page': subPage,
          'expectedRows': (response.total - (subPage - 1) * 100).clamp(0, 100),
          'receivedRows': response.rows.length,
        });
      }
      (report.putIfAbsent('splitBulkPages', () => <Object?>[]) as List).add({
        'originalPage': page,
        'originalSize': 500,
        'splitSize': 100,
        'splitPages': [
          for (var part = 0; part < 5; part++) (page - 1) * 5 + part + 1,
        ],
        'rows': combined.length,
        'complete':
            combined.length == (expected! - (page - 1) * 500).clamp(0, 500),
        'parts': parts,
      });
      final expectedRows = (expected - (page - 1) * 500).clamp(0, 500);
      if (combined.length < expectedRows) {
        final failures =
            report.putIfAbsent('bulkPageFailures', () => <Object?>[]) as List;
        if (!failures.any((value) => value is Map && value['page'] == page)) {
          failures.add({
            'page': page,
            'pageSize': 500,
            'expectedRows': expectedRows,
            'receivedRows': combined.length,
            'retryMode': 'five100RowPages',
            'parts': parts,
            'effect':
                'Missing catalog identities require direct queries; no absence inferred from this gap.',
          });
        }
        stdout.writeln(
          jsonEncode({
            'diagnostic': 'providerRowGapRetained',
            'page': page,
            'expectedRows': expectedRows,
            'receivedRows': combined.length,
          }),
        );
      }
      return _Page(page, 500, expected, combined, bytes);
    }
  }

  Future<void> _individual() async {
    var consecutiveTransient = 0;
    for (var index = 0; index < fish.length; index++) {
      if ({'success', 'noData'}.contains(records[index]['outcome'])) continue;
      final base = fish[index];
      final rows = <Map<String, String>>[];
      try {
        int? expected;
        var received = 0;
        for (var number = 1; number <= 5; number++) {
          final page = await _retryPage(
            number,
            20,
            scientific: base.scientificName,
          );
          expected ??= page.total;
          if (page.total != expected ||
              page.page != number ||
              page.rows.length !=
                  (expected - received).clamp(0, page.pageSize)) {
            throw const FishCatalogException(
              FishCatalogFailure.invalidResponse,
            );
          }
          rows.addAll(page.rows);
          received += page.rows.length;
          if (received == expected) break;
          if (number == 5) {
            throw const FishCatalogException(
              FishCatalogFailure.invalidResponse,
            );
          }
        }
        final local = Dio()
          ..httpClientAdapter = _SnapshotAdapter({
            _science(base.scientificName): rows,
          });
        try {
          final detail = await MbrisFishDetailProvider(
            dio: local,
            serviceKey: 'offline-public-snapshot',
            maxPages: 5,
          ).fetchDetail(base);
          records[index] = _success(
            base,
            detail,
            rows,
            'individualProviderExactMatch',
            _now(),
          );
        } finally {
          local.close(force: true);
        }
        consecutiveTransient = 0;
      } on FishCatalogException catch (error) {
        records[index] = _empty(
          base,
          error.reason == FishCatalogFailure.noData ? 'noData' : 'failure',
          reason: error.reason.name,
          checkedAt: _now(),
          origin: 'individualProviderExactMatch',
        );
        consecutiveTransient = _transient.contains(error.reason)
            ? consecutiveTransient + 1
            : 0;
        if ({
          FishCatalogFailure.unauthorized,
          FishCatalogFailure.configuration,
        }.contains(error.reason)) {
          report['stopReason'] = error.reason.name;
        } else if (consecutiveTransient >= 3) {
          // Three species have each exhausted three spaced/backed-off attempts.
          // This is a reproducible external outage/quota blocker, not noData.
          report['stopReason'] = 'threeSpeciesExhaustedTransientRetries';
        }
      }
      await persist();
      if (progressClock.elapsed > const Duration(seconds: 25)) {
        _log('Individual progress');
      }
      if (report['stopReason'] != null) break;
    }
  }

  Future<_Page> _retryPage(int page, int count, {String? scientific}) async {
    for (var attempt = 0; ; attempt++) {
      try {
        final finished = lastRequestFinished;
        if (finished != null) {
          final remaining = _spacing - DateTime.now().difference(finished);
          if (remaining > Duration.zero) await Future<void>.delayed(remaining);
        }
        requests++;
        return await _request(client, key, page, count, scientific: scientific);
      } on FishCatalogException catch (error) {
        if (!_transient.contains(error.reason) || attempt >= 2) rethrow;
        retries++;
        final delay = error.reason == FishCatalogFailure.rateLimited
            ? Duration(seconds: attempt == 0 ? 30 : 60)
            : Duration(seconds: attempt == 0 ? 3 : 12);
        report['lastRetryFailure'] = error.reason.name;
        await persist();
        _log('Retry backoff ${delay.inSeconds}s');
        await Future<void>.delayed(delay);
      } finally {
        lastRequestFinished = DateTime.now();
      }
    }
  }

  Future<void> persist() async {
    report['updatedAt'] = _now();
    report['networkRequests'] = requests;
    report['retryRequests'] = retries;
    report['records'] = records;
    report['summary'] = _summary(records);
    report['bulk'] = {
      'nextPage': nextPage,
      'rowsScanned': scanned,
      'totalCount': total,
      'pageSize': pageSize,
      'complete': bulkComplete,
      'matchingRows': matchingRows,
      'pageHashes': pageHashes.toList(),
      'nonemptyFieldCounts': fieldCounts,
      'matchedNonemptyFieldCounts': matchedFieldCounts,
      'possibleImageOrExplicitLengthFieldNames': fieldCounts.keys
          .where(
            (field) => RegExp(
              r'photo|image|img|length|size|len(?:gth)?|file|url',
              caseSensitive: false,
            ).hasMatch(field),
          )
          .toList(),
    };
    await output.parent.create(recursive: true);
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

  void _log(String phase) {
    stdout.writeln(
      jsonEncode({
        'phase': phase,
        'pages': nextPage - 1,
        'providerRowsScanned': scanned,
        'providerTotal': total,
        'matchingProviderRows': matchingRows.length,
        'networkRequests': requests,
        'summary': _summary(records),
      }),
    );
    progressClock.reset();
  }
}

Future<_Page> _request(
  Dio client,
  String key,
  int page,
  int count, {
  String? scientific,
}) async {
  final cancel = CancelToken();
  var stage = 'http';
  try {
    return await (() async {
      final response = await client.get<ResponseBody>(
        _endpoint,
        queryParameters: {
          'serviceKey': key,
          'pageNo': page,
          'numOfRows': count,
          'SpcScitfNm': ?scientific,
        },
        cancelToken: cancel,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: false,
          maxRedirects: 0,
          sendTimeout: _timeout,
          receiveTimeout: _timeout,
          validateStatus: (_) => true,
          headers: {
            'User-Agent':
                'FishingBuild/1.0 (+https://fishingbuild.firebaseapp.com)',
          },
        ),
      );
      final status = response.statusCode ?? 0;
      stage = 'responseBody';
      if (status == 401 || status == 403) {
        _fail(FishCatalogFailure.unauthorized);
      }
      if (status == 429) _fail(FishCatalogFailure.rateLimited);
      if (status < 200 || status >= 300) _fail(FishCatalogFailure.network);
      final body = response.data;
      if (body == null) _fail(FishCatalogFailure.invalidResponse);
      final expectedBytes = int.tryParse(
        response.headers.value('content-length') ?? '',
      );
      if (expectedBytes != null && expectedBytes > _maxBytes) {
        _fail(FishCatalogFailure.invalidResponse);
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in body.stream) {
        if (bytes.length + chunk.length > _maxBytes) {
          _fail(FishCatalogFailure.invalidResponse);
        }
        bytes.add(chunk);
      }
      final text = utf8.decode(bytes.takeBytes());
      stage = 'xmlParsing';
      if (RegExp(
        r'<!\s*(DOCTYPE|ENTITY)',
        caseSensitive: false,
      ).hasMatch(text)) {
        _fail(FishCatalogFailure.invalidResponse);
      }
      final root = XmlDocument.parse(text).rootElement;
      stage = 'envelope';
      if (root.name.local == 'OpenAPI_ServiceResponse') {
        _code(root.findAllElements('returnReasonCode').single.innerText);
        _fail(FishCatalogFailure.invalidResponse);
      }
      if (root.name.local != 'response') {
        _fail(FishCatalogFailure.invalidResponse);
      }
      _code(_scalar(_single(root, 'header'), 'ResultCode'));
      final data = _single(root, 'body');
      final rows = <Map<String, String>>[];
      for (final item in _single(data, 'items').findElements('item')) {
        stage = 'rowScalars';
        final values = <String, String>{};
        for (final field in item.childElements) {
          if (values.containsKey(field.name.local) ||
              field.childElements.isNotEmpty ||
              field.innerText.length > 256 * 1024) {
            _fail(FishCatalogFailure.invalidResponse);
          }
          values[field.name.local] = field.innerText;
        }
        rows.add(values);
      }
      final returnedSize = _integer(data, 'numOfRows');
      stage = 'pagination';
      if (returnedSize < 1 ||
          returnedSize > count ||
          rows.length > returnedSize) {
        _fail(FishCatalogFailure.invalidResponse);
      }
      return _Page(
        _integer(data, 'pageNo'),
        returnedSize,
        _integer(data, 'totalCount'),
        rows,
        utf8.encode(text).length,
      );
    })().timeout(
      _timeout,
      onTimeout: () {
        cancel.cancel();
        _fail(FishCatalogFailure.timedOut);
      },
    );
  } on FishCatalogException catch (error) {
    if (error.reason == FishCatalogFailure.invalidResponse) {
      stdout.writeln(
        jsonEncode({'diagnostic': stage, 'page': page, 'pageSize': count}),
      );
    }
    rethrow;
  } on DioException catch (error) {
    _fail(
      {
            DioExceptionType.connectionTimeout,
            DioExceptionType.sendTimeout,
            DioExceptionType.receiveTimeout,
          }.contains(error.type)
          ? FishCatalogFailure.timedOut
          : FishCatalogFailure.network,
    );
  } on TimeoutException {
    _fail(FishCatalogFailure.timedOut);
  } on Object {
    stdout.writeln(
      jsonEncode({'diagnostic': stage, 'page': page, 'pageSize': count}),
    );
    _fail(FishCatalogFailure.invalidResponse);
  } finally {
    cancel.cancel();
  }
}

class _Page {
  const _Page(this.page, this.pageSize, this.total, this.rows, this.bytes);
  final int page, pageSize, total, bytes;
  final List<Map<String, String>> rows;
}

class _SnapshotAdapter implements HttpClientAdapter {
  _SnapshotAdapter(this.byScience);
  final Map<String, List<Map<String, String>>> byScience;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final rows =
        byScience[_science('${options.queryParameters['SpcScitfNm']}')] ?? [];
    final count = options.queryParameters['numOfRows'] as int;
    final page = options.queryParameters['pageNo'] as int;
    final start = ((page - 1) * count).clamp(0, rows.length);
    final end = (start + count).clamp(0, rows.length);
    final xml = XmlBuilder();
    xml.element(
      'response',
      nest: () {
        xml.element(
          'header',
          nest: () => xml.element('ResultCode', nest: '00'),
        );
        xml.element(
          'body',
          nest: () {
            xml.element(
              'items',
              nest: () {
                for (final row in rows.sublist(start, end)) {
                  xml.element(
                    'item',
                    nest: () {
                      for (final entry in row.entries) {
                        xml.element(entry.key, nest: entry.value);
                      }
                    },
                  );
                }
              },
            );
            xml.element('numOfRows', nest: '$count');
            xml.element('pageNo', nest: '$page');
            xml.element('totalCount', nest: '${rows.length}');
          },
        );
      },
    );
    return ResponseBody.fromString(
      xml.buildDocument().toXmlString(),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/xml; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _success(
  FishSpecies base,
  FishSpecies detail,
  List<Map<String, String>> rows,
  String origin,
  String checkedAt, {
  String? cacheFile,
}) {
  final matched = rows.where((row) {
    final scientific = _science(
      row['SpcScitfNmShort']?.trim().isNotEmpty == true
          ? row['SpcScitfNmShort']!
          : row['SpcScitfNm'] ?? '',
    );
    return scientific == _science(base.scientificName) &&
        [
          base.name,
          ...base.aliases.take(64),
        ].map(_name).contains(_name(row['CommKorNm'] ?? ''));
  }).toList();
  final habiValues = matched
      .map((row) => _plain(row['HABI'] ?? ''))
      .where((value) => value.isNotEmpty)
      .toSet();
  final habi = habiValues.length == 1 ? habiValues.single : '';
  final feature = _boundedProse(detail.feature, 12000);
  final json = {
    ...base.toJson(),
    'feature': feature,
    'maxSize': extractFishSizeSummary(feature),
    'habitat': habi.isNotEmpty && habi.length <= 4000 ? habi : detail.habitat,
    'descriptionSourceUrl': _source,
    'descriptionAttribution': _credit,
    'sourceName': {...base.sourceName.split(' · '), _credit}.join(' · '),
  };
  return {
    ..._empty(base, 'success', checkedAt: checkedAt, origin: origin),
    'fetchedAt': checkedAt,
    'cacheFile': cacheFile,
    'description': feature.isNotEmpty,
    'size': '${json['maxSize']}'.isNotEmpty,
    'photo': false,
    'descriptionSourceUrl': _source,
    'descriptionAttribution': _credit,
    'descriptionProvenance': {
      'provider': _credit,
      'sourceUrl': _source,
      'attribution': _credit,
      'fetchedAt': checkedAt,
      'license': _license,
    },
    if (habi.isNotEmpty && habi.length <= 4000)
      'habitatProvenance': {
        'field': 'HABI',
        'sourceUrl': _source,
        'attribution': _credit,
        'fetchedAt': checkedAt,
        'license': _license,
      },
    'providerRows': matched,
    'result': json,
  };
}

Map<String, dynamic> _empty(
  FishSpecies fish,
  String outcome, {
  String? reason,
  String? checkedAt,
  String? origin,
}) => {
  'id': fish.id,
  'name': fish.name,
  'scientificName': fish.scientificName,
  'outcome': outcome,
  'reason': reason,
  'checkedAt': checkedAt,
  'origin': origin,
  'description': outcome == 'noData' ? false : null,
  'size': outcome == 'noData' ? false : null,
  'photo': false,
};

FishSpecies _catalogBase(FishSpecies fish) => FishSpecies(
  id: fish.id,
  name: fish.name,
  scientificName: fish.scientificName,
  category: fish.category,
  family: fish.family,
  habitat: fish.habitat,
  aliases: fish.aliases,
  sourceName: '국립수산과학원',
  sourceUrl: 'https://www.nifs.go.kr/openApi/actionOpenapiInfoList.do',
);

Map<String, int> _summary(List<Map<String, dynamic>> rows) => {
  'catalog': rows.length,
  'checked': rows.where((row) => row['outcome'] != 'notChecked').length,
  for (final outcome in ['success', 'noData', 'failure', 'notChecked'])
    outcome: rows.where((row) => row['outcome'] == outcome).length,
  'description': rows.where((row) => row['description'] == true).length,
  'size': rows.where((row) => row['size'] == true).length,
  'habitat': rows.where((row) => row['habitatProvenance'] != null).length,
};
void _countFields(Map<String, int> counts, Map<String, String> row) {
  for (final entry in row.entries) {
    counts.putIfAbsent(entry.key, () => 0);
    if (entry.value.trim().isNotEmpty) {
      counts[entry.key] = counts[entry.key]! + 1;
    }
  }
}

bool _sameIdentity(FishSpecies base, Map row) =>
    row['id'] == base.id &&
    row['name'] == base.name &&
    row['scientificName'] == base.scientificName;
String _science(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
String _name(String value) => value.trim().replaceAll(RegExp(r'\s+'), ' ');
String _now() => DateTime.now().toUtc().toIso8601String();
String _key(Object? raw) {
  var value = raw is String ? raw.trim() : '';
  if (value.contains('%')) value = Uri.decodeComponent(value);
  if (value.isEmpty ||
      value.length > 1024 ||
      !RegExp(r'^[A-Za-z0-9+/=_-]+$').hasMatch(value)) {
    _fail(FishCatalogFailure.configuration);
  }
  return value;
}

String _boundedProse(String text, int limit) {
  if (text.length <= limit) return text;
  final prefix = text.substring(0, limit);
  final end = prefix.lastIndexOf(RegExp(r'[.!?。](?!\d)|\n\n'));
  return (end >= limit ~/ 2 ? prefix.substring(0, end + 1) : prefix).trim();
}

String _plain(String value) {
  var text = value;
  for (var pass = 0; pass < 2; pass++) {
    text = text.replaceAllMapped(
      RegExp(r'&(?:amp|lt|gt|quot|apos|nbsp|#\d+|#x[0-9a-fA-F]+);'),
      (match) {
        final entity = match[0]!;
        const named = {
          '&amp;': '&',
          '&lt;': '<',
          '&gt;': '>',
          '&quot;': '"',
          '&apos;': "'",
          '&nbsp;': ' ',
        };
        if (named.containsKey(entity)) return named[entity]!;
        final hex = entity.startsWith('&#x');
        final code = int.tryParse(
          entity.substring(hex ? 3 : 2, entity.length - 1),
          radix: hex ? 16 : 10,
        );
        return code == null ||
                code < 32 ||
                code > 0x10ffff ||
                (code >= 0xd800 && code <= 0xdfff)
            ? ' '
            : String.fromCharCode(code);
      },
    );
  }
  return text
      .replaceAll(
        RegExp(
          r'<(script|style)\b[^>]*>[\s\S]*?</\1\s*>',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

XmlElement _single(XmlElement root, String name) {
  final children = root.findElements(name).toList();
  if (children.length != 1) _fail(FishCatalogFailure.invalidResponse);
  return children.single;
}

String _scalar(XmlElement root, String name) {
  final element = _single(root, name);
  if (element.childElements.isNotEmpty) {
    _fail(FishCatalogFailure.invalidResponse);
  }
  return element.innerText.trim();
}

int _integer(XmlElement root, String name) {
  final value = _scalar(root, name);
  if (!RegExp(r'^\d{1,9}$').hasMatch(value)) {
    _fail(FishCatalogFailure.invalidResponse);
  }
  return int.parse(value);
}

void _code(String raw) {
  switch (raw.trim()) {
    case '00':
      return;
    case '20':
    case '29':
    case '30':
    case '31':
      _fail(FishCatalogFailure.unauthorized);
    case '22':
    case '23':
      _fail(FishCatalogFailure.rateLimited);
    case '05':
      _fail(FishCatalogFailure.timedOut);
    case '01':
    case '04':
      _fail(FishCatalogFailure.network);
    default:
      _fail(FishCatalogFailure.invalidResponse);
  }
}

Never _fail(FishCatalogFailure failure) => throw FishCatalogException(failure);
