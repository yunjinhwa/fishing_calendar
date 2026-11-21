import 'dart:async';

import 'package:fishing_build/data/maps/current_location_gateway.dart';
import 'package:fishing_build/data/maps/map_location.dart';
import 'package:fishing_build/data/maps/map_search_gateway.dart';
import 'package:fishing_build/presentation/map/map_selection_controller.dart';
import 'package:fishing_build/presentation/record/record_location_search_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _LocationGateway location;
  late _SearchGateway search;
  late MapSelectionController controller;

  setUp(() {
    location = _LocationGateway();
    search = _SearchGateway();
    controller = MapSelectionController(locationGateway: location);
    controller.setGateway(search);
  });

  tearDown(() => controller.dispose());

  testWidgets('search keeps the map connection while showing progress', (
    tester,
  ) async {
    final pending = Completer<List<MapLocation>>();
    addTearDown(() {
      if (!pending.isCompleted) pending.complete([]);
    });
    controller.setGateway(null);
    var created = 0;
    var disposed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: RecordLocationSearchPage(
          controller: controller,
          mapBuilder: (_, onGateway, _) => _MapConnection(
            createGateway: () =>
                _SearchGateway()..respond = (_) => pending.future,
            onGatewayChanged: onGateway,
            onCreated: () => created++,
            onDisposed: () => disposed++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(created, 1);
    await tester.enterText(_query, '영도');
    await tester.tap(_searchButton);
    await tester.pump();
    expect(
      created,
      1,
      reason: 'Progress must not recreate the map connection.',
    );
    expect(disposed, 0);
    pending.complete([_point('검색한 영도')]);
    await tester.pumpAndSettle();
    expect(find.text('검색한 영도'), findsWidgets);
    expect(_confirmButton(tester).onPressed, isNotNull);
    expect(created, 1);
    expect(disposed, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(disposed, 1);
  });

  testWidgets('scrolling results keeps the map connection alive', (
    tester,
  ) async {
    controller.setGateway(null);
    final results = List.generate(30, (index) => _point('검색 장소 $index'));
    var created = 0;
    var disposed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: RecordLocationSearchPage(
          controller: controller,
          mapBuilder: (_, onGateway, _) => _MapConnection(
            createGateway: () =>
                _SearchGateway()..respond = (_) async => results,
            onGatewayChanged: onGateway,
            onCreated: () => created++,
            onDisposed: () => disposed++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _search(tester, '항구');
    final last = find.byKey(const ValueKey('record-location-result-29'));
    await tester.scrollUntilVisible(
      last,
      400,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(created, 1);
    expect(disposed, 0, reason: 'Offscreen maps still own the search gateway.');
    await tester.tap(last);
    await tester.pumpAndSettle();
    expect(controller.selection.name, '검색 장소 29');
    expect(_confirmButton(tester).onPressed, isNotNull);
    expect(created, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(disposed, 1);
  });

  testWidgets('plain initial text cannot confirm default map coordinates', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(controller, initialLocation: MapLocation(name: '영도')),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(_query).controller!.text, '영도');
    expect(_confirmButton(tester).onPressed, isNull);
    expect(location.requests, 0);
    expect(search.queries, isEmpty);
  });

  testWidgets('a selected result returns only after explicit confirmation', (
    tester,
  ) async {
    final first = _point('첫 번째 장소');
    final second = _point('두 번째 장소', latitude: 34, longitude: 128);
    search.respond = (_) async => [first, second];
    MapLocation? result;
    await _openRoute(tester, controller, onResult: (value) => result = value);
    await _search(tester, '영도');
    expect(search.queries, ['영도']);
    expect(result, isNull);
    expect(_confirmButton(tester).onPressed, isNotNull);
    expect(
      find.byKey(const ValueKey('record-location-selection')),
      findsNothing,
    );
    expect(find.text(first.name), findsOneWidget);
    expect(find.text(second.name), findsOneWidget);
    _expectResultSelection(tester, 0, selected: true);
    _expectResultSelection(tester, 1, selected: false);
    final secondResult = find.byKey(const ValueKey('record-location-result-1'));
    await tester.ensureVisible(secondResult);
    await tester.tap(secondResult);
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(controller.selection, same(second));
    expect(controller.results, [first, second]);
    _expectResultSelection(tester, 0, selected: false);
    _expectResultSelection(tester, 1, selected: true);
    expect(find.text(second.name), findsOneWidget);
    expect(secondResult, findsOneWidget);
    final firstResult = find.byKey(const ValueKey('record-location-result-0'));
    expect(firstResult, findsOneWidget);
    await tester.ensureVisible(firstResult);
    await tester.tap(firstResult);
    await tester.pumpAndSettle();
    expect(controller.selection, same(first));
    expect(controller.results, [first, second]);
    _expectResultSelection(tester, 0, selected: true);
    _expectResultSelection(tester, 1, selected: false);
    expect(find.text(first.name), findsOneWidget);
    await tester.ensureVisible(secondResult);
    await tester.tap(secondResult);
    await tester.pumpAndSettle();
    expect(search.queries, ['영도']);
    await tester.tap(_confirm);
    await tester.pumpAndSettle();
    expect(result, same(second));
    expect(find.byType(RecordLocationSearchPage), findsNothing);
    expect(location.requests, 0);
  });

  testWidgets('empty and failed searches cannot confirm an older selection', (
    tester,
  ) async {
    final chosen = _point('원래 장소');
    controller.selectLocation(chosen);
    await tester.pumpWidget(_app(controller, initialLocation: chosen));
    await tester.pumpAndSettle();
    expect(_confirmButton(tester).onPressed, isNotNull);
    await _search(tester, '없는 장소');
    expect(find.textContaining('검색 결과가 없습니다'), findsOneWidget);
    expect(_confirmButton(tester).onPressed, isNull);
    search.respond = (_) async => throw StateError('private backend failure');
    await _search(tester, '실패');
    expect(find.textContaining('장소를 검색하지 못했습니다'), findsOneWidget);
    expect(find.textContaining('private backend'), findsNothing);
    expect(_confirmButton(tester).onPressed, isNull);
  });

  testWidgets('existing coordinates survive the first map connection only', (
    tester,
  ) async {
    final existing = _point('기존 출조 장소');
    controller.setGateway(null);
    controller.selectLocation(existing);
    void Function(MapSearchGateway?)? changeGateway;
    await tester.pumpWidget(
      MaterialApp(
        home: RecordLocationSearchPage(
          initialLocation: existing,
          controller: controller,
          mapBuilder: (_, onGateway, _) {
            changeGateway = onGateway;
            return const SizedBox(height: 100);
          },
        ),
      ),
    );
    expect(_confirmButton(tester).onPressed, isNotNull);
    changeGateway!(search);
    await tester.pump();
    expect(_confirmButton(tester).onPressed, isNotNull);
    expect(controller.selection, same(existing));
    expect(search.queries, isEmpty);
    expect(location.requests, 0);
    changeGateway!(null);
    await tester.pump();
    expect(_confirmButton(tester).onPressed, isNull);
  });

  testWidgets('typing another query invalidates a pending search', (
    tester,
  ) async {
    final pending = Completer<List<MapLocation>>();
    search.respond = (_) => pending.future;
    await tester.pumpWidget(_app(controller));
    await tester.enterText(_query, '이전 검색');
    await tester.tap(_searchButton);
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.enterText(_query, '새 검색');
    await tester.pump();
    pending.complete([_point('오래된 결과')]);
    await tester.pumpAndSettle();
    expect(find.text('오래된 결과'), findsNothing);
    expect(_confirmButton(tester).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a new search wins when an older response arrives last', (
    tester,
  ) async {
    final older = Completer<List<MapLocation>>();
    final newer = Completer<List<MapLocation>>();
    search.respond = (query) => query == '이전' ? older.future : newer.future;
    await tester.pumpWidget(_app(controller));
    await tester.enterText(_query, '이전');
    await tester.tap(_searchButton);
    await tester.pump();
    await tester.enterText(_query, '최신');
    await tester.tap(_searchButton);
    await tester.pump();
    newer.complete([_point('최신 장소')]);
    await tester.pumpAndSettle();
    expect(_confirmButton(tester).onPressed, isNotNull);
    older.complete([_point('지난 장소')]);
    await tester.pumpAndSettle();
    expect(controller.selection.name, '최신 장소');
    expect(find.text('지난 장소'), findsNothing);
  });

  testWidgets('cancelling ignores late responses and does not return a place', (
    tester,
  ) async {
    final pending = Completer<List<MapLocation>>();
    search.respond = (_) => pending.future;
    MapLocation? result;
    var returned = false;
    await _openRoute(
      tester,
      controller,
      onResult: (value) {
        result = value;
        returned = true;
      },
    );
    await tester.enterText(_query, '취소할 검색');
    await tester.tap(_searchButton);
    await tester.pump();
    await tester.ensureVisible(_cancel);
    await tester.tap(_cancel);
    await tester.pumpAndSettle();
    pending.complete([_point('늦은 응답')]);
    await tester.pumpAndSettle();
    expect(returned, isTrue);
    expect(result, isNull);
    expect(tester.takeException(), isNull);
    // The caller still owns an injected controller after the route closes.
    expect(() => controller.selectLocation(_point('계속 사용')), returnsNormally);
  });

  testWidgets('gateway replacement cannot confirm a stale result', (
    tester,
  ) async {
    void Function(MapSearchGateway?)? changeGateway;
    final pending = Completer<List<MapLocation>>();
    search.respond = (_) => pending.future;
    await tester.pumpWidget(
      MaterialApp(
        home: RecordLocationSearchPage(
          controller: controller,
          mapBuilder: (_, onGateway, _) {
            changeGateway = onGateway;
            return const SizedBox(height: 100);
          },
        ),
      ),
    );
    await tester.enterText(_query, '검색');
    await tester.tap(_searchButton);
    await tester.pump();
    changeGateway!(null);
    await tester.pump();
    pending.complete([_point('이전 연결 결과')]);
    await tester.pumpAndSettle();
    expect(_confirmButton(tester).onPressed, isNull);
    expect(tester.widget<IconButton>(_searchButton).onPressed, isNull);
    expect(find.text('이전 연결 결과'), findsNothing);
  });

  testWidgets(
    'map selection waits for address resolution and keeps coordinates',
    (tester) async {
      void Function(double, double)? selectPoint;
      final address = Completer<String?>();
      search.resolve = (_, _) => address.future;
      await tester.pumpWidget(
        MaterialApp(
          home: RecordLocationSearchPage(
            controller: controller,
            mapBuilder: (_, _, onPoint) {
              selectPoint = onPoint;
              return const SizedBox(height: 100);
            },
          ),
        ),
      );
      selectPoint!(35.1, 129.2);
      await tester.pump();
      expect(_confirmButton(tester).onPressed, isNull);
      address.complete('선택한 해안');
      await tester.pumpAndSettle();
      expect(_confirmButton(tester).onPressed, isNotNull);
      expect(controller.selection.name, '선택한 해안');
      expect(controller.selection.latitude, 35.1);
      expect(controller.selection.longitude, 129.2);
      expect(
        find.byKey(const ValueKey('record-location-selection')),
        findsNothing,
      );
      expect(location.requests, 0);
    },
  );

  testWidgets('current location moves the map and waits for confirmation', (
    tester,
  ) async {
    final position = Completer<MapLocation>();
    final address = Completer<String?>();
    location.locate = () => position.future;
    const latitude = 35.13;
    const longitude = 129.08;
    search.resolve = (lat, lng) {
      expect((lat, lng), (latitude, longitude));
      return address.future;
    };
    MapLocation? mapSelection;
    MapLocation? result;
    await _openRoute(
      tester,
      controller,
      onResult: (value) => result = value,
      onMapSelection: (value) => mapSelection = value,
    );
    expect(location.requests, 0);
    expect(find.text('내 위치로 이동'), findsOneWidget);

    await tester.tap(_currentLocation);
    await tester.pump();
    expect(location.permissionRequests, [true]);
    expect(tester.widget<OutlinedButton>(_currentLocation).onPressed, isNull);
    expect(_confirmButton(tester).onPressed, isNull);

    position.complete(
      _point('현재 위치', latitude: latitude, longitude: longitude),
    );
    await tester.pump();
    expect(
      (mapSelection!.latitude, mapSelection!.longitude),
      (latitude, longitude),
    );
    expect(tester.widget<OutlinedButton>(_currentLocation).onPressed, isNull);
    expect(_confirmButton(tester).onPressed, isNull);

    address.complete('역에서 찾은 위치');
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(
      tester.widget<OutlinedButton>(_currentLocation).onPressed,
      isNotNull,
    );
    await tester.tap(_confirm);
    await tester.pumpAndSettle();
    expect(result?.name, '역에서 찾은 위치');
    expect((result?.latitude, result?.longitude), (latitude, longitude));
  });

  testWidgets('blocked location access offers app permission settings', (
    tester,
  ) async {
    location.locate = () async => throw const CurrentLocationException(
      CurrentLocationFailure.deniedForever,
    );
    search.respond = (_) async => [_point('기존 선택')];
    await tester.pumpWidget(_app(controller));
    await _search(tester, '기존');
    expect(_confirmButton(tester).onPressed, isNotNull);

    await tester.tap(_currentLocation);
    await tester.pumpAndSettle();

    expect(_confirmButton(tester).onPressed, isNull);
    expect(find.textContaining('위치 권한이 차단되어 있습니다'), findsOneWidget);
    await tester.tap(find.text('앱 권한 설정 열기'));
    await tester.pumpAndSettle();
    expect(location.appSettingsRequests, 1);
  });

  testWidgets('a newer place search wins over a pending GPS request', (
    tester,
  ) async {
    final pending = Completer<MapLocation>();
    location.locate = () => pending.future;
    final found = _point('검색한 장소', latitude: 36, longitude: 128);
    search.respond = (_) async => [found];
    await tester.pumpWidget(_app(controller));
    await tester.tap(_currentLocation);
    await tester.pump();

    await _search(tester, '새 장소');
    pending.complete(_point('늦게 받은 현재 위치'));
    await tester.pumpAndSettle();

    expect(controller.selection, same(found));
    expect(_confirmButton(tester).onPressed, isNotNull);
  });

  testWidgets('missing map configuration leaves manual input available', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: RecordLocationSearchPage(
          initialLocation: MapLocation(name: '영도'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(_searchButton).onPressed, isNull);
    expect(tester.widget<OutlinedButton>(_currentLocation).onPressed, isNull);
    expect(find.textContaining('장소를 직접 입력'), findsOneWidget);
    expect(_confirmButton(tester).onPressed, isNull);
    await tester.scrollUntilVisible(
      _cancel,
      180,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(_cancel.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow large text and keyboard remain scrollable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    search.respond = (_) async => [
      _point(List.filled(8, '이름이 긴 해안 위치').join(' ')),
    ];
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(2),
            viewInsets: EdgeInsets.only(bottom: 200),
          ),
          child: child!,
        ),
        home: RecordLocationSearchPage(
          controller: controller,
          mapBuilder: (_, _, _) => const SizedBox(height: 100),
        ),
      ),
    );
    await _search(tester, '해안');
    await tester.scrollUntilVisible(
      _cancel,
      180,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(_cancel.hitTestable(), findsOneWidget);
    expect(_confirm.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

final _query = find.byKey(const ValueKey('record-location-query'));
final _searchButton = find.byKey(const ValueKey('record-location-search'));
final _currentLocation = find.byKey(const ValueKey('record-location-current'));
final _confirm = find.byKey(const ValueKey('record-location-confirm'));
final _cancel = find.byKey(const ValueKey('record-location-cancel'));

FilledButton _confirmButton(WidgetTester tester) => tester.widget(_confirm);

void _expectResultSelection(
  WidgetTester tester,
  int index, {
  required bool selected,
}) {
  final tile = tester.widget<ListTile>(
    find.byKey(ValueKey('record-location-result-$index')),
  );
  expect(tile.selected, selected);
  final outline = find.byKey(ValueKey('record-location-result-outline-$index'));
  final card = tester.widget<Card>(outline);
  final border = (card.shape! as RoundedRectangleBorder).side;
  final colors = Theme.of(tester.element(outline)).colorScheme;
  expect(border.width, selected ? 2 : 1);
  expect(border.color, selected ? colors.primary : colors.outlineVariant);
}

MapLocation _point(
  String name, {
  double latitude = 35,
  double longitude = 129,
}) => MapLocation(name: name, latitude: latitude, longitude: longitude);

Widget _app(
  MapSelectionController controller, {
  MapLocation? initialLocation,
}) => MaterialApp(
  home: RecordLocationSearchPage(
    initialLocation: initialLocation,
    controller: controller,
    mapBuilder: (_, _, _) => const SizedBox(height: 100),
  ),
);

Future<void> _search(WidgetTester tester, String text) async {
  await tester.enterText(_query, text);
  await tester.tap(_searchButton);
  await tester.pumpAndSettle();
}

Future<void> _openRoute(
  WidgetTester tester,
  MapSelectionController controller, {
  required ValueChanged<MapLocation?> onResult,
  ValueChanged<MapLocation>? onMapSelection,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            final result = await Navigator.of(context).push<MapLocation>(
              MaterialPageRoute(
                builder: (_) => RecordLocationSearchPage(
                  controller: controller,
                  mapBuilder: (selection, _, _) {
                    onMapSelection?.call(selection);
                    return const SizedBox(height: 100);
                  },
                ),
              ),
            );
            onResult(result);
          },
          child: const Text('Open search'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open search'));
  await tester.pumpAndSettle();
}

class _MapConnection extends StatefulWidget {
  const _MapConnection({
    required this.createGateway,
    required this.onGatewayChanged,
    required this.onCreated,
    required this.onDisposed,
  });

  final MapSearchGateway Function() createGateway;
  final ValueChanged<MapSearchGateway?> onGatewayChanged;
  final VoidCallback onCreated;
  final VoidCallback onDisposed;

  @override
  State<_MapConnection> createState() => _MapConnectionState();
}

class _MapConnectionState extends State<_MapConnection> {
  @override
  void initState() {
    super.initState();
    final gateway = widget.createGateway();
    widget.onCreated();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onGatewayChanged(gateway);
    });
  }

  @override
  void dispose() {
    widget.onDisposed();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox(height: 280);
}

class _SearchGateway implements MapSearchGateway {
  final queries = <String>[];
  Future<List<MapLocation>> Function(String) respond = (_) async => [];
  Future<String?> Function(double, double) resolve = (_, _) async => null;

  @override
  Future<List<MapLocation>> search(String keyword) {
    queries.add(keyword);
    return respond(keyword);
  }

  @override
  Future<String?> addressForCoordinates(double latitude, double longitude) =>
      resolve(latitude, longitude);
}

class _LocationGateway implements CurrentLocationGateway {
  Future<MapLocation> Function() locate = () async => _point('현재 위치');
  final permissionRequests = <bool>[];
  int get requests => permissionRequests.length;
  int appSettingsRequests = 0;

  @override
  Future<MapLocation> currentLocation({bool requestPermission = true}) {
    permissionRequests.add(requestPermission);
    return locate();
  }

  @override
  Future<bool> openAppSettings() async {
    appSettingsRequests++;
    return true;
  }

  @override
  Future<bool> openLocationSettings() async => false;
}
