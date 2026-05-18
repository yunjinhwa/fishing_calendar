import 'package:flutter/material.dart';

class DailyRecordListPage extends StatelessWidget {
  final DateTime selectedDate;

  const DailyRecordListPage({
    super.key,
    required this.selectedDate,
  });

  @override
  Widget build(BuildContext context) {
    final records = _getMockRecords(selectedDate);

    return Scaffold(
      appBar: AppBar(
        title: Text(_formatDate(selectedDate)),
      ),
      body: records.isEmpty
          ? _EmptyRecordView(selectedDate: selectedDate)
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: records.length,
              separatorBuilder: (context, index) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final record = records[index];

                return Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.all(16),
                    title: Text(
                      record.title,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '${record.timeText}\n${record.location}\n${record.statusText}',
                      ),
                    ),
                    isThreeLine: true,
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('기록 상세 화면은 다음 단계에서 만듭니다.'),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('기록 작성 화면은 다음 브랜치에서 만듭니다.'),
            ),
          );
        },
        icon: const Icon(Icons.add),
        label: const Text('기록 작성'),
      ),
    );
  }

  List<_DailyRecord> _getMockRecords(DateTime date) {
    if (date.day == 14) {
      return const [
        _DailyRecord(
          title: '루어낚시 · 광어',
          timeText: '05:30 - 09:20',
          location: '부산 영도구 동삼동',
          statusText: '동기화 완료',
        ),
        _DailyRecord(
          title: '선상낚시 · 우럭',
          timeText: '19:00 - 23:40',
          location: '통영 욕지도',
          statusText: '업로드 대기',
        ),
      ];
    }

    if (date.day == 21) {
      return const [
        _DailyRecord(
          title: '찌낚시',
          timeText: '08:00 - 12:00',
          location: '부산 기장군 일광읍',
          statusText: '로컬 저장',
        ),
      ];
    }

    if (date.day == 28) {
      return const [
        _DailyRecord(
          title: '야간루어 · 전갱이',
          timeText: '22:00 - 다음날 02:30',
          location: '부산 영도구 동삼동',
          statusText: '날짜 넘김 기록',
        ),
      ];
    }

    if (date.day == 29) {
      return const [
        _DailyRecord(
          title: '야간루어 · 전갱이',
          timeText: '전날 22:00 - 02:30',
          location: '부산 영도구 동삼동',
          statusText: '날짜 넘김 기록',
        ),
      ];
    }

    return [];
  }

  String _formatDate(DateTime date) {
    return '${date.year}년 ${date.month}월 ${date.day}일 기록';
  }
}

class _EmptyRecordView extends StatelessWidget {
  final DateTime selectedDate;

  const _EmptyRecordView({
    required this.selectedDate,
  });

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
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
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

class _DailyRecord {
  final String title;
  final String timeText;
  final String location;
  final String statusText;

  const _DailyRecord({
    required this.title,
    required this.timeText,
    required this.location,
    required this.statusText,
  });
}