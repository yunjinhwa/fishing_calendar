import 'package:flutter/material.dart';

import '../../data/repositories/auth_session_repository.dart';
import '../auth/auth_access_guard.dart';
import '../auth/login_choice_page.dart';
import '../offline/offline_free_page.dart';
import '../offline/offline_guest_page.dart';
import '../offline/offline_paid_page.dart';
import '../sync/sync_conflict_page.dart';
import '../personal_best/personal_best_page.dart';

class MyPage extends StatelessWidget {
  const MyPage({super.key});

  @override
  Widget build(BuildContext context) {
    final authSession = AuthSessionRepository.instance;

    return AnimatedBuilder(
      animation: authSession,
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
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('플랜 정보 화면은 다음 단계에서 구현합니다.'),
                        ),
                      );
                    },
                  ),
                ),
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
                    leading: const Icon(Icons.sync_outlined),
                    title: const Text('동기화/충돌 관리'),
                    subtitle: const Text('충돌 알림과 동기화 상태를 확인합니다.'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
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
                  '오프라인 화면 테스트',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),

                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const OfflineGuestPage(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.person_off_outlined),
                  label: const Text('오프라인 + 비회원'),
                ),
                const SizedBox(height: 8),

                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const OfflineFreePage(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.phone_android_outlined),
                  label: const Text('오프라인 + 무료 회원'),
                ),
                const SizedBox(height: 8),

                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const OfflinePaidPage(),
                      ),
                    );
                  },
                  icon: const Icon(Icons.cloud_queue_outlined),
                  label: const Text('오프라인 + 유료 회원'),
                ),
                const SizedBox(height: 24),

                OutlinedButton.icon(
                  onPressed: () async {
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
