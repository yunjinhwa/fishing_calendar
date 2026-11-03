import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:vector_tile/raw/raw_vector_tile.dart' as mvt;

import 'map_location.dart';
import 'water_area.dart';
import 'water_area_service.dart';

/// Classifies water and nearby coastal land from full-detail water polygons.
/// A nearby tide station or a missing address never establishes sea.
/// Source: https://tiles.openfreemap.org/planet (OSM / OpenMapTiles attribution).
class OpenMapWaterService implements WaterAreaService {
  OpenMapWaterService({
    Dio? dio,
    DateTime Function()? clock,
    this.cacheTtl = const Duration(days: 1),
    this.requestTimeout = const Duration(seconds: 10),
    this.maxCachedEntries = 64,
    this.maxTileBytes = 2 * 1024 * 1024,
    this.coastalDistanceMeters = 500,
  }) : _dio = dio ?? Dio(),
       _clock = clock ?? DateTime.now {
    if (cacheTtl <= Duration.zero ||
        requestTimeout <= Duration.zero ||
        maxCachedEntries < 1 ||
        maxTileBytes < 1) {
      throw ArgumentError(
        'Water tile cache and request limits must be positive.',
      );
    }
    if (!coastalDistanceMeters.isFinite ||
        coastalDistanceMeters < 0 ||
        coastalDistanceMeters > maxCoastalDistanceMeters) {
      throw ArgumentError.value(
        coastalDistanceMeters,
        'coastalDistanceMeters',
        'Must be between 0 and $maxCoastalDistanceMeters meters.',
      );
    }
  }

  static final OpenMapWaterService instance = OpenMapWaterService();
  static const _zoom = 14;
  static const _metadataUrl = 'https://tiles.openfreemap.org/planet';
  static const _mercatorLimit = 85.0511287798066;
  static const _earthRadiusMeters = 6371008.8;
  static const maxCoastalDistanceMeters = 500.0;

  final Dio _dio;
  final DateTime Function() _clock;
  final Duration cacheTtl;
  final Duration requestTimeout;
  final int maxCachedEntries;
  final int maxTileBytes;

  /// Zero restricts classification to exact polygon containment.
  final double coastalDistanceMeters;
  final _cache = <String, _CachedTile>{};
  final _inFlight = <String, Future<_WaterTile>>{};
  _TileSource? _source;
  Future<_TileSource>? _sourceInFlight;

