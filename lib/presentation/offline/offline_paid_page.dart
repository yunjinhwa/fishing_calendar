import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/models/user_plan_policy.dart';
import '../../data/repositories/auth_session_repository.dart';
import '../../data/repositories/outbox_repository.dart';
import '../../data/services/network_status_service.dart';
import '../auth/auth_access_guard.dart';
import '../calendar/calendar_page.dart';
import '../common/top_card_notification.dart';
import '../record/record_form_page.dart';
import '../sync/outbox_page.dart';
import 'network_status_widgets.dart';

class OfflinePaidPage extends StatefulWidget {
  final NetworkStatusService? networkStatusService;

  const OfflinePaidPage({super.key, this.networkStatusService});

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
    final networkStatus =
        widget.networkStatusService ?? NetworkStatusService.instance;
    final pendingCount = OutboxRepository.instance.pendingCount;
    return PaidFeatureGate(
      title: '오프라인 모드',
      message: '오프라인 업로드 대기열은 유료 플랜에서 사용할 수 있습니다.',
      capability: UserCapability.outbox,
      child: Scaffold(
        appBar: AppBar(title: const Text('오프라인 모드')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              NetworkStatusSummary(service: networkStatus, compact: true),
              const SizedBox(height: 12),

              Card(
                child: ListTile(
                  leading: const Icon(Icons.pending_actions_outlined),
                  title: const Text('업로드 대기'),
                  subtitle: const Text('인터넷에 연결되면 대기 중인 변경 사항을 서버에 반영합니다.'),
                  trailing: Text(
                    '$pendingCount건',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
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

                  TopCardNotification.show(
                    context,
                    '오프라인 저장 요청이 업로드 대기열에 추가되었습니다.',
                    type: TopCardNotificationType.success,
                  );
                },
                icon: const Icon(Icons.edit_note),
                label: const Text('기록 작성'),
              ),
              const SizedBox(height: 12),

              OutlinedButton.icon(
                onPressed: () {
                  unawaited(
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const CalendarPage()),
                    ),
                  );
                },
                icon: const Icon(Icons.calendar_month_outlined),
                label: const Text('캘린더 보기'),
              ),
              const SizedBox(height: 12),

              FilledButton.tonalIcon(
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
              const SizedBox(height: 20),

              Card(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                child: const ListTile(
                  leading: Icon(Icons.cached_outlined),
                  title: Text('캐시 기록'),
                  subtitle: Text(
                    '유료 회원은 오프라인에서 캐시된 기록만 확인할 수 있습니다. '
                    '연결 전에는 일부 기록이 최신 상태가 아닐 수 있습니다.',
                  ),
                ),
              ),

              NetworkStatusRetryButton(service: networkStatus),
            ],
          ),
        ),
      ),
    );
  }
}
