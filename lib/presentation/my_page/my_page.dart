import 'package:flutter/material.dart';

import '../../data/auth/auth_gateway.dart';
import '../../data/repositories/auth_session_repository.dart';
import '../../data/repositories/fishing_record_repository.dart';
import '../../data/services/network_status_service.dart';
import '../app_info/app_info_page.dart';
import '../auth/auth_access_guard.dart';
import '../auth/account_management_dialogs.dart';
import '../auth/auth_error_message.dart';
import '../auth/login_choice_page.dart';
import '../common/top_card_notification.dart';
import '../legal/policy_document_page.dart';
import '../offline/offline_mode_page.dart';
import '../plan/plan_page.dart';
import '../personal_best/personal_best_page.dart';
import '../profile/profile_settings_page.dart';
import '../sync/outbox_page.dart';
import '../sync/sync_conflict_page.dart';

class MyPage extends StatelessWidget {
  final NetworkStatusService? networkStatusService;

  const MyPage({super.key, this.networkStatusService});

  Future<void> _showPasswordSetupDialog(BuildContext context) =>
      showMemberPasswordSetupDialog(context);

  Future<void> _showLegacyRecordImportDialog(BuildContext context) async {
    final repository = FishingRecordRepository.instance;
    if (!repository.canImportQuarantinedLegacyRecords) {
      TopCardNotification.show(
        context,
        '이전 기록 원본은 보존되어 있지만 안전하게 읽을 수 없습니다.',
        type: TopCardNotificationType.warning,
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
        TopCardNotification.show(
          context,
          '이전 기록 $importedCount건을 가져왔습니다.',
          type: TopCardNotificationType.success,
        );
      }
    } catch (_) {
      if (context.mounted) {
        TopCardNotification.show(
          context,
          '이전 기록을 가져오지 못했습니다. 원본은 그대로 보존됩니다.',
          type: TopCardNotificationType.error,
        );
      }
    }
  }

  Future<void> _logout(
    BuildContext context, {
    bool requireConfirmation = true,
  }) async {
    final authSession = AuthSessionRepository.instance;
    if (requireConfirmation && authSession.requiresPasswordSetup) {
      await _showPasswordSetupDialog(context);
      if (!context.mounted || authSession.requiresPasswordSetup) {
        return;
      }
    }

    if (requireConfirmation) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: const Text('로그아웃'),
            content: const Text('현재 계정에서 로그아웃할까요?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('로그아웃'),
              ),
            ],
          );
        },
      );
      if (confirmed != true || !context.mounted) {
        return;
      }
    }

    try {
      await authSession.logout();
    } on AuthFailure catch (failure) {
      if (context.mounted) {
        TopCardNotification.show(
          context,
          authFailureMessage(failure),
          type: TopCardNotificationType.error,
        );
      }
    }

    if (!context.mounted) {
      return;
    }
    Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginChoicePage()),
      (route) => false,
    );
  }

  Widget _buildRemotelyDeletedPage(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('내정보')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 48),
            Icon(Icons.person_off_outlined, size: 64, color: colors.error),
            const SizedBox(height: 20),
            Text(
              '해당 계정은 탈퇴되었습니다',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            const Text(
              '다른 기기에서 회원 탈퇴가 처리되어 이 계정은 더 이상 사용할 수 없습니다. 로그아웃해 주세요.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: () => _logout(context, requireConfirmation: false),
              icon: const Icon(Icons.logout),
              label: const Text('로그아웃'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final authSession = AuthSessionRepository.instance;
    final recordRepository = FishingRecordRepository.instance;

    return AnimatedBuilder(
      animation: Listenable.merge([authSession, recordRepository]),
      builder: (context, _) {
        if (authSession.isAccountDeletedRemotely) {
          return _buildRemotelyDeletedPage(context);
        }
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
                    key: const ValueKey('my-page-profile-settings'),
                    leading: const Icon(Icons.manage_accounts_outlined),
                    title: const Text('프로필 설정'),
                    subtitle: Text(
                      authSession.canResumeAccountDeletion
                          ? '중단된 회원 탈퇴를 계속할 수 있습니다.'
                          : '이메일을 확인하고 닉네임을 변경합니다.',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap:
                        authSession.isAuthOperationInProgress ||
                            (authSession.isMember &&
                                !authSession.canEditProfile &&
                                !authSession.canResumeAccountDeletion)
                        ? null
                        : () async {
                            if (!authSession.canEditProfile &&
                                !authSession.canResumeAccountDeletion) {
                              final allowed = await requireMemberAccess(
                                context,
                                message: '프로필 설정은 로그인 후 이용할 수 있습니다.',
                              );
                              if (!allowed || !context.mounted) return;
                            }
                            if (!context.mounted ||
                                (!authSession.canEditProfile &&
                                    !authSession.canResumeAccountDeletion)) {
                              return;
                            }
                            await Navigator.of(context).push<void>(
                              MaterialPageRoute(
                                builder: (_) => const ProfileSettingsPage(),
                              ),
                            );
                          },
                  ),
                ),
                const SizedBox(height: 8),

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

                Card(
                  child: ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: const Text('앱 정보'),
                    subtitle: const Text('버전·자료 출처·오픈소스 라이선스'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(builder: (_) => const AppInfoPage()),
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                Text(
                  '약관 및 정책',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: Column(
                    children: [
                      for (final document in PolicyDocument.values)
                        ListTile(
                          leading: Icon(
                            document == PolicyDocument.terms
                                ? Icons.description_outlined
                                : Icons.privacy_tip_outlined,
                          ),
                          title: Text(document.title),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.of(context).push<void>(
                            MaterialPageRoute(
                              builder: (_) =>
                                  PolicyDocumentPage(document: document),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                OutlinedButton.icon(
                  onPressed: () => _logout(context),
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
