import 'package:flutter/material.dart';

import '../../data/models/conflict_item.dart';
import '../../data/repositories/auth_session_repository.dart';
import '../../data/repositories/conflict_memory_repository.dart';
import '../../data/services/record_sync_service.dart';
import '../auth/auth_access_guard.dart';
import 'conflict_detail_page.dart';
import 'outbox_page.dart';

class SyncConflictPage extends StatefulWidget {
  const SyncConflictPage({super.key});

  @override
  State<SyncConflictPage> createState() => _SyncConflictPageState();
}

class _SyncConflictPageState extends State<SyncConflictPage> {
  bool _isManualSyncPending = false;

  @override
  void initState() {
    super.initState();
    AuthSessionRepository.instance.addListener(_handlePlanChange);
    RecordSyncService.instance.addListener(_handleSyncChange);
  }

  @override
  void dispose() {
    AuthSessionRepository.instance.removeListener(_handlePlanChange);
    RecordSyncService.instance.removeListener(_handleSyncChange);
    super.dispose();
  }

  void _handlePlanChange() {
    if (!mounted || !AuthSessionRepository.instance.canUseCloudSync) {
      return;
    }

    setState(() {});
  }

  void _handleSyncChange() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _syncNow() async {
    if (_isManualSyncPending || RecordSyncService.instance.isSyncing) {
      return;
    }

    setState(() {
      _isManualSyncPending = true;
    });

    final result = await RecordSyncService.instance.syncNow();
    if (!mounted) return;

    final message = switch (result.skipReason) {
      RecordSyncSkipReason.gatewayUnavailable =>
        'Firebase가 연결된 빌드에서 동기화할 수 있습니다.',
      RecordSyncSkipReason.signedOut => '로그인 후 동기화할 수 있습니다.',
      RecordSyncSkipReason.paidPlanRequired => '유료 플랜에서 동기화할 수 있습니다.',
      RecordSyncSkipReason.offline => '인터넷 연결을 확인한 뒤 다시 시도하세요.',
      RecordSyncSkipReason.sessionChanged => '계정이 변경되어 동기화를 중단했습니다.',
      RecordSyncSkipReason.none when result.isSuccess => '동기화를 완료했습니다.',
      RecordSyncSkipReason.none => result.errorMessage ?? '기록을 동기화하지 못했습니다.',
    };
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));

    setState(() {
      _isManualSyncPending = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final conflicts = ConflictMemoryRepository.instance.getUnresolvedItems();
    final unresolvedCount = ConflictMemoryRepository.instance.unresolvedCount;
    final syncService = RecordSyncService.instance;
    final isSyncing = syncService.isSyncing || _isManualSyncPending;
    final syncStatus = _syncStatusFor(syncService, unresolvedCount);

    return PaidFeatureGate(
      title: '동기화/충돌 관리',
      message: '동기화와 충돌 관리는 유료 플랜에서 사용할 수 있습니다.',
      migrationDestinationBuilder: (_) => const OutboxPage(),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('동기화/충돌 관리'),
          actions: [
            IconButton(
              onPressed: isSyncing ? null : _syncNow,
              tooltip: '지금 동기화',
              icon: isSyncing
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync),
            ),
          ],
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
                        syncStatus.icon,
                        size: 48,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        syncStatus.title,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        syncStatus.detail,
                        style: Theme.of(context).textTheme.bodyMedium,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              Text(
                '충돌 알림',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
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
                          builder: (_) =>
                              ConflictDetailPage(conflict: conflict),
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
      ),
    );
  }

  String _syncStatusText(DateTime? lastSyncedAt, int unresolvedCount) {
    if (lastSyncedAt == null) {
      return '동기화 완료 · 미해결 충돌 $unresolvedCount건';
    }
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    return '마지막 동기화 '
        '${lastSyncedAt.year}.${twoDigits(lastSyncedAt.month)}.'
        '${twoDigits(lastSyncedAt.day)} '
        '${twoDigits(lastSyncedAt.hour)}:${twoDigits(lastSyncedAt.minute)}'
        ' · 미해결 충돌 $unresolvedCount건';
  }

  _SyncStatusPresentation _syncStatusFor(
    RecordSyncService syncService,
    int unresolvedCount,
  ) {
    if (syncService.isSyncing || _isManualSyncPending) {
      return _SyncStatusPresentation(
        icon: Icons.sync,
        title: '서버 기록을 동기화하고 있습니다.',
        detail: '미해결 충돌 $unresolvedCount건',
      );
    }

    if (syncService.state == RecordSyncState.failed) {
      return _SyncStatusPresentation(
        icon: Icons.cloud_off_outlined,
        title: '최근 동기화에 실패했습니다.',
        detail:
            syncService.lastError ??
            '잠시 후 다시 시도하세요. · 미해결 충돌 $unresolvedCount건',
      );
    }

    final lastResult = syncService.lastResult;
    if (syncService.state == RecordSyncState.succeeded &&
        lastResult?.isSuccess == true) {
      return _SyncStatusPresentation(
        icon: unresolvedCount == 0
            ? Icons.cloud_done_outlined
            : Icons.sync_problem_outlined,
        title: unresolvedCount == 0 ? '모든 데이터가 최신 상태입니다.' : '해결이 필요한 충돌이 있습니다.',
        detail: _syncStatusText(syncService.lastSyncedAt, unresolvedCount),
      );
    }

    final skippedStatus = switch (lastResult?.skipReason) {
      RecordSyncSkipReason.gatewayUnavailable => const (
        title: '동기화 기능을 사용할 수 없습니다.',
        detail: 'Firebase가 연결된 빌드에서 다시 시도하세요.',
      ),
      RecordSyncSkipReason.signedOut => const (
        title: '로그인이 필요합니다.',
        detail: '로그인 후 서버 기록을 동기화할 수 있습니다.',
      ),
      RecordSyncSkipReason.paidPlanRequired => const (
        title: '유료 플랜이 필요합니다.',
        detail: '유료 플랜에서 서버 기록을 동기화할 수 있습니다.',
      ),
      RecordSyncSkipReason.offline => const (
        title: '인터넷 연결이 없습니다.',
        detail: '연결을 확인한 뒤 다시 시도하세요.',
      ),
      RecordSyncSkipReason.sessionChanged => const (
        title: '계정 변경으로 동기화를 중단했습니다.',
        detail: '현재 계정에서 다시 동기화해 주세요.',
      ),
      RecordSyncSkipReason.none || null => const (
        title: '아직 서버 동기화 전입니다.',
        detail: '지금 동기화를 눌러 서버 상태를 확인하세요.',
      ),
    };

    return _SyncStatusPresentation(
      icon: Icons.cloud_queue_outlined,
      title: skippedStatus.title,
      detail: '${skippedStatus.detail} · 미해결 충돌 $unresolvedCount건',
    );
  }
}

class _SyncStatusPresentation {
  final IconData icon;
  final String title;
  final String detail;

  const _SyncStatusPresentation({
    required this.icon,
    required this.title,
    required this.detail,
  });
}

class _ConflictCard extends StatelessWidget {
  final ConflictItem conflict;
  final VoidCallback onTap;

  const _ConflictCard({required this.conflict, required this.onTap});

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
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
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