  @override
  Future<WaterArea> classify(
    MapLocation location, {
    bool forceRefresh = false,
  }) async {
    if (!location.hasCoordinates ||
        location.latitude!.abs() >= _mercatorLimit) {
      return WaterArea.unknown;
    }
    try {
      final source = await _getSource(forceRefresh);
      final latitude = location.latitude!;
      final longitude = location.longitude!;
      if (!source.contains(latitude, longitude)) return WaterArea.unknown;
      final scale = (1 << _zoom).toDouble();
      // +180 and -180 describe the same meridian.
      final lon = longitude == 180 ? -180.0 : longitude;
      final tx = (lon + 180) / 360 * scale;
      final radians = latitude * math.pi / 180;
      final ty =
          (1 - math.log(math.tan(radians) + 1 / math.cos(radians)) / math.pi) /
          2 *
          scale;
      final x = tx.floor();
      final y = ty.floor();
      final tile = await _getTile(source.url(x, y), forceRefresh);
      final exact = tile.classify(tx - x, ty - y);
      if (exact != WaterArea.inland || coastalDistanceMeters == 0) {
        return exact;
      }

      final angularRadius = coastalDistanceMeters / _earthRadiusMeters;
      final latitudeRadius = angularRadius * 180 / math.pi;
      final longitudeRadius =
          math.asin(math.sin(angularRadius) / math.cos(radians)) *
          180 /
          math.pi;
      if (!source.coversRadius(
        latitude,
        lon,
        latitudeRadius,
        longitudeRadius,
      )) {
        return WaterArea.unknown;
      }
      // Use the smallest scale within the search circle for neighbor selection.
      // At very high latitudes 500 m can span more than a 3x3 tile block. Keep
      // that case unknown rather than expanding into an unbounded tile search.
      final furthestLatitude = latitude.abs() + latitudeRadius;
      if (furthestLatitude >= _mercatorLimit) return WaterArea.unknown;
      final metersPerTile =
          2 * math.pi * _earthRadiusMeters * math.cos(radians) / scale;
      final conservativeMetersPerTile =
          2 *
          math.pi *
          _earthRadiusMeters *
          math.cos(furthestLatitude * math.pi / 180) /
          scale;
      final tileRadius = coastalDistanceMeters / conservativeMetersPerTile;
      final minX = (tx - tileRadius).floor();
      final maxX = (tx + tileRadius).floor();
      final minY = (ty - tileRadius).floor();
      final maxY = (ty + tileRadius).floor();
      if (minX < x - 1 ||
          maxX > x + 1 ||
          minY < y - 1 ||
          maxY > y + 1 ||
          minY < 0 ||
          maxY >= scale) {
        return WaterArea.unknown;
      }
      final neighbors = <math.Point<int>>[];
      for (var nx = minX; nx <= maxX; nx++) {
        for (var ny = minY; ny <= maxY; ny++) {
          final dx = math.max(math.max(nx - tx, tx - (nx + 1)), 0.0);
          final dy = math.max(math.max(ny - ty, ty - (ny + 1)), 0.0);
          if (dx * dx + dy * dy <= tileRadius * tileRadius) {
            neighbors.add(math.Point(nx, ny));
          }
        }
      }
      // Reuse the point tile and the same request/cache safeguards for every
      // required neighbor. A failed neighbor leaves coastal inference unknown.
      final nearby = await Future.wait([
        for (final neighbor in neighbors)
          neighbor.x == x && neighbor.y == y
              ? Future.value(tile)
              : _getTile(
                  source.url(neighbor.x % (1 << _zoom), neighbor.y),
                  forceRefresh,
                ),
      ]);
      final distances = _WaterDistances();
      for (var i = 0; i < neighbors.length; i++) {
        distances.include(
          nearby[i],
          tx - neighbors[i].x,
          ty - neighbors[i].y,
          metersPerTile,
        );
      }
      const tolerance = 1e-6;
      if (distances.marine > coastalDistanceMeters + tolerance) {
        return WaterArea.inland;
      }
      if (distances.unknown <= distances.marine + tolerance) {
        return WaterArea.unknown;
      }
      // A river/lake bank beside the sea is still land. Only polygon membership
      // identifies freshwater; proximity here merely prevents a marine result.
      if (distances.freshwater <= distances.marine + tolerance) {
        return WaterArea.inland;
      }
      return WaterArea.marine;
    } on Object {
      // Includes no coverage, malformed geometry, timeouts and HTTP failures.
      // None of these establish that a point is sea or inland.
      return WaterArea.unknown;
    }
  }

  bool _fresh(DateTime fetchedAt) {
    final age = _clock().toUtc().difference(fetchedAt);
    return !age.isNegative && age < cacheTtl;
  }

  Future<_TileSource> _getSource(bool forceRefresh) async {
    final cached = _source;
    if (!forceRefresh && cached != null && _fresh(cached.fetchedAt)) {
      return cached;
    }
    final pending = _sourceInFlight;
    if (pending != null) return pending;
    final operation = _loadSource();
    _sourceInFlight = operation;
    try {
      return await operation;
    } finally {
      if (identical(_sourceInFlight, operation)) _sourceInFlight = null;
    }
  }

