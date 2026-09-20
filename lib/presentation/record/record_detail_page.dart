import 'package:flutter/material.dart';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../data/models/fishing_record.dart';
import '../../data/repositories/fishing_record_memory_repository.dart';
import '../../data/services/record_mutation_service.dart';
import '../auth/auth_access_guard.dart';
import 'record_form_page.dart';

class RecordDetailPage extends StatefulWidget {
  final FishingRecord record;

  const RecordDetailPage({super.key, required this.record});

  @override
  State<RecordDetailPage> createState() => _RecordDetailPageState();
}

class _RecordDetailPageState extends State<RecordDetailPage> {
  final _recordRepository = FishingRecordMemoryRepository.instance;

  late FishingRecord record;

  @override
  void initState() {
    super.initState();
    record = widget.record;
  }

  Future<void> editRecord() async {
    final allowed = await requireMemberAccess(
      context,
      message: '출조 기록 수정은 로그인 후 사용할 수 있습니다.',
    );

    if (!allowed || !mounted) {
      return;
    }

    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => RecordFormPage(editingRecord: record)),
    );

    if (saved != true || !mounted) {
      return;
    }

    final updatedRecord = _recordRepository.getRecordById(record.id);

    if (updatedRecord == null) {
      return;
    }

    setState(() {
      record = updatedRecord;
    });
  }

  Future<void> deleteRecord() async {
    final allowed = await requireMemberAccess(
      context,
      message: '출조 기록 삭제는 로그인 후 사용할 수 있습니다.',
    );

    if (!allowed || !mounted) {
      return;
    }

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

    await RecordMutationService.instance.deleteRecord(record.id);

    if (!mounted) {
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
            onPressed: editRecord,
            icon: const Icon(Icons.edit_outlined),
            tooltip: '수정',
          ),
          IconButton(
            onPressed: deleteRecord,
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

            if (record.photoPaths.isEmpty)
              const _EmptyInfoCard(message: '첨부된 사진이 없습니다.')
            else
              SizedBox(
                height: 120,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: record.photoPaths.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    final photoPath = record.photoPaths[index];

                    return ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: _RecordPhotoPreview(photoPath: photoPath),
                    );
                  },
                ),
              ),

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

class _RecordPhotoPreview extends StatelessWidget {
  final String photoPath;

  const _RecordPhotoPreview({required this.photoPath});

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      return Container(
        width: 120,
        height: 120,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Center(child: Icon(Icons.image_outlined)),
      );
    }

    return Image.file(
      File(photoPath),
      width: 120,
      height: 120,
      fit: BoxFit.cover,
      errorBuilder: (context, error, stackTrace) {
        return Container(
          width: 120,
          height: 120,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Center(child: Icon(Icons.broken_image_outlined)),
        );
      },
    );
  }
}
