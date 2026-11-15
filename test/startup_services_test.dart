import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fishing_build/data/local/app_database.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/photos/record_photo_file_store.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/conflict_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/repositories/outbox_repository.dart';
import 'package:fishing_build/data/services/app_startup_controller.dart';
import 'package:fishing_build/data/services/network_status_service.dart';
import 'package:fishing_build/data/services/paid_record_cache_service.dart';
import 'package:fishing_build/data/services/record_photo_cleanup_coordinator.dart';
import 'package:fishing_build/data/services/record_photo_cleanup_service.dart';
import 'package:fishing_build/data/services/record_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final auth = AuthSessionRepository.instance;
  final records = FishingRecordRepository.instance;
  final cleanup = RecordPhotoCleanupService.instance;
  final coordinator = RecordPhotoCleanupCoordinator.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    coordinator.dispose();
    await cleanup.resetForTesting();
    await PaidRecordCacheService.instance.resetForTesting();
    await RecordSyncService.instance.resetForTesting();
    await NetworkStatusService.instance.resetForTesting(
      gateway: _OfflineConnectivity(),
    );
    await resetTestDatabase();
    auth.resetAuthGatewayForTesting();
    records.clearCacheOnlyForTesting();
    OutboxRepository.instance.clearCacheOnlyForTesting();
    ConflictRepository.instance.clearCacheOnlyForTesting();
  });

  tearDown(() async {
    coordinator.dispose();
    await cleanup.flushPending();
    await PaidRecordCacheService.instance.resetForTesting();
    await RecordSyncService.instance.resetForTesting();
    await NetworkStatusService.instance.close();
    await cleanup.resetForTesting();
    auth.resetAuthGatewayForTesting();
    await AppDatabase.instance.close();
  });

  test(
    'production startup succeeds when automatic photo collection fails',
    () async {
      await auth.setSessionForTesting(
        plan: UserPlan.free,
        email: 'startup-services@example.com',
      );
      final record = FishingRecord(
        id: 'startup-record',
        location: '방파제',
        genreName: '루어',
        startAt: DateTime(2026, 11, 15, 8),
        endAt: DateTime(2026, 11, 15, 9),
        photoPaths: const ['existing-local-photo.jpg'],
      );
      await records.addRecord(record);
      var collectionAttempts = 0;
      await cleanup.configureForTesting(
        fileStore: RecordPhotoFileStore(
          supportPathProvider: () async {
            collectionAttempts++;
            throw StateError('Injected unavailable photo directory');
          },
        ),
      );
      records.clearCacheOnlyForTesting();
      final controller = AppStartupController.production();
      addTearDown(controller.dispose);

      await controller.start();
      await cleanup.flushPending();

      expect(controller.state, AppStartupState.ready);
      expect(cleanup.lastError, isA<StateError>());
      expect(collectionAttempts, 1);
      expect(records.getAllRecords().single.id, record.id);
      expect(records.getAllRecords().single.photoPaths, record.photoPaths);
      await controller.start();
      await cleanup.flushPending();
      expect(collectionAttempts, 1);
    },
  );
}

class _OfflineConnectivity implements ConnectivityGateway {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => [
    ConnectivityResult.none,
  ];
  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      const Stream.empty();
}