  Future<_TileSource> _loadSource() async {
    final bytes = await _download(_metadataUrl, 64 * 1024);
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! Map<String, dynamic> ||
        data['minzoom'] is! num ||
        data['maxzoom'] is! num ||
        (data['minzoom'] as num) > _zoom ||
        (data['maxzoom'] as num) < _zoom ||
        (data['scheme'] != null && data['scheme'] != 'xyz')) {
      throw const FormatException('Unsupported water tile metadata.');
    }
    final templates = data['tiles'];
    if (templates is! List || templates.isEmpty) {
      throw const FormatException('Missing water tile URL.');
    }
    String? template;
    for (final candidate in templates) {
      if (candidate is String && _safeTemplate(candidate)) {
        template = candidate;
        break;
      }
    }
    if (template == null) throw const FormatException('Unsafe tile URL.');
    var bounds = const [-180.0, -_mercatorLimit, 180.0, _mercatorLimit];
    if (data['bounds'] != null) {
      final rawBounds = data['bounds'];
      if (rawBounds is! List ||
          rawBounds.length != 4 ||
          rawBounds.any((value) => value is! num || !value.isFinite)) {
        throw const FormatException('Invalid tile coverage.');
      }
      bounds = rawBounds.map((value) => (value as num).toDouble()).toList();
      if (bounds[0] < -180 ||
          bounds[0] > 180 ||
          bounds[2] < -180 ||
          bounds[2] > 180 ||
          bounds[1] < -90 ||
          bounds[3] > 90 ||
          bounds[0] == bounds[2] ||
          bounds[1] >= bounds[3]) {
        throw const FormatException('Invalid tile coverage.');
      }
    }
    return _source = _TileSource(template, bounds, _clock().toUtc());
  }

  static bool _safeTemplate(String template) {
    final uri = Uri.tryParse(template);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host == 'tiles.openfreemap.org' &&
        uri.port == 443 &&
        uri.userInfo.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment &&
        RegExp(
          r'^https://tiles\.openfreemap\.org/planet/[A-Za-z0-9_-]+/\{z\}/\{x\}/\{y\}\.pbf$',
        ).hasMatch(template);
  }

  Future<_WaterTile> _getTile(String url, bool forceRefresh) async {
    final cached = _cache.remove(url);
    if (!forceRefresh && cached != null && _fresh(cached.fetchedAt)) {
      _cache[url] = cached;
      return cached.tile;
    }
    final pending = _inFlight[url];
    if (pending != null) return pending;
    final operation = _loadTile(url);
    _inFlight[url] = operation;
    try {
      return await operation;
    } finally {
      if (identical(_inFlight[url], operation)) _inFlight.remove(url);
    }
  }

  Future<_WaterTile> _loadTile(String url) async {
    final bytes = await _download(url, maxTileBytes);
    final tile = _WaterTile.decode(bytes);
    _cache[url] = _CachedTile(tile, _clock().toUtc());
    while (_cache.length > maxCachedEntries) {
      _cache.remove(_cache.keys.first);
    }
    return tile;
  }

  Future<Uint8List> _download(String url, int limit) async {
    final cancel = CancelToken();
    final operation = () async {
      final response = await _dio.get<ResponseBody>(
        url,
        cancelToken: cancel,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: false,
          receiveTimeout: requestTimeout,
          sendTimeout: requestTimeout,
          headers: const {'User-Agent': 'FishingBuild/1.0'},
        ),
      );
      final body = response.data;
      if (response.statusCode != 200 || body == null) {
        throw const FormatException('Missing water tile response.');
      }
      final declaredLength = int.tryParse(
        response.headers.value(Headers.contentLengthHeader) ?? '',
      );
      if (declaredLength != null && declaredLength > limit) {
        cancel.cancel();
        throw const FormatException('Water tile exceeds size limit.');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in body.stream) {
        if (bytes.length + chunk.length > limit) {
          cancel.cancel();
          throw const FormatException('Water tile exceeds size limit.');
        }
        bytes.add(chunk);
      }
      return bytes.takeBytes();
    }();
    return operation.timeout(
      requestTimeout,
      onTimeout: () {
        cancel.cancel();
        throw TimeoutException('Water tile request timed out.');
      },
    );
  }
}

class _TileSource {
  _TileSource(this.template, this.bounds, this.fetchedAt);
  final String template;
  final List<double> bounds;
  final DateTime fetchedAt;

  String url(int x, int y) => template
      .replaceAll('{z}', '${OpenMapWaterService._zoom}')
      .replaceAll('{x}', '$x')
      .replaceAll('{y}', '$y');

  double get _longitudeWidth => bounds[2] > bounds[0]
      ? bounds[2] - bounds[0]
      : bounds[2] - bounds[0] + 360;

  bool contains(double latitude, double longitude) =>
      (longitude - bounds[0]) % 360 <= _longitudeWidth &&
      latitude >= bounds[1] &&
      latitude <= bounds[3];

