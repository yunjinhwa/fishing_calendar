import 'package:flutter/material.dart';

import '../../data/models/fishing_record.dart';
import '../../data/repositories/fishing_record_memory_repository.dart';

class RecordDetailPage extends StatelessWidget {
  final FishingRecord record;

  const RecordDetailPage({super.key, required this.record});

  Future<void> deleteRecord(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('기록 삭제'),
          content: const Text('이 출조 기록을 삭제하시겠습니까?'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(false);
              },
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(context).pop(true);
              },
              child: const Text('삭제'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      return;
    }

    FishingRecordMemoryRepository.instance.deleteRecord(record.id);

    if (!context.mounted) {
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('출조 기록이 삭제되었습니다.')));

    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('출조 기록'),
        actions: [
          IconButton(
            onPressed: () {
              deleteRecord(context);
            },
            icon: const Icon(Icons.delete_outline),
            tooltip: '삭제',
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              record.summaryTitle,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),

            Text(
              _formatDateTimeRange(record.startAt, record.endAt),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),

            Row(
              children: [
                const Icon(Icons.place_outlined, size: 18),
                const SizedBox(width: 6),
                Expanded(child: Text(record.location)),
              ],
            ),
            const SizedBox(height: 24),

            _SectionTitle(title: '외부 데이터'),
            const SizedBox(height: 8),
            _InfoCard(
              children: [
                _InfoRow(label: '물때', value: record.tide ?? '-'),
                _InfoRow(label: '날씨', value: record.weather ?? '-'),
                _InfoRow(
                  label: '기온',
                  value: record.airTemperature == null
                      ? '-'
                      : '${record.airTemperature}℃',
                ),
                _InfoRow(
                  label: '수온',
                  value: record.waterTemperature == null
                      ? '-'
                      : '${record.waterTemperature}℃',
                ),
              ],
            ),
            const SizedBox(height: 24),

            _SectionTitle(title: '조과'),
            const SizedBox(height: 8),

            if (record.catches.isEmpty)
              const _EmptyInfoCard(message: '입력된 조과가 없습니다.')
            else
              ...record.catches.map(
                (catchRecord) => _InfoCard(
                  margin: const EdgeInsets.only(bottom: 8),
                  children: [
                    _InfoRow(label: '어종', value: catchRecord.speciesName),
                    _InfoRow(
                      label: '크기',
                      value: catchRecord.lengthCm == null
                          ? '-'
                          : '${catchRecord.lengthCm}cm',
                    ),
                    _InfoRow(
                      label: '무게',
                      value: catchRecord.weightG == null
                          ? '-'
                          : '${catchRecord.weightG}g',
                    ),
                  ],
                ),
              ),

            const SizedBox(height: 16),

            _SectionTitle(title: '사진'),
            const SizedBox(height: 8),
            const _EmptyInfoCard(message: '첨부된 사진이 없습니다.'),
            const SizedBox(height: 24),

            _SectionTitle(title: '메모'),
            const SizedBox(height: 8),
            _InfoCard(
              children: [
                Text(
                  record.memo?.isNotEmpty == true ? record.memo! : '메모가 없습니다.',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatDateTimeRange(DateTime startAt, DateTime endAt) {
    String twoDigits(int value) => value.toString().padLeft(2, '0');

    final start =
        '${startAt.year}.${twoDigits(startAt.month)}.${twoDigits(startAt.day)} '
        '${twoDigits(startAt.hour)}:${twoDigits(startAt.minute)}';

    final end =
        '${endAt.year}.${twoDigits(endAt.month)}.${twoDigits(endAt.day)} '
        '${twoDigits(endAt.hour)}:${twoDigits(endAt.minute)}';

    return '$start - $end';
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;

  const _SectionTitle({required this.title});

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final List<Widget> children;
  final EdgeInsetsGeometry? margin;

  const _InfoCard({required this.children, this.margin});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: margin,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 56,
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.grey.shade600),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyInfoCard extends StatelessWidget {
  final String message;

  const _EmptyInfoCard({required this.message});

  @override
  Widget build(BuildContext context) {
    return _InfoCard(
      children: [
        Text(
          message,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: Colors.grey.shade600),
        ),
      ],
    );
  }
}
