import 'package:flutter/material.dart';

import '../../data/models/outbox_item.dart';
import '../../data/models/user_plan_policy.dart';
import '../../data/repositories/auth_session_repository.dart';
import '../../data/repositories/outbox_repository.dart';
import '../../data/services/record_sync_service.dart';
import '../auth/auth_access_guard.dart';
import '../common/top_card_notification.dart';

class OutboxPage extends StatefulWidget {
  const OutboxPage({super.key});

  @override
  State<OutboxPage> createState() => _OutboxPageState();
}

class _OutboxPageState extends State<OutboxPage> {
  String? _retryingItemId;

  @override
  void initState() {
    super.initState();
    AuthSessionRepository.instance.addListener(_refresh);
    RecordSyncService.instance.addListener(_refresh);
  }

  @override
  void dispose() {
    AuthSessionRepository.instance.removeListener(_refresh);
    RecordSyncService.instance.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _syncAllPendingItems() async {
    final result = await RecordSyncService.instance.syncNow();
    if (!mounted) return;

    final message = switch (result.skipReason) {
      RecordSyncSkipReason.gatewayUnavailable =>
        'Firebase가 연결된 빌드에서 동기화할 수 있습니다.',
      RecordSyncSkipReason.signedOut => '로그인 후 동기화할 수 있습니다.',
      RecordSyncSkipReason.paidPlanRequired => '유료 플랜에서 동기화할 수 있습니다.',
      RecordSyncSkipReason.offline => '인터넷 연결을 확인한 뒤 다시 시도하세요.',
      RecordSyncSkipReason.sessionChanged => '계정이 변경되어 동기화를 중단했습니다.',
      RecordSyncSkipReason.none when result.isSuccess =>
        '서버 동기화를 완료했습니다. 업로드 ${result.pushedCount}건',
      RecordSyncSkipReason.none => result.errorMessage ?? '기록을 동기화하지 못했습니다.',
    };
    TopCardNotification.show(
      context,
      message,
      type: result.skipReason != RecordSyncSkipReason.none
          ? TopCardNotificationType.warning
          : result.isSuccess
          ? TopCardNotificationType.success
          : TopCardNotificationType.error,
    );
  }

  Future<void> _retryItem(String itemId) async {
    if (_retryingItemId != null || RecordSyncService.instance.isSyncing) {
      return;
    }

    setState(() {
      _retryingItemId = itemId;
    });

    try {
      await OutboxRepository.instance.retryItem(itemId);
      await _syncAllPendingItems();
    } on Object {
      if (mounted) {
        TopCardNotification.show(
          context,
          '재시도 요청을 처리하지 못했습니다.',
          type: TopCardNotificationType.error,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _retryingItemId = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = OutboxRepository.instance.getAllItems();
    final failedItems = items
        .where((item) => item.status == OutboxStatus.failed)
        .toList(growable: false);
    final syncService = RecordSyncService.instance;
    final canStartQueueAction =
        !syncService.isSyncing && _retryingItemId == null;
    final hasSendableItems =
        failedItems.isNotEmpty ||
        items.any((item) => item.status == OutboxStatus.pending);

    return PaidFeatureGate(
      title: '업로드 대기열',
      message: '업로드 대기열은 유료 플랜에서 사용할 수 있습니다.',
      capability: UserCapability.outbox,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('업로드 대기열'),
          actions: [
            IconButton(
              onPressed: canStartQueueAction && hasSendableItems
                  ? _syncAllPendingItems
                  : null,
              icon: syncService.isSyncing
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_upload_outlined),
              tooltip: '전체 전송 처리',
            ),
          ],
        ),
        body: failedItems.isEmpty
            ? const _EmptyOutboxView()
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: failedItems.length,
                separatorBuilder: (context, index) =>
                    const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final item = failedItems[index];

                  return _FailedOutboxItemCard(
                    item: item,
                    isRetrying: _retryingItemId == item.id,
                    onRetry: canStartQueueAction
                        ? () => _retryItem(item.id)
                        : null,
                  );
                },
              ),
      ),
    );
  }
}

class _FailedOutboxItemCard extends StatelessWidget {
  final OutboxItem item;
  final bool isRetrying;
  final VoidCallback? onRetry;

  const _FailedOutboxItemCard({
    required this.item,
    required this.isRetrying,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.error_outline,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${item.isMigration ? '기존 기록 이전 · ' : ''}'
                    '${item.operationLabel} 요청 · ${item.statusLabel}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('기록 ID: ${item.recordId}'),
            const SizedBox(height: 4),
            Text('생성 시각: ${_formatDateTime(item.createdAt)}'),

            if (item.lastTriedAt != null) ...[
              const SizedBox(height: 4),
              Text('마지막 시도: ${_formatDateTime(item.lastTriedAt!)}'),
            ],

            if (item.retryCount > 0) ...[
              const SizedBox(height: 4),
              Text('재시도 횟수: ${item.retryCount}회'),
            ],

            if (item.errorMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                '실패 사유: ${item.errorMessage}',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],

            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: isRetrying
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              label: Text(isRetrying ? '재시도 중' : '재시도'),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDateTime(DateTime dateTime) {
    String twoDigits(int value) => value.toString().padLeft(2, '0');

    return '${dateTime.year}.${twoDigits(dateTime.month)}.${twoDigits(dateTime.day)} '
        '${twoDigits(dateTime.hour)}:${twoDigits(dateTime.minute)}';
  }
}

class _EmptyOutboxView extends StatelessWidget {
  const _EmptyOutboxView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.inbox_outlined,
              size: 56,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              '실패한 업로드가 없습니다.',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }
}