  bool coversRadius(
    double latitude,
    double longitude,
    double latitudeRadius,
    double longitudeRadius,
  ) {
    if (latitude - latitudeRadius < bounds[1] ||
        latitude + latitudeRadius > bounds[3]) {
      return false;
    }
    if (_longitudeWidth == 360) return true;
    final offset = (longitude - bounds[0]) % 360;
    return offset - longitudeRadius >= 0 &&
        offset + longitudeRadius <= _longitudeWidth;
  }
}

class _CachedTile {
  _CachedTile(this.tile, this.fetchedAt);
  final _WaterTile tile;
  final DateTime fetchedAt;
}

class _WaterTile {
  _WaterTile(this.features);
  final List<_WaterFeature> features;

  factory _WaterTile.decode(Uint8List bytes) {
    if (bytes.isEmpty) throw const FormatException('Empty water tile.');
    final tile = mvt.VectorTile.fromBuffer(bytes);
    if (tile.layers.isEmpty ||
        tile.layers.every((layer) => layer.features.isEmpty)) {
      throw const FormatException('Empty water tile.');
    }
    final names = <String>{};
    final features = <_WaterFeature>[];
    for (final layer in tile.layers) {
      if (!layer.hasName() ||
          !names.add(layer.name) ||
          !layer.hasVersion() ||
          layer.version != 2 ||
          layer.extent < 1 ||
          layer.extent > 1 << 24) {
        throw const FormatException('Unsupported vector tile layer.');
      }
      if (layer.name != 'water') continue;
      for (final feature in layer.features) {
        if (feature.type != mvt.VectorTile_GeomType.POLYGON ||
            feature.tags.length.isOdd) {
          throw const FormatException('Invalid water feature.');
        }
        String? waterClass;
        final taggedKeys = <int>{};
        for (var i = 0; i < feature.tags.length; i += 2) {
          final key = feature.tags[i];
          final value = feature.tags[i + 1];
          if (key >= layer.keys.length ||
              value >= layer.values.length ||
              !taggedKeys.add(key)) {
            throw const FormatException('Invalid water properties.');
          }
          if (layer.keys[key] == 'class') {
            final property = layer.values[value];
            if (!property.hasStringValue()) {
              throw const FormatException('Invalid water class.');
            }
            waterClass = property.stringValue;
          }
        }
        final area = switch (waterClass) {
          'ocean' => WaterArea.marine,
          'lake' ||
          'river' ||
          'pond' ||
          'swimming_pool' => WaterArea.freshwater,
          _ => WaterArea.unknown,
        };
        features.add(
          _WaterFeature(area, layer.extent, _decodePolygons(feature.geometry)),
        );
      }
    }
    return _WaterTile(features);
  }

  WaterArea classify(double tileX, double tileY) {
    var marine = false;
    var uncertain = false;
    for (final feature in features) {
      final point = math.Point(tileX * feature.extent, tileY * feature.extent);
      for (final polygon in feature.polygons) {
        final hit = polygon.locate(point);
        if (hit == _Hit.boundary) uncertain = true;
        if (hit != _Hit.inside) continue;
        if (feature.area == WaterArea.freshwater) return WaterArea.freshwater;
        if (feature.area == WaterArea.marine) marine = true;
        if (feature.area == WaterArea.unknown) uncertain = true;
      }
    }
    if (uncertain) return WaterArea.unknown;
    return marine ? WaterArea.marine : WaterArea.inland;
  }
}

class _WaterDistances {
  double marine = double.infinity;
  double freshwater = double.infinity;
  double unknown = double.infinity;

  void include(_WaterTile tile, double x, double y, double metersPerTile) {
    for (final feature in tile.features) {
      final point = math.Point(x * feature.extent, y * feature.extent);
      for (final polygon in feature.polygons) {
        final distance =
            polygon.distanceTo(point) / feature.extent * metersPerTile;
        switch (feature.area) {
          case WaterArea.marine:
            marine = math.min(marine, distance);
          case WaterArea.freshwater:
            freshwater = math.min(freshwater, distance);
          case WaterArea.unknown:
            unknown = math.min(unknown, distance);
          case WaterArea.inland:
            break;
        }
      }
    }
  }
}

