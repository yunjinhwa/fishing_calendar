import 'package:flutter/material.dart';

import 'app.dart';
import 'data/repositories/auth_session_repository.dart';
import 'data/repositories/fishing_record_repository.dart';
import 'data/repositories/outbox_repository.dart';
import 'data/services/plan_policy_service.dart';
import 'data/services/record_mutation_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final authSession = AuthSessionRepository.instance;
  await authSession.loadSession();
  await FishingRecordRepository.instance.loadRecords();
  await OutboxRepository.instance.loadItems();
  await RecordMutationService.instance.reconcileOutboxWithLocalRecords();
  await PlanPolicyService.instance.resumePendingMigration();

  runApp(const FishingBuildApp());
}
