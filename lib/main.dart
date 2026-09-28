import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'data/auth/firebase_auth_bootstrap.dart';
import 'data/remote/firebase_record_sync_bootstrap.dart';
import 'data/repositories/auth_session_repository.dart';
import 'data/repositories/fishing_record_repository.dart';
import 'data/repositories/outbox_repository.dart';
import 'data/services/network_status_service.dart';
import 'data/services/plan_policy_service.dart';
import 'data/services/record_mutation_service.dart';
import 'data/services/record_sync_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  unawaited(NetworkStatusService.instance.initialize());

  final authSession = AuthSessionRepository.instance;
  final authGateway = await FirebaseAuthBootstrap.initialize();
  authSession.configureAuthGateway(authGateway);
  RecordSyncService.instance.configureGateway(
    FirebaseRecordSyncBootstrap.create(authGateway),
  );
  await authSession.loadSession();
  await FishingRecordRepository.instance.loadRecords();
  await OutboxRepository.instance.loadItems();
  await RecordMutationService.instance.reconcileOutboxWithLocalRecords();
  await PlanPolicyService.instance.resumePendingMigration();

  RecordSyncService.instance.initialize();
  runApp(const FishingBuildApp());
  unawaited(RecordSyncService.instance.syncNow());
}
