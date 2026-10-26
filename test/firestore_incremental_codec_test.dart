import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fishing_build/data/models/record_sync_metadata.dart';
import 'package:fishing_build/data/remote/firestore_record_sync_gateway.dart';
import 'package:fishing_build/data/remote/record_sync_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

const _through = RecordSyncCursor(
  seconds: 200,
  nanoseconds: 0,
  recordId: 'head',
);

void main() {
  test('revision cursor preserves the exact server timestamp precision', () {
    final revision = _decode(
      _active('precise', updatedAt: Timestamp(1792994400, 123456789)),
    );

    expect(revision.recordId, 'precise');
    expect(revision.cursor!.seconds, 1792994400);
    expect(revision.cursor!.nanoseconds, 123456789);
    expect(revision.cursor!.recordId, revision.recordId);
    expect(revision.record!.photoPaths, isEmpty);
  });

  test('deletion tombstones carry a cursor without a record body', () {
    final data = _active('deleted');
    data.removeWhere((key, _) => !_baseKeys.contains(key));
    data['recordStatus'] = 'DELETED';
    final revision = _decode(data);

    expect(revision.status, RemoteRecordStatus.deleted);
    expect(revision.record, isNull);
    expect(revision.cursor!.recordId, 'deleted');
    expect(revision.cursor!.nanoseconds, 987654321);
  });

  test('missing or malformed server timestamps fail closed', () {
    for (final timestamp in <Object?>[null, '2026-10-26T00:00:00Z', 42]) {
      expect(
        () => _decode({..._active('malformed'), 'serverUpdatedAt': timestamp}),
        throwsA(_invalidServerData),
      );
    }
    final missing = _active('missing')..remove('serverUpdatedAt');
    expect(() => _decode(missing), throwsA(_invalidServerData));
  });

  test(
    'full snapshot checkpoint uses server order rather than record dates',
    () {
      final laterStart = _active('a', updatedAt: Timestamp(100, 99));
      final earlierStart = _active('z', updatedAt: Timestamp(100, 100));
      earlierStart['startAt'] = Timestamp.fromDate(DateTime.utc(2025));
      earlierStart['endAt'] = Timestamp.fromDate(DateTime.utc(2025, 1, 1, 2));
      final sameTimeHigherId = _active('zz', updatedAt: Timestamp(100, 100));
      final snapshot = FirestoreRecordSyncGateway.decodeSnapshotForTesting(
        uid: 'incremental-user',
        documents: {'zz': sameTimeHigherId, 'a': laterStart, 'z': earlierStart},
      );

      expect(snapshot.revisions.first.recordId, 'z');
      expect(snapshot.cursor!.seconds, 100);
      expect(snapshot.cursor!.nanoseconds, 100);
      expect(snapshot.cursor!.recordId, 'zz');
    },
  );

  test('an empty full snapshot has an initialized origin checkpoint', () {
    final snapshot = FirestoreRecordSyncGateway.decodeSnapshotForTesting(
      uid: 'incremental-user',
      documents: {},
    );
    expect(snapshot.revisions, isEmpty);
    expect(snapshot.cursor!.compareTo(RecordSyncCursor.origin), 0);
  });

  test(
    'initial full decode does not silently omit a timestamp-less document',
    () {
      final malformed = _active('legacy')..remove('serverUpdatedAt');
      expect(
        () => FirestoreRecordSyncGateway.decodeSnapshotForTesting(
          uid: 'incremental-user',
          documents: {'valid': _active('valid'), 'legacy': malformed},
        ),
        throwsA(_invalidServerData),
      );
    },
  );

  test(
    'page boundaries allow same-time lower IDs and reject invalid requests',
    () {
      const since = RecordSyncCursor(
        seconds: 100,
        nanoseconds: 7,
        recordId: 'z',
      );
      const sameTimeLowerId = RecordSyncCursor(
        seconds: 100,
        nanoseconds: 7,
        recordId: 'a',
      );
      for (final limit in [1, 500]) {
        expect(
          () => FirestoreRecordSyncGateway.validateChangeRequestForTesting(
            uid: 'incremental-user',
            since: since,
            through: _through,
            after: sameTimeLowerId,
            limit: limit,
          ),
          returnsNormally,
        );
      }
      for (final limit in [0, 501]) {
        expect(
          () => FirestoreRecordSyncGateway.validateChangeRequestForTesting(
            uid: 'incremental-user',
            since: since,
            through: _through,
            limit: limit,
          ),
          throwsA(isA<RecordSyncGatewayException>()),
        );
      }
      for (final after in const [
        RecordSyncCursor(seconds: 100, nanoseconds: 6, recordId: 'zz'),
        RecordSyncCursor(seconds: 99, nanoseconds: 999999999, recordId: 'zz'),
        RecordSyncCursor(seconds: 101, nanoseconds: 1000000000, recordId: 'a'),
        RecordSyncCursor(seconds: 201, nanoseconds: 0, recordId: 'a'),
        RecordSyncCursor.origin,
      ]) {
        expect(
          () => FirestoreRecordSyncGateway.validateChangeRequestForTesting(
            uid: 'incremental-user',
            since: since,
            through: _through,
            after: after,
          ),
          throwsA(isA<RecordSyncGatewayException>()),
        );
      }
      expect(
        () => FirestoreRecordSyncGateway.validateChangeRequestForTesting(
          uid: 'another/user',
          since: RecordSyncCursor.origin,
          through: _through,
        ),
        throwsA(isA<RecordSyncGatewayException>()),
      );
      expect(
        () => FirestoreRecordSyncGateway.validateChangeRequestForTesting(
          uid: 'incremental-user',
          since: since,
          through: RecordSyncCursor.origin,
        ),
        throwsA(isA<RecordSyncGatewayException>()),
      );
      expect(
        () => FirestoreRecordSyncGateway.validateChangeRequestForTesting(
          uid: 'incremental-user',
          since: RecordSyncCursor.origin,
          through: RecordSyncCursor.origin,
        ),
        returnsNormally,
      );
    },
  );
}

final _invalidServerData = isA<RecordSyncGatewayException>().having(
  (error) => error.code,
  'code',
  'invalid-server-data',
);

RemoteRecordRevision _decode(Map<String, dynamic> data) =>
    FirestoreRecordSyncGateway.decodeRevisionForTesting(
      uid: 'incremental-user',
      recordId: data['recordId'] as String,
      data: data,
    );

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

Map<String, dynamic> _active(String id, {Timestamp? updatedAt}) => {
  'schemaVersion': 1,
  'ownerUid': 'incremental-user',
  'recordId': id,
  'recordStatus': 'ACTIVE',
  'versionNo': 1,
  'clientModifiedAt': Timestamp.fromDate(DateTime.utc(2026, 10, 26)),
  'createdAt': Timestamp.fromDate(DateTime.utc(2026, 10, 26)),
  'serverUpdatedAt': updatedAt ?? Timestamp(1792994400, 987654321),
  'lastOutboxId': 'outbox-$id',
  'location': '테스트 방파제',
  'startAt': Timestamp.fromDate(DateTime.utc(2026, 10, 26, 18)),
  'endAt': Timestamp.fromDate(DateTime.utc(2026, 10, 27, 3)),
  'genreName': '루어',
  'tide': null,
  'weather': null,
  'airTemperature': null,
  'waterTemperature': null,
  'catches': <Object>[],
  'memo': null,
  'photoUploadPending': false,
};
