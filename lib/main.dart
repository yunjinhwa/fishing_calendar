import 'package:flutter/material.dart';

import 'app.dart';
import 'data/app_info/app_licenses.dart';
import 'presentation/startup/startup_gate.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  registerAppLicenses();

  runApp(const StartupGate(child: FishingBuildApp()));
}
