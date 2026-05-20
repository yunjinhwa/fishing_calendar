import 'package:flutter/material.dart';

import '../../data/models/personal_best_record.dart';

class PersonalBestDetailPage extends StatelessWidget {
  final PersonalBestRecord record;

  const PersonalBestDetailPage({
    super.key,
    required this.record,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('기록어 상세'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              height: 180,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Center(
                child: Icon(
                  Icons.emoji_events_outlined,
                  size: 72,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(height: 24),

            Text(
              record.speciesName,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),

            Text(
              '${_formatDate(record.caughtAt)} · ${record.locationText}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),

            _SectionTitle(title: '기록 정보'),
            const SizedBox(height: 8),

            _InfoCard(
              children: [
                _InfoRow(label: '최고 크기', value: record.lengthText),
                _InfoRow(label: '최고 무게', value: record.weightText),
                _InfoRow(
                  label: '출조 위치',
                  value: record.sourceRecord.location,
                ),
                _InfoRow(
                  label: '낚시 장르',
                  value: record.sourceRecord.genreName,
                ),
              ],
            ),
            const SizedBox(height: 24),

            _SectionTitle(title: '기록 근거'),
            const SizedBox(height: 8),

            _InfoCard(
              children: [
                _InfoRow(
                  label: '출조 시간',
                  value: _formatDateTimeRange(
                    record.sourceRecord.startAt,
                    record.sourceRecord.endAt,
                  ),
                ),
                _InfoRow(
                  label: '물때',
                  value: record.sourceRecord.tide ?? '-',
                ),
                _InfoRow(
                  label: '날씨',
                  value: record.sourceRecord.weather ?? '-',
                ),
                _InfoRow(
                  label: '메모',
                  value: record.sourceRecord.memo ?? '메모가 없습니다.',
                ),
              ],
            ),
            const SizedBox(height: 24),

            _SectionTitle(title: '공유 이미지'),
            const SizedBox(height: 8),

            _InfoCard(
              children: [
                const Text(
                  '기록어 공유 이미지는 현재 준비 중입니다.',
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('공유 이미지 생성 기능은 현재 준비 중입니다.'),
                      ),
                    );
                  },
                  icon: const Icon(Icons.ios_share_outlined),
                  label: const Text('공유 이미지 미리보기'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    String twoDigits(int value) => value.toString().padLeft(2, '0');

    return '${date.year}.${twoDigits(date.month)}.${twoDigits(date.day)}';
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

  const _SectionTitle({
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final List<Widget> children;

  const _InfoCard({
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
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

  const _InfoRow({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: TextStyle(
                color: Colors.grey.shade600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}