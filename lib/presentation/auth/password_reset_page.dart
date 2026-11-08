import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/validation/auth_input_validator.dart';
import '../../data/auth/auth_gateway.dart';
import '../../data/repositories/auth_session_repository.dart';

class PasswordResetPage extends StatefulWidget {
  const PasswordResetPage({super.key, this.initialEmail = ''});

  final String initialEmail;

  @override
  State<PasswordResetPage> createState() => _PasswordResetPageState();
}

class _PasswordResetPageState extends State<PasswordResetPage> {
  final _auth = AuthSessionRepository.instance;
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _emailController;
  Timer? _cooldownTimer;
  int _remainingSeconds = 0;
  bool _sending = false;
  bool _requested = false;
  String? _failure;

  @override
  void initState() {
    super.initState();
    _emailController = TextEditingController(text: widget.initialEmail.trim());
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _emailController.dispose();
    super.dispose();
  }

  void _startCooldown() {
    _cooldownTimer?.cancel();
    _remainingSeconds = 60;
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final remaining = (60 - timer.tick).clamp(0, 60);
      if (!mounted || remaining == 0) timer.cancel();
      if (mounted && remaining != _remainingSeconds) {
        setState(() => _remainingSeconds = remaining);
      }
    });
  }

  void _refresh() {
    if (_sending) return;
    FocusScope.of(context).unfocus();
    final email = _emailController.value;
    _cooldownTimer?.cancel();
    _cooldownTimer = null;
    _formKey.currentState?.reset();
    _emailController.value = email;
    setState(() {
      _remainingSeconds = 0;
      _requested = false;
      _failure = null;
    });
  }

  Future<void> _send() async {
    if (_sending || _remainingSeconds > 0 || !_auth.canSendPasswordResetEmail) {
      return;
    }
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _sending = true;
      _failure = null;
      _requested = false;
    });
    try {
      await _auth.sendPasswordResetEmail(email: _emailController.text.trim());
      if (!mounted) return;
      setState(() {
        _requested = true;
        _startCooldown();
      });
    } on AuthFailure catch (failure) {
      if (mounted) {
        setState(() {
          _failure = switch (failure.code) {
            AuthFailureCode.invalidEmail => '이메일 형식을 확인해 주세요.',
            AuthFailureCode.networkUnavailable => '네트워크 연결을 확인한 뒤 다시 시도해 주세요.',
            AuthFailureCode.tooManyRequests => '요청이 너무 많습니다. 잠시 후 다시 시도해 주세요.',
            AuthFailureCode.configuration ||
            AuthFailureCode.initializationFailed ||
            AuthFailureCode.operationNotAllowed ||
            AuthFailureCode.serviceUnavailable =>
              '현재 인증 서비스를 사용할 수 없습니다. 잠시 후 다시 시도해 주세요.',
            _ => '재설정 메일을 요청하지 못했습니다. 다시 시도해 주세요.',
          };
        });
      }
    } on Object {
      if (mounted) {
        setState(() => _failure = '재설정 메일을 요청하지 못했습니다. 다시 시도해 주세요.');
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('비밀번호 재설정'),
      actions: [
        IconButton(
          tooltip: '재설정 화면 새로고침',
          onPressed: _sending ? null : _refresh,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: SafeArea(
      child: ListenableBuilder(
        listenable: _auth,
        builder: (context, _) {
          final available = _auth.canSendPasswordResetEmail;
          return Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const SizedBox(height: 16),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Icon(Icons.lock_reset_outlined, size: 40),
                ),
                const SizedBox(height: 20),
                Text(
                  '비밀번호를 잊으셨나요?',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                const Text('가입한 이메일로 비밀번호 재설정 링크를 요청할 수 있습니다.'),
                const SizedBox(height: 24),
                TextFormField(
                  controller: _emailController,
                  enabled: !_sending,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.done,
                  autofillHints: const [AutofillHints.email],
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: '이메일',
                    hintText: '가입한 이메일을 입력하세요',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return '이메일을 입력하세요.';
                    }
                    if (!AuthInputValidator.isValidEmail(value)) {
                      return '이메일 형식이 올바르지 않습니다.';
                    }
                    return null;
                  },
                  onFieldSubmitted: (_) => _send(),
                  onChanged: (_) {
                    if (_requested || _failure != null) {
                      setState(() {
                        _requested = false;
                        _failure = null;
                      });
                    }
                  },
                ),
                if (!available) ...[
                  const SizedBox(height: 16),
                  const Text('현재 실행 환경에서는 비밀번호 재설정 메일을 보낼 수 없습니다.'),
                ],
                if (_requested) ...[
                  const SizedBox(height: 20),
                  Semantics(
                    liveRegion: true,
                    child: Card(
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.mark_email_read_outlined),
                            const SizedBox(height: 12),
                            Text(
                              '메일을 확인해 주세요',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              '해당 이메일로 재설정이 가능한 계정이 있다면 안내 메일이 발송됩니다. '
                              '받은편지함과 스팸함을 확인해 주세요.',
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
                if (_failure != null) ...[
                  const SizedBox(height: 16),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _failure!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: !available || _sending || _remainingSeconds > 0
                      ? null
                      : _send,
                  child: Text(
                    _sending
                        ? '요청 중...'
                        : _remainingSeconds > 0
                        ? '$_remainingSeconds초 후 다시 보내기'
                        : _requested
                        ? '재설정 메일 다시 보내기'
                        : '재설정 메일 보내기',
                  ),
                ),
                const SizedBox(height: 16),
                const Text('메일의 링크에서 비밀번호를 변경한 뒤 로그인해 주세요.'),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: () => Navigator.of(
                    context,
                  ).maybePop(_emailController.text.trim()),
                  child: const Text('로그인으로 돌아가기'),
                ),
              ],
            ),
          );
        },
      ),
    ),
  );
}
