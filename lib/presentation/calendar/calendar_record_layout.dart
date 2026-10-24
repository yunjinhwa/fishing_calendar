import '../../data/models/fishing_record.dart';

const calendarVisibleRecordLanes = 2;

/// A Monday-first layout containing only days in the requested month.
class CalendarMonthLayout {
  final DateTime month;
  final int leadingEmptyCount;
  final int daysInMonth;
  final List<CalendarWeekLayout> weeks;

  const CalendarMonthLayout._({
    required this.month,
    required this.leadingEmptyCount,
    required this.daysInMonth,
    required this.weeks,
  });

  factory CalendarMonthLayout.fromRecords({
    required DateTime month,
    required List<FishingRecord> records,
  }) {
    final firstDay = DateTime(month.year, month.month);
    final nextMonth = DateTime(month.year, month.month + 1);
    final dayCount = DateTime(month.year, month.month + 1, 0).day;
    final leadingCount = firstDay.weekday - DateTime.monday;
    final weekCount = (leadingCount + dayCount + 6) ~/ 7;
    final candidates = List.generate(weekCount, (_) => <_UnplacedSegment>[]);

    for (final record in records) {
      if (!record.startAt.isBefore(nextMonth) ||
          !record.endAt.isAfter(firstDay)) {
        continue;
      }

      int? firstOffset;
      var lastOffset = 0;
      // Inspect at most 31 dates, even for a record spanning many years. Using
      // the model's predicate preserves local-day and exclusive-end semantics.
      for (var day = 1; day <= dayCount; day++) {
        if (record.overlapsDate(DateTime(month.year, month.month, day))) {
          firstOffset ??= leadingCount + day - 1;
          lastOffset = leadingCount + day - 1;
        }
      }
      if (firstOffset == null) continue;

      final firstWeek = firstOffset ~/ 7;
      final lastWeek = lastOffset ~/ 7;
      for (var week = firstWeek; week <= lastWeek; week++) {
        final startColumn = week == firstWeek ? firstOffset % 7 : 0;
        final endColumn = week == lastWeek ? lastOffset % 7 : 6;
        final segmentStart = DateTime(
          month.year,
          month.month,
          week * 7 + startColumn - leadingCount + 1,
        );
        final segmentEnd = DateTime(
          month.year,
          month.month,
          week * 7 + endColumn - leadingCount + 2,
        );
        candidates[week].add(
          _UnplacedSegment(
            record: record,
            startColumn: startColumn,
            endColumn: endColumn,
            continuesBefore: record.startAt.isBefore(segmentStart),
            continuesAfter: record.endAt.isAfter(segmentEnd),
          ),
        );
      }
    }

    var previousLanes = <String, int>{};
    final weeks = <CalendarWeekLayout>[];
    for (var index = 0; index < weekCount; index++) {
      final unplaced = candidates[index];
      unplaced.sort((left, right) {
        var comparison = left.startColumn.compareTo(right.startColumn);
        if (comparison != 0) return comparison;

        // Keep ongoing records in their existing order, compacting any lanes
        // vacated by records that ended in the previous week.
        final leftPrevious = previousLanes[left.record.id];
        final rightPrevious = previousLanes[right.record.id];
        if (leftPrevious != null || rightPrevious != null) {
          if (leftPrevious == null) return 1;
          if (rightPrevious == null) return -1;
          comparison = leftPrevious.compareTo(rightPrevious);
          if (comparison != 0) return comparison;
        }
        comparison = right.endColumn.compareTo(left.endColumn);
        if (comparison != 0) return comparison;
        comparison = left.record.startAt.compareTo(right.record.startAt);
        if (comparison != 0) return comparison;
        return left.record.id.compareTo(right.record.id);
      });

      final laneEnds = <int>[];
      final segments = <CalendarRecordSegment>[];
      final currentLanes = <String, int>{};
      for (final candidate in unplaced) {
        final previousLane = previousLanes[candidate.record.id];
        var lane = -1;
        if (previousLane != null &&
            previousLane < laneEnds.length &&
            laneEnds[previousLane] < candidate.startColumn) {
          lane = previousLane;
        } else {
          lane = laneEnds.indexWhere((end) => end < candidate.startColumn);
        }
        if (lane == -1) {
          lane = laneEnds.length;
          laneEnds.add(candidate.endColumn);
        } else {
          laneEnds[lane] = candidate.endColumn;
        }
        currentLanes[candidate.record.id] = lane;
        segments.add(
          CalendarRecordSegment(
            record: candidate.record,
            startColumn: candidate.startColumn,
            endColumn: candidate.endColumn,
            lane: lane,
            continuesBefore: candidate.continuesBefore,
            continuesAfter: candidate.continuesAfter,
          ),
        );
      }
      segments.sort((left, right) {
        final comparison = left.lane.compareTo(right.lane);
        return comparison != 0
            ? comparison
            : left.startColumn.compareTo(right.startColumn);
      });
      weeks.add(
        CalendarWeekLayout(
          index: index,
          segments: List.unmodifiable(segments),
          laneCount: laneEnds.length,
        ),
      );
      previousLanes = currentLanes;
    }

    return CalendarMonthLayout._(
      month: firstDay,
      leadingEmptyCount: leadingCount,
      daysInMonth: dayCount,
      weeks: List.unmodifiable(weeks),
    );
  }
}

class CalendarWeekLayout {
  final int index;
  final List<CalendarRecordSegment> segments;
  final int laneCount;

  const CalendarWeekLayout({
    required this.index,
    required this.segments,
    required this.laneCount,
  });

  int hiddenCountForColumn(
    int column, {
    int visibleLanes = calendarVisibleRecordLanes,
  }) {
    return segments.where((segment) {
      return segment.lane >= visibleLanes &&
          segment.startColumn <= column &&
          segment.endColumn >= column;
    }).length;
  }
}

class CalendarRecordSegment {
  final FishingRecord record;
  final int startColumn;
  final int endColumn;
  final int lane;
  final bool continuesBefore;
  final bool continuesAfter;

  const CalendarRecordSegment({
    required this.record,
    required this.startColumn,
    required this.endColumn,
    required this.lane,
    required this.continuesBefore,
    required this.continuesAfter,
  });
}

class _UnplacedSegment {
  final FishingRecord record;
  final int startColumn;
  final int endColumn;
  final bool continuesBefore;
  final bool continuesAfter;

  const _UnplacedSegment({
    required this.record,
    required this.startColumn,
    required this.endColumn,
    required this.continuesBefore,
    required this.continuesAfter,
  });
}
