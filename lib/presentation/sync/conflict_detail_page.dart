import 'package:flutter/material.dart';

import '../../core/validation/fishing_record_validator.dart';
import '../../data/models/conflict_item.dart';
import '../../data/models/fishing_record.dart';
import '../../data/repositories/conflict_repository.dart';
import '../../data/services/conflict_resolution_service.dart';

class ConflictDetailPage extends StatefulWidget {
  final ConflictItem conflict;

  const ConflictDetailPage({super.key, required this.conflict});

  @override
  State<ConflictDetailPage> createState() => _ConflictDetailPageState();
}

class _ConflictDetailPageState extends State<ConflictDetailPage> {
  bool _isResolving = false;

  ConflictItem get _conflict =>
      ConflictRepository.instance.findById(widget.conflict.id) ??
      widget.conflict;

  @override
  void initState() {
    super.initState();
    ConflictRepository.instance.addListener(_handleConflictChange);
  }

  @override
  void dispose() {
    ConflictRepository.instance.removeListener(_handleConflictChange);
    super.dispose();
  }

  void _handleConflictChange() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _resolve(
    ConflictResolutionType resolutionType, {
    FishingRecord? mergedRecord,
  }) async {
    if (_isResolving || _conflict.status != ConflictStatus.unresolved) {
      return;
    }
    setState(() {
      _isResolving = true;
    });

    try {
      switch (resolutionType) {
        case ConflictResolutionType.useMine:
          await ConflictResolutionService.instance.useMine(_conflict);
        case ConflictResolutionType.useTheirs:
          await ConflictResolutionService.instance.useTheirs(_conflict);
        case ConflictResolutionType.manualMerge:
          if (mergedRecord == null) {
            throw StateError('병합할 기록이 없습니다.');
          }
          await ConflictResolutionService.instance.useMerged(
            _conflict,
            mergedRecord,
          );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_resolutionMessage(resolutionType))),
      );
      Navigator.of(context).pop(true);
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_errorMessage(error))));
      setState(() {
        _isResolving = false;
      });
    }
  }

  Future<void> _openManualMerge() async {
    final conflict = _conflict;
    if (!conflict.canManualMerge || _isResolving) {
      return;
    }
    final mergedRecord = await Navigator.of(context).push<FishingRecord>(
      MaterialPageRoute(builder: (_) => _ManualMergePage(conflict: conflict)),
    );
    if (mergedRecord != null && mounted) {
      await _resolve(
        ConflictResolutionType.manualMerge,
        mergedRecord: mergedRecord,
      );
    }
  }

  String _resolutionMessage(ConflictResolutionType resolutionType) {
    return switch (resolutionType) {
      ConflictResolutionType.useMine => '내 변경을 새 동기화 요청으로 저장했습니다.',
      ConflictResolutionType.useTheirs => '최신 서버 변경을 이 기기에 적용했습니다.',
      ConflictResolutionType.manualMerge => '병합 결과를 새 동기화 요청으로 저장했습니다.',
    };
  }

  String _errorMessage(Object error) {
    if (error is StateError) {
      return error.message.toString();
    }
    return '충돌 해결을 처리하지 못했습니다. 잠시 후 다시 시도하세요.';
  }

  @override
  Widget build(BuildContext context) {
    final conflict = _conflict;
    final isResolved = conflict.status == ConflictStatus.resolved;
    final isResolving =
        conflict.status == ConflictStatus.resolving || _isResolving;

    return Scaffold(
      appBar: AppBar(title: const Text('충돌 상세')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              conflict.recordTitle,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.place_outlined, size: 18),
                const SizedBox(width: 6),
                Expanded(child: Text(conflict.location)),
              ],
            ),
            const SizedBox(height: 12),
            _StatusCard(conflict: conflict),
            const SizedBox(height: 24),
            Text(
              '변경 내용 비교',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ...conflict.fields.map((field) => _ConflictFieldCard(field: field)),
            const SizedBox(height: 24),
            if (isResolved)
              _ResolvedNotice(conflict: conflict)
            else if (isResolving)
              const _ResolvingNotice()
            else ...[
              FilledButton.icon(
                onPressed: () => _resolve(ConflictResolutionType.useMine),
                icon: const Icon(Icons.person_outline),
                label: const Text('내 변경 적용'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => _resolve(ConflictResolutionType.useTheirs),
                icon: const Icon(Icons.cloud_outlined),
                label: const Text('서버 변경 적용'),
              ),
              if (conflict.canManualMerge) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _openManualMerge,
                  icon: const Icon(Icons.merge_type_outlined),
                  label: const Text('필드별로 선택하여 병합'),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _ManualMergePage extends StatefulWidget {
  final ConflictItem conflict;

  const _ManualMergePage({required this.conflict});

  @override
  State<_ManualMergePage> createState() => _ManualMergePageState();
}

class _ManualMergePageState extends State<_ManualMergePage> {
  final Set<String> _remoteFieldKeys = <String>{};

  void _completeMerge() {
    final merged = widget.conflict.buildMergedRecord(_remoteFieldKeys);
    final validationMessage = FishingRecordValidator.validate(merged);
    if (validationMessage != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(validationMessage)));
      return;
    }
    Navigator.of(context).pop(merged);
  }

  @override
  Widget build(BuildContext context) {
    final fields = widget.conflict.fields
        .where(
          (field) =>
              field.key != ConflictFieldKey.status &&
              field.key != ConflictFieldKey.version,
        )
        .toList(growable: false);

    return Scaffold(
      appBar: AppBar(title: const Text('직접 병합')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const Text('각 항목에 사용할 값을 선택하세요. 사진은 이 기기의 파일을 유지합니다.'),
                  const SizedBox(height: 12),
                  for (final field in fields)
                    Card(
                      child: SwitchListTile(
                        value: _remoteFieldKeys.contains(field.key),
                        onChanged: (useRemote) {
                          setState(() {
                            if (useRemote) {
                              _remoteFieldKeys.add(field.key);
                            } else {
                              _remoteFieldKeys.remove(field.key);
                            }
                          });
                        },
                        title: Text(field.fieldName),
                        subtitle: Text(
                          _remoteFieldKeys.contains(field.key)
                              ? '서버: ${field.theirsValue}'
                              : '내 기기: ${field.mineValue}',
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _completeMerge,
                  child: const Text('병합 결과 적용'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final ConflictItem conflict;

  const _StatusCard({required this.conflict});

  @override
  Widget build(BuildContext context) {
    final icon = switch (conflict.status) {
      ConflictStatus.unresolved => Icons.warning_amber_outlined,
      ConflictStatus.resolving => Icons.sync_outlined,
      ConflictStatus.resolved => Icons.check_circle_outline,
    };
    final color = conflict.status == ConflictStatus.unresolved
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.primary;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                conflict.status == ConflictStatus.resolved
                    ? '해결 완료 · ${conflict.resolutionLabel}'
                    : conflict.statusLabel,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
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

  const _ConflictFieldCard({required this.field});

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
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _ValueBox(title: '내 변경', value: field.mineValue),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _ValueBox(title: '서버 변경', value: field.theirsValue),
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

  const _ValueBox({required this.title, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: Colors.grey.shade600),
          ),
          const SizedBox(height: 8),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _ResolvingNotice extends StatelessWidget {
  const _ResolvingNotice();

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Expanded(child: Text('선택한 해결 내용을 서버에 반영하고 있습니다.')),
          ],
        ),
      ),
    );
  }
}

class _ResolvedNotice extends StatelessWidget {
  final ConflictItem conflict;

  const _ResolvedNotice({required this.conflict});

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
            Expanded(child: Text('${conflict.resolutionLabel} 방식으로 해결했습니다.')),
          ],
        ),
      ),
    );
  }
}
