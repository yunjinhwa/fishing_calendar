import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'data/auth/firebase_auth_bootstrap.dart';
import 'data/repositories/auth_session_repository.dart';
import 'data/repositories/fishing_record_repository.dart';
import 'data/repositories/outbox_repository.dart';
import 'data/services/network_status_service.dart';
import 'data/services/plan_policy_service.dart';
import 'data/services/record_mutation_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  unawaited(NetworkStatusService.instance.initialize());

  final authSession = AuthSessionRepository.instance;
  authSession.configureAuthGateway(await FirebaseAuthBootstrap.initialize());
  await authSession.loadSession();
  await FishingRecordRepository.instance.loadRecords();
  await OutboxRepository.instance.loadItems();
  await RecordMutationService.instance.reconcileOutboxWithLocalRecords();
  await PlanPolicyService.instance.resumePendingMigration();

  runApp(const FishingBuildApp());
}
