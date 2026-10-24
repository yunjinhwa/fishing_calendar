import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'daily_record_list_page.dart';
import 'calendar_record_layout.dart';
import '../../data/models/fishing_record.dart';
import '../../data/repositories/fishing_record_repository.dart';
import '../../data/services/record_sync_service.dart';
//import 'calendar_settings_page.dart';

class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key});

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  DateTime focusedMonth = DateTime(DateTime.now().year, DateTime.now().month);
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
            onTap: () async {
              final today = DateTime.now();

              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => DailyRecordListPage(
                    selectedDate: DateTime(today.year, today.month, today.day),
                  ),
                ),
              );
              if (!context.mounted) return;
              unawaited(
                RecordSyncService.instance.syncNow(
                  scheduleFollowUpIfBusy: true,
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
    final layout = CalendarMonthLayout.fromRecords(
      month: focusedMonth,
      records: records,
    );
    final today = DateTime.now();
    final textScaler = MediaQuery.textScalerOf(context);
    final dateExtent = math.max(20.0, textScaler.scale(11) + 6);
    final barHeight = math.max(16.0, textScaler.scale(10) + 6);
    final barTop = 7 + dateExtent + 3;
    final overflowTop = barTop + calendarVisibleRecordLanes * (barHeight + 2);

    return LayoutBuilder(
      builder: (context, constraints) {
        final columnWidth = math.max(0.0, constraints.maxWidth - 24) / 7;
        final rowHeight = math.max(
          columnWidth / 0.62,
          overflowTop + textScaler.scale(11) + 9,
        );
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: layout.weeks.length,
          itemBuilder: (context, index) => _CalendarWeek(
            layout: layout,
            week: layout.weeks[index],
            today: today,
            rowHeight: rowHeight,
            columnWidth: columnWidth,
            dateExtent: dateExtent,
            barTop: barTop,
            barHeight: barHeight,
            overflowTop: overflowTop,
            onDateTap: (date) => _openDate(context, date),
          ),
        );
      },
    );
  }

  Future<void> _openDate(BuildContext context, DateTime date) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => DailyRecordListPage(selectedDate: date),
      ),
    );
    if (!context.mounted) return;
    unawaited(RecordSyncService.instance.syncNow(scheduleFollowUpIfBusy: true));
    if (changed == true) onChanged();
  }
}

class _CalendarWeek extends StatelessWidget {
  final CalendarMonthLayout layout;
  final CalendarWeekLayout week;
  final DateTime today;
  final double rowHeight;
  final double columnWidth;
  final double dateExtent;
  final double barTop;
  final double barHeight;
  final double overflowTop;
  final ValueChanged<DateTime> onDateTap;

  const _CalendarWeek({
    required this.layout,
    required this.week,
    required this.today,
    required this.rowHeight,
    required this.columnWidth,
    required this.dateExtent,
    required this.barTop,
    required this.barHeight,
    required this.overflowTop,
    required this.onDateTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: rowHeight,
      child: Stack(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: List.generate(7, (column) {
              final day =
                  week.index * 7 + column - layout.leadingEmptyCount + 1;
              if (day < 1 || day > layout.daysInMonth) {
                return const Expanded(child: SizedBox());
              }
              final date = DateTime(layout.month.year, layout.month.month, day);
              final dayRecords = week.segments.where(
                (segment) =>
                    segment.startColumn <= column &&
                    segment.endColumn >= column,
              );
              final hidden = week.hiddenCountForColumn(column);
              final isToday =
                  date.year == today.year &&
                  date.month == today.month &&
                  day == today.day;
              final colors = Theme.of(context).colorScheme;
              final label = [
                '${date.year}년 ${date.month}월 $day일',
                if (dayRecords.isEmpty) '기록 없음',
                for (final segment in dayRecords) segment.record.summaryTitle,
              ].join(', ');

              return Expanded(
                child: Semantics(
                  button: true,
                  label: label,
                  onTap: () => onDateTap(date),
                  child: ExcludeSemantics(
                    child: Card(
                      margin: const EdgeInsets.all(3),
                      child: InkWell(
                        key: ValueKey('calendar-day-${_dateKey(date)}'),
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => onDateTap(date),
                        child: Stack(
                          children: [
                            Positioned(
                              top: 4,
                              left: 4,
                              child: Container(
                                width: dateExtent,
                                height: dateExtent,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: isToday
                                      ? colors.primary
                                      : Colors.transparent,
                                  shape: BoxShape.circle,
                                ),
                                child: Text(
                                  '$day',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: isToday
                                        ? colors.onPrimary
                                        : colors.onSurface,
                                  ),
                                ),
                              ),
                            ),
                            if (hidden > 0)
                              Positioned(
                                top: overflowTop - 3,
                                left: 4,
                                right: 4,
                                child: Text(
                                  '+$hidden',
                                  key: ValueKey(
                                    'calendar-overflow-${_dateKey(date)}',
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(fontSize: 11, height: 1),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
          for (final segment in week.segments.where(
            (item) => item.lane < calendarVisibleRecordLanes,
          ))
            Positioned(
              left: segment.startColumn * columnWidth + 4,
              top: barTop + segment.lane * (barHeight + 2),
              width:
                  (segment.endColumn - segment.startColumn + 1) * columnWidth -
                  8,
              height: barHeight,
              // Keep each date tappable, including underneath a spanning bar.
              child: IgnorePointer(
                child: ExcludeSemantics(
                  child: _RecordRangeBar(
                    markerKey: ValueKey(
                      'calendar-range-${segment.record.id}-${week.index}',
                    ),
                    segment: segment,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _dateKey(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}

class _RecordRangeBar extends StatelessWidget {
  final Key markerKey;
  final CalendarRecordSegment segment;

  const _RecordRangeBar({required this.markerKey, required this.segment});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: markerKey,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: Colors.blue.shade200.withValues(alpha: 0.6),
        borderRadius: BorderRadius.horizontal(
          left: segment.continuesBefore
              ? Radius.zero
              : const Radius.circular(5),
          right: segment.continuesAfter
              ? Radius.zero
              : const Radius.circular(5),
        ),
      ),
      child: Text(
        segment.record.summaryTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          fontSize: 10,
          height: 1,
          color: Colors.blue.shade900,
          fontWeight: FontWeight.w600,
        ),
      ),
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
