import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fishing_build/data/maps/map_location.dart';
import 'package:fishing_build/data/maps/water_area.dart';
import 'package:fishing_build/data/services/network_status_service.dart';
import 'package:fishing_build/data/tides/tide_models.dart';
import 'package:fishing_build/data/tides/tide_service.dart';
import 'package:fishing_build/data/tides/tide_station_catalog.dart';
import 'package:fishing_build/presentation/map/location_conditions_card.dart';
import 'package:fishing_build/presentation/map/tide_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _station = TideStation(
  code: 'DT_0018',
  name: 'Test station',
  latitude: 35,
  longitude: 129,
);
final _catalog = TideStationCatalog(stations: [_station]);
final _location = MapLocation(
  name: 'Test location',
  latitude: 35,
  longitude: 129,
);

void main() {
  late _Connectivity connectivity;

  setUp(() async {
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    connectivity = _Connectivity();
    await NetworkStatusService.instance.resetForTesting(gateway: connectivity);
    await NetworkStatusService.instance.initialize();
  });

  tearDown(() async {
    await NetworkStatusService.instance.close();
    await connectivity.events.close();
  });

  testWidgets('active today selection rolls over at KST midnight', (
    tester,
  ) async {
    final clock = _Clock(DateTime.utc(2026, 11, 3, 14, 59, 55));
    final service = _Tides(clock);
    final references = <TideRecordReference?>[];
    await tester.pumpWidget(
      _panel(service, clock, onReference: references.add),
    );
    await tester.pumpAndSettle();
    expect(service.days, [TideDay(2026, 11, 3)]);

    await clock.advance(tester, const Duration(seconds: 6));
    await tester.pumpAndSettle();

    expect(service.days, [TideDay(2026, 11, 3), TideDay(2026, 11, 4)]);
    expect(find.text('2026.11.04'), findsOneWidget);
    expect(references.last!.forecast.day, TideDay(2026, 11, 4));
    expect(_card(tester).tideName!.day, TideDay(2026, 11, 4));
  });

  testWidgets('an active forecast refreshes once its cache lifetime expires', (
    tester,
  ) async {
    final clock = _Clock(DateTime.utc(2026, 11, 3));
    final service = _Tides(clock);
    await tester.pumpWidget(_panel(service, clock));
    await tester.pumpAndSettle();

    await clock.advance(tester, const Duration(minutes: 9));
    expect(service.days, hasLength(1));
    await clock.advance(tester, const Duration(minutes: 1));
    await tester.pumpAndSettle();
    expect(service.days, hasLength(2));
    expect(service.days.last, TideDay(2026, 11, 3));
  });

  testWidgets(
    'fresh resumes do not fetch and background expiry waits for resume',
    (tester) async {
      final clock = _Clock(DateTime.utc(2026, 11, 3));
      final service = _Tides(clock);
      await tester.pumpWidget(_panel(service, clock));
      await tester.pumpAndSettle();
      for (var i = 0; i < 4; i++) {
        _pause(tester);
        _resume(tester);
        await tester.pumpAndSettle();
      }
      expect(service.days, hasLength(1));

      _pause(tester);
      await clock.advance(tester, const Duration(days: 1));
      expect(service.days, hasLength(1));
      _resume(tester);
      await tester.pumpAndSettle();
      expect(service.days, [TideDay(2026, 11, 3), TideDay(2026, 11, 4)]);
    },
  );

  testWidgets('a manually selected past day survives midnight and resume', (
    tester,
  ) async {
    final clock = _Clock(DateTime.utc(2026, 11, 3, 14, 59, 55));
    final service = _Tides(clock);
    await tester.pumpWidget(_panel(service, clock));
    await tester.pumpAndSettle();
    await _selectDay(tester, DateTime(2026, 11, 1));
    expect(service.days.last, TideDay(2026, 11, 1));

    await clock.advance(tester, const Duration(seconds: 6));
    expect(service.days, hasLength(2));
    expect(find.text('2026.11.01'), findsOneWidget);
    _pause(tester);
    await clock.advance(tester, const Duration(days: 2));
    _resume(tester);
    await tester.pumpAndSettle();

    expect(service.days, hasLength(3));
    expect(service.days.last, TideDay(2026, 11, 1));
    expect(_card(tester).tideName!.day, TideDay(2026, 11, 1));
  });

  testWidgets('explicitly selecting today keeps that date after midnight', (
    tester,
  ) async {
    final clock = _Clock(DateTime.utc(2026, 11, 3, 14, 59, 55));
    final service = _Tides(clock);
    await tester.pumpWidget(_panel(service, clock));
    await tester.pumpAndSettle();
    await _selectDay(tester, DateTime(2026, 11, 3));

    await clock.advance(tester, const Duration(seconds: 6));
    _pause(tester);
    _resume(tester);
    await tester.pumpAndSettle();

    expect(service.days, [TideDay(2026, 11, 3)]);
    expect(find.text('2026.11.03'), findsOneWidget);
  });

  testWidgets(
    'inactive panels wait for activation and retain fresh forecasts',
    (tester) async {
      final clock = _Clock(DateTime.utc(2026, 11, 3));
      final service = _Tides(clock);
      await tester.pumpWidget(_panel(service, clock, active: false));
      await tester.pumpAndSettle();
      await clock.advance(tester, const Duration(days: 1));
      _pause(tester);
      _resume(tester);
      await tester.pumpAndSettle();
      expect(service.days, isEmpty);

      await tester.pumpWidget(_panel(service, clock));
      await tester.pumpAndSettle();
      expect(service.days, [TideDay(2026, 11, 4)]);
      await tester.pumpWidget(_panel(service, clock, active: false));
      await tester.pumpWidget(_panel(service, clock));
      await tester.pumpAndSettle();
      expect(service.days, hasLength(1));

      await tester.pumpWidget(_panel(service, clock, active: false));
      await clock.advance(tester, const Duration(days: 1));
      expect(service.days, hasLength(1));
      await tester.pumpWidget(_panel(service, clock));
      await tester.pumpAndSettle();
      expect(service.days.last, TideDay(2026, 11, 5));
      expect(service.days, hasLength(2));
    },
  );

  testWidgets('resume and reactivation reuse the same pending request', (
    tester,
  ) async {
    final clock = _Clock(DateTime.utc(2026, 11, 3));
    final service = _Tides(clock, deferred: true);
    await tester.pumpWidget(_panel(service, clock));
    await tester.pump();
    for (var i = 0; i < 3; i++) {
      _pause(tester);
      _resume(tester);
      await tester.pump();
    }
    await tester.pumpWidget(_panel(service, clock, active: false));
    await tester.pumpWidget(_panel(service, clock));
    await tester.pump();
    expect(service.days, hasLength(1));

    service.complete(0);
    await tester.pumpAndSettle();
    expect(_card(tester).tideForecast, isNotNull);
    await clock.advance(tester, const Duration(minutes: 10));
    expect(service.days, hasLength(2));
    await tester.pumpWidget(const SizedBox.shrink());
    service.complete(1);
    _pause(tester);
    _resume(tester);
    await clock.advance(tester, const Duration(days: 1));
    expect(service.days, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a request completed in the background is reused on resume', (
    tester,
  ) async {
    final clock = _Clock(DateTime.utc(2026, 11, 3));
    final service = _Tides(clock, deferred: true);
    await tester.pumpWidget(_panel(service, clock));
    await tester.pump();
    _pause(tester);
    service.complete(0);
    await tester.pump();
    _resume(tester);
    await tester.pumpAndSettle();
    expect(service.days, hasLength(1));
    expect(_card(tester).tideForecast, isNotNull);
  });

  testWidgets(
    'a background failure replaces loading on resume without retrying',
    (tester) async {
      for (final failure in [TideFailure.network, TideFailure.configuration]) {
        final clock = _Clock(DateTime.utc(2026, 11, 3));
        final service = _Tides(clock, deferred: true);
        await tester.pumpWidget(_panel(service, clock));
        await tester.pump();
        expect(_card(tester).tideLoading, isTrue);

        _pause(tester);
        service.pending.single.completeError(TideException(failure));
        await tester.pump();
        _resume(tester);
        await tester.pumpAndSettle();

        expect(_card(tester).tideLoading, isFalse);
        expect(_card(tester).tideError, TideException(failure).message);
        expect(
          _card(tester).onRetryTide,
          failure == TideFailure.configuration ? isNull : isNotNull,
        );
        expect(service.days, hasLength(1));
        await clock.advance(tester, const Duration(minutes: 4));
        expect(service.days, hasLength(1));
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets('automatic failure retries wait five minutes despite resumes', (
    tester,
  ) async {
    final clock = _Clock(DateTime.utc(2026, 11, 3));
    final service = _Tides(clock, failure: TideFailure.network);
    await tester.pumpWidget(_panel(service, clock));
    await tester.pumpAndSettle();
    for (var i = 0; i < 4; i++) {
      _pause(tester);
      _resume(tester);
      await tester.pumpAndSettle();
    }
    expect(service.days, hasLength(1));
    await clock.advance(tester, const Duration(minutes: 4, seconds: 59));
    expect(service.days, hasLength(1));
    await clock.advance(tester, const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(service.days, hasLength(2));
  });

  testWidgets('configuration failures do not create automatic retry traffic', (
    tester,
  ) async {
    final clock = _Clock(DateTime.utc(2026, 11, 3, 14, 59, 55));
    final service = _Tides(clock, failure: TideFailure.configuration);
    await tester.pumpWidget(_panel(service, clock));
    await tester.pumpAndSettle();
    await clock.advance(tester, const Duration(hours: 1));
    _pause(tester);
    _resume(tester);
    await tester.pumpAndSettle();
    expect(service.days, hasLength(1));
    expect(find.text('2026.11.04'), findsOneWidget);
  });

  testWidgets('offline midnight changes the day without sending requests', (
    tester,
  ) async {
    // Create the network subscription inside the widget test's fake-time zone.
    await tester.runAsync(() => NetworkStatusService.instance.close());
    await NetworkStatusService.instance.initialize();
    final clock = _Clock(DateTime.utc(2026, 11, 3, 14, 59, 55));
    final service = _Tides(clock);
    await tester.pumpWidget(_panel(service, clock));
    await tester.pumpAndSettle();
    connectivity.setConnected(false);
    await tester.pumpAndSettle();

    await clock.advance(tester, const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(service.days, hasLength(1));
    expect(_card(tester).tideName!.day, TideDay(2026, 11, 4));
    expect(find.text('2026.11.04'), findsOneWidget);
    connectivity.setConnected(true);
    await tester.pumpAndSettle();
    expect(service.days.last, TideDay(2026, 11, 4));
    expect(service.days, hasLength(2));
  });

  testWidgets('offline to unknown to connected still recovers the forecast', (
    tester,
  ) async {
    await tester.runAsync(() => NetworkStatusService.instance.close());
    await NetworkStatusService.instance.initialize();
    final clock = _Clock(DateTime.utc(2026, 11, 3));
    final service = _Tides(clock);
    await tester.pumpWidget(_panel(service, clock));
    await tester.pumpAndSettle();
    connectivity.setConnected(false);
    await tester.pumpAndSettle();
    connectivity.events.addError(StateError('Temporary transport failure'));
    await tester.pumpAndSettle();
    expect(NetworkStatusService.instance.status, NetworkStatus.unknown);
    expect(service.days, hasLength(1));

    connectivity.setConnected(true);
    await tester.pumpAndSettle();
    expect(service.days, hasLength(2));
    expect(_card(tester).tideForecast, isNotNull);
  });

  testWidgets('network recovery retains the automatic failure retry cooldown', (
    tester,
  ) async {
    await tester.runAsync(() => NetworkStatusService.instance.close());
    await NetworkStatusService.instance.initialize();
    final clock = _Clock(DateTime.utc(2026, 11, 3));
    final service = _Tides(clock, failure: TideFailure.network);
    await tester.pumpWidget(_panel(service, clock));
    await tester.pumpAndSettle();
    connectivity.setConnected(false);
    await tester.pumpAndSettle();
    connectivity.setConnected(true);
    await tester.pumpAndSettle();
    expect(service.days, hasLength(1));

    await clock.advance(tester, const Duration(minutes: 5));
    await tester.pumpAndSettle();
    expect(service.days, hasLength(2));
  });
}

LocationConditionsCard _card(WidgetTester tester) =>
    tester.widget<LocationConditionsCard>(find.byType(LocationConditionsCard));

Widget _panel(
  TideService service,
  _Clock clock, {
  bool active = true,
  ValueChanged<TideRecordReference?>? onReference,
}) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: TidePanel(
        key: const ValueKey('fresh-tide-panel'),
        location: _location,
        waterArea: WaterArea.marine,
        isActive: active,
        service: service,
        catalog: _catalog,
        clock: clock.call,
        onReferenceChanged: onReference,
      ),
    ),
  ),
);

Future<void> _selectDay(WidgetTester tester, DateTime day) async {
  await tester.ensureVisible(find.byKey(const ValueKey('tide-date')));
  await tester.tap(find.byKey(const ValueKey('tide-date')));
  await tester.pumpAndSettle();
  Navigator.of(tester.element(find.byType(DatePickerDialog))).pop(day);
  await tester.pumpAndSettle();
}

void _pause(WidgetTester tester) =>
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);

void _resume(WidgetTester tester) =>
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

class _Clock {
  _Clock(this.now);
  DateTime now;
  DateTime call() => now;

  Future<void> advance(WidgetTester tester, Duration duration) async {
    now = now.add(duration);
    await tester.pump(duration);
  }
}

class _Tides implements TideService {
  _Tides(this.clock, {this.deferred = false, this.failure});
  final _Clock clock;
  final bool deferred;
  final TideFailure? failure;
  final days = <TideDay>[];
  final pending = <Completer<TideForecast>>[];

  @override
  Future<TideForecast> fetchForecast({
    required TideStation station,
    required TideDay day,
    bool forceRefresh = false,
  }) {
    days.add(day);
    if (failure != null) return Future.error(TideException(failure!));
    if (!deferred) return Future.value(_forecast(day));
    final request = Completer<TideForecast>();
    pending.add(request);
    return request.future;
  }

  void complete(int index) => pending[index].complete(_forecast(days[index]));

  TideForecast _forecast(TideDay day) => TideForecast(
    station: _station,
    day: day,
    fetchedAt: clock.now,
    events: [
      TideEvent(
        at: DateTime.utc(day.year, day.month, day.day, 1),
        heightCm: 120,
        kind: TideEventKind.high,
      ),
    ],
  );
}

class _Connectivity implements ConnectivityGateway {
  final events = StreamController<List<ConnectivityResult>>.broadcast();

  void setConnected(bool connected) => events.add([
    connected ? ConnectivityResult.wifi : ConnectivityResult.none,
  ]);

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => [
    ConnectivityResult.wifi,
  ];

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => events.stream;
}
