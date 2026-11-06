import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:fishing_build/data/fish/bundled_fish_enrichment.dart';
import 'package:fishing_build/data/fish/fish_catalog_service.dart';
import 'package:fishing_build/data/fish/fish_photo_validation.dart';
import 'package:fishing_build/data/models/fish_species.dart';

String _output = '.dart_tool/fish_all_wiki_content.json';
String _mode = 'wikimedia-all800-v2:ko-batch-primary-taxobox,actual-photos';
const _agent = 'FishingBuild/1.0 (+https://fishingbuild.firebaseapp.com)';
// TextExtracts supplies at most twenty named-page extracts per request.
const _batchSize = 20;

/// A checkpointed, keyless whole-catalog pass. Direct Korean article batches
/// avoid Wikidata's global query-service maxlag. Only an exact primary taxobox
/// binomial and matching Korean title/alias authorize article text or photos.
Future<void> main(List<String> arguments) async {
  if (arguments.length == 1 && {'--help', '-h'}.contains(arguments.single)) {
    stdout.writeln(
      'Usage: dart run tool/collect_all_wiki_fish.dart [--english-photos]\n'
      'Collects all 800 species in batches of 20; resumes its public checkpoint.\n'
      'The optional English pass collects photos only. No keys or configuration.',
    );
    return;
  }
  final englishPhotos =
      arguments.length == 1 && arguments.single == '--english-photos';
  if (arguments.isNotEmpty && !englishPhotos) {
    exitCode = 64;
    return;
  }
  if (englishPhotos) {
    _output = '.dart_tool/fish_all_english_photos.json';
    _mode = 'wikimedia-all800-v1:en-primary-taxobox-photos-only';
  }
  final http = _PublicWikiClient();
  try {
    final bytes = await File('assets/data/fish_catalog.json').readAsBytes();
    final catalog = _map(jsonDecode(utf8.decode(bytes)));
    final raw = catalog['species'];
    if (raw is! List || raw.length != 800 || catalog['recordCount'] != 800) {
      throw const FormatException('Invalid complete public catalog.');
    }
    final fish = [for (final row in raw) FishSpecies.fromJson(_map(row))];
    final hash = sha256.convert(bytes).toString();
    final previous = await _previous(_output);
    final compatible =
        previous?['catalogSha256'] == hash &&
        previous?['sourceEnabledMode'] == _mode;
    final records = compatible
        ? [for (final row in previous!['records'] as List) _map(row)]
        : await _seed(fish, hash, photoOnly: englishPhotos);
    if (records.length != 800) throw const FormatException();
    final done = compatible && previous?['completedBatches'] is List
        ? (previous!['completedBatches'] as List).whereType<int>().toSet()
        : <int>{};
    final started = compatible
        ? previous!['startedAt']
        : DateTime.now().toUtc().toIso8601String();
    Future<void> checkpoint() async {
      final report = {
        'version': 1,
        'catalogSha256': hash,
        'sourceEnabledMode': _mode,
        'catalogRecordCount': 800,
        'offset': 0,
        'limit': 800,
        'startedAt': started,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
        'stopReason': null,
        'attemptedThisRun': done.length * _batchSize,
        'completedBatches': done.toList()..sort(),
        'records': records,
        'summary': _summary(records),
      };
      final temporary = File('$_output.tmp');
      await temporary.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report),
        flush: true,
      );
      await temporary.rename(_output);
      stdout.writeln(jsonEncode(report['summary']));
    }

    await checkpoint();
    for (var start = 0; start < fish.length; start += _batchSize) {
      if (done.contains(start ~/ _batchSize)) continue;
      final batch = fish.sublist(start, start + _batchSize);
      final checked = DateTime.now().toUtc().toIso8601String();
      final verifiedPages = <String, Map<String, dynamic>>{};
      try {
        final response = await http.get(
          englishPhotos
              ? 'https://en.wikipedia.org/w/api.php'
              : 'https://ko.wikipedia.org/w/api.php',
          {
            'action': 'query',
            'titles': batch
                .map((f) => englishPhotos ? f.scientificName : f.name)
                .join('|'),
            'redirects': 1,
            'prop': englishPhotos
                ? 'pageprops|revisions|langlinks'
                : 'extracts|pageprops|revisions',
            if (englishPhotos) ...{'lllang': 'ko', 'lllimit': 500},
            'exintro': 1,
            'explaintext': 1,
            'exchars': 1000,
            'exlimit': 20,
            'rvprop': 'ids|content',
            'rvslots': 'main',
            'meta': 'siteinfo',
            'siprop': 'rightsinfo',
          },
        );
        final query = _map(response['query']);
        final rights = _map(query['rightsinfo']);
        if (!'${rights['url']}'.startsWith(
          'https://creativecommons.org/licenses/by-sa/4.0/',
        )) {
          throw const FishCatalogException(FishCatalogFailure.invalidResponse);
        }
        final pages = (query['pages'] as List)
            .whereType<Map>()
            .map(_map)
            .toList();
        final redirects = <String, String>{};
        for (final key in ['normalized', 'redirects']) {
          for (final row
              in query[key] is List ? query[key] as List : const []) {
            final link = _map(row);
            if (link['from'] is String && link['to'] is String) {
              redirects[link['from'] as String] = link['to'] as String;
            }
          }
        }
        for (var offset = 0; offset < batch.length; offset++) {
          final base = batch[offset];
          final names = [base.name, ...base.aliases].map(_common).toSet();
          var requestedTitle = base.scientificName;
          for (
            var hop = 0;
            hop < 6 && redirects.containsKey(requestedTitle);
            hop++
          ) {
            requestedTitle = redirects[requestedTitle]!;
          }
          final matches = pages
              .where(
                (page) =>
                    !page.containsKey('missing') &&
                    !_mapOrEmpty(
                      page['pageprops'],
                    ).containsKey('disambiguation') &&
                    (englishPhotos
                        ? '${page['title']}' == requestedTitle
                        : names.contains(_common('${page['title']}'))) &&
                    (!englishPhotos || _koreanLinkAgrees(page, names)),
              )
              .toList();
          FishSpecies? candidate;
          if (matches.length == 1) {
            final page = matches.single;
            final revisions = page['revisions'];
            final revision = revisions is List && revisions.length == 1
                ? _map(revisions.single)
                : <String, dynamic>{};
            final content = _mapOrEmpty(
              _mapOrEmpty(revision['slots'])['main'],
            )['content'];
            final scientific = content is String ? _taxoboxName(content) : null;
            if (scientific != null &&
                _scientific(scientific) == _scientific(base.scientificName) &&
                revision['revid'] is int &&
                (revision['revid'] as int) > 0) {
              final text = _plain('${page['extract'] ?? ''}');
              if (!englishPhotos && text.isNotEmpty && text.length <= 12000) {
                candidate = FishSpecies.fromJson({
                  ...base.toJson(),
                  'feature': text,
                  'descriptionSourceUrl': Uri.https(
                    'ko.wikipedia.org',
                    '/w/index.php',
                    {
                      'title': '${page['title']}',
                      'oldid': '${revision['revid']}',
                    },
                  ).toString(),
                  'descriptionAttribution':
                      '한국어 위키백과 기여자 · CC BY-SA 4.0 · '
                      'https://creativecommons.org/licenses/by-sa/4.0/',
                  'sourceName': '${base.sourceName} · 한국어 위키백과',
                });
              }
              verifiedPages[base.id] = page;
            }
          }
          records[start + offset] = _record(
            base,
            candidate,
            records[start + offset],
            checked,
            photoOnly: englishPhotos,
          );
        }
        final files = <String, String>{};
        for (final entry in verifiedPages.entries) {
          final file = _mapOrEmpty(entry.value['pageprops'])['page_image_free'];
          if (file is String &&
              file.length <= 240 &&
              !RegExp(r'[|#<>\x00-\x1f]').hasMatch(file) &&
              !isNonPhotographicFishImage([file])) {
            files[entry.key] = file;
          }
        }
        if (files.isNotEmpty) {
          try {
            final photos = await http.get(
              'https://commons.wikimedia.org/w/api.php',
              {
                'action': 'query',
                'titles': files.values
                    .toSet()
                    .map((file) => 'File:$file')
                    .join('|'),
                'prop': 'imageinfo',
                'iiprop': 'url|mime|extmetadata',
                'iiurlwidth': 960,
                'iiextmetadatafilter':
                    'Artist|LicenseShortName|LicenseUrl|Copyrighted|ImageDescription|Categories',
              },
            );
            final byFile = <String, Map<String, dynamic>>{};
            for (final rawPage in _map(photos['query'])['pages'] as List) {
              final page = _map(rawPage);
              if (!page.containsKey('missing') && page['ns'] == 6) {
                byFile[_fileKey('${page['title']}')] = page;
              }
            }
            for (var offset = 0; offset < batch.length; offset++) {
              final base = batch[offset];
              final file = files[base.id];
              final page = file == null ? null : byFile[_fileKey('File:$file')];
              final photo = page == null ? null : _photo(base, page);
              if (photo != null) {
                records[start + offset] = _record(
                  base,
                  photo,
                  records[start + offset],
                  checked,
                  photoOnly: englishPhotos,
                );
              }
            }
          } on Object catch (error) {
            // A failed photo batch is unknown, never evidence of no photo.
            final reason = error is FishCatalogException
                ? error.reason.name
                : 'invalidResponse';
            for (var offset = 0; offset < batch.length; offset++) {
              if (!files.containsKey(batch[offset].id)) continue;
              final row = records[start + offset];
              if (row['result'] is Map) {
                final result = _map(row['result']);
                if (result['imageUrl'] == null) {
                  row['result'] = {...result, 'detailNeedsRetry': true};
                  row['photoFailure'] = reason;
                }
              } else {
                row.addAll({
                  'outcome': 'failure',
                  'reason': reason,
                  'description': null,
                  'photo': null,
                  'size': null,
                });
              }
            }
          }
        }
      } on Object catch (error) {
        final reason = error is FishCatalogException
            ? error.reason.name
            : 'invalidResponse';
        for (var offset = 0; offset < batch.length; offset++) {
          final record = records[start + offset];
          if (record['result'] is Map) continue;
          records[start + offset] = {
            'id': batch[offset].id,
            'name': batch[offset].name,
            'scientificName': batch[offset].scientificName,
            'checkedAt': checked,
            'outcome': 'failure',
            'reason': reason,
            'description': null,
            'photo': null,
            'size': null,
          };
        }
      }
      done.add(start ~/ _batchSize);
      await checkpoint();
    }
    stdout.writeln('Whole catalog pass complete: all 800 identities checked.');
  } on Object {
    stderr.writeln(
      'The complete Wiki pass stopped; its saved public checkpoint is preserved.',
    );
    exitCode = 1;
  } finally {
    http.close();
  }
}

