import 'package:flutter/material.dart';

import '../../core/validation/auth_input_validator.dart';
import '../../data/repositories/auth_session_repository.dart';
import '../../data/repositories/fishing_record_repository.dart';
import '../../data/services/network_status_service.dart';
import '../auth/auth_access_guard.dart';
import '../auth/login_choice_page.dart';
import '../offline/offline_mode_page.dart';
import '../plan/plan_page.dart';
import '../personal_best/personal_best_page.dart';
import '../sync/outbox_page.dart';
import '../sync/sync_conflict_page.dart';

class MyPage extends StatelessWidget {
  final NetworkStatusService? networkStatusService;

  const MyPage({super.key, this.networkStatusService});

  Future<void> _showPasswordSetupDialog(BuildContext context) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _PasswordSetupDialog(),
    );
  }

  Future<void> _showLegacyRecordImportDialog(BuildContext context) async {
    final repository = FishingRecordRepository.instance;
    if (!repository.canImportQuarantinedLegacyRecords) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('이전 기록 원본은 보존되어 있지만 안전하게 읽을 수 없습니다.')),
      );
      return;
    }

    final count = repository.quarantinedLegacyRecordCount ?? 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('이전 기기 기록 가져오기'),
          content: Text(
            '계정 정보 없이 저장된 이전 기록 $count건을 현재 계정으로 가져옵니다. '
            '공용 기기라면 다른 사용자의 기록일 수 있으므로 소유한 기록인지 확인해 주세요.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('가져오기'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !context.mounted) {
      return;
    }

    try {
      final importedCount = await repository.importQuarantinedLegacyRecords();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('이전 기록 $importedCount건을 가져왔습니다.')),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('이전 기록을 가져오지 못했습니다. 원본은 그대로 보존됩니다.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final authSession = AuthSessionRepository.instance;
    final recordRepository = FishingRecordRepository.instance;

    return AnimatedBuilder(
      animation: Listenable.merge([authSession, recordRepository]),
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(title: const Text('내정보')),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                CircleAvatar(
                  radius: 36,
                  backgroundColor: Theme.of(
                    context,
                  ).colorScheme.primaryContainer,
                  child: Icon(
                    Icons.person_outline,
                    size: 40,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(height: 16),

                Text(
                  authSession.displayName,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),

                Text(
                  '${authSession.planLabel} 상태입니다.',
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),

                Card(
                  child: ListTile(
                    leading: const Icon(Icons.workspace_premium_outlined),
                    title: const Text('플랜 정보'),
                    subtitle: Text('현재 ${authSession.planLabel}으로 이용 중입니다.'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const PlanPage()),
                      );
                    },
                  ),
                ),
                if (authSession.requiresPasswordSetup) ...[
                  const SizedBox(height: 8),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.password_outlined),
                      title: const Text('계정 비밀번호 설정 필요'),
                      subtitle: const Text(
                        '이전 버전에서 이전된 계정입니다. 로그아웃 전에 비밀번호를 설정해 주세요.',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _showPasswordSetupDialog(context),
                    ),
                  ),
                ],
                if (recordRepository.hasQuarantinedLegacyData) ...[
                  const SizedBox(height: 8),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.inventory_2_outlined),
                      title: const Text('이전 기기 기록 보관함'),
                      subtitle: Text(
                        recordRepository.canImportQuarantinedLegacyRecords
                            ? '계정 정보 없이 저장된 기록 '
                                  '${recordRepository.quarantinedLegacyRecordCount}건이 보존되어 있습니다.'
                            : '이전 기록 원본이 보존되어 있지만 자동으로 읽을 수 없습니다.',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _showLegacyRecordImportDialog(context),
                    ),
                  ),
                ],
                const SizedBox(height: 8),

                Card(
                  child: ListTile(
                    leading: const Icon(Icons.emoji_events_outlined),
                    title: const Text('내 기록어'),
                    subtitle: const Text('어종별 최고 크기와 최고 무게 기록을 확인합니다.'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      final allowed = await requireMemberAccess(
                        context,
                        message: '내 기록어는 로그인 후 확인할 수 있습니다.',
                      );

                      if (!allowed || !context.mounted) {
                        return;
                      }

                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const PersonalBestPage(),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),

                Card(
                  child: ListTile(
                    leading: Icon(
                      authSession.canUseCloudSync
                          ? Icons.sync_outlined
                          : Icons.lock_outline,
                    ),
                    title: const Text('동기화/충돌 관리'),
                    subtitle: Text(
                      authSession.canUseCloudSync
                          ? '충돌 알림과 동기화 상태를 확인합니다.'
                          : authSession.isPlanMigrationPending
                          ? '기존 기록을 업로드한 뒤 사용할 수 있습니다.'
                          : '유료 플랜에서 사용할 수 있습니다.',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      final allowed = await requirePaidAccess(
                        context,
                        message: '동기화와 충돌 관리는 유료 플랜에서 사용할 수 있습니다.',
                        migrationDestinationBuilder: (_) => const OutboxPage(),
                      );

                      if (!allowed || !context.mounted) {
                        return;
                      }

                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const SyncConflictPage(),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 24),

                Text(
                  '오프라인 이용',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),

                Card(
                  child: ListTile(
                    leading: Icon(
                      authSession.isPaid
                          ? Icons.cloud_queue_outlined
                          : Icons.phone_android_outlined,
                    ),
                    title: Text('${authSession.planLabel} 오프라인 이용'),
                    subtitle: Text(
                      authSession.isPaid
                          ? '캐시된 기록과 업로드 대기열을 사용합니다.'
                          : '기기에 저장된 기록을 작성하고 조회합니다.',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => OfflineModePage(
                            networkStatusService: networkStatusService,
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 24),

                OutlinedButton.icon(
                  onPressed: () async {
                    if (authSession.requiresPasswordSetup) {
                      await _showPasswordSetupDialog(context);
                      if (!context.mounted ||
                          authSession.requiresPasswordSetup) {
                        return;
                      }
                    }

                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (context) {
                        return AlertDialog(
                          title: const Text('로그아웃'),
                          content: const Text('현재 계정에서 로그아웃할까요?'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(false),
                              child: const Text('취소'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.of(context).pop(true),
                              child: const Text('로그아웃'),
                            ),
                          ],
                        );
                      },
                    );

                    if (confirmed != true || !context.mounted) {
                      return;
                    }

                    await authSession.logout();

                    if (!context.mounted) {
                      return;
                    }

                    Navigator.of(
                      context,
                      rootNavigator: true,
                    ).pushAndRemoveUntil(
                      MaterialPageRoute(
                        builder: (_) => const LoginChoicePage(),
                      ),
                      (route) => false,
                    );
                  },
                  icon: const Icon(Icons.logout),
                  label: const Text('로그아웃'),
                ),
              ],
            ),
          ),
        );
      },
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

    await AuthSessionRepository.instance.setPasswordForCurrentMember(password);
    if (mounted) {
      Navigator.of(context).pop();
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
            TextField(
              controller: passwordController,
              obscureText: true,
              enabled: !isSubmitting,
              decoration: const InputDecoration(
                labelText: '새 비밀번호',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: confirmController,
              obscureText: true,
              enabled: !isSubmitting,
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
