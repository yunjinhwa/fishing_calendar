import 'package:flutter/material.dart';

import 'core/theme/app_theme.dart';
import 'data/repositories/auth_session_repository.dart';
import 'presentation/auth/login_choice_page.dart';
import 'presentation/shell/app_shell.dart';

class FishingBuildApp extends StatelessWidget {
  const FishingBuildApp({super.key});

  @override
  Widget build(BuildContext context) {
    final authSession = AuthSessionRepository.instance;

    return AnimatedBuilder(
      animation: authSession,
      builder: (context, _) {
        return MaterialApp(
          title: 'Fishing Build',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          home: authSession.hasActiveSession
              ? AppShell(initialIndex: authSession.isGuest ? 1 : 0)
              : const LoginChoicePage(),
        );
      },
    );
  }
}
