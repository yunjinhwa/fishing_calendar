import 'package:flutter/material.dart';

import 'daily_record_list_page.dart';
import '../../data/models/fishing_record.dart';
import '../../data/repositories/fishing_record_memory_repository.dart';
//import 'calendar_settings_page.dart';

class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key});

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  DateTime focusedMonth = DateTime(DateTime.now().year, DateTime.now().month);
  final _recordRepository = FishingRecordMemoryRepository.instance;

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

    setState(() {});
  }

  void goToPreviousMonth() {
    setState(() {
      focusedMonth = DateTime(focusedMonth.year, focusedMonth.month - 1);
    });
  }

  void goToNextMonth() {
    setState(() {
      focusedMonth = DateTime(focusedMonth.year, focusedMonth.month + 1);
    });
  }

  void goToCurrentMonth() {
    final today = DateTime.now();

    setState(() {
      focusedMonth = DateTime(today.year, today.month);
    });
  }

  @override
  Widget build(BuildContext context) {
    final records = _recordRepository.getAllRecords();

    return Scaffold(
      appBar: AppBar(
        title: const Text('낚시 캘린더'),
        actions: [
          IconButton(
            onPressed: goToCurrentMonth,
            icon: const Icon(Icons.today_outlined),
            tooltip: '이번 달로 이동',
          ),
          // IconButton(
          //   onPressed: () {
          //     Navigator.of(context).push(
          //       MaterialPageRoute(
          //         builder: (_) => const CalendarSettingsPage(),
          //       ),
          //     );
          //   },
          //   icon: const Icon(Icons.settings_outlined),
          //   tooltip: '캘린더 설정',
          // ),
        ],
      ),
      body: Column(
        children: [
          _MonthHeader(
            focusedMonth: focusedMonth,
            onPrevious: goToPreviousMonth,
            onNext: goToNextMonth,
          ),
          const _WeekHeader(),
          Expanded(
            child: _CalendarGrid(
              focusedMonth: focusedMonth,
              records: records,
              onChanged: () {
                setState(() {});
              },
            ),
          ),
          _TodaySummaryCard(
            onTap: () {
              final today = DateTime.now();

              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => DailyRecordListPage(
                    selectedDate: DateTime(today.year, today.month, today.day),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _MonthHeader extends StatelessWidget {
  final DateTime focusedMonth;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  const _MonthHeader({
    required this.focusedMonth,
    required this.onPrevious,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          IconButton(
            onPressed: onPrevious,
            icon: const Icon(Icons.chevron_left),
          ),
          Expanded(
            child: Center(
              child: Text(
                '${focusedMonth.year}년 ${focusedMonth.month}월',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
          ),
          IconButton(onPressed: onNext, icon: const Icon(Icons.chevron_right)),
        ],
      ),
    );
  }
}

class _WeekHeader extends StatelessWidget {
  const _WeekHeader();

  @override
  Widget build(BuildContext context) {
    const weekDays = ['월', '화', '수', '목', '금', '토', '일'];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: weekDays
            .map(
              (day) => Expanded(
                child: Center(
                  child: Text(
                    day,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}

class _CalendarGrid extends StatelessWidget {
  final DateTime focusedMonth;
  final List<FishingRecord> records;
  final VoidCallback onChanged;

  const _CalendarGrid({
    required this.focusedMonth,
    required this.records,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final firstDayOfMonth = DateTime(focusedMonth.year, focusedMonth.month, 1);
    final lastDayOfMonth = DateTime(
      focusedMonth.year,
      focusedMonth.month + 1,
      0,
    );

    final leadingEmptyCount = firstDayOfMonth.weekday - 1;
    final totalDays = lastDayOfMonth.day;
    final totalCells = leadingEmptyCount + totalDays;
    final rowCount = (totalCells / 7).ceil();
    final cellCount = rowCount * 7;

    return GridView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: cellCount,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 7,
        childAspectRatio: 0.62,
      ),
      itemBuilder: (context, index) {
        final dayNumber = index - leadingEmptyCount + 1;

        if (dayNumber < 1 || dayNumber > totalDays) {
          return const SizedBox();
        }

        final date = DateTime(focusedMonth.year, focusedMonth.month, dayNumber);
        final now = DateTime.now();
        final isToday =
            date.year == now.year &&
            date.month == now.month &&
            date.day == now.day;

        final dayRecords = records.where((record) {
          return record.overlapsDate(date);
        }).toList();

        return Card(
          margin: const EdgeInsets.all(3),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () async {
              final changed = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => DailyRecordListPage(selectedDate: date),
                ),
              );

              if (changed == true) {
                onChanged();
              }
            },
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 10,
                    backgroundColor: isToday
                        ? Theme.of(context).colorScheme.primary
                        : Colors.transparent,
                    child: Text(
                      '$dayNumber',
                      style: TextStyle(
                        fontSize: 11,
                        color: isToday
                            ? Theme.of(context).colorScheme.onPrimary
                            : Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  ...dayRecords.take(2).map((record) {
                    final summary = record.summaryTitle;

                    return Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(top: 2),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 3,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          fontSize: 10,
                          height: 1.0,
                          color: Theme.of(
                            context,
                          ).colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    );
                  }),
                  if (dayRecords.length > 2)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '+${dayRecords.length - 2}',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TodaySummaryCard extends StatelessWidget {
  final VoidCallback onTap;

  const _TodaySummaryCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Card(
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(
                    Icons.waves_outlined,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '오늘의 요약',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '출조 기록 · 날씨/물때 정보는 이후 외부 데이터 연동에서 표시합니다.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
