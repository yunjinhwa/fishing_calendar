import 'dart:async';

import 'package:fishing_build/data/maps/kakao_map_configuration.dart';
import 'package:fishing_build/data/maps/kakao_map_search_gateway.dart';
import 'package:fishing_build/data/maps/map_location.dart';
import 'package:fishing_build/presentation/map/kakao_map_canvas.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kakao_map_plugin/kakao_map_plugin.dart';

void main() {
  test(
    'place and address results preserve WGS84 axes and remove duplicates',
    () async {
      final gateway = _gateway(
        keyword: (_) async => KeywordSearchResponse(
          list: [
            KeywordAddress(
              placeName: ' 부산항 ',
              addressName: '지번 주소',
              roadAddressName: ' 도로명 주소 ',
              x: '129.075612345',
              y: '35.179612345',
            ),
          ],
        ),
        address: (_) async => AddressSearchResponse(
          list: [
            SearchAddress(
              id: null,
              addressType: null,
              address: null,
              roadAddress: null,
              addressName: '부산항',
              x: '129.075612345',
              y: '35.179612345',
            ),
            SearchAddress(
              id: null,
              addressType: null,
              address: null,
              roadAddress: null,
              addressName: '남쪽 바다',
              x: '151.2093',
              y: '-33.8688',
            ),
          ],
        ),
      );
      final result = await gateway.search('부산');
      expect(result.map((location) => location.name), ['부산항', '남쪽 바다']);
      expect(result.first.latitude, 35.179612345);
      expect(result.first.longitude, 129.075612345);
      expect(result.first.address, '도로명 주소');
      expect(result.last.latitude, -33.8688);
    },
  );

  test(
    'search filters malformed coordinates and names but accepts zero',
    () async {
      final gateway = _gateway(
        keyword: (_) async => KeywordSearchResponse(
          list: [
            KeywordAddress(placeName: 'no latitude', x: '129'),
            KeywordAddress(placeName: 'out of range', x: '181', y: '35'),
            KeywordAddress(placeName: 'invalid number', x: '129', y: 'NaN'),
            KeywordAddress(
              placeName: 'infinite number',
              x: 'Infinity',
              y: '35',
            ),
            KeywordAddress(placeName: 'missing name', x: '35', y: '91'),
            KeywordAddress(placeName: '  ', x: '129', y: '35'),
            KeywordAddress(placeName: 'x' * 201, x: '129', y: '35'),
            KeywordAddress(placeName: 'Zero point', x: '0', y: '0'),
          ],
        ),
      );
      final result = await gateway.search('point');
      expect(result, hasLength(1));
      expect(result.single.name, 'Zero point');
      expect(result.single.latitude, 0.0);
      expect(result.single.longitude, 0.0);
    },
  );

  test(
    'requests keep quoted search input as data and skip empty input',
    () async {
      final queries = <String>[];
      final gateway = _gateway(
        keyword: (request) async {
          queries.add(request.keyword);
          expect(request.size, 15);
          return KeywordSearchResponse(list: []);
        },
        address: (request) async {
          queries.add(request.addr);
          expect(request.size, 15);
          return AddressSearchResponse(list: []);
        },
      );
      const input = '''항구 '); alert(1); // "\\\n다음 줄''';
      expect(await gateway.search('  '), isEmpty);
      expect(queries, isEmpty);
      expect(await gateway.search(' $input '), isEmpty);
      expect(queries, [input, input]);
      await expectLater(gateway.search('x' * 201), throwsArgumentError);
      expect(queries, hasLength(2));
    },
  );

  test(
    'one failed service can still return the other service results',
    () async {
      final gateway = _gateway(
        keyword: (_) => Future.error(StateError('keyword unavailable')),
        address: (_) async => AddressSearchResponse(
          list: [
            SearchAddress(
              id: null,
              addressType: null,
              address: null,
              roadAddress: null,
              addressName: '주소 결과',
              x: '129',
              y: '35',
            ),
          ],
        ),
      );
      expect((await gateway.search('부산')).single.name, '주소 결과');
    },
  );

  test(
    'a partial or total failure is not reported as an empty search',
    () async {
      for (final failAddress in [false, true]) {
        final gateway = _gateway(
          keyword: (_) => Future.error(StateError('keyword unavailable')),
          address: (_) => failAddress
              ? Future.error(StateError('address unavailable'))
              : Future.value(AddressSearchResponse(list: [])),
        );
        await expectLater(gateway.search('부산'), throwsStateError);
      }
      expect(await _gateway().search('아무 결과 없음'), isEmpty);
    },
  );

  test(
    'reverse geocoding prefers road addresses then falls back to land addresses',
    () async {
      for (final road in ['도로명 주소', '   ']) {
        final gateway = _gateway(
          reverse: (request) async {
            expect(request.x, 129.0756);
            expect(request.y, 35.1796);
            return Coord2AddressResponse(
              list: [
                Coord2Address(
                  roadAddress: _road(road),
                  address: _land('지번 주소'),
                ),
              ],
            );
          },
        );
        expect(
          await gateway.addressForCoordinates(35.1796, 129.0756),
          road.trim().isEmpty ? '지번 주소' : '도로명 주소',
        );
      }
      expect(await _gateway().addressForCoordinates(0, 0), isNull);
    },
  );

  test('invalid reverse coordinates never call the map service', () async {
    var calls = 0;
    final gateway = _gateway(
      reverse: (_) async {
        calls++;
        return Coord2AddressResponse(list: []);
      },
    );
    for (final pair in [(91.0, 0.0), (0.0, 181.0), (double.nan, 0.0)]) {
      await expectLater(
        gateway.addressForCoordinates(pair.$1, pair.$2),
        throwsArgumentError,
      );
    }
    expect(calls, 0);
  });

  test('requests have a bounded wait if the WebView never replies', () async {
    final gateway = _gateway(
      keyword: (_) => Completer<KeywordSearchResponse>().future,
      address: (_) => Completer<AddressSearchResponse>().future,
      reverse: (_) => Completer<Coord2AddressResponse>().future,
      timeout: const Duration(milliseconds: 1),
    );
    await expectLater(gateway.search('부산'), throwsStateError);
    await expectLater(
      gateway.addressForCoordinates(35, 129),
      throwsA(isA<TimeoutException>()),
    );
  });

  test(
    'disposing a map rejects its pending result and all later requests',
    () async {
      final pending = Completer<KeywordSearchResponse>();
      var calls = 0;
      final gateway = _gateway(
        keyword: (_) {
          calls++;
          return pending.future;
        },
      );
      final response = gateway.search('부산');
      gateway.dispose();
      pending.complete(
        KeywordSearchResponse(
          list: [KeywordAddress(placeName: 'old map', x: '129', y: '35')],
        ),
      );
      await expectLater(response, throwsStateError);
      await expectLater(gateway.search('다른 장소'), throwsStateError);
      await expectLater(
        gateway.addressForCoordinates(35, 129),
        throwsStateError,
      );
      expect(calls, 1);
    },
  );

  testWidgets('missing map configuration never constructs a WebView', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KakaoMapCanvas(
            configuration: const KakaoMapConfiguration(javascriptKey: ''),
            selection: MapLocation(name: '부산'),
            onGatewayChanged: (_) =>
                fail('An unavailable map cannot publish a gateway.'),
            onPointSelected: (_, _) =>
                fail('An unavailable map cannot publish a point.'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(KakaoMap), findsNothing);
    expect(find.textContaining('장소를 직접 입력'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unsupported desktop environments keep manual input available', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KakaoMapCanvas(
            configuration: const KakaoMapConfiguration(
              javascriptKey: 'development-key-placeholder-123456',
            ),
            selection: MapLocation(name: '부산'),
            onGatewayChanged: (_) =>
                fail('An unsupported map cannot publish a gateway.'),
            onPointSelected: (_, _) =>
                fail('An unsupported map cannot publish a point.'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(KakaoMap), findsNothing);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}

KakaoMapSearchGateway _gateway({
  Future<KeywordSearchResponse> Function(KeywordSearchRequest)? keyword,
  Future<AddressSearchResponse> Function(AddressSearchRequest)? address,
  Future<Coord2AddressResponse> Function(Coord2AddressRequest)? reverse,
  Duration timeout = const Duration(seconds: 12),
}) => KakaoMapSearchGateway.withRequests(
  keywordSearch: keyword ?? (_) async => KeywordSearchResponse(list: []),
  addressSearch: address ?? (_) async => AddressSearchResponse(list: []),
  reverseGeocode: reverse ?? (_) async => Coord2AddressResponse(list: []),
  requestTimeout: timeout,
);

RoadAddress _road(String name) => RoadAddress(
  addressName: name,
  region1DepthName: '',
  region2DepthName: '',
  region3DepthName: '',
  roadName: '',
  undergroundYn: 'N',
  mainBuildingNo: '',
  subBuildingNo: '',
  buildingName: '',
  zoneNo: '',
);

Address _land(String name) => Address(
  addressName: name,
  region1DepthName: '',
  region2DepthName: '',
  region3DepthName: '',
  mountainYn: 'N',
  mainAddressNo: '',
  subAddressNo: '',
  zipCode: '',
);
