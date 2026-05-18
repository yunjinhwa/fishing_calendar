import 'package:flutter/material.dart';

import 'core/theme/app_theme.dart';
import 'presentation/auth/login_choice_page.dart';

class FishingBuildApp extends StatelessWidget {
  const FishingBuildApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fishing Build',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      home: const LoginChoicePage(),
    );
  }
}
