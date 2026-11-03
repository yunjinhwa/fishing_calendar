import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fishing_build/data/maps/map_location.dart';
import 'package:fishing_build/data/maps/open_map_water_service.dart';
import 'package:fishing_build/data/maps/water_area.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_tile/raw/raw_vector_tile.dart' as mvt;

void main() {
  late DateTime now;
  late _Adapter adapter;
  late Dio dio;
  late OpenMapWaterService service;
  late Uint8List tile;

  setUp(() {
    now = DateTime.utc(2026, 11, 3);
    tile = _tile([
      _feature('ocean', [_square(512, 3584)]),
    ]);
    adapter = _Adapter(
      (request) => request.uri.path == '/planet' ? _metadata() : _bytes(tile),
    );
    dio = Dio()..httpClientAdapter = adapter;
    service = OpenMapWaterService(
      dio: dio,
      clock: () => now,
      coastalDistanceMeters: 0,
    );
  });

  test('only ocean polygon membership enables marine data', () async {
    expect(await service.classify(_location(2048, 2048)), WaterArea.marine);
    expect(await service.classify(_location(100, 100)), WaterArea.inland);
    expect(adapter.calls, hasLength(2));
    expect(
      adapter.calls.first.uri.toString(),
      'https://tiles.openfreemap.org/planet',
    );
    expect(
      adapter.calls.last.uri.path,
      '/planet/test_version/14/13940/6350.pbf',
    );
    expect(adapter.calls.last.headers['User-Agent'], 'FishingBuild/1.0');
    expect(adapter.calls.last.followRedirects, isFalse);
  });

  test(
    'ocean holes are inland and multipolygon exteriors are independent',
    () async {
      tile = _tile([
        _feature('ocean', [
          _square(512, 2500),
          _square(1000, 2000).reversed.toList(),
          _square(3000, 3800),
        ]),
      ]);
      expect(await service.classify(_location(1500, 1500)), WaterArea.inland);
      expect(await service.classify(_location(750, 750)), WaterArea.marine);
      expect(await service.classify(_location(3500, 3500)), WaterArea.marine);
    },
  );

  test(
    'freshwater overrides overlapping ocean polygons in either order',
    () async {
      for (final reverse in [false, true]) {
        final features = [
          _feature('ocean', [_square(0, 4096)]),
          _feature('river', [_square(1000, 3000)]),
        ];
        tile = _tile(reverse ? features.reversed.toList() : features);
        expect(
          await service.classify(_location(2048, 2048), forceRefresh: true),
          WaterArea.freshwater,
        );
      }
    },
  );

  test('lake pond and swimming pool are never marine', () async {
    for (final waterClass in ['lake', 'pond', 'swimming_pool']) {
      tile = _tile([
        _feature(waterClass, [_square(0, 4096)]),
      ]);
      expect(
        await service.classify(_location(2048, 2048), forceRefresh: true),
        WaterArea.freshwater,
      );
    }
  });

  test('polygon and hole boundaries are uncertain', () async {
    tile = _tile([
      _feature('ocean', [
        _square(512, 3584),
        _square(1000, 2000).reversed.toList(),
      ]),
    ]);
    expect(await service.classify(_location(512, 2048)), WaterArea.unknown);
    expect(await service.classify(_location(1000, 1500)), WaterArea.unknown);
    // Keep the fractional Mercator point; rounding this would hit the boundary.
    expect(await service.classify(_location(512.25, 2048)), WaterArea.marine);
  });

  test('dock and future water classes remain unknown', () async {
    for (final waterClass in ['dock', 'future_class']) {
      tile = _tile([
        _feature(waterClass, [_square(0, 4096)]),
      ]);
      expect(
        await service.classify(_location(2048, 2048), forceRefresh: true),
        WaterArea.unknown,
      );
    }
  });

  test(
    'nonempty land tile without water is inland; empty tile is unknown',
    () async {
      tile = mvt.VectorTile(
        layers: [
          mvt.VectorTile_Layer(
            name: 'place',
            version: 2,
            extent: 4096,
            features: [
              mvt.VectorTile_Feature(
                type: mvt.VectorTile_GeomType.POINT,
                geometry: [9, 0, 0],
              ),
            ],
          ),
        ],
      ).writeToBuffer();
      expect(await service.classify(_location(2048, 2048)), WaterArea.inland);
      tile = Uint8List(0);
      expect(
        await service.classify(_location(2048, 2048), forceRefresh: true),
        WaterArea.unknown,
      );
    },
  );

  test(
    'truncated commands, degenerate rings and invalid tags are unknown',
    () async {
      for (final invalid in [
        mvt.VectorTile_Feature(
          type: mvt.VectorTile_GeomType.POLYGON,
          tags: [0, 0],
          geometry: [9, 0, 0, 26, 1],
        ),
        _feature('ocean', [
          [
            const math.Point(1, 1),
            const math.Point(2, 2),
            const math.Point(3, 3),
          ],
        ]),
        _feature('ocean', [_square(512, 3584)])..tags.add(99),
        _feature('ocean', [_square(512, 3584)])..tags[1] = 99,
        _feature('ocean', [_square(512, 3584).reversed.toList()]),
        _feature('ocean', [
          [
            const math.Point(0, 0),
            const math.Point(3000, 2500),
            const math.Point(0, 3000),
            const math.Point(2500, 0),
          ],
        ]),
        _feature('ocean', [
          _square(512, 3584),
          [
            const math.Point(1000, 1000),
            const math.Point(1000, 2000),
            const math.Point(4000, 2000),
            const math.Point(4000, 1000),
          ],
        ]),
      ]) {
        tile = _tile([invalid]);
        expect(
          await service.classify(_location(2048, 2048), forceRefresh: true),
          WaterArea.unknown,
        );
      }
      tile = Uint8List.fromList([255, 255, 255]);
      expect(
        await service.classify(_location(2048, 2048), forceRefresh: true),
        WaterArea.unknown,
      );
    },
  );

  test(
    'missing coordinates and unsupported Mercator latitude make no requests',
    () async {
      expect(
        await service.classify(MapLocation(name: '직접 입력')),
        WaterArea.unknown,
      );
      expect(
        await service.classify(
          MapLocation(name: '극지', latitude: 89, longitude: 127),
        ),
        WaterArea.unknown,
      );
      expect(adapter.calls, isEmpty);
    },
  );

  test('untrusted templates and lower-detail sources are rejected', () async {
    for (final data in [
      _source(tiles: ['https://example.com/planet/v/{z}/{x}/{y}.pbf']),
      _source(tiles: ['http://tiles.openfreemap.org/planet/v/{z}/{x}/{y}.pbf']),
      _source(
        tiles: [
          'https://tiles.openfreemap.org.evil.test/planet/v/{z}/{x}/{y}.pbf',
        ],
      ),
      _source(
        tiles: [
          'https://tiles.openfreemap.org/planet/v/{z}/{x}/{y}.pbf?key=bad',
        ],
      ),
      {..._source(), 'maxzoom': 13},
      {..._source(), 'scheme': 'tms'},
    ]) {
      adapter.respond = (_) => _json(data);
      expect(
        await service.classify(_location(2048, 2048), forceRefresh: true),
        WaterArea.unknown,
      );
    }
    expect(
      adapter.calls.every((request) => request.uri.path == '/planet'),
      isTrue,
    );
  });

  test('source coverage limits do not imply inland', () async {
    adapter.respond = (_) => _json({
      ..._source(),
      'bounds': [-1, -1, 1, 1],
    });
    expect(await service.classify(_location(2048, 2048)), WaterArea.unknown);
    expect(adapter.calls, hasLength(1));
  });

  test('network failure is unknown and there is no automatic retry', () async {
    adapter.respond = (_) => ResponseBody.fromString('unavailable', 503);
    expect(await service.classify(_location(2048, 2048)), WaterArea.unknown);
    expect(adapter.calls, hasLength(1));
  });

  test('tile response size is bounded', () async {
    service = OpenMapWaterService(dio: dio, maxTileBytes: 16);
    expect(await service.classify(_location(2048, 2048)), WaterArea.unknown);
    expect(adapter.calls, hasLength(2));
  });

  test('requests time out and a later explicit request can recover', () async {
    final stalled = Completer<ResponseBody>();
    adapter.respond = (_) => stalled.future;
    service = OpenMapWaterService(
      dio: dio,
      requestTimeout: const Duration(milliseconds: 20),
    );
    expect(await service.classify(_location(2048, 2048)), WaterArea.unknown);
    expect(adapter.calls, hasLength(1));
    stalled.complete(_metadata());
    adapter.respond = (request) =>
        request.uri.path == '/planet' ? _metadata() : _bytes(tile);
    expect(await service.classify(_location(2048, 2048)), WaterArea.marine);
  });

  test('same-tile lookups coalesce source and tile requests', () async {
    final gate = Completer<ResponseBody>();
    final started = Completer<void>();
    adapter.respond = (request) {
      if (request.uri.path == '/planet') return _metadata();
      if (!started.isCompleted) started.complete();
      return gate.future;
    };
    final first = service.classify(_location(2048, 2048));
    final second = service.classify(_location(1500, 1500));
    await started.future;
    gate.complete(_bytes(tile));
    expect(await Future.wait([first, second]), [
      WaterArea.marine,
      WaterArea.marine,
    ]);
    expect(adapter.calls, hasLength(2));
  });

  test('TTL and explicit refresh reload metadata and tiles', () async {
    expect(await service.classify(_location(2048, 2048)), WaterArea.marine);
    now = now.add(const Duration(hours: 23));
    expect(await service.classify(_location(2048, 2048)), WaterArea.marine);
    expect(adapter.calls, hasLength(2));
    now = now.add(const Duration(hours: 2));
    expect(await service.classify(_location(2048, 2048)), WaterArea.marine);
    expect(adapter.calls, hasLength(4));
    tile = _tile([
      _feature('lake', [_square(0, 4096)]),
    ]);
    expect(
      await service.classify(_location(2048, 2048), forceRefresh: true),
      WaterArea.freshwater,
    );
    expect(adapter.calls, hasLength(6));
  });

  test(
    'LRU eviction retains recently read tile and bounds cache size',
    () async {
      service = OpenMapWaterService(
        dio: dio,
        clock: () => now,
        maxCachedEntries: 2,
      );
      await service.classify(_location(2048, 2048, tileX: 13940));
      await service.classify(_location(2048, 2048, tileX: 13941));
      await service.classify(_location(2048, 2048, tileX: 13940));
      await service.classify(_location(2048, 2048, tileX: 13942));
      await service.classify(_location(2048, 2048, tileX: 13940));
      expect(adapter.calls, hasLength(4));
      await service.classify(_location(2048, 2048, tileX: 13941));
      expect(adapter.calls, hasLength(5));
    },
  );

  group('coastal land', () {
    setUp(() {
      service = OpenMapWaterService(dio: dio, clock: () => now);
    });

    test(
      'default 500 meter radius and a smaller radius use ocean geometry',
      () async {
        tile = _tile([
          _feature('ocean', [_rectangle(0, 0, 1500, 4096)]),
        ]);
        final shore = _location(2048, 2048);
        expect(await service.classify(shore), WaterArea.marine);
        service = OpenMapWaterService(dio: dio, coastalDistanceMeters: 200);
        expect(await service.classify(shore), WaterArea.inland);
        service = OpenMapWaterService(dio: dio, coastalDistanceMeters: 0);
        expect(await service.classify(shore), WaterArea.inland);
        tile = _tile([
          _feature('ocean', [_rectangle(0, 0, 500, 4096)]),
        ]);
        service = OpenMapWaterService(dio: dio);
        expect(await service.classify(shore), WaterArea.inland);
      },
    );

    test('radius is finite, nonnegative and conservatively capped', () {
      for (final invalid in [-1.0, 501.0, double.infinity, double.nan]) {
        expect(
          () => OpenMapWaterService(coastalDistanceMeters: invalid),
          throwsArgumentError,
        );
      }
    });

    test(
      'island hole edges count as coast but large island interiors do not',
      () async {
        tile = _tile([
          _feature('ocean', [
            _square(-1000, 5096),
            _square(500, 3596).reversed.toList(),
          ]),
        ]);
        expect(await service.classify(_location(1200, 2048)), WaterArea.marine);
        expect(await service.classify(_location(2048, 2048)), WaterArea.inland);
        expect(await service.classify(_location(500, 2048)), WaterArea.unknown);
      },
    );

    test('distance respects the vector layer extent', () async {
      tile = _tile([
        _feature('ocean', [_rectangle(0, 0, 3000, 8192)]),
      ], extent: 8192);
      expect(await service.classify(_location(2048, 2048)), WaterArea.marine);
      tile = _tile([
        _feature('ocean', [_rectangle(0, 0, 1000, 8192)]),
      ], extent: 8192);
      expect(
        await service.classify(_location(2048, 2048), forceRefresh: true),
        WaterArea.inland,
      );
    });

    test(
      'ocean in adjacent tile is cached and concurrent reads coalesce',
      () async {
        final ocean = _tile([
          _feature('ocean', [_rectangle(600, 0, 4096, 4096)]),
        ]);
        adapter.respond = (request) => request.uri.path == '/planet'
            ? _metadata()
            : _bytes(
                request.uri.path.endsWith('/13941/6350.pbf')
                    ? ocean
                    : _landTile(),
              );
        final points = [_location(3900, 2048), _location(3850, 2048)];
        expect(await Future.wait(points.map(service.classify)), [
          WaterArea.marine,
          WaterArea.marine,
        ]);
        expect(adapter.calls, hasLength(3));
        expect(await service.classify(points.first), WaterArea.marine);
        expect(adapter.calls, hasLength(3));
        expect(
          await service.classify(points.first, forceRefresh: true),
          WaterArea.marine,
        );
        expect(adapter.calls, hasLength(6));
      },
    );

    test(
      'closer or equally close freshwater protects a coastal bank',
      () async {
        for (final freshEdge in [2500, 2596]) {
          tile = _tile([
            _feature('ocean', [_rectangle(0, 0, 1500, 4096)]),
            _feature('river', [_rectangle(freshEdge, 0, 4096, 4096)]),
          ]);
          expect(
            await service.classify(_location(2048, 2048), forceRefresh: true),
            WaterArea.inland,
          );
          expect(
            await service.classify(_location(2800, 2048)),
            WaterArea.freshwater,
          );
        }
        tile = _tile([
          _feature('ocean', [_rectangle(0, 0, 1500, 4096)]),
          _feature('lake', [_rectangle(2800, 0, 4096, 4096)]),
        ]);
        expect(
          await service.classify(_location(2048, 2048), forceRefresh: true),
          WaterArea.marine,
        );
      },
    );

    test(
      'freshwater in the adjacent tile also protects a coastal bank',
      () async {
        final coast = _tile([
          _feature('ocean', [_rectangle(300, 0, 4096, 4096)]),
          _feature('pond', [_rectangle(50, 0, 150, 4096)]),
        ]);
        adapter.respond = (request) => request.uri.path == '/planet'
            ? _metadata()
            : _bytes(
                request.uri.path.endsWith('/13941/6350.pbf')
                    ? coast
                    : _landTile(),
              );
        expect(await service.classify(_location(3900, 2048)), WaterArea.inland);
        expect(adapter.calls, hasLength(3));
      },
    );

    test(
      'dock membership and a closer unknown water edge stay unknown',
      () async {
        tile = _tile([
          _feature('ocean', [_rectangle(0, 0, 1500, 4096)]),
          _feature('dock', [_rectangle(1900, 0, 2200, 4096)]),
        ]);
        expect(
          await service.classify(_location(2048, 2048)),
          WaterArea.unknown,
        );
        tile = _tile([
          _feature('ocean', [_rectangle(0, 0, 1500, 4096)]),
          _feature('future_class', [_rectangle(2500, 0, 4096, 4096)]),
        ]);
        expect(
          await service.classify(_location(2048, 2048), forceRefresh: true),
          WaterArea.unknown,
        );
      },
    );

    test('required neighbor failure stays unknown without retries', () async {
      adapter.respond = (request) {
        if (request.uri.path == '/planet') return _metadata();
        if (request.uri.path.endsWith('/13940/6350.pbf')) {
          return _bytes(_landTile());
        }
        return ResponseBody.fromString('unavailable', 503);
      };
      expect(await service.classify(_location(3900, 2048)), WaterArea.unknown);
      expect(adapter.calls, hasLength(3));
      expect(await service.classify(_location(2048, 2048)), WaterArea.inland);
      expect(adapter.calls, hasLength(3));
    });

    test(
      'diagonal tile outside the radius is not a required neighbor',
      () async {
        adapter.respond = (request) {
          if (request.uri.path == '/planet') return _metadata();
          if (request.uri.path.endsWith('/13941/6351.pbf')) {
            return ResponseBody.fromString('unavailable', 503);
          }
          return _bytes(_landTile());
        };
        expect(await service.classify(_location(3300, 3300)), WaterArea.inland);
        expect(adapter.calls, hasLength(4));
      },
    );

    test(
      'source coverage must include the entire coastal search radius',
      () async {
        final point = _location(2048, 2048);
        adapter.respond = (request) => request.uri.path == '/planet'
            ? _json({
                ..._source(),
                'bounds': [
                  point.longitude! - 0.001,
                  point.latitude! - 0.001,
                  point.longitude! + 0.001,
                  point.latitude! + 0.001,
                ],
              })
            : _bytes(_landTile());
        expect(await service.classify(point), WaterArea.unknown);
        expect(adapter.calls, hasLength(2));
      },
    );

    test(
      'wrapped tiles and dateline source bounds preserve local distance',
      () async {
        final ocean = _tile([
          _feature('ocean', [_rectangle(600, 0, 4096, 4096)]),
        ]);
        adapter.respond = (request) => request.uri.path == '/planet'
            ? _json({
                ..._source(),
                'bounds': [170, -80, -170, 80],
              })
            : _bytes(
                request.uri.path.endsWith('/0/6350.pbf') ? ocean : _landTile(),
              );
        expect(
          await service.classify(_location(3900, 2048, tileX: 16383)),
          WaterArea.marine,
        );
        expect(adapter.calls, hasLength(3));
        expect(adapter.calls.last.uri.path, endsWith('/0/6350.pbf'));
      },
    );

    test(
      'very high latitude stays bounded instead of expanding tile search',
      () async {
        adapter.respond = (request) =>
            request.uri.path == '/planet' ? _metadata() : _bytes(_landTile());
        expect(
          await service.classify(
            MapLocation(name: 'High latitude', latitude: 84, longitude: 127),
          ),
          WaterArea.unknown,
        );
        expect(adapter.calls, hasLength(2));
      },
    );
  });
}

