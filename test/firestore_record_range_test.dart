import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fishing_build/data/remote/firestore_record_sync_gateway.dart';
import 'package:fishing_build/data/remote/record_sync_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

final _from = DateTime.utc(2026, 10);
final _to = DateTime.utc(2026, 11);

void main() {
  test('range cursor preserves nanoseconds and pre-epoch timestamps', () {
    const cursor = RecordRangeCursor(
      endSeconds: -1,
      endNanoseconds: 123456789,
      startSeconds: -2,
      startNanoseconds: 987654321,
      recordId: 'precise',
    );
    final decoded = RecordRangeCursor.fromJson(cursor.toJson());
    expect(decoded.toJson(), cursor.toJson());
    expect(decoded.compareTo(cursor), 0);
    expect(decoded.endNanoseconds, 123456789);
    expect(decoded.startNanoseconds, 987654321);
  });

  test('range cursor rejects invalid precision, bounds, IDs and intervals', () {
    final valid = _cursor('a').toJson();
    for (final overrides in <Map<String, dynamic>>[
      {'endSeconds': 253402300800},
      {'startSeconds': -62135596801},
      {'endNanoseconds': -1},
      {'startNanoseconds': 1000000000},
      {'endSeconds': 1.5},
      {'recordId': ''},
      {'recordId': 'a/b'},
      {
        'startSeconds': valid['endSeconds'],
        'startNanoseconds': valid['endNanoseconds'],
      },
    ]) {
      expect(
        () => RecordRangeCursor.fromJson({...valid, ...overrides}),
        throwsFormatException,
      );
    }
  });

  test('range requests validate bounds, page size and the resume cursor', () {
    void validate({
      DateTime? from,
      DateTime? to,
      int limit = 100,
      RecordRangeCursor? after,
      String uid = 'range-user',
    }) {
      FirestoreRecordSyncGateway.validateRangeRequestForTesting(
        uid: uid,
        from: from ?? _from,
        to: to ?? _to,
        limit: limit,
        after: after,
      );
    }

    validate(limit: 1);
    validate(limit: 500, after: _cursor('a'));
    expect(() => validate(to: _from), throwsA(_error('invalid-range')));
    expect(() => validate(from: _to), throwsA(_error('invalid-range')));
    expect(
      () => validate(from: DateTime.utc(0)),
      throwsA(_error('invalid-range')),
    );
    for (final limit in [0, -1, 501]) {
      expect(
        () => validate(limit: limit),
        throwsA(_error('invalid-page-size')),
      );
    }
    expect(
      () => validate(uid: 'other/user'),
      throwsA(_error('invalid-document-id')),
    );
    final outside = _cursor(
      'outside',
      endAt: Timestamp.fromDate(_from),
      startAt: Timestamp.fromDate(_from.subtract(const Duration(hours: 1))),
    );
    expect(() => validate(after: outside), throwsA(_error('invalid-cursor')));
  });

  test(
    'range page cursor uses exact query timestamps independently of sync',
    () {
      final data = _active('precise');
      data['startAt'] = Timestamp(1791828000, 123456789);
      data['endAt'] = Timestamp(1791860400, 987654321);
      final page = _page({'precise': data});
      expect(page.nextCursor!.startNanoseconds, 123456789);
      expect(page.nextCursor!.endNanoseconds, 987654321);
      expect(page.nextCursor!.recordId, 'precise');
      expect(page.revisions.single.cursor!.nanoseconds, 111222333);
      expect(page.revisions.single.record!.photoPaths, isEmpty);
      expect(page.hasMore, isFalse);
    },
  );

  test('equal start and end times paginate by document ID without loss', () {
    final first = _page({'a': _active('a'), 'b': _active('b')}, limit: 2);
    expect(first.revisions.map((revision) => revision.recordId), ['a', 'b']);
    expect(first.hasMore, isTrue);
    final second = _page(
      {'c': _active('c')},
      after: first.nextCursor,
      limit: 2,
    );
    expect(second.revisions.single.recordId, 'c');
    expect(second.nextCursor!.recordId, 'c');
    expect(second.hasMore, isFalse);
    final empty = _page({}, after: second.nextCursor, limit: 2);
    expect(empty.nextCursor, isNull);
    expect(empty.hasMore, isFalse);
    expect(
      () => _page({'b': _active('b')}, after: first.nextCursor),
      throwsA(_error('invalid-server-data')),
    );
  });

  test('range pages enforce end, start, then document ID ordering', () {
    final a = _active('a');
    final b = _active('b');
    b['startAt'] = Timestamp.fromDate(DateTime.utc(2026, 10, 12, 19));
    final c = _active('c');
    c['endAt'] = Timestamp.fromDate(DateTime.utc(2026, 10, 13, 4));
    expect(_page({'a': a, 'b': b, 'c': c}).revisions, hasLength(3));
    for (final documents in [
      {'b': b, 'a': a},
      {'c': c, 'b': b},
      {'b': _active('b'), 'a': _active('a')},
    ]) {
      expect(() => _page(documents), throwsA(_error('invalid-server-data')));
    }
  });

  test(
    'overlap includes month-spanning records and excludes exact midnight ends',
    () {
      final spanning = _active('spanning')
        ..['startAt'] = Timestamp.fromDate(DateTime.utc(2026, 9, 29))
        ..['endAt'] = Timestamp.fromDate(DateTime.utc(2026, 11, 2));
      expect(
        _page({'spanning': spanning}).revisions.single.recordId,
        'spanning',
      );
      final midnight = _active('midnight')
        ..['startAt'] = Timestamp.fromDate(DateTime.utc(2026, 9, 30, 18))
        ..['endAt'] = Timestamp.fromDate(_from);
      final nextMonth = _active('next-month')
        ..['startAt'] = Timestamp.fromDate(_to)
        ..['endAt'] = Timestamp.fromDate(_to.add(const Duration(hours: 1)));
      for (final data in [midnight, nextMonth]) {
        expect(
          () => _page({data['recordId'] as String: data}),
          throwsA(_error('invalid-server-data')),
        );
      }
      final deleted = _active('deleted')
        ..removeWhere((key, _) => !_baseKeys.contains(key))
        ..['recordStatus'] = 'DELETED';
      expect(
        () => _page({'deleted': deleted}),
        throwsA(_error('invalid-server-data')),
      );
    },
  );

  test(
    'range pages reject malformed ownership, dates and excess page data',
    () {
      for (final changes in <Map<String, dynamic>>[
        {'ownerUid': 'another-user'},
        {'recordId': 'different'},
        {'startAt': '2026-10-12T18:00:00Z'},
        {'endAt': null},
        {'serverUpdatedAt': null},
      ]) {
        expect(
          () => _page({
            'a': {..._active('a'), ...changes},
          }),
          throwsA(_error('invalid-server-data')),
        );
      }
      expect(
        () => _page({'a': _active('a'), 'b': _active('b')}, limit: 1),
        throwsA(_error('invalid-server-data')),
      );
    },
  );
}

