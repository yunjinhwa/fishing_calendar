import 'dart:async';

import 'package:fishing_build/data/maps/current_location_gateway.dart';
import 'package:fishing_build/data/maps/map_location.dart';
import 'package:fishing_build/data/maps/map_search_gateway.dart';
import 'package:fishing_build/data/models/external_data.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/services/external_data_service.dart';
import 'package:fishing_build/data/services/network_status_service.dart';
import 'package:fishing_build/presentation/map/map_detail_page.dart';
import 'package:fishing_build/presentation/map/map_page.dart';
import 'package:fishing_build/presentation/map/map_selection_controller.dart';
import 'package:fishing_build/presentation/record/record_form_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_database.dart';

void main() {
  final auth = AuthSessionRepository.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await NetworkStatusService.instance.resetForTesting();
    await resetTestDatabase();
    auth.clearMemoryOnlyForTesting();
    FishingRecordRepository.instance.clearCacheOnlyForTesting();
    await auth.setSessionForTesting(
      plan: UserPlan.free,
      email: 'map-widget@example.com',
    );
  });

  testWidgets('inactive map and ungranted location never request GPS', (
    tester,
  ) async {
    final gps = _LocationGateway();
    final controller = MapSelectionController(locationGateway: gps);
    final service = _ExternalService();
    var mapBuilds = 0;
    Widget page(bool isActive) => MaterialApp(
      home: MapPage(
        isActive: isActive,
        controller: controller,
        externalDataService: service,
        mapBuilder: (_, _, _) {
          mapBuilds++;
          return const SizedBox(key: ValueKey('fake-map'));
        },
      ),
    );
    _prepareView(tester);
    addTearDown(controller.dispose);
    addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(page(false));
    await tester.pump();
    expect(mapBuilds, 0);
    expect(service.calls, isEmpty);
    expect(gps.requests, 0);

    await tester.pumpWidget(page(true));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fake-map')), findsOneWidget);
    expect(service.calls, ['부산 영도구 동삼동']);
    expect(gps.requests, 0);
    expect(gps.permissionModes, [false]);

    await tester.pumpWidget(page(false));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fake-map')), findsNothing);
    expect(service.calls, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('granted location refreshes once on each map tab entry', (
    tester,
  ) async {
    final gps = _LocationGateway()..permissionGranted = true;
    final controller = MapSelectionController(locationGateway: gps);
    final service = _ExternalService();
    MapLocation? displayedSelection;
    Widget page(bool isActive) => MaterialApp(
      home: MapPage(
        isActive: isActive,
        controller: controller,
        externalDataService: service,
        mapBuilder: (selection, _, _) {
          displayedSelection = selection;
          return const SizedBox();
        },
      ),
    );
    _prepareView(tester);
    addTearDown(controller.dispose);
    addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(page(false));
    await tester.pumpAndSettle();
    expect(gps.requests, 0);
    expect(service.calls, isEmpty);

    await tester.pumpWidget(page(true));
    await tester.pumpAndSettle();
    expect(gps.requests, 1);
    expect(gps.permissionModes, [false]);
    expect(displayedSelection!.latitude, 35);
    expect(displayedSelection!.longitude, 129);
    expect(service.calls, ['현재 위치']);

    await tester.pumpWidget(page(true));
    await tester.pumpAndSettle();
    expect(
      gps.requests,
      1,
      reason: 'Rebuilding an open tab must not reread GPS.',
    );

    await tester.pumpWidget(page(false));
    await tester.pumpAndSettle();
    gps.onCurrent = () async =>
        MapLocation(name: '이동한 현재 위치', latitude: 36, longitude: 128);
    await tester.pumpWidget(page(true));
    await tester.pumpAndSettle();
    expect(gps.requests, 2);
    expect(gps.permissionModes, [false, false]);
    expect(displayedSelection!.latitude, 36);
    expect(displayedSelection!.longitude, 128);
    expect(service.calls, ['현재 위치', '이동한 현재 위치']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving the tab cancels an initial automatic location request', (
    tester,
  ) async {
    final pending = Completer<MapLocation>();
    final gps = _LocationGateway()
      ..permissionGranted = true
      ..onCurrent = () => pending.future;
    final controller = MapSelectionController(locationGateway: gps);
    final service = _ExternalService();
    final original = controller.selection;
    Widget page(bool isActive) => MaterialApp(
      home: MapPage(
        isActive: isActive,
        controller: controller,
        externalDataService: service,
        mapBuilder: (_, _, _) => const SizedBox(),
      ),
    );
    _prepareView(tester);
    addTearDown(controller.dispose);
    addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(page(true));
    await tester.pump();
    expect(gps.requests, 1);
    expect(controller.isLocating, isTrue);
    expect(service.calls, isEmpty);

    await tester.pumpWidget(page(false));
    await tester.pumpAndSettle();
    expect(controller.isLocating, isFalse);
    pending.complete(MapLocation(name: '늦은 GPS', latitude: 34, longitude: 127));
    await tester.pumpAndSettle();
    expect(controller.selection, same(original));
    expect(service.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'search automatically moves the map and forwards its place to a new record',
    (tester) async {
      final place = MapLocation(
        name: '영도 등대',
        address: '부산 영도구 전망로',
        latitude: 35.061,
        longitude: 129.08,
      );
      final gateway = _SearchGateway([place]);
      final controller = MapSelectionController(
        locationGateway: _LocationGateway(),
      )..setGateway(gateway);
      MapLocation? displayedSelection;
      await _openMap(
        tester,
        controller: controller,
        mapBuilder: (selection, _, _) {
          displayedSelection = selection;
          return const SizedBox(key: ValueKey('fake-map'));
        },
      );

      await tester.enterText(find.byType(TextField), '영도');
      await tester.tap(find.byTooltip('검색'));
      await tester.pumpAndSettle();
      expect(gateway.queries, ['영도']);
      expect(controller.selection, same(place));
      expect(displayedSelection, same(place));
      expect(controller.results.single, same(place));
      await _tap(tester, '기록 작성');

      final form = tester.widget<RecordFormPage>(find.byType(RecordFormPage));
      expect(form.initialLocation, place.name);
      expect(form.initialLatitude, place.latitude);
      expect(form.initialLongitude, place.longitude);
      expect(form.initialExternalData!.weather, '예보 날씨');
      expect(form.initialExternalData!.latitude, place.latitude);
      expect(form.initialExternalData!.longitude, place.longitude);
      expect(form.initialTide, isNull);
      expect(form.initialWaterTemperature, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'map detail keeps the selected coordinates when opening a record',
    (tester) async {
      final controller = MapSelectionController(
        locationGateway: _LocationGateway(),
        initialSelection: MapLocation(
          name: '선택한 항구',
          latitude: 34.8,
          longitude: 128.4,
        ),
      );
      await _openMap(tester, controller: controller);
      await _tap(tester, '자세히 보기');
      final detail = tester.widget<MapDetailPage>(find.byType(MapDetailPage));
      expect(detail.latitude, 34.8);
      expect(detail.longitude, 128.4);
      await _tap(tester, '기록 작성으로 이동');

      final form = tester.widget<RecordFormPage>(find.byType(RecordFormPage));
      expect(form.initialLocation, '선택한 항구');
      expect(form.initialLatitude, 34.8);
      expect(form.initialLongitude, 128.4);
      expect(form.initialExternalData, same(detail.externalData));
      expect(form.initialTide, isNull);
      expect(form.initialWaterTemperature, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'manual place replaces both the selected name and old coordinates',
    (tester) async {
      final controller = MapSelectionController(
        locationGateway: _LocationGateway(),
        initialSelection: MapLocation(
          name: '이전 지도 위치',
          latitude: 35,
          longitude: 129,
        ),
      );
      await _openMap(tester, controller: controller);
      await _tap(tester, '장소 직접 입력');
      final field = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == '위치명',
      );
      await tester.enterText(field, '  직접 적은 방파제  ');
      await _tap(tester, '위치 확정');
      expect(controller.selection.name, '직접 적은 방파제');
      expect(controller.selection.hasCoordinates, isFalse);
      await _tap(tester, '기록 작성');

      final form = tester.widget<RecordFormPage>(find.byType(RecordFormPage));
      expect(form.initialLocation, '직접 적은 방파제');
      expect(form.initialLatitude, isNull);
      expect(form.initialLongitude, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('guest can see the map but must log in to create a record', (
    tester,
  ) async {
    await auth.setSessionForTesting(plan: UserPlan.guest);
    final controller = MapSelectionController(
      locationGateway: _LocationGateway(),
    );
    await _openMap(tester, controller: controller);
    expect(find.byKey(const ValueKey('fake-map')), findsOneWidget);
    await _tap(tester, '기록 작성');
    expect(find.text('로그인이 필요합니다'), findsOneWidget);
    expect(find.byType(RecordFormPage), findsNothing);
    await _tap(tester, '나중에');
    expect(find.byType(MapPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late forecast response cannot replace a newer selected place', (
    tester,
  ) async {
    final controller = MapSelectionController(
      locationGateway: _LocationGateway(),
    );
    final service = _ExternalService(deferred: true);
    _prepareView(tester);
    addTearDown(controller.dispose);
    addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(
        home: MapPage(
          controller: controller,
          externalDataService: service,
          mapBuilder: (_, _, _) => const SizedBox(),
        ),
      ),
    );
    expect(service.calls, ['부산 영도구 동삼동']);
    controller.selectLocation(MapLocation(name: '새로 고른 항구'));
    await tester.pump();
    expect(service.calls, ['부산 영도구 동삼동', '새로 고른 항구']);
    service.pending[1].complete(_sample('새로 고른 항구', weather: '최신 날씨'));
    await tester.pumpAndSettle();
    service.pending[0].complete(_sample('부산 영도구 동삼동', weather: '이전 날씨'));
    await tester.pumpAndSettle();
    expect(find.text('최신 날씨'), findsOneWidget);
    expect(find.text('이전 날씨'), findsNothing);
    expect(controller.selection.name, '새로 고른 항구');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'weather setup failure allows manual records and explicit retry',
    (tester) async {
      const error = ExternalDataException(ExternalDataFailure.configuration);
      final service = _ExternalService(failure: error);
      final controller = MapSelectionController(
        locationGateway: _LocationGateway(),
        initialSelection: MapLocation(name: '항구', latitude: 35, longitude: 129),
      );
      await _openMap(
        tester,
        controller: controller,
        externalDataService: service,
      );
      expect(find.text(error.message), findsOneWidget);
      expect(service.locations.single.latitude, 35);
      expect(service.locations.single.longitude, 129);
      expect(service.forceRefreshes, [false]);
      await _tap(tester, '다시 조회');
      expect(service.forceRefreshes, [false, true]);
      await _tap(tester, '기록 작성');
      final form = tester.widget<RecordFormPage>(find.byType(RecordFormPage));
      expect(form.initialExternalData, isNull);
      expect(form.initialWeather, isNull);
      expect(form.initialAirTemperature, isNull);
      expect(form.initialTide, isNull);
      expect(form.initialWaterTemperature, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'partial forecast displays KST source times and manual marine data',
    (tester) async {
      final data = ExternalData(
        locationName: '항구',
        latitude: 35,
        longitude: 129,
        airTemperature: 18,
        gridX: 98,
        gridY: 74,
        issuedAt: DateTime.utc(2026, 11, 1, 23, 30),
        validAt: DateTime.utc(2026, 11, 2),
        fetchedAt: DateTime.utc(2026, 11, 2, 0, 10),
      );
      final controller = MapSelectionController(
        locationGateway: _LocationGateway(),
        initialSelection: MapLocation(name: '항구', latitude: 35, longitude: 129),
      );
      await _openMap(
        tester,
        controller: controller,
        externalDataService: _ExternalService(result: data),
      );
      expect(find.text('제공: 기상청 초단기예보'), findsOneWidget);
      expect(find.text('예보 격자: 98, 74'), findsOneWidget);
      expect(find.text('발표 기준: 2026.11.02 08:30 (KST)'), findsOneWidget);
      expect(find.text('예보: 2026.11.02 09:00 (KST)'), findsOneWidget);
      expect(find.text('정보 없음'), findsOneWidget);
      expect(find.text('18.0℃'), findsOneWidget);
      expect(find.text('수동 입력'), findsNWidgets(2));
      expect(find.textContaining('샘플'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'search keeps its map alive while waiting and displaying results',
    (tester) async {
      _prepareView(tester);
      final lifecycle = _MapLifecycle();
      final controller = MapSelectionController(
        locationGateway: _LocationGateway(),
      );
      addTearDown(controller.dispose);
      addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
      await tester.pumpWidget(
        MaterialApp(
          home: MapPage(
            controller: controller,
            externalDataService: _ExternalService(),
            mapBuilder: (_, onGatewayChanged, _) => _LifecycleMapCanvas(
              lifecycle: lifecycle,
              onGatewayChanged: onGatewayChanged,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(lifecycle.created, 1);
      expect(controller.isMapReady, isTrue);

      await tester.enterText(find.byType(TextField), '항구');
      await tester.tap(find.byTooltip('검색'));
      await tester.pump();
      expect(
        lifecycle.disposed,
        0,
        reason: 'Showing search progress must not dispose the live map.',
      );
      expect(lifecycle.created, 1);
      expect(controller.isSearching, isTrue);
      expect(lifecycle.queries, ['항구']);

      final results = _searchResults(6);
      lifecycle.response.complete(results);
      await tester.pumpAndSettle();
      expect(
        controller.results.map((place) => place.name),
        results.map((place) => place.name),
      );
      expect(find.widgetWithText(ListTile, '검색 항구 0'), findsOneWidget);
      expect(lifecycle.created, 1);
      expect(lifecycle.disposed, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'search results and scrolling preserve the active map until its tab closes',
    (tester) async {
      _prepareView(tester);
      tester.view.physicalSize = const Size(800, 900);
      final lifecycle = _MapLifecycle();
      final controller = MapSelectionController(
        locationGateway: _LocationGateway(),
      );
      Widget page(bool isActive) => MaterialApp(
        home: MapPage(
          isActive: isActive,
          controller: controller,
          externalDataService: _ExternalService(),
          mapBuilder: (_, onGatewayChanged, _) => _LifecycleMapCanvas(
            lifecycle: lifecycle,
            onGatewayChanged: onGatewayChanged,
          ),
        ),
      );
      addTearDown(controller.dispose);
      addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
      await tester.pumpWidget(page(true));
      await tester.pumpAndSettle();
      expect(lifecycle.created, 1);

      unawaited(controller.search('항구'));
      await tester.pump();
      lifecycle.response.complete(_searchResults(30));
      await tester.pumpAndSettle();
      expect(controller.results, hasLength(30));
      expect(
        find.byKey(const ValueKey('lifecycle-map')).hitTestable(),
        findsOneWidget,
        reason: 'Search results should leave the map visible above the list.',
      );
      expect(lifecycle.disposed, 0);

      await tester.drag(find.byType(ListView).first, const Offset(0, -2000));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('lifecycle-map')).hitTestable(),
        findsNothing,
      );
      await tester.drag(find.byType(ListView).first, const Offset(0, 2000));
      await tester.pumpAndSettle();
      expect(controller.results, hasLength(30));
      expect(lifecycle.created, 1);
      expect(lifecycle.disposed, 0);

      await tester.pumpWidget(page(false));
      await tester.pumpAndSettle();
      expect(
        lifecycle.disposed,
        1,
        reason: 'Leaving the map tab must release its map resources.',
      );
      expect(controller.isMapReady, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}

void _prepareView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 2200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _openMap(
  WidgetTester tester, {
  required MapSelectionController controller,
  MapCanvasBuilder? mapBuilder,
  ExternalDataService? externalDataService,
}) async {
  _prepareView(tester);
  addTearDown(controller.dispose);
  addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
  await tester.pumpWidget(
    MaterialApp(
      home: MapPage(
        controller: controller,
        externalDataService: externalDataService ?? _ExternalService(),
        mapBuilder:
            mapBuilder ??
            (_, _, _) => const SizedBox(key: ValueKey('fake-map')),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String text) async {
  final button = find.text(text);
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

ExternalData _sample(
  String name, {
  String? weather = '예보 날씨',
  double? airTemperature = 18,
  double latitude = 35,
  double longitude = 129,
}) {
  final now = DateTime.now().toUtc();
  final validAt = DateTime.utc(now.year, now.month, now.day, now.hour);
  return ExternalData(
    locationName: name,
    latitude: latitude,
    longitude: longitude,
    weather: weather,
    airTemperature: airTemperature,
    gridX: 98,
    gridY: 74,
    issuedAt: validAt.subtract(const Duration(minutes: 30)),
    validAt: validAt,
    fetchedAt: now,
  );
}

class _ExternalService implements ExternalDataService {
  _ExternalService({this.deferred = false, this.failure, this.result});
  final bool deferred;
  final ExternalDataException? failure;
  final ExternalData? result;
  final calls = <String>[];
  final locations = <MapLocation>[];
  final forceRefreshes = <bool>[];
  final pending = <Completer<ExternalData>>[];

  @override
  Future<ExternalData> fetchCurrentData({
    required MapLocation location,
    bool forceRefresh = false,
  }) {
    calls.add(location.name);
    locations.add(location);
    forceRefreshes.add(forceRefresh);
    if (failure != null) return Future.error(failure!);
    if (!deferred) {
      return Future.value(
        result ??
            _sample(
              location.name,
              latitude: location.latitude ?? 35,
              longitude: location.longitude ?? 129,
            ),
      );
    }
    final completer = Completer<ExternalData>();
    pending.add(completer);
    return completer.future;
  }
}

class _SearchGateway implements MapSearchGateway {
  _SearchGateway(this.results);
  final List<MapLocation> results;
  final queries = <String>[];

  @override
  Future<List<MapLocation>> search(String keyword) async {
    queries.add(keyword);
    return results;
  }

  @override
  Future<String?> addressForCoordinates(
    double latitude,
    double longitude,
  ) async => null;
}

class _LocationGateway implements CurrentLocationGateway {
  int requests = 0;
  bool permissionGranted = false;
  final permissionModes = <bool>[];
  Future<MapLocation> Function()? onCurrent;

  @override
  Future<MapLocation> currentLocation({bool requestPermission = true}) async {
    permissionModes.add(requestPermission);
    if (!requestPermission && !permissionGranted) {
      throw const CurrentLocationException(CurrentLocationFailure.denied);
    }
    requests++;
    return await onCurrent?.call() ??
        MapLocation(name: '현재 위치', latitude: 35, longitude: 129);
  }

  @override
  Future<bool> openAppSettings() async => true;

  @override
  Future<bool> openLocationSettings() async => true;
}

List<MapLocation> _searchResults(int count) => List.generate(
  count,
  (index) => MapLocation(
    name: '검색 항구 $index',
    latitude: 35 + index * 0.001,
    longitude: 129,
  ),
);

class _MapLifecycle {
  int created = 0;
  int disposed = 0;
  final queries = <String>[];
  final response = Completer<List<MapLocation>>();
}

class _LifecycleMapCanvas extends StatefulWidget {
  const _LifecycleMapCanvas({
    required this.lifecycle,
    required this.onGatewayChanged,
  });

  final _MapLifecycle lifecycle;
  final ValueChanged<MapSearchGateway?> onGatewayChanged;

  @override
  State<_LifecycleMapCanvas> createState() => _LifecycleMapCanvasState();
}

class _LifecycleMapCanvasState extends State<_LifecycleMapCanvas> {
  late final _LifecycleSearchGateway _gateway;

  @override
  void initState() {
    super.initState();
    widget.lifecycle.created++;
    _gateway = _LifecycleSearchGateway(widget.lifecycle);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onGatewayChanged(_gateway);
    });
  }

  @override
  void dispose() {
    widget.lifecycle.disposed++;
    _gateway.disposed = true;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(
    key: ValueKey('lifecycle-map'),
    color: Colors.transparent,
    child: SizedBox(height: 280),
  );
}

class _LifecycleSearchGateway implements MapSearchGateway {
  _LifecycleSearchGateway(this.lifecycle);
  final _MapLifecycle lifecycle;
  bool disposed = false;

  @override
  Future<List<MapLocation>> search(String keyword) async {
    lifecycle.queries.add(keyword);
    final response = await lifecycle.response.future;
    if (disposed) throw StateError('Map disposed while searching.');
    return response;
  }

  @override
  Future<String?> addressForCoordinates(
    double latitude,
    double longitude,
  ) async => null;
}