MapLocation _location(num px, num py, {int tileX = 13940}) {
  const scale = 16384;
  final x = tileX + px / 4096;
  final y = 6350 + py / 4096;
  final mercator = math.pi * (1 - 2 * y / scale);
  return MapLocation(
    name: 'Fixture point',
    longitude: x / scale * 360 - 180,
    latitude:
        math.atan((math.exp(mercator) - math.exp(-mercator)) / 2) *
        180 /
        math.pi,
  );
}

List<math.Point<int>> _square(int min, int max) => [
  math.Point(min, min),
  math.Point(max, min),
  math.Point(max, max),
  math.Point(min, max),
];

List<math.Point<int>> _rectangle(int left, int top, int right, int bottom) => [
  math.Point(left, top),
  math.Point(right, top),
  math.Point(right, bottom),
  math.Point(left, bottom),
];

mvt.VectorTile_Feature _feature(
  String waterClass,
  List<List<math.Point<int>>> rings,
) {
  final commands = <int>[];
  var x = 0;
  var y = 0;
  int zigzag(int value) => (value << 1) ^ (value >> 31);
  for (final ring in rings) {
    for (var i = 0; i < ring.length; i++) {
      if (i == 0) commands.add(9);
      if (i == 1) commands.add(((ring.length - 1) << 3) | 2);
      final point = ring[i];
      commands.addAll([zigzag(point.x - x), zigzag(point.y - y)]);
      x = point.x;
      y = point.y;
    }
    commands.add(15);
  }
  return mvt.VectorTile_Feature(
    tags: [0, _classes.indexOf(waterClass)],
    type: mvt.VectorTile_GeomType.POLYGON,
    geometry: commands,
  );
}