class _WaterFeature {
  _WaterFeature(this.area, this.extent, this.polygons);
  final WaterArea area;
  final int extent;
  final List<_Polygon> polygons;
}

enum _Hit { outside, inside, boundary }

class _Polygon {
  _Polygon(this.outer);
  final List<math.Point<int>> outer;
  final holes = <List<math.Point<int>>>[];

  _Hit locate(math.Point<double> point) {
    final outerHit = _inRing(outer, point);
    if (outerHit != _Hit.inside) return outerHit;
    for (final hole in holes) {
      final hit = _inRing(hole, point);
      if (hit == _Hit.boundary) return hit;
      if (hit == _Hit.inside) return _Hit.outside;
    }
    return _Hit.inside;
  }

  double distanceTo(math.Point<double> point) {
    if (locate(point) != _Hit.outside) return 0;
    var distanceSquared = double.infinity;
    for (final ring in [outer, ...holes]) {
      for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
        final a = ring[j];
        final b = ring[i];
        final dx = (b.x - a.x).toDouble();
        final dy = (b.y - a.y).toDouble();
        final t =
            ((point.x - a.x) * dx + (point.y - a.y) * dy) / (dx * dx + dy * dy);
        final fraction = t.clamp(0.0, 1.0);
        final px = point.x - (a.x + fraction * dx);
        final py = point.y - (a.y + fraction * dy);
        distanceSquared = math.min(distanceSquared, px * px + py * py);
      }
    }
    return math.sqrt(distanceSquared);
  }
}

// Parse the strict MVT polygon grammar ourselves after protobuf decoding.
// This preserves multipolygon winding and rejects incomplete command streams.
List<_Polygon> _decodePolygons(List<int> commands) {
  final polygons = <_Polygon>[];
  var offset = 0;
  var x = 0;
  var y = 0;
  int next() {
    if (offset >= commands.length) {
      throw const FormatException('Truncated water geometry.');
    }
    return commands[offset++];
  }

  math.Point<int> point() {
    final dx = next();
    final dy = next();
    x += (dx >> 1) ^ -(dx & 1);
    y += (dy >> 1) ^ -(dy & 1);
    return math.Point(x, y);
  }

  while (offset < commands.length) {
    if (next() != 9) throw const FormatException('Invalid polygon MoveTo.');
    final ring = <math.Point<int>>[point()];
    final line = next();
    final count = line >> 3;
    if ((line & 7) != 2 || count < 2 || count * 2 > commands.length - offset) {
      throw const FormatException('Invalid polygon LineTo.');
    }
    for (var i = 0; i < count; i++) {
      final vertex = point();
      if (vertex == ring.last) {
        throw const FormatException('Repeated water polygon vertex.');
      }
      ring.add(vertex);
    }
    if (next() != 15 || ring.first == ring.last) {
      throw const FormatException('Invalid polygon ClosePath.');
    }
    var twiceArea = 0;
    for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      twiceArea += ring[j].x * ring[i].y - ring[i].x * ring[j].y;
    }
    if (twiceArea > 0) {
      polygons.add(_Polygon(ring));
    } else if (twiceArea < 0 && polygons.isNotEmpty) {
      if (_inRing(
            polygons.last.outer,
            math.Point(ring.first.x.toDouble(), ring.first.y.toDouble()),
          ) !=
          _Hit.inside) {
        throw const FormatException('Water polygon hole outside exterior.');
      }
      polygons.last.holes.add(ring);
    } else {
      throw const FormatException('Invalid water polygon winding or area.');
    }
  }
  if (polygons.isEmpty) throw const FormatException('Missing water polygon.');
  for (final polygon in polygons) {
    _validateRings([polygon.outer, ...polygon.holes]);
    for (var i = 0; i < polygon.holes.length; i++) {
      final hole = polygon.holes[i];
      for (final vertex in hole) {
        final point = math.Point(vertex.x.toDouble(), vertex.y.toDouble());
        if (_inRing(polygon.outer, point) != _Hit.inside ||
            polygon.holes
                .take(i)
                .any((other) => _inRing(other, point) != _Hit.outside)) {
          throw const FormatException(
            'Overlapping or uncontained polygon hole.',
          );
        }
      }
    }
  }
  return polygons;
}

