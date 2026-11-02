import 'dart:async';

import 'package:fishing_build/data/maps/current_location_gateway.dart';
import 'package:fishing_build/data/maps/map_location.dart';
import 'package:fishing_build/data/maps/map_search_gateway.dart';
import 'package:fishing_build/presentation/map/map_selection_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _LocationGateway location;
  late _SearchGateway search;
  late MapSelectionController controller;

  setUp(() {
    location = _LocationGateway();
    search = _SearchGateway();
    controller = MapSelectionController(locationGateway: location);
  });

  tearDown(() => controller.dispose());

  test(
    'initial and manual selections do not request location or map services',
    () {
      expect(controller.selection.name, '부산 영도구 동삼동');
      expect(controller.selection.hasCoordinates, isFalse);
      controller.selectLocation(MapLocation(name: '수동 방파제'));
      expect(controller.selection.name, '수동 방파제');
      expect(location.calls, 0);
      expect(search.queries, isEmpty);
      expect(search.points, isEmpty);
    },
  );

  test(
    'missing gateway and empty search provide useful errors without requests',
    () async {
      await controller.search('바다');
      expect(controller.errorMessage, contains('지도가 준비된 뒤'));
      controller.setGateway(search);
      await controller.search('  ');
      expect(controller.errorMessage, contains('입력하세요'));
      expect(search.queries, isEmpty);
      expect(controller.isSearching, isFalse);
      expect(location.calls, 0);
    },
  );

  test(
    'search selects the first valid point and retains immutable alternatives',
    () async {
      controller.setGateway(search);
      final found = _point('영도 방파제');
      final alternative = _point('다른 방파제', latitude: 34, longitude: 128);
      final source = [MapLocation(name: '좌표 없는 응답'), found, alternative];
      search.onSearch = (_) async => source;
      await controller.search('  영도  ');
      expect(search.queries, ['영도']);
      expect(controller.results, [found, alternative]);
      expect(() => controller.results.clear(), throwsUnsupportedError);
      expect(controller.selection, same(found));
      expect(controller.selection.latitude, 35);
      expect(controller.selection.longitude, 129);
      expect(search.points, isEmpty);
      source.clear();
      expect(controller.results, [found, alternative]);
      controller.selectLocation(alternative);
      expect(controller.selection, same(alternative));
      expect(controller.results, isEmpty);
    },
  );

  test('empty results and failed searches are retryable', () async {
    controller.setGateway(search);
    final original = _point('기존 선택', latitude: 36, longitude: 127);
    controller.selectLocation(original);
    await controller.search('없는 장소');
    expect(controller.errorMessage, contains('검색 결과가 없습니다'));
    expect(controller.selection, same(original));
    expect(controller.results, isEmpty);
    search.onSearch = (_) async => throw StateError('backend failure');
    await controller.search('장소');
    expect(controller.errorMessage, contains('다시 시도'));
    expect(controller.isSearching, isFalse);
    expect(controller.selection, same(original));
    expect(controller.results, isEmpty);
    final recovered = _point('복구된 장소');
    search.onSearch = (_) async => [recovered];
    await controller.search('장소');
    expect(controller.errorMessage, isNull);
    expect(controller.results.single, same(recovered));
    expect(controller.selection, same(recovered));
    search.onSearch = (_) async => [MapLocation(name: '좌표 없는 장소')];
    await controller.search('좌표 없음');
    expect(controller.errorMessage, contains('검색 결과가 없습니다'));
    expect(controller.results, isEmpty);
    expect(controller.selection, same(recovered));
  });

  test(
    'late old searches cannot replace newer results or a manual selection',
    () async {
      controller.setGateway(search);
      final first = Completer<List<MapLocation>>();
      final second = Completer<List<MapLocation>>();
      search.onSearch = (query) =>
          query == '첫 검색' ? first.future : second.future;
      final old = controller.search('첫 검색');
      final newest = controller.search('새 검색');
      final latest = _point('새 결과', latitude: 37, longitude: 126);
      second.complete([latest]);
      await newest;
      first.complete([_point('옛 결과')]);
      await old;
      expect(controller.results.single.name, '새 결과');
      expect(controller.selection, same(latest));

      for (final lateFailure in [false, true]) {
        final late = Completer<List<MapLocation>>();
        search.onSearch = (_) => late.future;
        final loading = controller.search('진행 중');
        final manual = MapLocation(name: '직접 선택');
        controller.selectLocation(manual);
        if (lateFailure) {
          late.completeError(StateError('late failure'));
        } else {
          late.complete([_point('늦게 도착한 결과')]);
        }
        await loading;
        expect(controller.selection, same(manual));
        expect(controller.selection.hasCoordinates, isFalse);
        expect(controller.results, isEmpty);
        expect(controller.errorMessage, isNull);
        expect(controller.isSearching, isFalse);
      }
    },
  );

  test(
    'a selected point keeps exact coordinates if its address cannot be resolved',
    () async {
      controller.setGateway(search);
      search.onAddress = (_, _) async =>
          throw StateError('address unavailable');
      await controller.selectCoordinates(35.179612345, 129.075612345);
      expect(controller.selection.name, '지도에서 선택한 위치');
      expect(controller.selection.latitude, 35.179612345);
      expect(controller.selection.longitude, 129.075612345);
      expect(controller.errorMessage, contains('좌표는 유지'));
      expect(controller.isResolving, isFalse);
      search.onAddress = (_, _) async => null;
      await controller.selectCoordinates(0, 0);
      expect(controller.selection.latitude, 0);
      expect(controller.selection.longitude, 0);
      expect(controller.errorMessage, isNull);
    },
  );

  test('point addresses cannot overwrite a newer selected place', () async {
    controller.setGateway(search);
    final late = Completer<String?>();
    search.onAddress = (_, _) => late.future;
    final loading = controller.selectCoordinates(35, 129);
    expect(controller.isResolving, isTrue);
    controller.selectLocation(_point('새 장소', latitude: 37, longitude: 126));
    late.complete('이전 주소');
    await loading;
    expect(controller.selection.name, '새 장소');
    expect(controller.selection.latitude, 37);
    expect(controller.isResolving, isFalse);
  });

  test(
    'detaching a gateway cancels search and reverse responses while keeping selection',
    () async {
      controller.setGateway(search);
      final late = Completer<String?>();
      search.onAddress = (_, _) => late.future;
      final loading = controller.selectCoordinates(35, 129);
      controller.setGateway(null);
      expect(controller.isMapReady, isFalse);
      expect(controller.isResolving, isFalse);
      late.complete('이전 SDK 주소');
      await loading;
      expect(controller.selection.name, '지도에서 선택한 위치');
      expect(controller.selection.longitude, 129);

      controller.setGateway(search);
      final lateSearch = Completer<List<MapLocation>>();
      search.onSearch = (_) => lateSearch.future;
      final searching = controller.search('검색');
      controller.setGateway(_SearchGateway());
      lateSearch.complete([_point('이전 SDK 결과')]);
      await searching;
      expect(controller.results, isEmpty);
      expect(controller.isSearching, isFalse);
      expect(controller.selection.name, '지도에서 선택한 위치');
      expect(controller.selection.longitude, 129);
    },
  );

  test(
    'current position requires an explicit request and can work without a map',
    () async {
      final gate = Completer<MapLocation>();
      location.onCurrent = () => gate.future;
      expect(location.calls, 0);
      final loading = controller.useCurrentLocation();
      expect(location.calls, 1);
      expect(location.permissionModes, [true]);
      expect(controller.isLocating, isTrue);
      gate.complete(_point('현재 위치'));
      await loading;
      expect(controller.selection.name, '현재 위치');
      expect(controller.selection.latitude, 35);
      expect(controller.isLocating, isFalse);
      expect(search.points, isEmpty);
    },
  );

  test(
    'an existing grant can locate automatically without prompting',
    () async {
      location.permissionGranted = true;
      controller.setGateway(search);
      search.onAddress = (_, _) async => '자동으로 찾은 주소';

      await controller.useCurrentLocation(requestPermission: false);

      expect(location.permissionModes, [false]);
      expect(location.calls, 1);
      expect(controller.selection.name, '자동으로 찾은 주소');
      expect(controller.selection.latitude, 35);
      expect(controller.selection.longitude, 129);
      expect(controller.isLocating, isFalse);
      expect(controller.isResolving, isFalse);
      expect(controller.errorMessage, isNull);
    },
  );

  test(
    'automatic location quietly preserves the selection if unavailable',
    () async {
      final original = _point('보존할 장소');
      controller.selectLocation(original);
      await controller.useCurrentLocation(requestPermission: false);
      expect(location.permissionModes, [false]);
      expect(location.calls, 0);
      expect(controller.selection, same(original));
      expect(controller.errorMessage, isNull);
      expect(controller.locationFailure, isNull);

      location.permissionGranted = true;
      for (final reason in [
        CurrentLocationFailure.denied,
        CurrentLocationFailure.deniedForever,
        CurrentLocationFailure.serviceDisabled,
        CurrentLocationFailure.unavailable,
      ]) {
        location.onCurrent = () async => throw CurrentLocationException(reason);
        await controller.useCurrentLocation(requestPermission: false);
        expect(controller.selection, same(original));
        expect(controller.errorMessage, isNull);
        expect(controller.locationFailure, isNull);
        expect(controller.isLocating, isFalse);
      }

      location.onCurrent = () async =>
          throw const CurrentLocationException(CurrentLocationFailure.timedOut);
      await controller.useCurrentLocation(requestPermission: false);
      expect(controller.selection, same(original));
      expect(controller.locationFailure, CurrentLocationFailure.timedOut);
      expect(controller.errorMessage, contains('다시 시도'));
      expect(controller.isLocating, isFalse);
    },
  );

  test(
    'late manual and automatic GPS fixes cannot replace a newer selection',
    () async {
      controller.setGateway(search);
      location.permissionGranted = true;
      for (final requestPermission in [true, false]) {
        final late = Completer<MapLocation>();
        location.onCurrent = () => late.future;
        final loading = controller.useCurrentLocation(
          requestPermission: requestPermission,
        );
        controller.selectLocation(MapLocation(name: '직접 입력한 위치'));
        late.complete(_point('오래된 GPS'));
        await loading;
        expect(controller.selection.name, '직접 입력한 위치');
        expect(controller.selection.hasCoordinates, isFalse);
        expect(controller.isLocating, isFalse);
        expect(search.points, isEmpty);
      }
    },
  );

  test('an automatic GPS fix cannot replace a newer search result', () async {
    controller.setGateway(search);
    location.permissionGranted = true;
    final late = Completer<MapLocation>();
    location.onCurrent = () => late.future;
    final loading = controller.useCurrentLocation(requestPermission: false);
    final result = _point('직접 검색한 항구', latitude: 34, longitude: 128);
    search.onSearch = (_) async => [result];

    await controller.search('항구');
    late.complete(_point('늦은 자동 위치'));
    await loading;

    expect(controller.selection, same(result));
    expect(controller.results.single, same(result));
    expect(controller.isLocating, isFalse);
    expect(controller.errorMessage, isNull);
    expect(search.points, isEmpty);
  });

  test(
    'cancelling location drops late fixes and failures after a tab exit',
    () async {
      location.permissionGranted = true;
      final original = _point('기존 선택');
      for (final lateFailure in [false, true]) {
        controller.selectLocation(original);
        final late = Completer<MapLocation>();
        location.onCurrent = () => late.future;
        final loading = controller.useCurrentLocation(requestPermission: false);
        expect(controller.isLocating, isTrue);

        controller.cancelPendingLocation();
        expect(controller.isLocating, isFalse);
        if (lateFailure) {
          late.completeError(
            const CurrentLocationException(CurrentLocationFailure.timedOut),
          );
        } else {
          late.complete(_point('늦은 자동 위치'));
        }
        await loading;
        expect(controller.selection, same(original));
        expect(controller.errorMessage, isNull);
        expect(controller.locationFailure, isNull);
        expect(controller.isLocating, isFalse);
      }
    },
  );

  test('cancelling location also drops an in-flight address lookup', () async {
    controller.setGateway(search);
    location.permissionGranted = true;
    final address = Completer<String?>();
    final resolving = Completer<void>();
    search.onAddress = (_, _) {
      resolving.complete();
      return address.future;
    };
    final loading = controller.useCurrentLocation(requestPermission: false);
    await resolving.future;
    expect(controller.isResolving, isTrue);
    final point = controller.selection;

    controller.cancelPendingLocation();
    address.complete('늦게 도착한 주소');
    await loading;

    expect(controller.selection, same(point));
    expect(controller.isResolving, isFalse);
    expect(controller.isLocating, isFalse);
    expect(controller.errorMessage, isNull);
  });

  test(
    'GPS can use a gateway that becomes ready while permission is pending',
    () async {
      final late = Completer<MapLocation>();
      location.onCurrent = () => late.future;
      final loading = controller.useCurrentLocation();
      search.onAddress = (_, _) async => '현재 GPS 주소';
      controller.setGateway(search);
      late.complete(_point('현재 위치'));
      await loading;
      expect(controller.selection.name, '현재 GPS 주소');
      expect(controller.selection.latitude, 35);
      expect(search.points, [(35.0, 129.0)]);
      expect(controller.isLocating, isFalse);
      expect(controller.isResolving, isFalse);
    },
  );

  test(
    'permission, service and timeout failures keep the prior choice and can clear',
    () async {
      for (final reason in CurrentLocationFailure.values) {
        controller.selectLocation(_point('보존할 선택'));
        location.onCurrent = () async => throw CurrentLocationException(reason);
        await controller.useCurrentLocation();
        expect(controller.locationFailure, reason);
        expect(controller.errorMessage, isNotEmpty);
        expect(controller.selection.name, '보존할 선택');
        expect(controller.isLocating, isFalse);
        controller.clearError();
        expect(controller.locationFailure, isNull);
        expect(controller.errorMessage, isNull);
      }
    },
  );

  test(
    'invalid points and incomplete GPS results do not erase a valid selection',
    () async {
      controller.selectLocation(_point('원래 위치'));
      await controller.selectCoordinates(91, 129);
      expect(controller.selection.name, '원래 위치');
      expect(controller.errorMessage, isNotNull);
      location.onCurrent = () async => MapLocation(name: '좌표 없는 응답');
      await controller.useCurrentLocation();
      expect(controller.selection.name, '원래 위치');
      expect(controller.locationFailure, CurrentLocationFailure.unavailable);
    },
  );

  test(
    'settings open only when requested and failures are reported as false',
    () async {
      expect(location.appSettingsCalls, 0);
      expect(location.locationSettingsCalls, 0);
      expect(await controller.openAppSettings(), isTrue);
      expect(await controller.openLocationSettings(), isTrue);
      expect(location.appSettingsCalls, 1);
      expect(location.locationSettingsCalls, 1);
      location.failSettings = true;
      expect(await controller.openAppSettings(), isFalse);
      expect(await controller.openLocationSettings(), isFalse);
      expect(controller.selection.name, '부산 영도구 동삼동');
    },
  );

  test('dispose drops every late result without notifying listeners', () async {
    controller.setGateway(search);
    final late = Completer<String?>();
    search.onAddress = (_, _) => late.future;
    final loading = controller.selectCoordinates(35, 129);
    var notifications = 0;
    controller.addListener(() => notifications++);
    controller.dispose();
    late.complete('늦은 주소');
    await loading;
    expect(notifications, 0);
    // A fresh instance lets the shared tearDown dispose safely once.
    controller = MapSelectionController(locationGateway: location);
  });
}

