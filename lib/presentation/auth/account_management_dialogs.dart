import 'package:flutter/material.dart';

import '../../core/validation/auth_input_validator.dart';
import '../../data/auth/auth_gateway.dart';
import '../../data/repositories/auth_session_repository.dart';
import '../../data/services/account_deletion_service.dart';
import '../common/hold_to_reveal_password_field.dart';
import 'auth_error_message.dart';

Future<void> showMemberPasswordSetupDialog(BuildContext context) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _PasswordSetupDialog(),
    );

Future<bool> showAccountDeletionConfirmation(BuildContext context) async {
  final auth = AuthSessionRepository.instance;
  final owner = auth.dataOwnerKey;
  final generation = auth.sessionGeneration;
  bool current() =>
      context.mounted &&
      auth.isMember &&
      !auth.isAccountDeletedRemotely &&
      owner == auth.dataOwnerKey &&
      generation == auth.sessionGeneration;
  if (!current() || auth.isAuthOperationInProgress) return false;
  if (auth.requiresPasswordSetup) {
    await showMemberPasswordSetupDialog(context);
    if (!current() || auth.requiresPasswordSetup) return false;
  }
  if (!context.mounted || !current()) return false;
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) =>
            _AccountDeletionDialog(isResume: auth.canResumeAccountDeletion),
      ) ==
      true;
}

class _AccountDeletionDialog extends StatefulWidget {
  final bool isResume;

  const _AccountDeletionDialog({required this.isResume});

  @override
  State<_AccountDeletionDialog> createState() => _AccountDeletionDialogState();
}

class _AccountDeletionDialogState extends State<_AccountDeletionDialog> {
  final auth = AuthSessionRepository.instance;
  final passwordController = TextEditingController();
  final confirmationController = TextEditingController();
  late final String owner;
  late final int generation;
  String? errorText;
  bool isSubmitting = false;

  bool get canSubmit =>
      auth.isMember &&
      !auth.isAccountDeletedRemotely &&
      owner == auth.dataOwnerKey &&
      generation == auth.sessionGeneration &&
      !auth.isAuthOperationInProgress &&
      passwordController.text.isNotEmpty &&
      confirmationController.text.trim() == '탈퇴' &&
      !isSubmitting;

  @override
  void initState() {
    super.initState();
    owner = auth.dataOwnerKey;
    generation = auth.sessionGeneration;
    auth.addListener(_refresh);
    passwordController.addListener(_refresh);
    confirmationController.addListener(_refresh);
  }

  @override
  void dispose() {
    auth.removeListener(_refresh);
    passwordController
      ..removeListener(_refresh)
      ..dispose();
    confirmationController
      ..removeListener(_refresh)
      ..dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _submit() async {
    if (!canSubmit) {
      return;
    }
    setState(() {
      isSubmitting = true;
      errorText = null;
    });
    try {
      await AccountDeletionService.instance.deleteCurrentAccount(
        passwordController.text,
      );
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } on AuthFailure catch (failure) {
      if (mounted) {
        setState(() {
          isSubmitting = false;
          errorText = authFailureMessage(failure);
        });
      }
    } on Object {
      if (mounted) {
        setState(() {
          isSubmitting = false;
          errorText = '회원 탈퇴를 완료하지 못했습니다. 네트워크를 확인한 뒤 다시 시도해 주세요.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !isSubmitting,
      child: AlertDialog(
        title: Text(widget.isResume ? '회원 탈퇴 계속하기' : '회원 탈퇴'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.isResume
                    ? '이전에 시작한 탈퇴 처리를 완료합니다.'
                    : '탈퇴하면 계정, 낚시 기록, 동기화 내역, 로컬 사진과 닉네임이 삭제되며 되돌릴 수 없습니다.',
              ),
              const SizedBox(height: 8),
              const Text(
                '다른 기기의 동기화도 중단됩니다. 중단된 삭제를 재시도하기 위해 Firebase UID와 요청 시각만 담은 표식은 서버에 남습니다.',
              ),
              const SizedBox(height: 16),
              HoldToRevealPasswordField(
                controller: passwordController,
                enabled: !isSubmitting,
                autofillHints: const [AutofillHints.password],
                decoration: const InputDecoration(
                  labelText: '현재 비밀번호',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: confirmationController,
                enabled: !isSubmitting,
                decoration: InputDecoration(
                  labelText: '확인을 위해 탈퇴 입력',
                  border: const OutlineInputBorder(),
                  errorText: errorText,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: isSubmitting
                ? null
                : () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: canSubmit ? _submit : null,
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(isSubmitting ? '처리 중...' : '영구 삭제'),
          ),
        ],
      ),
    );
  }
}

class _PasswordSetupDialog extends StatefulWidget {
  const _PasswordSetupDialog();

  @override
  State<_PasswordSetupDialog> createState() => _PasswordSetupDialogState();
}

class _PasswordSetupDialogState extends State<_PasswordSetupDialog> {
  final passwordController = TextEditingController();
  final confirmController = TextEditingController();
  String? errorText;
  bool isSubmitting = false;

  @override
  void dispose() {
    passwordController.dispose();
    confirmController.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    final password = passwordController.text;
    if (!AuthInputValidator.isValidPassword(password)) {
      setState(() {
        errorText = '8자 이상이며 영문과 숫자를 포함해 주세요.';
      });
      return;
    }

    if (password != confirmController.text) {
      setState(() {
        errorText = '비밀번호가 일치하지 않습니다.';
      });
      return;
    }

    setState(() {
      isSubmitting = true;
      errorText = null;
    });

    try {
      await AuthSessionRepository.instance.setPasswordForCurrentMember(
        password,
      );
      if (mounted) {
        Navigator.of(context).pop();
      }
    } on AuthFailure catch (failure) {
      if (mounted) {
        setState(() {
          isSubmitting = false;
          errorText = authFailureMessage(failure);
        });
      }
    } on Object {
      if (mounted) {
        setState(() {
          isSubmitting = false;
          errorText = '비밀번호를 설정하지 못했습니다. 다시 시도해 주세요.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('계정 비밀번호 설정'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('이전 버전의 계정을 보호하려면 로그아웃 전에 비밀번호를 설정해야 합니다.'),
            const SizedBox(height: 16),
            HoldToRevealPasswordField(
              controller: passwordController,
              enabled: !isSubmitting,
              autofillHints: const [AutofillHints.newPassword],
              decoration: const InputDecoration(
                labelText: '새 비밀번호',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            HoldToRevealPasswordField(
              controller: confirmController,
              enabled: !isSubmitting,
              autofillHints: const [AutofillHints.newPassword],
              decoration: InputDecoration(
                labelText: '새 비밀번호 확인',
                border: const OutlineInputBorder(),
                errorText: errorText,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: isSubmitting ? null : () => Navigator.of(context).pop(),
          child: const Text('나중에'),
        ),
        FilledButton(
          onPressed: isSubmitting ? null : submit,
          child: Text(isSubmitting ? '설정 중...' : '설정'),
        ),
      ],
    );
  }
}
