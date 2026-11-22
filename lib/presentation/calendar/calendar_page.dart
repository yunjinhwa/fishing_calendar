import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/fishing_record.dart';
import '../../data/repositories/auth_session_repository.dart';
import '../../data/repositories/fishing_record_repository.dart';
import '../../data/services/network_status_service.dart';
import '../../data/services/paid_record_cache_service.dart';
import '../../data/services/record_sync_service.dart';
import 'calendar_month_picker.dart';
import 'calendar_record_layout.dart';
import 'calendar_today_summary.dart';
import 'daily_record_list_page.dart';

class CalendarPage extends StatefulWidget {
  const CalendarPage({
    super.key,
    this.isActive = true,
    this.initialMonth,
    this.now,
  });

  final bool isActive;
  final DateTime? initialMonth;
  final DateTime Function()? now;

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage>
    with WidgetsBindingObserver {
  late DateTime focusedMonth;
  late DateTime _today;
  Timer? _dayChangeTimer;
  final _recordRepository = FishingRecordRepository.instance;
  final _auth = AuthSessionRepository.instance;
  final _cache = PaidRecordCacheService.instance;
  VoidCallback? _releaseMonth;
  int? _heldGeneration;
  bool _loadScheduled = false;
  bool _isChoosingMonth = false;
  bool _isOpeningToday = false;
  double _horizontalDragDistance = 0;

  bool get _canNavigate => widget.isActive && _auth.canManageRecords;
  bool get _canGoBack => focusedMonth.year > 1 || focusedMonth.month > 1;
  bool get _canGoForward => focusedMonth.year < 9999 || focusedMonth.month < 12;
  DateTime get _now => (widget.now ?? DateTime.now)().toLocal();

  static DateTime _dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  @override
  void initState() {
    super.initState();
    final now = _now;
    _today = _dateOnly(now);
    final initial = widget.initialMonth ?? now;
    RangeError.checkValueInInterval(initial.year, 1, 9999, 'initialMonth.year');
    focusedMonth = DateTime(initial.year, initial.month);
    _recordRepository.addListener(_refreshRecords);
    _auth.addListener(_onSessionChanged);
    _cache.addListener(_onCacheChanged);
    WidgetsBinding.instance.addObserver(this);
    _updateMonthLease();
    _scheduleDayChange(now);
  }

  @override
  void didUpdateWidget(CalendarPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive != widget.isActive) _updateMonthLease();
    if (oldWidget.isActive != widget.isActive || oldWidget.now != widget.now) {
      _refreshToday(rebuild: false);
    }
  }

  @override
  void dispose() {
    _recordRepository.removeListener(_refreshRecords);
    _auth.removeListener(_onSessionChanged);
    _cache.removeListener(_onCacheChanged);
    WidgetsBinding.instance.removeObserver(this);
    _dayChangeTimer?.cancel();
    _releaseMonth?.call();
    super.dispose();
  }

