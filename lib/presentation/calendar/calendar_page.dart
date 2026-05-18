import 'package:flutter/material.dart';

class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key});

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  DateTime focusedMonth = DateTime(DateTime.now().year, DateTime.now().month);

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('낚시 캘린더'),
        actions: [
          IconButton(onPressed: () {}, icon: const Icon(Icons.refresh)),
          IconButton(
            onPressed: () {},
            icon: const Icon(Icons.settings_outlined),
          ),
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
            child: _CalendarGrid(focusedMonth: focusedMonth, records: records),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          // 다음 단계에서 기록 작성 화면으로 이동
        },
        icon: const Icon(Icons.add),
        label: const Text('기록 작성'),
      ),
    );
  }

  late final List<DummyFishingRecord> records = [
    DummyFishingRecord(
      startAt: DateTime(DateTime.now().year, DateTime.now().month, 14, 5, 30),
      endAt: DateTime(DateTime.now().year, DateTime.now().month, 14, 9, 20),
      genreName: '루어',
      speciesName: '광어',
    ),
    DummyFishingRecord(
      startAt: DateTime(DateTime.now().year, DateTime.now().month, 14, 19, 0),
      endAt: DateTime(DateTime.now().year, DateTime.now().month, 14, 23, 40),
      genreName: '선상',
      speciesName: '우럭',
    ),
    DummyFishingRecord(
      startAt: DateTime(DateTime.now().year, DateTime.now().month, 21, 8, 0),
      endAt: DateTime(DateTime.now().year, DateTime.now().month, 21, 12, 0),
      genreName: '찌낚시',
      speciesName: null,
    ),
  ];
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
  final List<DummyFishingRecord> records;

  const _CalendarGrid({required this.focusedMonth, required this.records});

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
        childAspectRatio: 0.75,
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
          return record.startAt.year == date.year &&
              record.startAt.month == date.month &&
              record.startAt.day == date.day;
        }).toList();

        return Card(
          margin: const EdgeInsets.all(3),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              // 다음 단계에서 날짜별 기록 목록으로 이동
            },
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 12,
                    backgroundColor: isToday
                        ? Theme.of(context).colorScheme.primary
                        : Colors.transparent,
                    child: Text(
                      '$dayNumber',
                      style: TextStyle(
                        fontSize: 12,
                        color: isToday
                            ? Theme.of(context).colorScheme.onPrimary
                            : Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  ...dayRecords.take(2).map((record) {
                    final summary = record.speciesName == null
                        ? record.genreName
                        : '${record.genreName}·${record.speciesName}';

                    return Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(top: 2),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
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

class DummyFishingRecord {
  final DateTime startAt;
  final DateTime endAt;
  final String genreName;
  final String? speciesName;

  const DummyFishingRecord({
    required this.startAt,
    required this.endAt,
    required this.genreName,
    this.speciesName,
  });
}
