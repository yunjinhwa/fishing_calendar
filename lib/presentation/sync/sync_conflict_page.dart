import 'package:flutter/material.dart';

import '../../data/models/conflict_item.dart';
import '../../data/repositories/conflict_memory_repository.dart';
import 'conflict_detail_page.dart';

class SyncConflictPage extends StatefulWidget {
  const SyncConflictPage({super.key});

  @override
  State<SyncConflictPage> createState() => _SyncConflictPageState();
}

class _SyncConflictPageState extends State<SyncConflictPage> {
  @override
  void initState() {
    super.initState();
    ConflictMemoryRepository.instance.seedMockItemsIfEmpty();
  }

  @override
  Widget build(BuildContext context) {
    final conflicts = ConflictMemoryRepository.instance.getAllItems();
    final unresolvedCount = ConflictMemoryRepository.instance.unresolvedCount;

    return Scaffold(
      appBar: AppBar(
        title: const Text('동기화/충돌 관리'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Icon(
                      unresolvedCount == 0
                          ? Icons.cloud_done_outlined
                          : Icons.sync_problem_outlined,
                      size: 48,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      unresolvedCount == 0
                          ? '모든 데이터가 최신 상태입니다.'
                          : '해결이 필요한 충돌이 있습니다.',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '미해결 충돌 $unresolvedCount건',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            Text(
              '충돌 알림',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),

            if (conflicts.isEmpty)
              const _EmptyConflictView()
            else
              ...conflicts.map(
                (conflict) => _ConflictCard(
                  conflict: conflict,
                  onTap: () async {
                    final changed = await Navigator.of(context).push<bool>(
                      MaterialPageRoute(
                        builder: (_) => ConflictDetailPage(
                          conflict: conflict,
                        ),
                      ),
                    );

                    if (changed == true && context.mounted) {
                      setState(() {});
                    }
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ConflictCard extends StatelessWidget {
  final ConflictItem conflict;
  final VoidCallback onTap;

  const _ConflictCard({
    required this.conflict,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isResolved = conflict.status == ConflictStatus.resolved;

    return Card(
      child: ListTile(
        leading: Icon(
          isResolved
              ? Icons.check_circle_outline
              : Icons.warning_amber_outlined,
          color: isResolved
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.error,
        ),
        title: Text(conflict.recordTitle),
        subtitle: Text(
          '${conflict.location}\n'
          '${_formatDateTime(conflict.occurredAt)} · ${conflict.statusLabel}',
        ),
        isThreeLine: true,
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }

  String _formatDateTime(DateTime dateTime) {
    String twoDigits(int value) => value.toString().padLeft(2, '0');

    return '${dateTime.year}.${twoDigits(dateTime.month)}.${twoDigits(dateTime.day)} '
        '${twoDigits(dateTime.hour)}:${twoDigits(dateTime.minute)}';
  }
}

class _EmptyConflictView extends StatelessWidget {
  const _EmptyConflictView();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(
              Icons.check_circle_outline,
              size: 48,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 12),
            Text(
              '충돌 알림이 없습니다.',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              '동기화 충돌이 발생하면 이곳에 표시됩니다.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}