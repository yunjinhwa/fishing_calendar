import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fishing_build/app.dart';
import 'package:fishing_build/data/services/network_status_service.dart';
import 'package:fishing_build/presentation/offline/network_status_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NetworkStatusService', () {
    test(
      'initial check reports disconnected when no network is available',
      () async {
        final gateway = FakeConnectivityGateway(
          checkResults: const <ConnectivityResult>[ConnectivityResult.none],
        );
        final checkedAt = DateTime(2026, 9, 21, 10, 30);
        final service = _createService(gateway, now: () => checkedAt);

        await service.initialize();

        expect(service.status, NetworkStatus.disconnected);
        expect(service.connectivityResults, const <ConnectivityResult>[
          ConnectivityResult.none,
        ]);
        expect(service.lastCheckedAt, checkedAt);
        expect(service.lastError, isNull);
        expect(service.isChecking, isFalse);
      },
    );

    test('initial check treats any usable transport as connected', () async {
      final gateway = FakeConnectivityGateway(
        checkResults: const <ConnectivityResult>[
          ConnectivityResult.wifi,
          ConnectivityResult.mobile,
        ],
      );
      final service = _createService(gateway);

      await service.initialize();

      expect(service.status, NetworkStatus.connected);
      expect(service.connectivityResults, const <ConnectivityResult>[
        ConnectivityResult.wifi,
        ConnectivityResult.mobile,
      ]);
      expect(
        () => service.connectivityResults.add(ConnectivityResult.ethernet),
        throwsUnsupportedError,
      );
    });

    test('stream events update connected and disconnected state', () async {
      final gateway = FakeConnectivityGateway(
        checkResults: const <ConnectivityResult>[ConnectivityResult.none],
      );
      final service = _createService(gateway);
      await service.initialize();

      gateway.emit(const <ConnectivityResult>[ConnectivityResult.wifi]);
      await _flushEvents();

      expect(service.status, NetworkStatus.connected);
      expect(service.connectivityResults, const <ConnectivityResult>[
        ConnectivityResult.wifi,
      ]);

      gateway.emit(const <ConnectivityResult>[ConnectivityResult.none]);
      await _flushEvents();

      expect(service.status, NetworkStatus.disconnected);
      expect(service.connectivityResults, const <ConnectivityResult>[
        ConnectivityResult.none,
      ]);
    });

    test('refresh failure becomes unknown and does not escape', () async {
      final gateway = FakeConnectivityGateway(
        checkResults: const <ConnectivityResult>[ConnectivityResult.wifi],
      );
      final service = _createService(gateway);
      await service.initialize();
      final error = StateError('connectivity check failed');
      gateway.checkError = error;

      final result = await service.refresh();

      expect(result, NetworkStatus.unknown);
      expect(service.status, NetworkStatus.unknown);
      expect(service.connectivityResults, isEmpty);
      expect(service.lastError, same(error));
      expect(service.lastErrorStackTrace, isNotNull);
      expect(service.isChecking, isFalse);
    });

    test(
      'repeated initialize calls create only one stream subscription',
      () async {
        final initialCheck = Completer<List<ConnectivityResult>>();
        final gateway = FakeConnectivityGateway(pendingCheck: initialCheck);
        final service = _createService(gateway);

        final first = service.initialize();
        final second = service.initialize();

        expect(gateway.listenCount, 1);
        expect(gateway.checkCount, 1);

        initialCheck.complete(const <ConnectivityResult>[
          ConnectivityResult.mobile,
        ]);
        await Future.wait(<Future<void>>[first, second]);
        await service.initialize();

        expect(gateway.listenCount, 1);
        expect(gateway.checkCount, 1);
      },
    );

    test('initialize restores a connectivity stream that has ended', () async {
      final gateway = FakeConnectivityGateway(
        checkResults: const <ConnectivityResult>[ConnectivityResult.wifi],
      );
      final service = _createService(gateway);
      await service.initialize();

      expect(service.isInitialized, isTrue);
      expect(gateway.listenCount, 1);

      await gateway.finishStream();
      await _flushEvents();
      expect(service.isInitialized, isFalse);

      gateway.reopenStream();
      await service.initialize();

      expect(service.isInitialized, isTrue);
      expect(gateway.listenCount, 2);
      expect(gateway.checkCount, 2);
    });

    test(
      'concurrent refresh calls share a single connectivity check',
      () async {
        final check = Completer<List<ConnectivityResult>>();
        final gateway = FakeConnectivityGateway(pendingCheck: check);
        final service = _createService(gateway);

        final first = service.refresh();
        final second = service.refresh();

        expect(gateway.checkCount, 1);
        expect(identical(first, second), isTrue);

        check.complete(const <ConnectivityResult>[ConnectivityResult.wifi]);

        expect(await first, NetworkStatus.connected);
        expect(await second, NetworkStatus.connected);
        expect(gateway.checkCount, 1);
      },
    );

    test(
      'late initial check does not overwrite a newer stream event',
      () async {
        final initialCheck = Completer<List<ConnectivityResult>>();
        final gateway = FakeConnectivityGateway(pendingCheck: initialCheck);
        final service = _createService(gateway);

        final initialization = service.initialize();
        gateway.emit(const <ConnectivityResult>[ConnectivityResult.wifi]);
        await _flushEvents();
        expect(service.status, NetworkStatus.connected);

        initialCheck.complete(const <ConnectivityResult>[
          ConnectivityResult.none,
        ]);
        await initialization;

        expect(service.status, NetworkStatus.connected);
        expect(service.connectivityResults, const <ConnectivityResult>[
          ConnectivityResult.wifi,
        ]);
      },
    );

    test('close ignores connectivity events that arrive later', () async {
      final gateway = FakeConnectivityGateway(
        checkResults: const <ConnectivityResult>[ConnectivityResult.none],
      );
      final service = _createService(gateway);
      await service.initialize();
      var notificationCount = 0;
      service.addListener(() => notificationCount += 1);

      await service.close();
      final notificationsAfterClose = notificationCount;
      gateway.emit(const <ConnectivityResult>[ConnectivityResult.wifi]);
      await _flushEvents();

      expect(service.status, NetworkStatus.disconnected);
      expect(notificationCount, notificationsAfterClose);
    });
  });

  testWidgets('retry button refreshes status and shows the result', (
    tester,
  ) async {
    final gateway = FakeConnectivityGateway(
      checkResults: const <ConnectivityResult>[ConnectivityResult.none],
    );
    final service = _createService(gateway);
    await service.initialize();
    gateway.checkResults = const <ConnectivityResult>[ConnectivityResult.wifi];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: NetworkStatusRetryButton(service: service)),
      ),
    );

    await tester.tap(find.byType(TextButton));
    await tester.pumpAndSettle();

    expect(gateway.checkCount, 2);
    expect(service.status, NetworkStatus.connected);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('네트워크 연결이 확인되었습니다.'), findsOneWidget);
  });

  testWidgets('app resume refreshes the current connectivity status', (
    tester,
  ) async {
    final gateway = FakeConnectivityGateway(
      checkResults: const <ConnectivityResult>[ConnectivityResult.wifi],
    );
    final service = _createService(gateway);

    await tester.pumpWidget(FishingBuildApp(networkStatusService: service));
    await tester.pump();
    expect(gateway.checkCount, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(gateway.checkCount, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();

    expect(gateway.checkCount, 2);
    expect(service.status, NetworkStatus.connected);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}

NetworkStatusService _createService(
  FakeConnectivityGateway gateway, {
  DateTime Function()? now,
}) {
  final service = NetworkStatusService(gateway: gateway, now: now);
  addTearDown(() async {
    await service.close();
    await gateway.dispose();
  });
  return service;
}

Future<void> _flushEvents() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

class FakeConnectivityGateway implements ConnectivityGateway {
  FakeConnectivityGateway({
    this.checkResults = const <ConnectivityResult>[ConnectivityResult.none],
    this.pendingCheck,
  }) {
    _openStream();
  }

  List<ConnectivityResult> checkResults;
  Completer<List<ConnectivityResult>>? pendingCheck;
  Object? checkError;
  int checkCount = 0;
  int listenCount = 0;

  late StreamController<List<ConnectivityResult>> _controller;

  @override
  Future<List<ConnectivityResult>> checkConnectivity() {
    checkCount += 1;
    final error = checkError;
    if (error != null) {
      return Future<List<ConnectivityResult>>.error(error);
    }

    final pending = pendingCheck;
    if (pending != null) {
      return pending.future;
    }

    return Future<List<ConnectivityResult>>.value(checkResults);
  }

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      _controller.stream;

  void emit(List<ConnectivityResult> results) {
    if (!_controller.isClosed) {
      _controller.add(results);
    }
  }

  Future<void> finishStream() => _controller.close();

  void reopenStream() {
    if (!_controller.isClosed) {
      throw StateError('The previous connectivity stream is still open.');
    }
    _openStream();
  }

  void _openStream() {
    _controller = StreamController<List<ConnectivityResult>>.broadcast(
      onListen: () => listenCount += 1,
    );
  }

  Future<void> dispose() => _controller.close();
}