// An x-axis sweep avoids comparing most unrelated edges. Limit work on unusually
// complex or malicious geometries rather than blocking the UI with unbounded
// topology validation. Nonadjacent edges and different rings must not touch.
void _validateRings(List<List<math.Point<int>>> rings) {
  final segments = <_Segment>[
    for (var r = 0; r < rings.length; r++)
      for (var i = 0; i < rings[r].length; i++)
        _Segment(
          rings[r][i],
          rings[r][(i + 1) % rings[r].length],
          r,
          i,
          rings[r].length,
        ),
  ]..sort((a, b) => a.minX.compareTo(b.minX));
  var comparisons = 0;
  for (var i = 0; i < segments.length; i++) {
    final a = segments[i];
    for (var j = i + 1; j < segments.length; j++) {
      final b = segments[j];
      if (b.minX > a.maxX) break;
      if (++comparisons > 500000) {
        throw const FormatException('Water geometry exceeds validation limit.');
      }
      if (a.maxY < b.minY || b.maxY < a.minY) continue;
      if (a.ring == b.ring &&
          ((a.index - b.index).abs() == 1 ||
              (a.index - b.index).abs() == a.length - 1)) {
        // Adjacent edges may share their common endpoint, but cannot double back.
        final common = a.a == b.a || a.a == b.b ? a.a : a.b;
        final otherA = common == a.a ? a.b : a.a;
        final otherB = common == b.a ? b.b : b.a;
        if (_orientation(common, otherA, otherB) == 0 &&
            (otherA.x - common.x) * (otherB.x - common.x) +
                    (otherA.y - common.y) * (otherB.y - common.y) >
                0) {
          throw const FormatException('Overlapping adjacent polygon edges.');
        }
        continue;
      }
      final c1 = _orientation(a.a, a.b, b.a);
      final c2 = _orientation(a.a, a.b, b.b);
      final c3 = _orientation(b.a, b.b, a.a);
      final c4 = _orientation(b.a, b.b, a.b);
      if ((c1 == 0 || c2 == 0 || c1.sign != c2.sign) &&
          (c3 == 0 || c4 == 0 || c3.sign != c4.sign)) {
        throw const FormatException('Intersecting water polygon edges.');
      }
    }
  }
}

num _orientation(math.Point<int> a, math.Point<int> b, math.Point<int> c) =>
    (b.x - a.x).toDouble() * (c.y - a.y) - (b.y - a.y).toDouble() * (c.x - a.x);

class _Segment {
  _Segment(this.a, this.b, this.ring, this.index, this.length);
  final math.Point<int> a;
  final math.Point<int> b;
  final int ring;
  final int index;
  final int length;
  int get minX => math.min(a.x, b.x);
  int get maxX => math.max(a.x, b.x);
  int get minY => math.min(a.y, b.y);
  int get maxY => math.max(a.y, b.y);
}

_Hit _inRing(List<math.Point<int>> ring, math.Point<double> point) {
  var inside = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final a = ring[j];
    final b = ring[i];
    final dx = (b.x - a.x).toDouble();
    final dy = (b.y - a.y).toDouble();
    final cross = (point.x - a.x) * dy - (point.y - a.y) * dx;
    // Numerical tolerance only; this is not a coastline-distance buffer.
    if (cross.abs() <= 1e-7 * math.max(1, math.sqrt(dx * dx + dy * dy)) &&
        point.x >= math.min(a.x, b.x) - 1e-7 &&
        point.x <= math.max(a.x, b.x) + 1e-7 &&
        point.y >= math.min(a.y, b.y) - 1e-7 &&
        point.y <= math.max(a.y, b.y) + 1e-7) {
      return _Hit.boundary;
    }
    if ((a.y > point.y) != (b.y > point.y) &&
        point.x < a.x + (point.y - a.y) * dx / dy) {
      inside = !inside;
    }
  }
  return inside ? _Hit.inside : _Hit.outside;
}