Future<List<Map<String, dynamic>>> _seed(
  List<FishSpecies> fish,
  String hash, {
  bool photoOnly = false,
}) async {
  final prior = await _previous(
    photoOnly
        ? '.dart_tool/fish_all_wiki_content.json'
        : '.dart_tool/fish_detail_audit.json',
  );
  final saved = <String, Map<String, dynamic>>{};
  if (prior?['catalogSha256'] == hash && prior?['records'] is List) {
    for (final raw in prior!['records'] as List) {
      final row = _map(raw);
      if (row['outcome'] == 'success' && row['id'] is String) {
        saved[row['id'] as String] = row;
      }
    }
  }
  return [
    for (final base in fish)
      _record(
        base,
        null,
        saved[base.id] ?? {},
        null,
        unchecked: true,
        photoOnly: photoOnly,
      ),
  ];
}

Map<String, dynamic> _record(
  FishSpecies base,
  FishSpecies? incoming,
  Map<String, dynamic> previous,
  String? checked, {
  bool unchecked = false,
  bool photoOnly = false,
}) {
  FishSpecies current = base;
  final savedAt = previous['checkedAt'];
  if (previous['result'] is Map && savedAt is String) {
    try {
      current = BundledFishEnrichment.fromJson({
        'version': 1,
        'recordCount': 1,
        'dataUpdatedAt': savedAt,
        'records': [
          {'checkedAt': savedAt, 'result': previous['result']},
        ],
      }).apply(base);
    } on Object {
      /* Invalid historical fields are not reused. */
    }
  }
  if (incoming != null && checked != null) {
    try {
      current = BundledFishEnrichment.fromJson({
        'version': 1,
        'recordCount': 1,
        'dataUpdatedAt': checked,
        'records': [
          {'checkedAt': checked, 'result': incoming.toJson()},
        ],
      }).apply(current);
    } on Object {
      /* An unsafe optional field never replaces verified data. */
    }
  }
  if (photoOnly) {
    current = FishSpecies.fromJson({
      ...current.toJson(),
      'feature': '',
      'maxSize': '',
      'descriptionSourceUrl': null,
      'descriptionAttribution': null,
    });
  }
  final has = current.feature.isNotEmpty || current.imageUrl != null;
  final at = has && savedAt is String ? savedAt : checked;
  return {
    'id': base.id,
    'name': base.name,
    'scientificName': base.scientificName,
    'checkedAt': at,
    'outcome': has
        ? 'success'
        : unchecked
        ? 'notChecked'
        : 'noData',
    'reason': has || unchecked ? null : 'noData',
    'description': has
        ? current.feature.isNotEmpty
        : unchecked
        ? null
        : false,
    'photo': has
        ? current.imageUrl != null
        : unchecked
        ? null
        : false,
    'size': has
        ? current.maxSize.isNotEmpty
        : unchecked
        ? null
        : false,
    if (has) 'result': current.toJson(),
  };
}