Matcher _error(String code) => isA<RecordSyncGatewayException>().having(
  (error) => error.code,
  'code',
  code,
);

RemoteRecordRangePage _page(
  Map<String, Map<String, dynamic>> documents, {
  RecordRangeCursor? after,
  int limit = 100,
}) => FirestoreRecordSyncGateway.decodeRangePageForTesting(
  uid: 'range-user',
  from: _from,
  to: _to,
  documents: documents,
  after: after,
  limit: limit,
);

RecordRangeCursor _cursor(String id, {Timestamp? startAt, Timestamp? endAt}) {
  final data = _active(id);
  final start = startAt ?? data['startAt'] as Timestamp;
  final end = endAt ?? data['endAt'] as Timestamp;
  return RecordRangeCursor(
    endSeconds: end.seconds,
    endNanoseconds: end.nanoseconds,
    startSeconds: start.seconds,
    startNanoseconds: start.nanoseconds,
    recordId: id,
  );
}

Map<String, dynamic> _active(String id) => {
  'schemaVersion': 1,
  'ownerUid': 'range-user',
  'recordId': id,
  'recordStatus': 'ACTIVE',
  'versionNo': 1,
  'clientModifiedAt': Timestamp.fromDate(DateTime.utc(2026, 10, 26)),
  'createdAt': Timestamp.fromDate(DateTime.utc(2026, 10, 26)),
  'serverUpdatedAt': Timestamp(1792994400, 111222333),
  'lastOutboxId': 'outbox-$id',
  'location': '테스트 방파제',
  'startAt': Timestamp.fromDate(DateTime.utc(2026, 10, 12, 18)),
  'endAt': Timestamp.fromDate(DateTime.utc(2026, 10, 13, 3)),
  'genreName': '루어',
  'tide': null,
  'weather': null,
  'airTemperature': null,
  'waterTemperature': null,
  'catches': <Object>[],
  'memo': null,
  'photoUploadPending': false,
};

const _baseKeys = {
  'schemaVersion',
  'ownerUid',
  'recordId',
  'recordStatus',
  'versionNo',
  'clientModifiedAt',
  'createdAt',
  'serverUpdatedAt',
  'lastOutboxId',
};
