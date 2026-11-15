import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import '../auth/firebase_auth_bootstrap.dart';
import '../local/app_database.dart';
import '../remote/firebase_record_sync_bootstrap.dart';
import '../repositories/auth_session_repository.dart';
import '../repositories/conflict_repository.dart';
import '../repositories/fishing_record_repository.dart';
import '../repositories/outbox_repository.dart';
import 'account_deletion_service.dart';
import 'network_status_service.dart';
import 'paid_record_cache_service.dart';
import 'plan_policy_service.dart';
import 'record_mutation_service.dart';
import 'record_photo_cleanup_coordinator.dart';
import 'record_sync_service.dart';

enum AppStartupStage {
  storage('기록 저장소를 열지 못했습니다.'),
  authentication('앱 연결을 준비하지 못했습니다.'),
  account('계정 정보를 준비하지 못했습니다.'),
  records('저장된 기록을 준비하지 못했습니다.'),
  services('앱을 준비하지 못했습니다.');

  const AppStartupStage(this.failureMessage);
  final String failureMessage;
}

class AppStartupStep {
  const AppStartupStep(this.stage, this.run);
  final AppStartupStage stage;
  final Future<void> Function() run;
}

enum AppStartupState { idle, loading, failed, ready }

/// Resumes at the failed step without resetting repositories or files.
class AppStartupController extends ChangeNotifier {
  AppStartupController({required List<AppStartupStep> steps})
    : _steps = List.unmodifiable(steps);

  factory AppStartupController.production() {
    final auth = AuthSessionRepository.instance;
    int? loadedGeneration;
    Future<void> loadLocalState() async {
      final generation = auth.sessionGeneration;
      for (final load in <Future<void> Function()>[
        FishingRecordRepository.instance.loadRecords,
        OutboxRepository.instance.loadItems,
        ConflictRepository.instance.loadItems,
        RecordMutationService.instance.reconcileOutboxWithLocalRecords,
        PlanPolicyService.instance.resumePendingMigration,
      ]) {
        await load();
        if (generation != auth.sessionGeneration) {
          throw StateError('Session changed while preparing local records.');
        }
      }
      loadedGeneration = generation;
    }

    return AppStartupController(
      steps: [
        AppStartupStep(AppStartupStage.storage, () async {
          // Auth restoration can migrate identity data in SQLite and convert a
          // DB exception into sign-out. Open/upgrade before touching auth.
          await AppDatabase.instance.database;
        }),
        AppStartupStep(AppStartupStage.authentication, () async {
          unawaited(
            NetworkStatusService.instance.initialize().onError<Object>((
              error,
              stack,
            ) {
              _reportOptionalFailure('network detection', error, stack);
            }),
          );
          final gateway = await FirebaseAuthBootstrap.initialize();
          auth.configureAuthGateway(gateway);
          auth.configureRemoteAccountDeletionCleanup(
            AccountDeletionService.instance.handleRemoteAccountDeletion,
          );
          RecordSyncService.instance.configureGateway(
            FirebaseRecordSyncBootstrap.create(gateway),
          );
        }),
        AppStartupStep(AppStartupStage.account, () async {
          // Keep the deletion barrier ahead of session restoration. The service
          // retains its durable marker if file cleanup must be deferred.
          await AccountDeletionService.instance.resumePendingLocalCleanup();
        }),
        AppStartupStep(AppStartupStage.account, auth.loadSession),
        AppStartupStep(AppStartupStage.records, loadLocalState),
        AppStartupStep(AppStartupStage.services, () async {
          // A remote deletion/session change may arrive on the recovery screen.
          if (loadedGeneration != auth.sessionGeneration) {
            await loadLocalState();
          }
          PaidRecordCacheService.instance.initialize();
        }),
        AppStartupStep(AppStartupStage.services, () async {
          RecordSyncService.instance.initialize();
        }),
        AppStartupStep(AppStartupStage.services, () async {
          try {
            RecordPhotoCleanupCoordinator.instance.initialize();
          } on Object catch (error, stack) {
            _reportOptionalFailure('photo cleanup', error, stack);
          }
        }),
      ],
    );
  }

  final List<AppStartupStep> _steps;
  AppStartupState _state = AppStartupState.idle;
  int _nextStep = 0;
  Future<void>? _running;
  bool _disposed = false;
  Object? lastError;
  StackTrace? lastErrorStackTrace;

  AppStartupState get state => _state;
  AppStartupStage? get stage =>
      _nextStep < _steps.length ? _steps[_nextStep].stage : null;

  Future<void> start() {
    if (_disposed || _state == AppStartupState.ready) return Future.value();
    final pending = _running;
    if (pending != null) return pending;
    late final Future<void> operation;
    // Set the guard before a notification or callback can reenter start().
    operation = Future<void>.microtask(_performStartup).whenComplete(() {
      if (identical(_running, operation)) _running = null;
    });
    _running = operation;
    return operation;
  }

  Future<void> _performStartup() async {
    if (_disposed) return;
    _state = AppStartupState.loading;
    lastError = null;
    lastErrorStackTrace = null;
    notifyListeners();
    while (!_disposed && _nextStep < _steps.length) {
      final stageName = stage?.name;
      final timer = Stopwatch()..start();
      try {
        await _steps[_nextStep].run();
      } on Object catch (error, stack) {
        if (_disposed) return;
        lastError = error;
        lastErrorStackTrace = stack;
        _state = AppStartupState.failed;
        developer.log(
          'Startup failed at ${stage?.name}.',
          name: 'AppStartup',
          error: error,
          stackTrace: stack,
        );
        notifyListeners();
        return;
      } finally {
        if (kDebugMode) {
          developer.log(
            '$stageName: ${timer.elapsedMilliseconds}ms.',
            name: 'AppStartupTiming',
          );
        }
      }
      if (_disposed) return;
      _nextStep++;
      notifyListeners();
    }
    if (_disposed) return;
    _state = AppStartupState.ready;
    notifyListeners();
  }

  static void _reportOptionalFailure(
    String operation,
    Object error,
    StackTrace stack,
  ) {
    developer.log(
      'Deferred startup $operation.',
      name: 'AppStartup',
      error: error,
      stackTrace: stack,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
