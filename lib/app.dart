import 'package:flutter/material.dart';

import 'core/theme/app_theme.dart';
//import 'presentation/calendar/calendar_page.dart';
import 'presentation/shell/app_shell.dart';

class FishingBuildApp extends StatelessWidget {
  const FishingBuildApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fishing Build',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      home: const AppShell(),
    );
  }
}