String? _taxoboxName(String source) {
  final start = RegExp(
    r'\{\{\s*(?:생물\s*분류|taxobox|speciesbox)\s*[|\n]',
    caseSensitive: false,
  ).firstMatch(source);
  if (start == null || start.start > 12000) return null;
  var depth = 0;
  var end = -1;
  for (
    var index = start.start;
    index < source.length - 1 && index - start.start < 20000;
    index++
  ) {
    final pair = source.substring(index, index + 2);
    if (pair == '{{') {
      depth++;
      index++;
    } else if (pair == '}}') {
      depth--;
      index++;
      if (depth == 0) {
        end = index + 1;
        break;
      }
    }
  }
  if (end < 0) return null;
  final box = source.substring(start.start, end);
  final names =
      RegExp(
            r'\|\s*(?:학명|binomial|taxon)\s*=\s*([^\n|}]+)',
            caseSensitive: false,
          )
          .allMatches(box)
          .map(
            (match) => _plain(match.group(1)!)
                .replaceAll("'", '')
                .replaceAll('[[', '')
                .replaceAll(']]', '')
                .trim(),
          )
          .toSet();
  if (names.length != 1 ||
      !RegExp(r'^[A-Z][a-z]+ [a-z][a-z-]+$').hasMatch(names.single)) {
    return null;
  }
  return names.single;
}

