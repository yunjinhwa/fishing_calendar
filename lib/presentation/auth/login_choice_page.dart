import 'package:flutter/material.dart';

import '../../data/auth/auth_gateway.dart';
import '../../data/repositories/auth_session_repository.dart';
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

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const AppShell(initialIndex: 1)),
      );
    } on AuthFailure catch (failure) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(authFailureMessage(failure))));
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
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const LoginPage()));
  }

  void _openSignup() {
    if (_isBusy) return;
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SignupPage()));
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
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    const Spacer(),

                    Icon(
                      Icons.phishing,
                      size: 72,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: 24),

                    Text(
                      '낚시 캘린더',
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),

                    Text(
                      '바다와 함께하는 나의 출조 기록',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.grey.shade600,
                      ),
                    ),

                    const Spacer(),

                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: isBusy ? null : _continueAsGuest,
                        child: const Text('비회원으로 시작하기'),
                      ),
                    ),
                    const SizedBox(height: 12),

                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: isBusy ? null : _openLogin,
                        child: const Text('로그인'),
                      ),
                    ),
                    const SizedBox(height: 12),

                    SizedBox(
                      width: double.infinity,
                      child: TextButton(
                        onPressed: isBusy ? null : _openSignup,
                        child: const Text('회원가입'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
