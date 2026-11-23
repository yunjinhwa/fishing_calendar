import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/validation/auth_input_validator.dart';
import '../../data/auth/auth_gateway.dart';
import '../../data/repositories/auth_session_repository.dart';
import '../../data/repositories/conflict_repository.dart';
import '../../data/repositories/fishing_record_repository.dart';
import '../../data/repositories/outbox_repository.dart';
import '../../data/services/record_mutation_service.dart';
import '../common/hold_to_reveal_password_field.dart';
import '../common/top_card_notification.dart';
import '../legal/policy_document_page.dart';
import '../shell/app_shell.dart';
import 'auth_error_message.dart';
import 'login_page.dart';

class SignupPage extends StatefulWidget {
  final bool returnToPrevious;

  const SignupPage({super.key, this.returnToPrevious = false});

  @override
  State<SignupPage> createState() => _SignupPageState();
}

enum _SignupAge { underFourteen, fourteenOrOlder }

class _SignupPageState extends State<SignupPage> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  final passwordConfirmController = TextEditingController();
  final nicknameController = TextEditingController();

  bool agreeTerms = false;
  bool agreePrivacy = false;
  bool isSubmitting = false;
  _SignupAge? _age;

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    passwordConfirmController.dispose();
    nicknameController.dispose();
    super.dispose();
  }

  void _openPolicy(PolicyDocument document) {
    if (isSubmitting) return;
    FocusScope.of(context).unfocus();
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => PolicyDocumentPage(document: document),
        ),
      ),
    );
  }

  void _resetAge() {
    FocusScope.of(context).unfocus();
    emailController.clear();
    passwordController.clear();
    passwordConfirmController.clear();
    nicknameController.clear();
    setState(() {
      _age = null;
      agreeTerms = false;
      agreePrivacy = false;
    });
  }

  Future<void> _openLogin() async {
    if (isSubmitting) return;
    if (!widget.returnToPrevious) {
      unawaited(
        Navigator.of(
          context,
        ).pushReplacement(MaterialPageRoute(builder: (_) => const LoginPage())),
      );
      return;
    }

    final loggedIn = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => const LoginPage(returnToPrevious: true),
      ),
    );
    if (loggedIn == true && mounted) {
      Navigator.of(context).pop(true);
    }
  }

  Future<void> signup() async {
    if (isSubmitting || _age != _SignupAge.fourteenOrOlder) return;

    final email = emailController.text.trim();
    final password = passwordController.text;
    final passwordConfirm = passwordConfirmController.text;
    final nickname = nicknameController.text.trim();

    if (email.isEmpty ||
        password.isEmpty ||
        passwordConfirm.isEmpty ||
        nickname.isEmpty) {
      TopCardNotification.show(
        context,
        '필수 정보를 모두 입력하세요.',
        type: TopCardNotificationType.warning,
      );
      return;
    }

    if (!AuthInputValidator.isValidEmail(email)) {
      TopCardNotification.show(
        context,
        '이메일 형식이 올바르지 않습니다.',
        type: TopCardNotificationType.warning,
      );
      return;
    }

    if (!AuthInputValidator.isValidPassword(password)) {
      TopCardNotification.show(
        context,
        '비밀번호는 8자 이상이며 영문과 숫자를 포함해야 합니다.',
        type: TopCardNotificationType.warning,
      );
      return;
    }

    if (password != passwordConfirm) {
      TopCardNotification.show(
        context,
        '비밀번호가 일치하지 않습니다.',
        type: TopCardNotificationType.warning,
      );
      return;
    }

    if (!AuthInputValidator.isValidNickname(nickname)) {
      TopCardNotification.show(
        context,
        '닉네임은 2~20자의 한글, 영문, 숫자, 공백, 밑줄, 하이픈만 사용할 수 있습니다.',
        type: TopCardNotificationType.warning,
      );
      return;
    }

    if (!agreeTerms || !agreePrivacy) {
      TopCardNotification.show(
        context,
        '필수 약관에 동의해야 합니다.',
        type: TopCardNotificationType.warning,
      );
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
        TopCardNotification.show(
          context,
          '이미 가입된 이메일입니다. 로그인해 주세요.',
          type: TopCardNotificationType.error,
        );
        return;
      }

      await FishingRecordRepository.instance.loadRecords();
      await OutboxRepository.instance.loadItems();
      await ConflictRepository.instance.loadItems();
      await RecordMutationService.instance.reconcileOutboxWithLocalRecords();

      if (!mounted) return;
      if (widget.returnToPrevious) {
        Navigator.of(context).pop(true);
        return;
      }
      unawaited(
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const AppShell()),
          (route) => false,
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
    } on Object {
      if (mounted) {
        TopCardNotification.show(
          context,
          '회원가입 중 오류가 발생했습니다. 다시 시도해 주세요.',
          type: TopCardNotificationType.error,
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
    final showSignupForm = _age == _SignupAge.fourteenOrOlder;
    return PopScope(
      canPop: !isSubmitting,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.white,
          actions: [
            if (showSignupForm)
              TextButton(
                onPressed: isSubmitting ? null : _resetAge,
                child: const Text('연령 다시 선택'),
              ),
          ],
        ),
        body: SafeArea(
          child: showSignupForm ? _signupForm(context) : _ageStep(context),
        ),
      ),
    );
  }

  Widget _ageStep(BuildContext context) {
    final theme = Theme.of(context);
    final isUnderFourteen = _age == _SignupAge.underFourteen;
    return ListView(
      key: ValueKey(_age),
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 12),
        Text(
          isUnderFourteen ? '회원가입은 만 14세 이상부터 가능해요' : '회원가입',
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        if (isUnderFourteen) ...[
          const SizedBox(height: 24),
          OutlinedButton(onPressed: _resetAge, child: const Text('돌아가기')),
        ] else ...[
          const SizedBox(height: 12),
          Text('현재 연령을 선택해 주세요.', style: theme.textTheme.bodyLarge),
          const SizedBox(height: 24),
          OutlinedButton(
            onPressed: () => setState(() => _age = _SignupAge.underFourteen),
            child: const Text('만 14세 미만'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => setState(() => _age = _SignupAge.fourteenOrOlder),
            child: const Text('만 14세 이상'),
          ),
        ],
        const SizedBox(height: 24),
        _loginLink(),
      ],
    );
  }

  Widget _loginLink() => Wrap(
    alignment: WrapAlignment.center,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      const Text('이미 계정이 있으신가요?'),
      TextButton(
        onPressed: isSubmitting ? null : _openLogin,
        child: const Text('로그인'),
      ),
    ],
  );

  Widget _signupForm(BuildContext context) => ListView(
    key: const ValueKey(_SignupAge.fourteenOrOlder),
    padding: const EdgeInsets.all(24),
    children: [
      const SizedBox(height: 12),

      Text(
        '회원가입',
        style: Theme.of(
          context,
        ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 20),

      TextField(
        controller: emailController,
        keyboardType: TextInputType.emailAddress,
        decoration: const InputDecoration(
          labelText: '이메일',
          hintText: '이메일을 입력하세요',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 12),

      HoldToRevealPasswordField(
        controller: passwordController,
        autofillHints: const [AutofillHints.newPassword],
        decoration: const InputDecoration(
          labelText: '비밀번호',
          hintText: '비밀번호를 입력하세요',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 12),

      HoldToRevealPasswordField(
        controller: passwordConfirmController,
        autofillHints: const [AutofillHints.newPassword],
        decoration: const InputDecoration(
          labelText: '비밀번호 확인',
          hintText: '비밀번호를 다시 입력하세요',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 12),

      TextField(
        controller: nicknameController,
        decoration: const InputDecoration(
          labelText: '닉네임',
          hintText: '닉네임을 입력하세요',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 16),

      Row(
        children: [
          Expanded(
            child: CheckboxListTile(
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
          ),
          TextButton(
            key: const ValueKey('signup-view-terms'),
            onPressed: isSubmitting
                ? null
                : () => _openPolicy(PolicyDocument.terms),
            child: const Text('내용 보기'),
          ),
        ],
      ),

      Row(
        children: [
          Expanded(
            child: CheckboxListTile(
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
          ),
          TextButton(
            key: const ValueKey('signup-view-privacy'),
            onPressed: isSubmitting
                ? null
                : () => _openPolicy(PolicyDocument.privacy),
            child: const Text('내용 보기'),
          ),
        ],
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

      _loginLink(),
    ],
  );
}