FishSpecies? _photo(FishSpecies base, Map<String, dynamic> page) {
  final infos = page['imageinfo'];
  if (infos is! List) return null;
  for (final raw in infos) {
    final info = _map(raw);
    if (!{
      'image/jpeg',
      'image/png',
      'image/gif',
      'image/webp',
    }.contains(info['mime'])) {
      continue;
    }
    final metadata = _mapOrEmpty(info['extmetadata']);
    String field(String name) =>
        _plain('${_mapOrEmpty(metadata[name])['value'] ?? ''}');
    if (field('Artist').isEmpty) continue;
    if (isNonPhotographicFishImage([
      '${page['title']}',
      field('ImageDescription'),
      field('Categories'),
    ])) {
      continue;
    }
    var license = field('LicenseUrl');
    if (license.isEmpty &&
        field('LicenseShortName').toLowerCase() == 'public domain' &&
        field('Copyrighted') == 'False') {
      license = 'https://creativecommons.org/publicdomain/mark/1.0/';
    }
    final candidate = FishSpecies.fromJson({
      ...base.toJson(),
      'imageUrl': info['thumburl'] ?? info['url'],
      'photoSourceUrl': info['descriptionurl'],
      'photoAttribution': '${field('Artist')} · ${field('LicenseShortName')}',
      'photoLicenseUrl': license,
    });
    return candidate;
  }
  return null;
}