const _classes = [
  'ocean',
  'lake',
  'river',
  'pond',
  'swimming_pool',
  'dock',
  'future_class',
];

Uint8List _tile(List<mvt.VectorTile_Feature> features, {int extent = 4096}) =>
    mvt.VectorTile(
      layers: [
        mvt.VectorTile_Layer(
          name: 'water',
          extent: extent,
          version: 2,
          keys: ['class'],
          values: [
            for (final waterClass in _classes)
              mvt.VectorTile_Value(stringValue: waterClass),
          ],
          features: features,
        ),
      ],
    ).writeToBuffer();

Uint8List _landTile() => mvt.VectorTile(
  layers: [
    mvt.VectorTile_Layer(
      name: 'place',
      extent: 4096,
      version: 2,
      features: [
        mvt.VectorTile_Feature(
          type: mvt.VectorTile_GeomType.POINT,
          geometry: [9, 0, 0],
        ),
      ],
    ),
  ],
).writeToBuffer();

Map<String, Object> _source({List<String>? tiles}) => {
  'tilejson': '3.0.0',
  'minzoom': 0,
  'maxzoom': 14,
  'tiles':
      tiles ??
      ['https://tiles.openfreemap.org/planet/test_version/{z}/{x}/{y}.pbf'],
};

ResponseBody _metadata() => _json(_source());
ResponseBody _json(Object data) => ResponseBody.fromString(
  jsonEncode(data),
  200,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);
ResponseBody _bytes(Uint8List bytes) => ResponseBody.fromBytes(
  bytes,
  200,
  headers: {
    Headers.contentTypeHeader: ['application/vnd.mapbox-vector-tile'],
  },
);

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  FutureOr<ResponseBody> Function(RequestOptions) respond;
  final calls = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(options);
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}
