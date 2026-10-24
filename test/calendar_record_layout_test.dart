import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/presentation/calendar/calendar_record_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  FishingRecord record(String id, DateTime start, DateTime end) {
    return FishingRecord(
      id: id,
      location: '테스트 낚시터',
      startAt: start,
      endAt: end,
      genreName: '바다낚시',
    );
  }

  List<CalendarRecordSegment> segments(CalendarMonthLayout layout) {
    return layout.weeks.expand((week) => week.segments).toList();
  }

  test('overnight record is one segment across both dates', () {
    final layout = CalendarMonthLayout.fromRecords(
      month: DateTime(2026, 10),
      records: [
        record(
          'overnight',
          DateTime(2026, 10, 21, 18),
          DateTime(2026, 10, 22, 3),
        ),
      ],
    );

    expect(layout.leadingEmptyCount, 3);
    expect(layout.daysInMonth, 31);
    expect(layout.weeks, hasLength(5));
    final segment = layout.weeks[3].segments.single;
    expect(segment.startColumn, 2);
    expect(segment.endColumn, 3);
    expect(segment.lane, 0);
    expect(segment.continuesBefore, isFalse);
    expect(segment.continuesAfter, isFalse);
    expect(segments(layout), hasLength(1));
  });

  test('same day and midnight end retain exclusive-end semantics', () {
    final layout = CalendarMonthLayout.fromRecords(
      month: DateTime(2026, 10),
      records: [
        record('same-day', DateTime(2026, 10, 8, 8), DateTime(2026, 10, 8, 20)),
        record('midnight', DateTime(2026, 10, 21, 18), DateTime(2026, 10, 22)),
      ],
    );

    expect(layout.weeks[1].segments.single.startColumn, 3);
    expect(layout.weeks[1].segments.single.endColumn, 3);
    final midnight = layout.weeks[3].segments.single;
    expect(midnight.startColumn, 2);
    expect(midnight.endColumn, 2);
    expect(midnight.continuesAfter, isFalse);
  });

  test('week crossing creates connected continuation segments', () {
    final layout = CalendarMonthLayout.fromRecords(
      month: DateTime(2026, 10),
      records: [
        record(
          'weekend',
          DateTime(2026, 10, 24, 18),
          DateTime(2026, 10, 26, 3),
        ),
      ],
    );

    final first = layout.weeks[3].segments.single;
    final last = layout.weeks[4].segments.single;
    expect((first.startColumn, first.endColumn), (5, 6));
    expect((first.continuesBefore, first.continuesAfter), (false, true));
    expect((last.startColumn, last.endColumn), (0, 0));
    expect((last.continuesBefore, last.continuesAfter), (true, false));
  });

  test('month and year boundaries clip bars before blank cells', () {
    final spanning = record(
      'new-year',
      DateTime(2026, 12, 31, 18),
      DateTime(2027, 1, 2, 3),
    );
    final december = CalendarMonthLayout.fromRecords(
      month: DateTime(2026, 12),
      records: [spanning],
    );
    final january = CalendarMonthLayout.fromRecords(
      month: DateTime(2027, 1),
      records: [spanning],
    );

    final decemberSegment = segments(december).single;
    expect((decemberSegment.startColumn, decemberSegment.endColumn), (3, 3));
    expect(decemberSegment.continuesBefore, isFalse);
    expect(decemberSegment.continuesAfter, isTrue);
    final januarySegment = segments(january).single;
    expect((januarySegment.startColumn, januarySegment.endColumn), (4, 5));
    expect(januarySegment.continuesBefore, isTrue);
    expect(januarySegment.continuesAfter, isFalse);
  });

  test('empty months include all required calendar rows', () {
    final november = CalendarMonthLayout.fromRecords(
      month: DateTime(2026, 11, 24, 12),
      records: [],
    );
    final february = CalendarMonthLayout.fromRecords(
      month: DateTime(2027, 2),
      records: [],
    );

    expect(november.month, DateTime(2026, 11));
    expect(november.leadingEmptyCount, 6);
    expect(november.weeks, hasLength(6));
    expect(february.leadingEmptyCount, 0);
    expect(february.weeks, hasLength(4));
    expect(november.weeks.every((week) => week.laneCount == 0), isTrue);
  });

  test('overlapping bars have deterministic distinct lanes and reuse gaps', () {
    final records = [
      record('long', DateTime(2026, 10, 20), DateTime(2026, 10, 24)),
      record('short-b', DateTime(2026, 10, 20), DateTime(2026, 10, 22)),
      record('short-a', DateTime(2026, 10, 20), DateTime(2026, 10, 22)),
      record('later', DateTime(2026, 10, 24), DateTime(2026, 10, 25)),
    ];
    final forward = CalendarMonthLayout.fromRecords(
      month: DateTime(2026, 10),
      records: records,
    );
    final reversed = CalendarMonthLayout.fromRecords(
      month: DateTime(2026, 10),
      records: records.reversed.toList(),
    );

    List<(String, int, int, int)> placement(CalendarMonthLayout layout) =>
        segments(layout)
            .map(
              (item) =>
                  (item.record.id, item.lane, item.startColumn, item.endColumn),
            )
            .toList();

    expect(placement(forward), placement(reversed));
    final week = forward.weeks[3];
    expect(week.laneCount, 3);
    expect(
      week.segments.singleWhere((item) => item.record.id == 'long').lane,
      0,
    );
    expect(
      week.segments.singleWhere((item) => item.record.id == 'short-a').lane,
      1,
    );
    expect(
      week.segments.singleWhere((item) => item.record.id == 'short-b').lane,
      2,
    );
    expect(
      week.segments.singleWhere((item) => item.record.id == 'later').lane,
      0,
    );
    for (final left in week.segments) {
      for (final right in week.segments) {
        if (identical(left, right) || left.lane != right.lane) continue;
        expect(
          left.endColumn < right.startColumn ||
              right.endColumn < left.startColumn,
          isTrue,
        );
      }
    }
  });

  test('overflow counts only hidden bars that touch the requested day', () {
    final layout = CalendarMonthLayout.fromRecords(
      month: DateTime(2026, 10),
      records: [
        record('a', DateTime(2026, 10, 20), DateTime(2026, 10, 24)),
        record('b', DateTime(2026, 10, 20), DateTime(2026, 10, 23)),
        record('c', DateTime(2026, 10, 20), DateTime(2026, 10, 22)),
        record('d', DateTime(2026, 10, 20), DateTime(2026, 10, 21)),
      ],
    );
    final week = layout.weeks[3];

    expect(week.hiddenCountForColumn(1), 2);
    expect(week.hiddenCountForColumn(2), 1);
    expect(week.hiddenCountForColumn(3), 0);
    expect(week.hiddenCountForColumn(0), 0);
    expect(week.hiddenCountForColumn(1, visibleLanes: 3), 1);
  });

  test('ongoing records retain lane order and vacated lanes are compacted', () {
    final layout = CalendarMonthLayout.fromRecords(
      month: DateTime(2026, 10),
      records: [
        record('ends-early', DateTime(2026, 10, 13), DateTime(2026, 10, 20)),
        record('ongoing-a', DateTime(2026, 10, 14), DateTime(2026, 10, 27)),
        record('ongoing-b', DateTime(2026, 10, 15), DateTime(2026, 10, 28)),
      ],
    );

    Map<String, int> lanes(int week) => {
      for (final segment in layout.weeks[week].segments)
        segment.record.id: segment.lane,
    };
    expect(lanes(2), {'ends-early': 0, 'ongoing-a': 1, 'ongoing-b': 2});
    expect(lanes(3), {'ends-early': 0, 'ongoing-a': 1, 'ongoing-b': 2});
    expect(lanes(4), {'ongoing-a': 0, 'ongoing-b': 1});
    expect(layout.weeks[4].laneCount, 2);
  });

  test('multi-year records are bounded to the current month', () {
    final layout = CalendarMonthLayout.fromRecords(
      month: DateTime(2026, 10),
      records: [
        record('long-term', DateTime(1900), DateTime(2200)),
        record('past', DateTime(2025), DateTime(2026)),
        record('future', DateTime(2027), DateTime(2028)),
      ],
    );

    expect(segments(layout), hasLength(5));
    expect(
      segments(layout).every((item) => item.record.id == 'long-term'),
      isTrue,
    );
    expect(layout.weeks.first.segments.single.startColumn, 3);
    expect(layout.weeks.last.segments.single.endColumn, 5);
    expect(segments(layout).every((item) => item.continuesBefore), isTrue);
    expect(segments(layout).every((item) => item.continuesAfter), isTrue);
  });

  test('UTC timestamps use the same local dates as the record model', () {
    final utcRecord = record(
      'utc',
      DateTime(2026, 10, 21, 18).toUtc(),
      DateTime(2026, 10, 22, 3).toUtc(),
    );
    final layout = CalendarMonthLayout.fromRecords(
      month: DateTime.utc(2026, 10),
      records: [utcRecord],
    );

    final visibleDays = <int>[];
    for (final week in layout.weeks) {
      for (final item in week.segments) {
        for (
          var column = item.startColumn;
          column <= item.endColumn;
          column++
        ) {
          visibleDays.add(
            week.index * 7 + column - layout.leadingEmptyCount + 1,
          );
        }
      }
    }
    expect(visibleDays, [21, 22]);
    expect(visibleDays, [
      for (var day = 1; day <= 31; day++)
        if (utcRecord.overlapsDate(DateTime(2026, 10, day))) day,
    ]);
  });
}
