import 'package:flutter/material.dart';

import '../shell/app_shell.dart';
import 'login_page.dart';

class SignupPage extends StatefulWidget {
  const SignupPage({super.key});

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

  void signup() async {
    final email = emailController.text.trim();
    final password = passwordController.text.trim();
    final passwordConfirm = passwordConfirmController.text.trim();
    final nickname = nicknameController.text.trim();

    if (email.isEmpty ||
        password.isEmpty ||
        passwordConfirm.isEmpty ||
        nickname.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('필수 정보를 모두 입력하세요.'),
        ),
      );
      return;
    }

    if (password != passwordConfirm) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('비밀번호가 일치하지 않습니다.'),
        ),
      );
      return;
    }

    if (!agreeTerms || !agreePrivacy) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('필수 약관에 동의해야 합니다.'),
        ),
      );
      return;
    }

    setState(() {
      isSubmitting = true;
    });

    await Future.delayed(const Duration(milliseconds: 500));

    if (!mounted) return;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => const AppShell(),
      ),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('회원가입'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 24),

            Text(
              '계정을 만들어 출조 기록을 관리하세요',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),

            Text(
              '가입 후 무료 회원으로 시작합니다.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.grey.shade600,
                  ),
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
                  onPressed: () {
                    Navigator.of(context).pushReplacement(
                      MaterialPageRoute(
                        builder: (_) => const LoginPage(),
                      ),
                    );
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