class _PublicWikiClient {
  final Dio dio = Dio();
  DateTime? _last;
  Future<Map<String, dynamic>> get(
    String url,
    Map<String, Object> params,
  ) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      Duration? serverPause;
      final last = _last;
      if (last != null) {
        final pause =
            const Duration(seconds: 1) - DateTime.now().difference(last);
        if (pause > Duration.zero) await Future<void>.delayed(pause);
      }
      _last = DateTime.now();
      final token = CancelToken();
      try {
        Future<Map<String, dynamic>> read() async {
          final response = await dio.get<ResponseBody>(
            url,
            queryParameters: {
              'format': 'json',
              'formatversion': 2,
              'origin': '*',
              ...params,
            },
            cancelToken: token,
            options: Options(
              responseType: ResponseType.stream,
              followRedirects: false,
              validateStatus: (_) => true,
              receiveTimeout: const Duration(seconds: 20),
              headers: {'User-Agent': _agent, 'Api-User-Agent': _agent},
            ),
          );
          final retry = response.headers.value('retry-after');
          if (retry != null) {
            final seconds = int.tryParse(retry);
            if (seconds != null && seconds > 0) {
              serverPause = Duration(seconds: seconds);
            } else {
              try {
                final wait = HttpDate.parse(retry).difference(DateTime.now());
                if (wait > Duration.zero) serverPause = wait;
              } on Object {
                /* An invalid optional header is ignored. */
              }
            }
          }
          if (response.statusCode == 429) {
            throw const FishCatalogException(FishCatalogFailure.rateLimited);
          }
          if (response.statusCode != 200 || response.data == null) {
            throw const FishCatalogException(FishCatalogFailure.network);
          }
          final bytes = BytesBuilder(copy: false);
          await for (final chunk in response.data!.stream) {
            if (bytes.length + chunk.length > 4 * 1024 * 1024) {
              throw const FormatException();
            }
            bytes.add(chunk);
          }
          final data = _map(jsonDecode(utf8.decode(bytes.takeBytes())));
          if (data['error'] is Map) {
            final code = (data['error'] as Map)['code'];
            throw FishCatalogException(
              code == 'maxlag' || code == 'ratelimited'
                  ? FishCatalogFailure.rateLimited
                  : FishCatalogFailure.invalidResponse,
            );
          }
          return data;
        }

        return await read().timeout(const Duration(seconds: 25));
      } on Object catch (error) {
        if (attempt == 1) rethrow;
        final limited =
            error is FishCatalogException &&
            error.reason == FishCatalogFailure.rateLimited;
        final minimum = Duration(seconds: limited ? 30 : 3);
        await Future<void>.delayed(
          serverPause != null && serverPause! > minimum
              ? serverPause!
              : minimum,
        );
      } finally {
        token.cancel();
      }
    }
    throw const FishCatalogException(FishCatalogFailure.network);
  }

  void close() => dio.close(force: true);
}

Map<String, int> _summary(List<Map<String, dynamic>> rows) => {
  'checked': rows.where((r) => r['outcome'] != 'notChecked').length,
  'success': rows.where((r) => r['outcome'] == 'success').length,
  'noData': rows.where((r) => r['outcome'] == 'noData').length,
  'failure': rows.where((r) => r['outcome'] == 'failure').length,
  'notChecked': rows.where((r) => r['outcome'] == 'notChecked').length,
  'description': rows.where((r) => r['description'] == true).length,
  'photo': rows.where((r) => r['photo'] == true).length,
  'size': rows.where((r) => r['size'] == true).length,
};
Future<Map<String, dynamic>?> _previous(String path) async =>
    await File(path).exists()
    ? _map(jsonDecode(await File(path).readAsString()))
    : null;
Map<String, dynamic> _map(Object? value) =>
    Map<String, dynamic>.from(value as Map);
Map<String, dynamic> _mapOrEmpty(Object? value) =>
    value is Map ? _map(value) : {};
String _common(String value) =>
    value.replaceAll(RegExp(r'\s+'), '').toLowerCase();

bool _koreanLinkAgrees(Map<String, dynamic> page, Set<String> names) {
  final links = page['langlinks'];
  if (links is! List) return true;
  for (final raw in links) {
    final link = _map(raw);
    if (link['lang'] != 'ko') continue;
    final title = link['title'] ?? link['*'];
    if (title is! String || !names.contains(_common(title))) return false;
  }
  return true;
}

String _scientific(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
String _fileKey(String value) => value
    .replaceFirst(RegExp(r'^File:', caseSensitive: false), '')
    .replaceAll('_', ' ')
    .trim();
String _plain(String value) => value
    .replaceAll(RegExp(r'<[^>]*>'), '')
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&nbsp;', ' ')
    .replaceAll(RegExp(r'\r\n?'), '\n')
    .trim();
