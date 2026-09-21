import 'package:flutter/material.dart';

import '../../data/models/user_plan_policy.dart';
import '../../data/repositories/auth_session_repository.dart';
import '../../data/repositories/outbox_repository.dart';
import '../auth/auth_access_guard.dart';
import '../calendar/calendar_page.dart';
import '../record/record_form_page.dart';
import '../sync/outbox_page.dart';

class OfflinePaidPage extends StatefulWidget {
  const OfflinePaidPage({super.key});

  @override
  State<OfflinePaidPage> createState() => _OfflinePaidPageState();
}

class _OfflinePaidPageState extends State<OfflinePaidPage> {
  @override
  void initState() {
    super.initState();
    AuthSessionRepository.instance.addListener(_handlePlanChange);
  }

  @override
  void dispose() {
    AuthSessionRepository.instance.removeListener(_handlePlanChange);
    super.dispose();
  }

  void _handlePlanChange() {
    if (!mounted || !AuthSessionRepository.instance.canUseOutbox) {
      return;
    }

    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final pendingCount = OutboxRepository.instance.pendingCount;
    return PaidFeatureGate(
      title: '오프라인 모드',
      message: '오프라인 업로드 대기열은 유료 플랜에서 사용할 수 있습니다.',
      capability: UserCapability.outbox,
      child: Scaffold(
        appBar: AppBar(title: const Text('오프라인 모드')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Icon(
                Icons.sync_problem_outlined,
                size: 64,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 24),

              Text(
                '오프라인 상태입니다',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),

              Text(
                '유료 회원은 오프라인에서 캐시된 기록만 조회할 수 있고, '
                '새 기록은 대기열에 저장된 뒤 온라인 복구 시 서버에 업로드됩니다.',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),

              Card(
                child: ListTile(
                  leading: const Icon(Icons.pending_actions_outlined),
                  title: const Text('업로드 대기'),
                  subtitle: const Text('서버 반영이 끝나지 않은 항목 수입니다.'),
                  trailing: Text('$pendingCount건'),
                ),
              ),
              const SizedBox(height: 12),

              Card(
                child: ListTile(
                  leading: const Icon(Icons.cached_outlined),
                  title: const Text('캐시 기록'),
                  subtitle: const Text('최근 캐시된 기록만 조회 가능합니다.'),
                  trailing: const Icon(Icons.cloud_queue),
                ),
              ),
              const SizedBox(height: 16),

              FilledButton.icon(
                onPressed: () async {
                  final allowed = await requireOutboxAccess(
                    context,
                    message: '오프라인 업로드 대기열은 유료 플랜에서 사용할 수 있습니다.',
                  );

                  if (!allowed || !context.mounted) {
                    return;
                  }

                  final saved = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(builder: (_) => const RecordFormPage()),
                  );

                  if (saved != true || !context.mounted) {
                    return;
                  }

                  setState(() {});

                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('오프라인 저장 요청이 업로드 대기열에 추가되었습니다.'),
                    ),
                  );
                },
                icon: const Icon(Icons.edit_note),
                label: const Text('기록 작성'),
              ),
              const SizedBox(height: 12),

              OutlinedButton.icon(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const CalendarPage()),
                  );
                },
                icon: const Icon(Icons.calendar_month_outlined),
                label: const Text('캘린더 보기'),
              ),
              const SizedBox(height: 12),

              OutlinedButton.icon(
                onPressed: () async {
                  final allowed = await requireOutboxAccess(
                    context,
                    message: '업로드 대기열은 유료 플랜에서 사용할 수 있습니다.',
                  );

                  if (!allowed || !context.mounted) {
                    return;
                  }

                  await Navigator.of(
                    context,
                  ).push(MaterialPageRoute(builder: (_) => const OutboxPage()));

                  if (mounted) {
                    setState(() {});
                  }
                },
                icon: const Icon(Icons.queue_outlined),
                label: const Text('대기열 보기'),
              ),
              const SizedBox(height: 12),

              TextButton.icon(
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('네트워크 연결 상태를 다시 확인합니다.')),
                  );
                },
                icon: const Icon(Icons.refresh),
                label: const Text('다시 시도'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
