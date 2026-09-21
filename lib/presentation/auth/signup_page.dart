import 'package:flutter/material.dart';

import '../../core/validation/auth_input_validator.dart';
import '../../data/auth/auth_gateway.dart';
import '../../data/repositories/auth_session_repository.dart';
import '../../data/repositories/fishing_record_repository.dart';
import '../../data/repositories/outbox_repository.dart';
import '../../data/services/record_mutation_service.dart';
import '../shell/app_shell.dart';
import 'auth_error_message.dart';
import 'login_page.dart';

class SignupPage extends StatefulWidget {
  final bool returnToPrevious;

  const SignupPage({super.key, this.returnToPrevious = false});

  @override
  State<SignupPage> createState() => _SignupPageState();
}

class _SignupPageState extends State<SignupPage> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  final passwordConfirmController = TextEditingController();
  final nicknameController = TextEditingController();

  bool agreeTerms = false;
  bool agreePrivacy = false;
  bool isSubmitting = false;

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    passwordConfirmController.dispose();
    nicknameController.dispose();
    super.dispose();
  }

  Future<void> signup() async {
    final email = emailController.text.trim();
    final password = passwordController.text;
    final passwordConfirm = passwordConfirmController.text;
    final nickname = nicknameController.text.trim();

    if (email.isEmpty ||
        password.isEmpty ||
        passwordConfirm.isEmpty ||
        nickname.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('필수 정보를 모두 입력하세요.')));
      return;
    }

    if (!AuthInputValidator.isValidEmail(email)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('이메일 형식이 올바르지 않습니다.')));
      return;
    }

    if (!AuthInputValidator.isValidPassword(password)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('비밀번호는 8자 이상이며 영문과 숫자를 포함해야 합니다.')),
      );
      return;
    }

    if (password != passwordConfirm) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('비밀번호가 일치하지 않습니다.')));
      return;
    }

    if (!AuthInputValidator.isValidNickname(nickname)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('닉네임은 2~20자의 한글, 영문, 숫자, 공백, 밑줄, 하이픈만 사용할 수 있습니다.'),
        ),
      );
      return;
    }

    if (!agreeTerms || !agreePrivacy) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('필수 약관에 동의해야 합니다.')));
      return;
    }

    setState(() {
      isSubmitting = true;
    });

    try {
      final registered = await AuthSessionRepository.instance.registerAsFree(
        email: email,
        password: password,
        nickname: nickname,
      );

      if (!mounted) return;
      if (!registered) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('이미 가입된 이메일입니다. 로그인해 주세요.')),
        );
        return;
      }

      await FishingRecordRepository.instance.loadRecords();
      await OutboxRepository.instance.loadItems();
      await RecordMutationService.instance.reconcileOutboxWithLocalRecords();

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
          const SnackBar(content: Text('회원가입 중 오류가 발생했습니다. 다시 시도해 주세요.')),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('회원가입')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 24),

            Text(
              '계정을 만들어 출조 기록을 관리하세요',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),

            Text(
              '가입 후 무료 회원으로 시작합니다.',
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
            const SizedBox(height: 16),

            TextField(
              controller: passwordConfirmController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '비밀번호 확인',
                hintText: '비밀번호를 다시 입력하세요',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),

            TextField(
              controller: nicknameController,
              decoration: const InputDecoration(
                labelText: '닉네임',
                hintText: '닉네임을 입력하세요',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),

            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: agreeTerms,
              onChanged: (value) {
                setState(() {
                  agreeTerms = value ?? false;
                });
              },
              title: const Text('이용약관 동의 (필수)'),
              controlAffinity: ListTileControlAffinity.leading,
            ),

            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: agreePrivacy,
              onChanged: (value) {
                setState(() {
                  agreePrivacy = value ?? false;
                });
              },
              title: const Text('개인정보 처리방침 동의 (필수)'),
              controlAffinity: ListTileControlAffinity.leading,
            ),
            const SizedBox(height: 24),

            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: isSubmitting ? null : signup,
                child: Text(isSubmitting ? '가입 중...' : '가입하기'),
              ),
            ),
            const SizedBox(height: 24),

            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('이미 계정이 있으신가요?'),
                TextButton(
                  onPressed: () async {
                    if (!widget.returnToPrevious) {
                      Navigator.of(context).pushReplacement(
                        MaterialPageRoute(builder: (_) => const LoginPage()),
                      );
                      return;
                    }

                    final loggedIn = await Navigator.of(context).push<bool>(
                      MaterialPageRoute(
                        builder: (_) => const LoginPage(returnToPrevious: true),
                      ),
                    );

                    if (loggedIn == true && context.mounted) {
                      Navigator.of(context).pop(true);
                    }
                  },
                  child: const Text('로그인'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
