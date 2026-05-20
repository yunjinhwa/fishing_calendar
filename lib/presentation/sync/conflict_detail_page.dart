import 'package:flutter/material.dart';

import '../../data/models/conflict_item.dart';
import '../../data/repositories/conflict_memory_repository.dart';

class ConflictDetailPage extends StatelessWidget {
  final ConflictItem conflict;

  const ConflictDetailPage({
    super.key,
    required this.conflict,
  });

  void resolveConflict(
    BuildContext context,
    ConflictResolutionType resolutionType,
  ) {
    ConflictMemoryRepository.instance.resolveConflict(
      conflictId: conflict.id,
      resolutionType: resolutionType,
    );

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${_resolutionMessage(resolutionType)} 처리했습니다.'),
      ),
    );

    Navigator.of(context).pop(true);
  }

  String _resolutionMessage(ConflictResolutionType resolutionType) {
    switch (resolutionType) {
      case ConflictResolutionType.useMine:
        return '내 변경 적용';
      case ConflictResolutionType.useTheirs:
        return '상대 변경 적용';
      case ConflictResolutionType.manualMerge:
        return '직접 병합';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isResolved = conflict.status == ConflictStatus.resolved;

    return Scaffold(
      appBar: AppBar(
        title: const Text('충돌 상세'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              conflict.recordTitle,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),

            Row(
              children: [
                const Icon(Icons.place_outlined, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(conflict.location),
                ),
              ],
            ),
            const SizedBox(height: 12),

            _StatusCard(conflict: conflict),
            const SizedBox(height: 24),

            Text(
              '변경 내용 비교',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),

            ...conflict.fields.map(
              (field) => _ConflictFieldCard(field: field),
            ),

            const SizedBox(height: 24),

            if (isResolved)
              _ResolvedNotice(conflict: conflict)
            else ...[
              FilledButton.icon(
                onPressed: () {
                  resolveConflict(context, ConflictResolutionType.useMine);
                },
                icon: const Icon(Icons.person_outline),
                label: const Text('내 변경 적용'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () {
                  resolveConflict(context, ConflictResolutionType.useTheirs);
                },
                icon: const Icon(Icons.cloud_outlined),
                label: const Text('상대 변경 적용'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () {
                  resolveConflict(context, ConflictResolutionType.manualMerge);
                },
                icon: const Icon(Icons.merge_type_outlined),
                label: const Text('직접 선택하여 병합'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final ConflictItem conflict;

  const _StatusCard({
    required this.conflict,
  });

  @override
  Widget build(BuildContext context) {
    final isResolved = conflict.status == ConflictStatus.resolved;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              isResolved
                  ? Icons.check_circle_outline
                  : Icons.warning_amber_outlined,
              color: isResolved
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.error,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                isResolved
                    ? '해결 완료 · ${conflict.resolutionLabel}'
                    : '해결 필요',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConflictFieldCard extends StatelessWidget {
  final ConflictField field;

  const _ConflictFieldCard({
    required this.field,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              field.fieldName,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 12),

            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _ValueBox(
                    title: '내 변경',
                    value: field.mineValue,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _ValueBox(
                    title: '상대 변경',
                    value: field.theirsValue,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ValueBox extends StatelessWidget {
  final String title;
  final String value;

  const _ValueBox({
    required this.title,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Colors.grey.shade600,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _ResolvedNotice extends StatelessWidget {
  final ConflictItem conflict;

  const _ResolvedNotice({
    required this.conflict,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              Icons.check_circle_outline,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '이 충돌은 ${conflict.resolutionLabel} 방식으로 해결되었습니다.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}