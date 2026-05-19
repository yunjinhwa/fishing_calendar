import 'package:flutter/material.dart';

import '../../data/models/outbox_item.dart';
import '../../data/repositories/outbox_memory_repository.dart';

class OutboxPage extends StatefulWidget {
  const OutboxPage({super.key});

  @override
  State<OutboxPage> createState() => _OutboxPageState();
}

class _OutboxPageState extends State<OutboxPage> {
  @override
  void initState() {
    super.initState();
    OutboxMemoryRepository.instance.seedMockItemsIfEmpty();
  }

  void mockUploadAllPendingItems() {
    final items = OutboxMemoryRepository.instance.getAllItems();

    for (final item in items) {
      if (item.status == OutboxStatus.pending ||
          item.status == OutboxStatus.failed) {
        OutboxMemoryRepository.instance.updateItemStatus(
          itemId: item.id,
          status: OutboxStatus.succeeded,
        );
      }
    }

    setState(() {});

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('대기 중인 항목을 모두 업로드 완료 처리했습니다.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = OutboxMemoryRepository.instance.getAllItems();

    return Scaffold(
      appBar: AppBar(
        title: const Text('업로드 대기열'),
        actions: [
          IconButton(
            onPressed: mockUploadAllPendingItems,
            icon: const Icon(Icons.cloud_upload_outlined),
            tooltip: '전체 mock 전송',
          ),
          IconButton(
            onPressed: () {
              setState(() {
                OutboxMemoryRepository.instance.clearSucceeded();
              });
            },
            icon: const Icon(Icons.cleaning_services_outlined),
            tooltip: '완료 항목 정리',
          ),
        ],
      ),
      body: items.isEmpty
          ? const _EmptyOutboxView()
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: items.length,
              separatorBuilder: (context, index) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final item = items[index];

                return _OutboxItemCard(
                  item: item,
                  onRetry: () {
                    setState(() {
                      OutboxMemoryRepository.instance.retryItem(item.id);
                    });

                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('재시도 대기 상태로 변경했습니다.'),
                      ),
                    );
                  },
                  onMockSuccess: () {
                    setState(() {
                      OutboxMemoryRepository.instance.updateItemStatus(
                        itemId: item.id,
                        status: OutboxStatus.succeeded,
                      );
                    });
                  },
                  onMockFail: () {
                    setState(() {
                      OutboxMemoryRepository.instance.updateItemStatus(
                        itemId: item.id,
                        status: OutboxStatus.failed,
                        errorMessage: 'mock 업로드 실패',
                      );
                    });
                  },
                );
              },
            ),
    );
  }
}

class _OutboxItemCard extends StatelessWidget {
  final OutboxItem item;
  final VoidCallback onRetry;
  final VoidCallback onMockSuccess;
  final VoidCallback onMockFail;

  const _OutboxItemCard({
    required this.item,
    required this.onRetry,
    required this.onMockSuccess,
    required this.onMockFail,
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
                  _statusIcon(item.status),
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
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

            if (item.errorMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                '실패 사유: ${item.errorMessage}',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],

            const SizedBox(height: 12),

            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (item.status == OutboxStatus.failed)
                  OutlinedButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('재시도'),
                  ),
                OutlinedButton.icon(
                  onPressed: onMockSuccess,
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('성공 처리'),
                ),
                OutlinedButton.icon(
                  onPressed: onMockFail,
                  icon: const Icon(Icons.error_outline),
                  label: const Text('실패 처리'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  IconData _statusIcon(OutboxStatus status) {
    switch (status) {
      case OutboxStatus.pending:
        return Icons.pending_actions_outlined;
      case OutboxStatus.sending:
        return Icons.sync_outlined;
      case OutboxStatus.succeeded:
        return Icons.check_circle_outline;
      case OutboxStatus.failed:
        return Icons.error_outline;
    }
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
              '업로드 대기열이 비어 있습니다.',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              '오프라인 상태에서 생성, 수정, 삭제한 요청이 이곳에 표시됩니다.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}