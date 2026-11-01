import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/record_cache_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late DateTime now;
  late RecordCachePolicy policy;

  setUp(() {
    now = DateTime(2026, 10, 26, 23, 59);
    policy = RecordCachePolicy(now: () => now);
  });

  test('disabled policy keeps old bodies until the runtime opts in', () {
    final old = _record('old', DateTime(2020, 1), DateTime(2020, 1, 2));

    expect(policy.keepsRecord('owner', old), isTrue);
    policy.enabled = true;
    expect(policy.keepsRecord('owner', old), isFalse);
  });

  test(
    '31-day cutoff uses local calendar days and half-open record ranges',
    () {
      policy.enabled = true;
      final cutoff = DateTime(2026, 9, 26);

      expect(policy.oldestDate, cutoff);
      expect(
        policy.keepsRecord(
          'owner',
          _record('boundary', DateTime(2026, 9, 25), cutoff),
        ),
        isFalse,
      );
      expect(
        policy.keepsRecord(
          'owner',
          _record(
            'overlap',
            DateTime(2026, 9, 25),
            cutoff.add(const Duration(microseconds: 1)),
          ),
        ),
        isTrue,
      );
      expect(
        policy.keepsRecord(
          'owner',
          _record(
            'ongoing',
            DateTime(2020, 1),
            now.add(const Duration(hours: 1)),
          ),
        ),
        isTrue,
      );
      expect(
        policy.keepsRecord(
          'owner',
          _record('future', DateTime(2027, 1), DateTime(2027, 1, 2)),
        ),
        isTrue,
      );
      expect(policy.needsMonthQuery(DateTime(2026, 9, 30)), isTrue);
      expect(policy.needsMonthQuery(DateTime(2026, 10)), isFalse);

      now = DateTime(2026, 10, 27);
      expect(policy.oldestDate, DateTime(2026, 9, 27));
    },
  );

  test('record leases are owner-scoped, reference-counted and idempotent', () {
    policy.enabled = true;
    final old = _record('same-id', DateTime(2020, 1), DateTime(2020, 1, 2));
    var changes = 0;
    policy.onPinsChanged = () => changes++;
    final releaseFirst = policy.holdRecord('owner-a', old.id);
    final releaseSecond = policy.holdRecord('owner-a', old.id);

    expect(policy.keepsRecord('owner-a', old), isTrue);
    expect(policy.keepsRecord('owner-b', old), isFalse);
    expect(changes, 2);
    expect(policy.revision, 2);
    releaseFirst();
    releaseFirst();
    expect(policy.keepsRecord('owner-a', old), isTrue);
    expect(changes, 3);
    expect(policy.revision, 3);
    releaseSecond();
    expect(policy.keepsRecord('owner-a', old), isFalse);
    expect(changes, 4);
    expect(policy.revision, 4);
  });

  test('month leases normalize dates and keep only records that overlap', () {
    policy.enabled = true;
    final releaseFirst = policy.holdMonth('owner', DateTime(2026, 8, 15, 14));
    final releaseSecond = policy.holdMonth('owner', DateTime(2026, 8, 29));
    final spanning = _record(
      'spanning',
      DateTime(2026, 7, 31, 18),
      DateTime(2026, 8, 1, 3),
    );
    final endsAtMonth = _record(
      'end-boundary',
      DateTime(2026, 7, 31),
      DateTime(2026, 8),
    );
    final startsAfterMonth = _record(
      'start-boundary',
      DateTime(2026, 9),
      DateTime(2026, 9, 2),
    );

    expect(policy.holdsMonth('owner', DateTime(2026, 8)), isTrue);
    expect(policy.keepsRecord('owner', spanning), isTrue);
    expect(policy.keepsRecord('other', spanning), isFalse);
    expect(policy.keepsRecord('owner', endsAtMonth), isFalse);
    expect(policy.keepsRecord('owner', startsAfterMonth), isFalse);
    releaseFirst();
    expect(policy.holdsMonth('owner', DateTime(2026, 8, 12)), isTrue);
    releaseSecond();
    expect(policy.holdsMonth('owner', DateTime(2026, 8)), isFalse);
    expect(policy.keepsRecord('owner', spanning), isFalse);
  });

  test(
    'history leases retain all old records for their owner until last release',
    () {
      policy.enabled = true;
      final old = _record('old', DateTime(2020, 1), DateTime(2020, 1, 2));
      var changes = 0;
      policy.onPinsChanged = () => changes++;
      final releaseFirst = policy.holdHistory('owner-a');
      final releaseSecond = policy.holdHistory('owner-a');

      expect(policy.holdsHistory('owner-a'), isTrue);
      expect(policy.holdsHistory('owner-b'), isFalse);
      expect(policy.keepsRecord('owner-a', old), isTrue);
      expect(policy.keepsRecord('owner-b', old), isFalse);
      releaseFirst();
      releaseFirst();
      expect(policy.holdsHistory('owner-a'), isTrue);
      expect(policy.keepsRecord('owner-a', old), isTrue);
      releaseSecond();
      expect(policy.holdsHistory('owner-a'), isFalse);
      expect(policy.keepsRecord('owner-a', old), isFalse);
      expect(changes, 4);
      expect(policy.revision, 4);
    },
  );
}

FishingRecord _record(String id, DateTime start, DateTime end) => FishingRecord(
  id: id,
  location: 'Harbor',
  startAt: start,
  endAt: end,
  genreName: 'Lure',
);
