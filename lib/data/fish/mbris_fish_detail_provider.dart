import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:xml/xml.dart';

import '../models/fish_species.dart';
import 'fish_catalog_service.dart';
import 'fish_size_summary.dart';

/// Optional Korean descriptions from the National Marine Biodiversity Institute.
///
/// Uses the public taxonlist3 XML contract published on [sourceUrl]. The
/// repository owns caching. A supplied credential never appears in failures.
class MbrisFishDetailProvider
    implements FishDetailProvider, FishDetailDeadlineProvider {
  MbrisFishDetailProvider({
    Dio? dio,
    String serviceKey = const String.fromEnvironment('MBRIS_SERVICE_KEY'),
    this.requestTimeout = const Duration(seconds: 12),
    this.maxPages = 3,
  }) : _dio = dio ?? Dio(),
       _serviceKey = _normalizeServiceKey(serviceKey) {
    if (requestTimeout <= Duration.zero ||
        requestTimeout > const Duration(seconds: 12) ||
        maxPages < 1 ||
        maxPages > 5) {
      throw ArgumentError('Invalid MBRIS request limits.');
    }
  }

  static final MbrisFishDetailProvider instance = MbrisFishDetailProvider();

  @override
  MbrisFishDetailProvider withDeadline(Duration timeout) =>
      MbrisFishDetailProvider(
        dio: _dio,
        serviceKey: _serviceKey ?? '',
        requestTimeout: timeout < requestTimeout ? timeout : requestTimeout,
        maxPages: maxPages,
      );
  static const sourceUrl =
      'https://www.data.go.kr/data/15094770/openapi.do?format=html';
  static const _endpoint =
      'https://apis.data.go.kr/B553482/mbrisdataview3/taxonlist3';
  static const _credit = '국립해양생물자원관 MBRIS';
  // The portal's operation examples document a default page size of twenty.
  static const _pageSize = 20;
  static const _maxBytes = 2 * 1024 * 1024;

  final Dio _dio;
  final String? _serviceKey;
  final Duration requestTimeout;
  final int maxPages;

  bool get isConfigured => _serviceKey != null;

  @override
  Future<FishSpecies> fetchDetail(
    FishSpecies species, {
    bool forceRefresh = false,
  }) async {
    final key = _serviceKey;
    if (key == null) _fail(FishCatalogFailure.configuration);
    final scientific = _scientificKey(species.scientificName);
    final names = [
      species.name,
      ...species.aliases.take(64),
    ].map(_nameKey).where((name) => RegExp(r'[가-힣]').hasMatch(name)).toSet();
    if (scientific.isEmpty || scientific.length > 255 || names.isEmpty) {
      _fail(FishCatalogFailure.noData);
    }

    final elapsed = Stopwatch()..start();
    final matches = <Map<String, String>>[];
    int? expectedTotal;
    int? expectedPageSize;
    var conflictingAcceptedName = false;
    var received = 0;
    for (var page = 1; page <= maxPages; page++) {
      final remaining = requestTimeout - elapsed.elapsed;
      if (remaining <= Duration.zero) _fail(FishCatalogFailure.timedOut);
      final document = await _request({
        'serviceKey': key,
        'pageNo': page,
        'numOfRows': _pageSize,
        // Current taxonlist3 Swagger uses these capitalized names. The
        // portal also embeds legacy taxonlist2 metadata with lowercase names.
        'SpcScitfNm': species.scientificName.trim(),
      }, remaining);
      final root = document.rootElement;
      _checkResult(root);
      final body = _single(root, 'body');
      final total = _integer(body, 'totalCount');
      final returnedPage = _integer(body, 'pageNo');
      final pageSize = _integer(body, 'numOfRows');
      if (returnedPage != page ||
          pageSize < 1 ||
          pageSize > _pageSize ||
          (expectedPageSize != null && pageSize != expectedPageSize) ||
          (expectedTotal != null && total != expectedTotal)) {
        _fail(FishCatalogFailure.invalidResponse);
      }
      expectedTotal = total;
      expectedPageSize = pageSize;
      final items = _single(body, 'items');
      final rows = items.findElements('item').toList();
      if (rows.length > pageSize || received + rows.length > total) {
        _fail(FishCatalogFailure.invalidResponse);
      }
      // Every page must account for its advertised position in the result.
      // A truncated/ignored page is a provider failure, never a negative cache.
      final expectedRows = (total - received).clamp(0, pageSize);
      if (rows.length != expectedRows) {
        _fail(FishCatalogFailure.invalidResponse);
      }
      for (final row in rows) {
        final values = <String, String>{};
        for (final field in row.childElements) {
          if (values.containsKey(field.name.local) ||
              field.childElements.isNotEmpty) {
            _fail(FishCatalogFailure.invalidResponse);
          }
          values[field.name.local] = field.innerText;
        }
        final returnedFull = _scientificKey(values['SpcScitfNm'] ?? '');
        final returnedShort = _scientificKey(values['SpcScitfNmShort'] ?? '');
        // The service supplies a separate canonical name, so author-bearing
        // full names never need guessed suffix stripping or fuzzy matching.
        final canonical = returnedShort.isNotEmpty
            ? returnedShort
            : returnedFull;
        if (returnedFull.isEmpty ||
            canonical != scientific ||
            !names.contains(_nameKey(values['CommKorNm'] ?? ''))) {
          continue;
        }
        final accepted = _scientificKey(values['CorrSpcScitfNm'] ?? '');
        if (accepted.isNotEmpty &&
            accepted != canonical &&
            accepted != returnedFull) {
          conflictingAcceptedName = true;
          continue;
        }
        matches.add(values);
      }
      received += rows.length;
      if (received == total) break;
      if (page == maxPages) _fail(FishCatalogFailure.invalidResponse);
    }
    if (matches.isEmpty) _fail(FishCatalogFailure.noData);
    if (conflictingAcceptedName) _fail(FishCatalogFailure.invalidResponse);
    // Identical duplicate rows are harmless; disagreeing descriptions or
    // taxon identifiers cannot be resolved by choosing the first result.
    final fingerprints = matches.map(_fingerprint).toSet();
    if (fingerprints.length != 1) _fail(FishCatalogFailure.invalidResponse);
    final row = matches.first;
    final paragraphs = <String>{};
    for (final field in ['ABST', 'FORM', 'ECOL']) {
      final text = _plainText(row[field] ?? '');
      if (RegExp(r'[가-힣]').hasMatch(text)) paragraphs.add(text);
    }
    final habitat = _plainText(row['HABI'] ?? '');
    if (RegExp(r'[가-힣]').hasMatch(habitat) &&
        !paragraphs.any((text) => text.contains(habitat))) {
      paragraphs.add('서식지: $habitat');
    }
    for (final field in {'NADI': '국내 분포', 'INDI': '해외 분포'}.entries) {
      final text = _plainText(row[field.key] ?? '');
      if (RegExp(r'[가-힣]').hasMatch(text) &&
          !paragraphs.any((paragraph) => paragraph.contains(text))) {
        paragraphs.add('${field.value}: $text');
      }
    }
    if (paragraphs.isEmpty) _fail(FishCatalogFailure.noData);
    final sources = <String>{
      ...species.sourceName.split(' · ').where((name) => name.isNotEmpty),
      _credit,
    };
    return FishSpecies(
      id: species.id,
      name: species.name,
      scientificName: species.scientificName,
      category: species.category,
      family: species.family,
      habitat: species.habitat,
      maxSize: species.maxSize.trim().isNotEmpty
          ? species.maxSize
          : extractFishSizeSummary(paragraphs.join('\n\n')),
      aliases: species.aliases,
      feature: paragraphs.join('\n\n'),
      imageUrl: species.imageUrl,
      photoAttribution: species.photoAttribution,
      photoSourceUrl: species.photoSourceUrl,
      photoLicenseUrl: species.photoLicenseUrl,
      descriptionSourceUrl: sourceUrl,
      descriptionAttribution: _credit,
      sourceName: sources.join(' · '),
      sourceUrl: species.sourceUrl ?? sourceUrl,
    );
  }

  Future<XmlDocument> _request(
    Map<String, Object> parameters,
    Duration timeout,
  ) async {
    final cancel = CancelToken();
    try {
      return await _read(parameters, timeout, cancel).timeout(
        timeout,
        onTimeout: () {
          cancel.cancel();
          _fail(FishCatalogFailure.timedOut);
        },
      );
    } on FishCatalogException {
      cancel.cancel();
      rethrow;
    } on DioException catch (error) {
      cancel.cancel();
      if ({
        DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
      }.contains(error.type)) {
        _fail(FishCatalogFailure.timedOut);
      }
      _fail(FishCatalogFailure.network);
    } on TimeoutException {
      cancel.cancel();
      _fail(FishCatalogFailure.timedOut);
    } on Object {
      cancel.cancel();
      _fail(FishCatalogFailure.invalidResponse);
    }
  }

  Future<XmlDocument> _read(
    Map<String, Object> parameters,
    Duration timeout,
    CancelToken cancel,
  ) async {
    final response = await _dio.get<ResponseBody>(
      _endpoint,
      queryParameters: parameters,
      cancelToken: cancel,
      options: Options(
        responseType: ResponseType.stream,
        followRedirects: false,
        maxRedirects: 0,
        sendTimeout: timeout,
        receiveTimeout: timeout,
        validateStatus: (_) => true,
      ),
    );
    final status = response.statusCode ?? 0;
    if (status == 401 || status == 403) _fail(FishCatalogFailure.unauthorized);
    if (status == 429) _fail(FishCatalogFailure.rateLimited);
    if (status < 200 || status >= 300) _fail(FishCatalogFailure.network);
    final body = response.data;
    if (body == null) _fail(FishCatalogFailure.invalidResponse);
    final length = int.tryParse(
      response.headers.value(Headers.contentLengthHeader) ?? '',
    );
    if (length != null && length > _maxBytes) {
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
    // XML has no need for a DTD here. Reject entities before parsing rather
    // than trusting a provider response to define or load external resources.
    if (RegExp(
      r'<!\s*(?:DOCTYPE|ENTITY)',
      caseSensitive: false,
    ).hasMatch(text)) {
      _fail(FishCatalogFailure.invalidResponse);
    }
    final document = XmlDocument.parse(text);
    final root = document.rootElement;
    if (!{'response', 'OpenAPI_ServiceResponse'}.contains(root.name.local)) {
      _fail(FishCatalogFailure.invalidResponse);
    }
    return document;
  }
}

void _checkResult(XmlElement root) {
  if (root.name.local == 'OpenAPI_ServiceResponse') {
    final header = _single(root, 'cmmMsgHeader');
    _checkCode(_scalar(header, 'returnReasonCode'));
    // A gateway envelope never contains a successful species payload.
    _fail(FishCatalogFailure.invalidResponse);
  }
  final header = _single(root, 'header');
  _checkCode(_scalar(header, 'ResultCode'));
}

void _checkCode(String code) {
  switch (code.trim()) {
    // 00 is the issuer's documented normal-service code. Unknown result
    // codes must be verified against a real response rather than guessed.
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

XmlElement _single(XmlElement parent, String name) {
  final values = parent.findElements(name).toList();
  if (values.length != 1) _fail(FishCatalogFailure.invalidResponse);
  return values.single;
}

String _scalar(XmlElement parent, String name) {
  final element = _single(parent, name);
  if (element.childElements.isNotEmpty) {
    _fail(FishCatalogFailure.invalidResponse);
  }
  return element.innerText.trim();
}

int _integer(XmlElement parent, String name) {
  final value = _scalar(parent, name);
  if (!RegExp(r'^\d{1,9}$').hasMatch(value)) {
    _fail(FishCatalogFailure.invalidResponse);
  }
  return int.parse(value);
}

String? _normalizeServiceKey(String raw) {
  var value = raw.trim();
  // Decode a portal Encoding key once, then let Dio encode the query once.
  // decodeComponent preserves a literal + in a portal Decoding key.
  if (value.contains('%')) {
    try {
      value = Uri.decodeComponent(value);
    } on ArgumentError {
      return null;
    } on FormatException {
      return null;
    }
  }
  if (value.isEmpty ||
      value.length > 1024 ||
      !RegExp(r'^[A-Za-z0-9+/=_-]+$').hasMatch(value)) {
    return null;
  }
  return value;
}

String _scientificKey(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
String _nameKey(String value) => value.trim().replaceAll(RegExp(r'\s+'), ' ');

String _fingerprint(Map<String, String> row) => jsonEncode([
  row['SpcTxnId']?.trim() ?? '',
  _scientificKey(row['SpcScitfNm'] ?? ''),
  _nameKey(row['CommKorNm'] ?? ''),
  for (final field in ['ABST', 'FORM', 'ECOL', 'HABI', 'NADI', 'INDI'])
    _plainText(row[field] ?? ''),
]);

String _plainText(String value) {
  var text = value;
  // Fields may contain CDATA HTML or XML-escaped HTML. Decode only text
  // entities; remove all executable markup before producing plain text.
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
        final number = int.tryParse(
          entity.substring(hex ? 3 : 2, entity.length - 1),
          radix: hex ? 16 : 10,
        );
        return number == null ||
                number < 32 ||
                number > 0x10ffff ||
                (number >= 0xd800 && number <= 0xdfff)
            ? ' '
            : String.fromCharCode(number);
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

Never _fail(FishCatalogFailure reason) => throw FishCatalogException(reason);
