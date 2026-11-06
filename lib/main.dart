import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'data/auth/firebase_auth_bootstrap.dart';
import 'data/remote/firebase_record_sync_bootstrap.dart';
import 'data/repositories/auth_session_repository.dart';
import 'data/repositories/conflict_repository.dart';
import 'data/repositories/fishing_record_repository.dart';
import 'data/repositories/outbox_repository.dart';
import 'data/services/account_deletion_service.dart';
import 'data/services/network_status_service.dart';
import 'data/services/plan_policy_service.dart';
import 'data/services/record_mutation_service.dart';
import 'data/services/record_photo_cleanup_coordinator.dart';
import 'data/services/record_sync_service.dart';
import 'data/services/paid_record_cache_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'klc (Korean lunar calendar data)',
    ], await rootBundle.loadString('third_party/klc_LICENSE.txt'));
    yield LicenseEntryWithLineBreaks([
      'OpenFreeMap / OpenMapTiles / OpenStreetMap',
    ], await rootBundle.loadString('third_party/open_map_water_NOTICE.txt'));
    yield LicenseEntryWithLineBreaks([
      'NIFS / Wikidata / Wikipedia / Wikimedia Commons / iNaturalist / GBIF',
    ], await rootBundle.loadString('third_party/fish_encyclopedia_NOTICE.txt'));
  });

  unawaited(NetworkStatusService.instance.initialize());

  final authSession = AuthSessionRepository.instance;
  final authGateway = await FirebaseAuthBootstrap.initialize();
  authSession.configureAuthGateway(authGateway);
  final accountDeletionService = AccountDeletionService.instance;
  authSession.configureRemoteAccountDeletionCleanup(
    accountDeletionService.handleRemoteAccountDeletion,
  );
  RecordSyncService.instance.configureGateway(
    FirebaseRecordSyncBootstrap.create(authGateway),
  );
  await accountDeletionService.resumePendingLocalCleanup();
  await authSession.loadSession();
  await FishingRecordRepository.instance.loadRecords();
  await OutboxRepository.instance.loadItems();
  await ConflictRepository.instance.loadItems();
  await RecordMutationService.instance.reconcileOutboxWithLocalRecords();
  await PlanPolicyService.instance.resumePendingMigration();

  PaidRecordCacheService.instance.initialize();
  RecordPhotoCleanupCoordinator.instance.initialize();
  RecordSyncService.instance.initialize();
  runApp(const FishingBuildApp());
  unawaited(RecordSyncService.instance.syncNow());
}
