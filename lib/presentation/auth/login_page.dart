import 'package:flutter/material.dart';

import '../../core/validation/auth_input_validator.dart';
import '../../data/auth/auth_gateway.dart';
import '../../data/repositories/auth_session_repository.dart';
import '../../data/repositories/fishing_record_repository.dart';
import '../../data/repositories/outbox_repository.dart';
import '../../data/services/plan_policy_service.dart';
import '../../data/services/record_mutation_service.dart';
import '../shell/app_shell.dart';
import 'auth_error_message.dart';
import 'signup_page.dart';

class LoginPage extends StatefulWidget {
  final bool returnToPrevious;

  const LoginPage({super.key, this.returnToPrevious = false});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();

  bool rememberLogin = true;
  bool isSubmitting = false;

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  Future<void> login() async {
    final email = emailController.text.trim();
    final password = passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('이메일과 비밀번호를 입력하세요.')));
      return;
    }

    if (!AuthInputValidator.isValidEmail(email)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('이메일 형식이 올바르지 않습니다.')));
      return;
    }

    setState(() {
      isSubmitting = true;
    });

    try {
      String? replacementNickname;
      late AuthSignInResult result;
      while (true) {
        try {
          result = await AuthSessionRepository.instance.signIn(
            email: email,
            password: password,
            nickname: replacementNickname,
            rememberSession: rememberLogin,
          );
          break;
        } on AuthFailure catch (failure) {
          final needsNickname =
              failure.code == AuthFailureCode.nicknameAlreadyInUse ||
              failure.code == AuthFailureCode.nicknameRequired;
          if (!needsNickname || !mounted) {
            rethrow;
          }

          replacementNickname = await _requestReplacementNickname(
            alreadyInUse: failure.code == AuthFailureCode.nicknameAlreadyInUse,
          );
          if (replacementNickname == null || !mounted) {
            return;
          }
        }
      }

      if (result != AuthSignInResult.success) {
        if (!mounted) return;
        final message = switch (result) {
          AuthSignInResult.accountNotFound => '가입된 계정을 찾을 수 없습니다.',
          AuthSignInResult.invalidCredentials => '이메일 또는 비밀번호가 일치하지 않습니다.',
          AuthSignInResult.credentialSetupRequired =>
            '이전 버전 계정입니다. 기존 비밀번호로 계정을 이전할 수 없습니다. 관리자에게 문의해 주세요.',
          AuthSignInResult.success => '',
        };
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
        return;
      }

      await FishingRecordRepository.instance.loadRecords();
      await OutboxRepository.instance.loadItems();
      await RecordMutationService.instance.reconcileOutboxWithLocalRecords();
      await PlanPolicyService.instance.resumePendingMigration();

      if (!mounted) return;
      if (widget.returnToPrevious) {
        Navigator.of(context).pop(true);
        return;
      }
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const AppShell()),
        (route) => false,
      );
    } on AuthFailure catch (failure) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(authFailureMessage(failure))));
      }
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('로그인 중 오류가 발생했습니다. 다시 시도해 주세요.')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          isSubmitting = false;
        });
      }
    }
  }

  Future<String?> _requestReplacementNickname({required bool alreadyInUse}) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ReplacementNicknameDialog(alreadyInUse: alreadyInUse),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('로그인')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 24),

            Text(
              '다시 오신 것을 환영합니다',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),

            Text(
              '출조 기록을 안전하게 관리하려면 로그인하세요.',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.grey.shade600),
            ),
            const SizedBox(height: 32),

            TextField(
              controller: emailController,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: '이메일',
                hintText: '이메일을 입력하세요',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),

            TextField(
              controller: passwordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '비밀번호',
                hintText: '비밀번호를 입력하세요',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),

            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: rememberLogin,
              onChanged: (value) {
                setState(() {
                  rememberLogin = value ?? false;
                });
              },
              title: const Text('로그인 상태 유지'),
              controlAffinity: ListTileControlAffinity.leading,
            ),
            const SizedBox(height: 24),

            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: isSubmitting ? null : login,
                child: Text(isSubmitting ? '로그인 중...' : '로그인'),
              ),
            ),
            const SizedBox(height: 16),

            const OutlinedButton(
              onPressed: null,
              child: Text('Google로 계속하기 (준비 중)'),
            ),
            const SizedBox(height: 8),

            const OutlinedButton(
              onPressed: null,
              child: Text('Apple로 계속하기 (준비 중)'),
            ),
            const SizedBox(height: 24),

            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('계정이 없으신가요?'),
                TextButton(
                  onPressed: () async {
                    if (!widget.returnToPrevious) {
                      Navigator.of(context).pushReplacement(
                        MaterialPageRoute(builder: (_) => const SignupPage()),
                      );
                      return;
                    }

                    final signedUp = await Navigator.of(context).push<bool>(
                      MaterialPageRoute(
                        builder: (_) =>
                            const SignupPage(returnToPrevious: true),
                      ),
                    );

                    if (signedUp == true && context.mounted) {
                      Navigator.of(context).pop(true);
                    }
                  },
                  child: const Text('회원가입'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ReplacementNicknameDialog extends StatefulWidget {
  final bool alreadyInUse;

  const _ReplacementNicknameDialog({required this.alreadyInUse});

  @override
  State<_ReplacementNicknameDialog> createState() =>
      _ReplacementNicknameDialogState();
}

class _ReplacementNicknameDialogState
    extends State<_ReplacementNicknameDialog> {
  final TextEditingController controller = TextEditingController();
  String? validationMessage;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void submit() {
    final value = controller.text.trim();
    if (!AuthInputValidator.isValidNickname(value)) {
      setState(() {
        validationMessage = '2~20자의 한글, 영문, 숫자, 공백, 밑줄, 하이픈만 사용할 수 있습니다.';
      });
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('닉네임 설정'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.alreadyInUse
                ? '기존 닉네임이 이미 사용 중입니다. 계속하려면 다른 닉네임을 입력하세요.'
                : '이 계정에 사용할 고유 닉네임을 입력하세요.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: '새 닉네임',
              errorText: validationMessage,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(onPressed: submit, child: const Text('확인')),
      ],
    );
  }
}
