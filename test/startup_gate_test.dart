import 'dart:async';

import 'package:fishing_build/data/services/app_startup_controller.dart';
import 'package:fishing_build/presentation/startup/startup_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _retryKey = ValueKey('startup-retry');
const _appKey = ValueKey('prepared-app');
const _app = MaterialApp(
  home: Scaffold(body: Text('Prepared app', key: _appKey)),
);

void main() {
  testWidgets(
    'waits to mount the app and calls onReady once after preparation',
    (tester) async {
      final finish = Completer<void>();
      final controller = AppStartupController(
        steps: [AppStartupStep(AppStartupStage.records, () => finish.future)],
      );
      addTearDown(controller.dispose);
      var appBuilds = 0;
      var readyCalls = 0;
      await tester.pumpWidget(
        StartupGate(
          controller: controller,
          onReady: () => readyCalls++,
          child: Builder(
            builder: (_) {
              appBuilds++;
              return _app;
            },
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('낚시 캘린더'), findsOneWidget);
      expect(find.byIcon(Icons.phishing), findsOneWidget);
      expect(find.text('기록을 불러오고 있습니다.'), findsNothing);
      expect(appBuilds, 0);
      expect(readyCalls, 0);

      finish.complete();
      await tester.pumpAndSettle();

      expect(find.byKey(_appKey), findsOneWidget);
      expect(readyCalls, 1);
      await controller.start();
      await tester.pump();
      await tester.pump();
      expect(readyCalls, 1);
    },
  );

  testWidgets('reports failure and rapid retry taps start only one attempt', (
    tester,
  ) async {
    var attempts = 0;
    var readyCalls = 0;
    final finishRetry = Completer<void>();
    final controller = AppStartupController(
      steps: [
        AppStartupStep(AppStartupStage.storage, () async {
          if (++attempts == 1) throw StateError('private database detail');
          await finishRetry.future;
        }),
      ],
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      StartupGate(
        controller: controller,
        onReady: () => readyCalls++,
        child: _app,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('앱을 시작하지 못했습니다.'), findsOneWidget);
    expect(
      find.textContaining(AppStartupStage.storage.failureMessage),
      findsOneWidget,
    );
    expect(find.textContaining('private database detail'), findsNothing);
    expect(find.byKey(_appKey), findsNothing);
    expect(readyCalls, 0);

    await tester.tap(find.byKey(_retryKey));
    await tester.tap(find.byKey(_retryKey));
    await tester.tap(find.byKey(_retryKey));
    await tester.pump();

    expect(attempts, 2);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byKey(_retryKey), findsNothing);
    expect(readyCalls, 0);

    finishRetry.complete();
    await tester.pumpAndSettle();

    expect(find.byKey(_appKey), findsOneWidget);
    expect(attempts, 2);
    expect(readyCalls, 1);
  });

  testWidgets('removing the gate ignores an in-flight completion', (
    tester,
  ) async {
    final finish = Completer<void>();
    final controller = AppStartupController(
      steps: [AppStartupStep(AppStartupStage.records, () => finish.future)],
    );
    addTearDown(controller.dispose);
    var readyCalls = 0;
    await tester.pumpWidget(
      StartupGate(
        controller: controller,
        onReady: () => readyCalls++,
        child: _app,
      ),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());

    finish.complete();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(readyCalls, 0);
    expect(find.byKey(_appKey), findsNothing);
  });

  testWidgets('removing the gate before its ready callback makes it harmless', (
    tester,
  ) async {
    final finish = Completer<void>();
    final controller = AppStartupController(
      steps: [AppStartupStep(AppStartupStage.records, () => finish.future)],
    );
    addTearDown(controller.dispose);
    var readyCalls = 0;
    await tester.pumpWidget(
      StartupGate(
        controller: controller,
        onReady: () => readyCalls++,
        child: _app,
      ),
    );
    await tester.pump();

    finish.complete();
    // Complete the controller without drawing the frame that delivers onReady.
    await tester.idle();
    expect(controller.state, AppStartupState.ready);
    expect(readyCalls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(readyCalls, 0);
  });

  testWidgets('the retry action remains reachable on a small screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(260, 220);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var attempts = 0;
    final controller = AppStartupController(
      steps: [
        AppStartupStep(AppStartupStage.records, () async {
          if (++attempts == 1) throw StateError('temporarily unavailable');
        }),
      ],
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      StartupGate(controller: controller, onReady: () {}, child: _app),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.byKey(_retryKey), 100);
    await tester.tap(find.byKey(_retryKey));
    await tester.pumpAndSettle();

    expect(find.byKey(_appKey), findsOneWidget);
    expect(attempts, 2);
    expect(tester.takeException(), isNull);
  });
}
