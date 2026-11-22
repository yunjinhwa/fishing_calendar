import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../data/auth/auth_gateway.dart';
import '../../data/repositories/auth_session_repository.dart';
import '../common/top_card_notification.dart';
import '../shell/app_shell.dart';
import 'auth_error_message.dart';
import 'login_page.dart';
import 'signup_page.dart';

class LoginChoicePage extends StatefulWidget {
  const LoginChoicePage({super.key});

  @override
  State<LoginChoicePage> createState() => _LoginChoicePageState();
}

class _LoginChoicePageState extends State<LoginChoicePage> {
  bool _isContinuingAsGuest = false;

  bool get _isBusy =>
      _isContinuingAsGuest ||
      AuthSessionRepository.instance.isAuthOperationInProgress;

  Future<void> _continueAsGuest() async {
    if (_isBusy) return;
    setState(() {
      _isContinuingAsGuest = true;
    });

    try {
      await AuthSessionRepository.instance.continueAsGuest();
      if (!mounted) return;

      unawaited(
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const AppShell(initialIndex: 1)),
        ),
      );
    } on AuthFailure catch (failure) {
      if (mounted) {
        TopCardNotification.show(
          context,
          authFailureMessage(failure),
          type: TopCardNotificationType.error,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isContinuingAsGuest = false;
        });
      }
    }
  }

  void _openLogin() {
    if (_isBusy) return;
    unawaited(
      Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const LoginPage())),
    );
  }

  void _openSignup() {
    if (_isBusy) return;
    unawaited(
      Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const SignupPage())),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AuthSessionRepository.instance,
      builder: (context, _) {
        final isBusy = _isBusy;
        return PopScope(
          canPop: !isBusy,
          child: Scaffold(
            body: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 352),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(
                          child: Container(
                            width: 108,
                            height: 108,
                            decoration: BoxDecoration(
                              color: AppTheme.primary,
                              borderRadius: BorderRadius.circular(24),
                            ),
                            child: const Icon(
                              Icons.phishing,
                              size: 56,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(height: 26),
                        Text(
                          '낚시 캘린더',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '바다와 함께하는 나의 출조 기록',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppTheme.muted),
                        ),
                        const SizedBox(height: 40),
                        OutlinedButton(
                          onPressed: isBusy ? null : _continueAsGuest,
                          child: const Text('비회원으로 시작하기'),
                        ),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: isBusy ? null : _openLogin,
                          child: const Text('로그인'),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: isBusy ? null : _openSignup,
                          child: const Text('회원가입'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
