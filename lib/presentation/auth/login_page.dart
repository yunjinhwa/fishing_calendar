import 'package:flutter/material.dart';

import '../shell/app_shell.dart';
import 'signup_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

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

  void login() async {
    final email = emailController.text.trim();
    final password = passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('이메일과 비밀번호를 입력하세요.'),
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
        title: const Text('로그인'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 24),

            Text(
              '다시 오신 것을 환영합니다',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),

            Text(
              '출조 기록을 안전하게 관리하려면 로그인하세요.',
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

            OutlinedButton(
              onPressed: () {},
              child: const Text('Google로 계속하기'),
            ),
            const SizedBox(height: 8),

            OutlinedButton(
              onPressed: () {},
              child: const Text('Apple로 계속하기'),
            ),
            const SizedBox(height: 24),

            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('계정이 없으신가요?'),
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pushReplacement(
                      MaterialPageRoute(
                        builder: (_) => const SignupPage(),
                      ),
                    );
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