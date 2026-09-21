import 'dart:async';

import 'package:flutter/material.dart';

import 'core/theme/app_theme.dart';
import 'data/repositories/auth_session_repository.dart';
import 'data/services/network_status_service.dart';
import 'presentation/auth/login_choice_page.dart';
import 'presentation/shell/app_shell.dart';

class FishingBuildApp extends StatefulWidget {
  final NetworkStatusService? networkStatusService;

  const FishingBuildApp({super.key, this.networkStatusService});

  @override
  State<FishingBuildApp> createState() => _FishingBuildAppState();
}

class _FishingBuildAppState extends State<FishingBuildApp>
    with WidgetsBindingObserver {
  late NetworkStatusService _networkStatusService;

  @override
  void initState() {
    super.initState();
    _networkStatusService =
        widget.networkStatusService ?? NetworkStatusService.instance;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_networkStatusService.initialize());
  }

  @override
  void didUpdateWidget(covariant FishingBuildApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextService =
        widget.networkStatusService ?? NetworkStatusService.instance;
    if (identical(nextService, _networkStatusService)) {
      return;
    }

    _networkStatusService = nextService;
    unawaited(_networkStatusService.initialize());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshNetworkStatus());
    }
  }

  Future<void> _refreshNetworkStatus() async {
    if (_networkStatusService.isInitialized) {
      await _networkStatusService.refresh();
    } else {
      await _networkStatusService.initialize();
    }
  }

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
              ? AppShell(
                  initialIndex: authSession.isGuest ? 1 : 0,
                  networkStatusService: _networkStatusService,
                )
              : const LoginChoicePage(),
        );
      },
    );
  }
}
