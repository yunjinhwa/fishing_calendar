import 'package:flutter/material.dart';

import '../../data/models/user_plan.dart';
import '../../data/repositories/auth_session_repository.dart';
import '../../data/services/plan_policy_service.dart';

class PlanPage extends StatefulWidget {
  const PlanPage({super.key});

  @override
  State<PlanPage> createState() => _PlanPageState();
}

class _PlanPageState extends State<PlanPage> {
  bool isChanging = false;

  Future<void> changePlan(UserPlan nextPlan) async {
    final authSession = AuthSessionRepository.instance;
    final upgrading = nextPlan == UserPlan.paid;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(upgrading ? '유료 플랜으로 변경' : '무료 플랜으로 변경'),
          content: Text(
            upgrading
                ? '클라우드 동기화, 최근 31일 캐시, 오프라인 업로드 대기열을 사용할 수 있습니다. '
                      '기존 로컬 기록의 클라우드 이전은 동기화 단계에서 진행됩니다.'
                : '클라우드 동기화와 새 업로드가 중지됩니다. '
                      '현재 기기에 저장된 로컬 기록은 유지됩니다.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('변경'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !mounted) {
      return;
    }

    setState(() {
      isChanging = true;
    });

    try {
      final result = await PlanPolicyService.instance.changePlan(nextPlan);

      if (!mounted) {
        return;
      }

      setState(() {
        isChanging = false;
      });

      if (result == PlanChangeResult.blockedByPendingUploads) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('업로드 대기 또는 실패 항목을 처리한 뒤 무료 플랜으로 변경하세요.'),
          ),
        );
        return;
      }

      final message = authSession.isPlanMigrationPending
          ? '유료 플랜으로 변경했습니다. 기존 기록은 업로드 대기열에서 이전됩니다.'
          : '${nextPlan.label}으로 변경했습니다.';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        isChanging = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('플랜을 변경하지 못했습니다. 다시 시도하세요.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final authSession = AuthSessionRepository.instance;

    return AnimatedBuilder(
      animation: authSession,
      builder: (context, _) {
        if (!authSession.isMember) {
          return Scaffold(
            appBar: AppBar(title: const Text('플랜 정보')),
            body: const SafeArea(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    '플랜 정보는 로그인 후 확인할 수 있습니다.',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          );
        }

        final isPaid = authSession.isPaid;

        return Scaffold(
          appBar: AppBar(title: const Text('플랜 정보')),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        Icon(
                          isPaid
                              ? Icons.workspace_premium
                              : Icons.person_outline,
                          size: 48,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          authSession.planLabel,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          isPaid
                              ? authSession.isPlanMigrationPending
                                    ? '기존 로컬 기록을 클라우드로 이전할 준비 중입니다.'
                                    : '클라우드 동기화와 오프라인 업로드 대기열을 사용할 수 있습니다.'
                              : '출조 기록 원본을 현재 기기에 저장합니다.',
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  '현재 이용 범위',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                if (isPaid) ...[
                  if (authSession.isPlanMigrationPending)
                    const _PlanFeature(
                      icon: Icons.cloud_upload_outlined,
                      title: '기존 기록 이전 대기',
                      description: '업로드 대기열을 모두 처리하면 클라우드 동기화가 활성화됩니다.',
                    ),
                  const _PlanFeature(
                    icon: Icons.cloud_done_outlined,
                    title: '클라우드 원본',
                    description: '서버에 반영된 기록을 원본으로 관리합니다.',
                  ),
                  const _PlanFeature(
                    icon: Icons.cached_outlined,
                    title: '최근 31일 로컬 캐시',
                    description: '최근 기록은 기기에 캐시해 빠르게 확인합니다.',
                  ),
                  const _PlanFeature(
                    icon: Icons.pending_actions_outlined,
                    title: '오프라인 업로드 대기열',
                    description: '오프라인 변경 사항을 보관하고 연결 복구 후 반영합니다.',
                  ),
                  const _PlanFeature(
                    icon: Icons.sync_problem_outlined,
                    title: '동기화 및 충돌 관리',
                    description: '업로드 상태와 충돌 알림을 확인할 수 있습니다.',
                  ),
                ] else ...[
                  const _PlanFeature(
                    icon: Icons.phone_android_outlined,
                    title: '로컬 원본',
                    description: '출조 기록을 현재 기기에 보관합니다.',
                  ),
                  const _PlanFeature(
                    icon: Icons.edit_note_outlined,
                    title: '오프라인 기록 관리',
                    description: '인터넷 없이 기록을 작성하고 조회할 수 있습니다.',
                  ),
                  const _PlanFeature(
                    icon: Icons.cloud_off_outlined,
                    title: '클라우드 동기화 미포함',
                    description: '업로드 대기열과 충돌 관리는 유료 플랜에서 제공됩니다.',
                  ),
                ],
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: isPaid
                      ? OutlinedButton(
                          onPressed: isChanging
                              ? null
                              : () => changePlan(UserPlan.free),
                          child: Text(isChanging ? '변경 중...' : '무료 플랜으로 변경'),
                        )
                      : FilledButton(
                          onPressed: isChanging
                              ? null
                              : () => changePlan(UserPlan.paid),
                          child: Text(isChanging ? '변경 중...' : '유료 플랜으로 변경'),
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _PlanFeature extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;

  const _PlanFeature({
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(description),
      ),
    );
  }
}
