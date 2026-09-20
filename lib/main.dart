import 'package:flutter/material.dart';

import 'app.dart';
import 'data/repositories/auth_session_repository.dart';
import 'data/repositories/fishing_record_memory_repository.dart';
import 'data/repositories/outbox_memory_repository.dart';
import 'data/services/plan_policy_service.dart';
import 'data/services/record_mutation_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final authSession = AuthSessionRepository.instance;
  await authSession.loadSession();
  await FishingRecordMemoryRepository.instance.loadRecords();
  await OutboxMemoryRepository.instance.loadItems();
  await RecordMutationService.instance.reconcileOutboxWithLocalRecords();
  await PlanPolicyService.instance.resumePendingMigration();

  runApp(const FishingBuildApp());
}
