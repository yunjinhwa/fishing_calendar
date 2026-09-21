import 'package:flutter/material.dart';

import '../../data/repositories/fishing_record_repository.dart';
import '../record/record_detail_page.dart';

class DailyRecordListPage extends StatefulWidget {
  final DateTime selectedDate;

  const DailyRecordListPage({super.key, required this.selectedDate});

  @override
  State<DailyRecordListPage> createState() => _DailyRecordListPageState();
}

class _DailyRecordListPageState extends State<DailyRecordListPage> {
  bool hasChanged = false;
  final _recordRepository = FishingRecordRepository.instance;

  @override
  void initState() {
    super.initState();
    _recordRepository.addListener(_refreshRecords);
  }

  @override
  void dispose() {
    _recordRepository.removeListener(_refreshRecords);
    super.dispose();
  }

  void _refreshRecords() {
    if (!mounted) {
      return;
    }

    setState(() {
      hasChanged = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final records = _recordRepository.getRecordsByDate(widget.selectedDate);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          return;
        }

        Navigator.of(context).pop(hasChanged);
      },
      child: Scaffold(
        appBar: AppBar(title: Text(_formatDate(widget.selectedDate))),
        body: records.isEmpty
            ? _EmptyRecordView(selectedDate: widget.selectedDate)
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: records.length,
                separatorBuilder: (context, index) =>
                    const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final record = records[index];

                  return Card(
                    child: ListTile(
                      contentPadding: const EdgeInsets.all(16),
                      title: Text(
                        record.summaryTitle,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          '${_formatTimeRange(record.startAt, record.endAt)}\n'
                          '${record.location}\n'
                          '로컬 저장',
                        ),
                      ),
                      isThreeLine: true,
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () async {
                        final changed = await Navigator.of(context).push<bool>(
                          MaterialPageRoute(
                            builder: (_) => RecordDetailPage(record: record),
                          ),
                        );

                        if (changed == true && mounted) {
                          setState(() {
                            hasChanged = true;
                          });
                        }
                      },
                    ),
                  );
                },
              ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.year}년 ${date.month}월 ${date.day}일 기록';
  }

  String _formatTimeRange(DateTime startAt, DateTime endAt) {
    String twoDigits(int value) => value.toString().padLeft(2, '0');

    final start =
        '${twoDigits(startAt.month)}.${twoDigits(startAt.day)} '
        '${twoDigits(startAt.hour)}:${twoDigits(startAt.minute)}';

    final end =
        '${twoDigits(endAt.month)}.${twoDigits(endAt.day)} '
        '${twoDigits(endAt.hour)}:${twoDigits(endAt.minute)}';

    return '$start - $end';
  }
}

class _EmptyRecordView extends StatelessWidget {
  final DateTime selectedDate;

  const _EmptyRecordView({required this.selectedDate});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.event_note_outlined,
              size: 56,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              '저장된 출조 기록이 없습니다.',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              '${selectedDate.month}월 ${selectedDate.day}일에는 아직 기록이 없습니다.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