  void _onSessionChanged() {
    _refreshToday(rebuild: false);
    if (_heldGeneration != _auth.sessionGeneration) _updateMonthLease();
    _scheduleMonthLoad();
    _refreshRecords();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshToday();
    } else {
      _dayChangeTimer?.cancel();
    }
  }

  void _refreshToday({bool rebuild = true}) {
    final now = _now;
    final date = _dateOnly(now);
    if (date != _today) {
      _today = date;
      if (rebuild) _refreshRecords();
    }
    _scheduleDayChange(now);
  }

  void _scheduleDayChange(DateTime now) {
    _dayChangeTimer?.cancel();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (!_canNavigate ||
        (lifecycle != null && lifecycle != AppLifecycleState.resumed)) {
      return;
    }
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    _dayChangeTimer = Timer(tomorrow.difference(now), _refreshToday);
  }

  Future<void> _openToday() async {
    if (!_canNavigate ||
        _isOpeningToday ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    final now = _now;
    final owner = _auth.dataOwnerKey;
    final generation = _auth.sessionGeneration;
    _isOpeningToday = true;
    try {
      final changed = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => DailyRecordListPage(
            selectedDate: _dateOnly(now),
            isTodaySummary: true,
            now: widget.now,
          ),
        ),
      );
      if (!mounted ||
          !_canNavigate ||
          owner != _auth.dataOwnerKey ||
          generation != _auth.sessionGeneration) {
        return;
      }
      _refreshToday();
      if (changed == true) {
        unawaited(
          RecordSyncService.instance.syncNow(scheduleFollowUpIfBusy: true),
        );
      }
    } finally {
      _isOpeningToday = false;
    }
  }

  void _onCacheChanged() {
    _refreshRecords();
    // A recovered connection may finish an earlier offline request.
    if (_cache.stateFor(focusedMonth) == CachedMonthState.offline &&
        !NetworkStatusService.instance.isDisconnected) {
      _scheduleMonthLoad();
    }
  }

  void _updateMonthLease() {
    _releaseMonth?.call();
    _releaseMonth = null;
    _heldGeneration = _auth.sessionGeneration;
    if (!widget.isActive || !_auth.canManageRecords) return;
    _releaseMonth = _cache.holdMonth(focusedMonth);
    _scheduleMonthLoad();
  }

  void _scheduleMonthLoad() {
    if (_loadScheduled || !widget.isActive) return;
    _loadScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadScheduled = false;
      if (mounted && widget.isActive) unawaited(_cache.loadMonth(focusedMonth));
    });
  }

  void _refreshRecords() {
    if (!mounted) {
      return;
    }

    setState(() {});
  }

  void goToPreviousMonth() {
    _goToMonth(DateTime(focusedMonth.year, focusedMonth.month - 1));
  }

  void goToNextMonth() {
    _goToMonth(DateTime(focusedMonth.year, focusedMonth.month + 1));
  }

  void goToCurrentMonth() {
    final today = _now;

    _goToMonth(DateTime(today.year, today.month));
  }

  void _goToMonth(DateTime month) {
    if (!mounted || !_canNavigate || month.year < 1 || month.year > 9999) {
      return;
    }
    final target = DateTime(month.year, month.month);
    if (target == focusedMonth) return;
    setState(() => focusedMonth = target);
    _updateMonthLease();
  }

  Future<void> _chooseMonth() async {
    if (!_canNavigate || _isChoosingMonth) return;
    _isChoosingMonth = true;
    final owner = _auth.dataOwnerKey;
    final generation = _auth.sessionGeneration;
    try {
      final selected = await showCalendarMonthPicker(
        context,
        initialMonth: focusedMonth,
      );
      if (!mounted ||
          !_canNavigate ||
          owner != _auth.dataOwnerKey ||
          generation != _auth.sessionGeneration ||
          selected == null) {
        return;
      }
      _goToMonth(selected);
    } finally {
      _isChoosingMonth = false;
    }
  }

  void _finishMonthSwipe(DragEndDetails details) {
    final distance = _horizontalDragDistance;
    _horizontalDragDistance = 0;
    if (distance.abs() < 48) return;
    if (distance < 0) {
      goToNextMonth();
    } else {
      goToPreviousMonth();
    }
  }

  @override
  Widget build(BuildContext context) {
    final records = _recordRepository.getAllRecords();

    return Scaffold(
      appBar: AppBar(
        title: const Text('낚시 캘린더'),
        actions: [
          IconButton(
            onPressed: _canNavigate ? goToCurrentMonth : null,
            icon: const Icon(Icons.today_outlined),
            tooltip: '이번 달로 이동',
          ),
        ],
      ),
      body: Column(
        children: [
          _MonthHeader(
            focusedMonth: focusedMonth,
            onPrevious: _canNavigate && _canGoBack ? goToPreviousMonth : null,
            onNext: _canNavigate && _canGoForward ? goToNextMonth : null,
            onChoose: _canNavigate ? _chooseMonth : null,
          ),
          _MonthLoadStatus(
            state: _cache.stateFor(focusedMonth),
            errorMessage: _cache.errorFor(focusedMonth),
            onRetry: () =>
                unawaited(_cache.loadMonth(focusedMonth, force: true)),
          ),
          const _WeekHeader(),
          Expanded(
            child: GestureDetector(
              key: const ValueKey('calendar-month-grid'),
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: _canNavigate
                  ? (_) => _horizontalDragDistance = 0
                  : null,
              onHorizontalDragUpdate: _canNavigate
                  ? (details) =>
                        _horizontalDragDistance += details.primaryDelta ?? 0
                  : null,
              onHorizontalDragEnd: _canNavigate ? _finishMonthSwipe : null,
              onHorizontalDragCancel: () => _horizontalDragDistance = 0,
              child: _CalendarGrid(
                focusedMonth: focusedMonth,
                today: _today,
                records: records,
                onChanged: () {
                  setState(() {});
                },
              ),
            ),
          ),
          if (_auth.canManageRecords)
            CalendarTodaySummary(
              onPressed: _canNavigate ? () => unawaited(_openToday()) : null,
            ),
        ],
      ),
    );
  }
}

