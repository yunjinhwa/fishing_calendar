import 'dart:async';

import 'package:fishing_build/data/services/app_startup_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'successful startup runs in order and stays ready on later starts',
    () async {
      final calls = <String>[];
      final controller = AppStartupController(
        steps: [
          AppStartupStep(AppStartupStage.storage, () async {
            calls.add('storage');
          }),
          AppStartupStep(AppStartupStage.records, () async {
            calls.add('records');
          }),
        ],
      );
      addTearDown(controller.dispose);

      await controller.start();
      await controller.start();

      expect(controller.state, AppStartupState.ready);
      expect(calls, ['storage', 'records']);
    },
  );

  test(
    'retry resumes the failed step without repeating completed work',
    () async {
      var storageCalls = 0;
      var recordCalls = 0;
      var serviceCalls = 0;
      final failure = StateError('records are temporarily unavailable');
      final controller = AppStartupController(
        steps: [
          AppStartupStep(AppStartupStage.storage, () async {
            storageCalls++;
          }),
          AppStartupStep(AppStartupStage.records, () async {
            if (++recordCalls == 1) throw failure;
          }),
          AppStartupStep(AppStartupStage.services, () async {
            serviceCalls++;
          }),
        ],
      );
      addTearDown(controller.dispose);

      await controller.start();

      expect(controller.state, AppStartupState.failed);
      expect(controller.stage, AppStartupStage.records);
      expect(controller.lastError, same(failure));
      expect(controller.lastErrorStackTrace, isNotNull);
      expect(serviceCalls, 0);

      await controller.start();

      expect(controller.state, AppStartupState.ready);
      expect(storageCalls, 1);
      expect(recordCalls, 2);
      expect(serviceCalls, 1);
      expect(controller.lastError, isNull);
      expect(controller.lastErrorStackTrace, isNull);
    },
  );

  test('concurrent calls and a reentrant listener share one startup', () async {
    final started = Completer<void>();
    final finish = Completer<void>();
    var calls = 0;
    final controller = AppStartupController(
      steps: [
        AppStartupStep(AppStartupStage.storage, () async {
          calls++;
          started.complete();
          await finish.future;
        }),
      ],
    );
    addTearDown(controller.dispose);
    Future<void>? reentrant;
    controller.addListener(() {
      if (controller.state == AppStartupState.loading) {
        reentrant ??= controller.start();
      }
    });

    final first = controller.start();
    final second = controller.start();
    await started.future;

    expect(second, same(first));
    expect(reentrant, same(first));
    expect(calls, 1);

    finish.complete();
    await Future.wait([first, second, reentrant!]);

    expect(controller.state, AppStartupState.ready);
    expect(calls, 1);
  });

  test('a second failure remains retryable with its current error', () async {
    var attempts = 0;
    final failures = [
      StateError('first failure'),
      StateError('second failure'),
    ];
    final controller = AppStartupController(
      steps: [
        AppStartupStep(AppStartupStage.storage, () async {
          final attempt = attempts++;
          if (attempt < failures.length) throw failures[attempt];
        }),
      ],
    );
    addTearDown(controller.dispose);

    await controller.start();
    expect(controller.lastError, same(failures[0]));

    await controller.start();
    expect(controller.state, AppStartupState.failed);
    expect(controller.lastError, same(failures[1]));

    await controller.start();
    expect(controller.state, AppStartupState.ready);
    expect(attempts, 3);
  });

  test(
    'disposal during a step stops later work and late notifications',
    () async {
      final started = Completer<void>();
      final finish = Completer<void>();
      var laterCalls = 0;
      var notifications = 0;
      final controller = AppStartupController(
        steps: [
          AppStartupStep(AppStartupStage.storage, () async {
            started.complete();
            await finish.future;
          }),
          AppStartupStep(AppStartupStage.records, () async {
            laterCalls++;
          }),
        ],
      );
      controller.addListener(() => notifications++);

      final pending = controller.start();
      await started.future;
      controller.dispose();
      final notificationsAtDisposal = notifications;
      finish.complete();
      await pending;
      await controller.start();

      expect(laterCalls, 0);
      expect(notifications, notificationsAtDisposal);
    },
  );
}
