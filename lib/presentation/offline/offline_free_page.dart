import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/repositories/auth_session_repository.dart';
import '../../data/services/network_status_service.dart';
import '../auth/auth_access_guard.dart';
import '../calendar/calendar_page.dart';
import '../common/top_card_notification.dart';
import '../record/record_form_page.dart';
import 'network_status_widgets.dart';

class OfflineFreePage extends StatelessWidget {
  final NetworkStatusService? networkStatusService;

  const OfflineFreePage({super.key, this.networkStatusService});

  @override
  Widget build(BuildContext context) {
    final networkStatus = networkStatusService ?? NetworkStatusService.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('오프라인 모드')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            NetworkStatusSummary(service: networkStatus, compact: true),
            const SizedBox(height: 12),

            const Card(
              child: ListTile(
                leading: Icon(Icons.save_outlined),
                title: Text('이 기기에 저장됨'),
                subtitle: Text('무료 회원은 이 기기에 저장된 로컬 기록을 작성하고 조회할 수 있습니다.'),
              ),
            ),
            const SizedBox(height: 16),

            FilledButton.icon(
              onPressed: () async {
                if (AuthSessionRepository.instance.isPaid) {
                  TopCardNotification.show(
                    context,
                    '유료 회원의 오프라인 변경은 업로드 대기열에 저장해야 합니다.',
                    type: TopCardNotificationType.warning,
                  );
                  return;
                }

                final allowed = await requireMemberAccess(
                  context,
                  message: '오프라인 기록 작성은 로그인 후 사용할 수 있습니다.',
                );

                if (!allowed || !context.mounted) {
                  return;
                }

                unawaited(
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const RecordFormPage()),
                  ),
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
            const SizedBox(height: 20),

            Card(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              child: const ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('오프라인에서는 날씨·물때·수온 정보가 제공되지 않습니다.'),
              ),
            ),

            NetworkStatusRetryButton(service: networkStatus),
          ],
        ),
      ),
    );
  }
}