class _MonthLoadStatus extends StatelessWidget {
  const _MonthLoadStatus({
    required this.state,
    required this.onRetry,
    this.errorMessage,
  });

  final CachedMonthState state;
  final VoidCallback onRetry;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    if (state == CachedMonthState.loading) {
      return const LinearProgressIndicator();
    }
    if (state != CachedMonthState.offline && state != CachedMonthState.failed) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: Text(
              state == CachedMonthState.offline
                  ? '과거 기록을 모두 보려면 인터넷에 연결해 주세요.'
                  : errorMessage ?? '과거 기록을 불러오지 못했습니다.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (state == CachedMonthState.failed)
            TextButton(onPressed: onRetry, child: const Text('다시 불러오기')),
        ],
      ),
    );
  }
}

class _MonthHeader extends StatelessWidget {
  final DateTime focusedMonth;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback? onChoose;

  const _MonthHeader({
    required this.focusedMonth,
    required this.onPrevious,
    required this.onNext,
    required this.onChoose,
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
            tooltip: '이전 달',
          ),
          Expanded(
            child: Tooltip(
              message: '연·월 선택',
              child: TextButton(
                key: const ValueKey('calendar-month-picker'),
                onPressed: onChoose,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        '${focusedMonth.year}년 ${focusedMonth.month}월',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const Icon(Icons.arrow_drop_down),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            onPressed: onNext,
            icon: const Icon(Icons.chevron_right),
            tooltip: '다음 달',
          ),
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
  final DateTime today;
  final List<FishingRecord> records;
  final VoidCallback onChanged;

  const _CalendarGrid({
    required this.focusedMonth,
    required this.today,
    required this.records,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final layout = CalendarMonthLayout.fromRecords(
      month: focusedMonth,
      records: records,
    );
    final textScaler = MediaQuery.textScalerOf(context);
    final dateExtent = math.max(20.0, textScaler.scale(11) + 6);
    final barHeight = math.max(16.0, textScaler.scale(10) + 6);
    final barTop = 4 + dateExtent + 3;

    return LayoutBuilder(
      builder: (context, constraints) {
        final columnWidth = math.max(0.0, constraints.maxWidth - 24) / 7;
        final preferredRowHeight =
            ((constraints.maxHeight - 8) / layout.weeks.length)
                .clamp(44.0, math.max(44.0, columnWidth / 0.62))
                .toDouble();
        return ListView.builder(
          key: ValueKey(
            'calendar-grid-${focusedMonth.year}-${focusedMonth.month}',
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          itemCount: layout.weeks.length,
          itemBuilder: (context, index) {
            final week = layout.weeks[index];
            final visibleLanes = math.min(
              week.laneCount,
              calendarVisibleRecordLanes,
            );
            final overflowTop = barTop + visibleLanes * (barHeight + 2);
            final requiredHeight =
                overflowTop +
                (week.laneCount > visibleLanes ? textScaler.scale(11) + 7 : 3);
            return _CalendarWeek(
              layout: layout,
              week: week,
              today: today,
              rowHeight: math.max(preferredRowHeight, requiredHeight),
              columnWidth: columnWidth,
              dateExtent: dateExtent,
              barTop: barTop,
              barHeight: barHeight,
              overflowTop: overflowTop,
              onDateTap: (date) => _openDate(context, date),
            );
          },
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
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        key: ValueKey('calendar-day-${_dateKey(date)}'),
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => onDateTap(date),
                        child: Stack(
                          children: [
                            Positioned(
                              top: 4,
                              left: 0,
                              right: 0,
                              child: Center(
                                child: Container(
                                  width: dateExtent,
                                  height: dateExtent,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: isToday
                                        ? AppTheme.primary
                                        : Colors.transparent,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Text(
                                    '$day',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: isToday
                                          ? Colors.white
                                          : colors.onSurface,
                                      fontWeight: isToday
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                    ),
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
        color: AppTheme.primaryContainer,
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
          color: AppTheme.ink,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
