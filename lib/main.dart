import 'package:flutter/material.dart';

import 'app.dart';
import 'data/repositories/auth_session_repository.dart';
import 'data/repositories/fishing_record_memory_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await AuthSessionRepository.instance.loadSession();
  await FishingRecordMemoryRepository.instance.loadRecords();

  runApp(const FishingBuildApp());
}