MapLocation _point(
  String name, {
  double latitude = 35,
  double longitude = 129,
}) => MapLocation(name: name, latitude: latitude, longitude: longitude);

class _SearchGateway implements MapSearchGateway {
  final queries = <String>[];
  final points = <(double, double)>[];
  Future<List<MapLocation>> Function(String)? onSearch;
  Future<String?> Function(double, double)? onAddress;

  @override
  Future<List<MapLocation>> search(String keyword) {
    queries.add(keyword);
    return onSearch?.call(keyword) ?? Future.value([]);
  }

  @override
  Future<String?> addressForCoordinates(double latitude, double longitude) {
    points.add((latitude, longitude));
    return onAddress?.call(latitude, longitude) ?? Future.value(null);
  }
}

class _LocationGateway implements CurrentLocationGateway {
  int calls = 0;
  final permissionModes = <bool>[];
  bool permissionGranted = false;
  int appSettingsCalls = 0;
  int locationSettingsCalls = 0;
  bool failSettings = false;
  Future<MapLocation> Function()? onCurrent;

  @override
  Future<MapLocation> currentLocation({bool requestPermission = true}) {
    permissionModes.add(requestPermission);
    if (!requestPermission && !permissionGranted) {
      return Future.error(
        const CurrentLocationException(CurrentLocationFailure.denied),
      );
    }
    calls++;
    return onCurrent?.call() ?? Future.value(_point('현재 위치'));
  }

  @override
  Future<bool> openAppSettings() async {
    appSettingsCalls++;
    if (failSettings) throw StateError('Settings unavailable');
    return true;
  }

  @override
  Future<bool> openLocationSettings() async {
    locationSettingsCalls++;
    if (failSettings) throw StateError('Settings unavailable');
    return true;
  }
}
