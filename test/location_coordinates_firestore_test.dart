import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/outbox_item.dart';
import 'package:fishing_build/data/models/record_sync_metadata.dart';
import 'package:fishing_build/data/remote/firestore_record_sync_gateway.dart';
import 'package:fishing_build/data/remote/record_sync_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

const _uid = 'coordinate-member';

void main() {
  test('text-only writes preserve the exact legacy v1 document shape', () {
    final record = _record();
    final encoded = _encode(record);
    expect(encoded['schemaVersion'], 1);
    expect(encoded, hasLength(20));
    expect(encoded.containsKey('latitude'), isFalse);
    expect(encoded.containsKey('longitude'), isFalse);
    final decoded = _decode(_active());
    expect(decoded.record!.latitude, isNull);
    expect(decoded.record!.longitude, isNull);
  });

  test('coordinate writes use v2 and preserve a zero coordinate pair', () {
    final encoded = _encode(_record(latitude: 0, longitude: 0));
    expect(encoded['schemaVersion'], 2);
    expect(encoded, hasLength(22));
    expect(encoded['latitude'], 0);
    expect(encoded['longitude'], 0);
  });

  test(
    'v2 reads preserve numeric precision and inclusive WGS84 boundaries',
    () {
      for (final pair in <(num, num)>[
        (-90, -180),
        (90, 180),
        (0, 0),
        (37.5665123456, 126.9780123456),
      ]) {
        final data = _active()
          ..['schemaVersion'] = 2
          ..['latitude'] = pair.$1
          ..['longitude'] = pair.$2;
        final decoded = _decode(data).record!;
        expect(decoded.latitude, pair.$1.toDouble());
        expect(decoded.longitude, pair.$2.toDouble());
      }
    },
  );

  test('v2 malformed or incomplete coordinate pairs fail closed', () {
    final valid = _active()
      ..['schemaVersion'] = 2
      ..['latitude'] = 37.5665
      ..['longitude'] = 126.9780;
    final invalid = <Map<String, dynamic>>[
      {...valid}..remove('latitude'),
      {...valid}..remove('longitude'),
      {...valid}
        ..remove('latitude')
        ..remove('longitude'),
      {...valid, 'latitude': null},
      {...valid, 'longitude': null},
      {...valid, 'latitude': '37.5665'},
      {...valid, 'longitude': true},
      {...valid, 'latitude': 90.00001},
      {...valid, 'latitude': -90.00001},
      {...valid, 'longitude': 180.00001},
      {...valid, 'longitude': -180.00001},
      {...valid, 'latitude': double.nan},
      {...valid, 'longitude': double.infinity},
      {...valid, 'latitude': double.negativeInfinity},
      {...valid, 'schemaVersion': 3},
      {...valid, 'coordinateLabel': 'unexpected'},
    ];
    for (final data in invalid) {
      expect(() => _decode(data), throwsA(_invalidServerData));
    }
  });

  test(
    'v1 reads reject mixed coordinate fields and continue accepting null-free legacy data',
    () {
      for (final extras in <Map<String, dynamic>>[
        {'latitude': 37.5665},
        {'longitude': 126.9780},
        {'latitude': null, 'longitude': null},
        {'latitude': 37.5665, 'longitude': 126.9780},
      ]) {
        expect(
          () => _decode({..._active(), ...extras}),
          throwsA(_invalidServerData),
        );
      }
      expect(_decode(_active()).record!.location, '테스트 방파제');
    },
  );

  test('one full snapshot can mix v1 and v2 records', () {
    final legacy = _active('legacy');
    final coordinates = _active('coordinates')
      ..['schemaVersion'] = 2
      ..['latitude'] = 35.1
      ..['longitude'] = 129.1;
    final snapshot = FirestoreRecordSyncGateway.decodeSnapshotForTesting(
      uid: _uid,
      documents: {'legacy': legacy, 'coordinates': coordinates},
    );
    expect(snapshot.activeRecords, hasLength(2));
    expect(snapshot.revisionFor('legacy')!.record!.latitude, isNull);
    expect(snapshot.revisionFor('coordinates')!.record!.latitude, 35.1);
  });

  test('deletion tombstones retain the legacy v1 envelope', () {
    final deleted = _active()
      ..removeWhere((key, _) => !_baseKeys.contains(key))
      ..['recordStatus'] = 'DELETED';
    final revision = _decode(deleted);
    expect(revision.status, RemoteRecordStatus.deleted);
    expect(revision.record, isNull);
    expect(
      () => _decode({...deleted, 'schemaVersion': 2}),
      throwsA(_invalidServerData),
    );
    expect(
      () => _decode({...deleted, 'latitude': 35.1, 'longitude': 129.1}),
      throwsA(_invalidServerData),
    );
  });

  test('legacy mutation fingerprints remain byte-for-byte compatible', () {
    final legacy = _outbox(_record());
    const expected =
        'fafb7d37f23c6488451126e6e3cde5bb59e0ae484d481c2c2e137d660ac30865';
    expect(
      FirestoreRecordSyncGateway.mutationFingerprintForTesting(legacy),
      expected,
    );
    final explicitNullPair = legacy.copyWith(
      payload: {...legacy.payload!, 'latitude': null, 'longitude': null},
    );
    expect(
      FirestoreRecordSyncGateway.mutationFingerprintForTesting(
        explicitNullPair,
      ),
      expected,
    );
  });

  test('coordinate changes invalidate a receipt for the same outbox ID', () {
    final original = _outbox(_record(latitude: 35.1, longitude: 129.1));
    final fingerprint =
        FirestoreRecordSyncGateway.mutationFingerprintForTesting(original);
    final receipt = <String, dynamic>{
      'schemaVersion': 2,
      'ownerUid': _uid,
      'outboxId': original.id,
      'recordId': original.recordId,
      'operationType': 'create',
      'baseVersionNo': 0,
      'resultingVersionNo': 1,
      'mutationFingerprint': fingerprint,
      'processedAt': Timestamp.fromDate(DateTime.utc(2026, 11, 1)),
    };
    expect(
      FirestoreRecordSyncGateway.validateExistingReceiptForTesting(
        receipt,
        uid: _uid,
        item: original,
      ).versionNo,
      1,
    );
    for (final record in [
      _record(latitude: 35.2, longitude: 129.1),
      _record(latitude: 35.1, longitude: 129.2),
      _record(),
    ]) {
      final changed = original.copyWith(payload: record.toJson());
      expect(
        FirestoreRecordSyncGateway.mutationFingerprintForTesting(changed),
        isNot(fingerprint),
      );
      expect(
        () => FirestoreRecordSyncGateway.validateExistingReceiptForTesting(
          receipt,
          uid: _uid,
          item: changed,
        ),
        throwsA(
          isA<RecordSyncGatewayException>().having(
            (error) => error.code,
            'code',
            'idempotency-conflict',
          ),
        ),
      );
    }
  });

  test(
    'clearing coordinates writes the legacy shape without residual fields',
    () {
      final withCoordinates = _encode(
        _record(latitude: 35.1, longitude: 129.1),
      );
      final cleared = _encode(_record());
      expect(withCoordinates['schemaVersion'], 2);
      expect(cleared['schemaVersion'], 1);
      expect(
        cleared.keys.toSet(),
        withCoordinates.keys.toSet().difference({'latitude', 'longitude'}),
      );
    },
  );
}

final _invalidServerData = isA<RecordSyncGatewayException>().having(
  (error) => error.code,
  'code',
  'invalid-server-data',
);

FishingRecord _record({double? latitude, double? longitude}) => FishingRecord(
  id: 'coordinate-record',
  location: '테스트 방파제',
  latitude: latitude,
  longitude: longitude,
  startAt: DateTime.utc(2026, 11, 1, 8),
  endAt: DateTime.utc(2026, 11, 1, 12),
  genreName: '루어',
);

OutboxItem _outbox(FishingRecord record) => OutboxItem(
  id: 'coordinate-outbox',
  userId: _uid,
  recordId: record.id,
  operationType: OutboxOperationType.create,
  status: OutboxStatus.pending,
  createdAt: DateTime.utc(2026, 11, 1),
  baseVersionNo: 0,
  payload: record.toJson(),
);

Map<String, Object?> _encode(FishingRecord record) =>
    FirestoreRecordSyncGateway.encodeActiveRecordForTesting(
      uid: _uid,
      item: _outbox(record),
      record: record,
      versionNo: 1,
      createdAt: Timestamp.fromDate(DateTime.utc(2026, 11, 1)),
    );

RemoteRecordRevision _decode(Map<String, dynamic> data) =>
    FirestoreRecordSyncGateway.decodeRevisionForTesting(
      uid: _uid,
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

Map<String, dynamic> _active([String id = 'coordinate-record']) => {
  'schemaVersion': 1,
  'ownerUid': _uid,
  'recordId': id,
  'recordStatus': 'ACTIVE',
  'versionNo': 1,
  'lastOutboxId': 'coordinate-outbox',
  'clientModifiedAt': Timestamp.fromDate(DateTime.utc(2026, 11, 1)),
  'createdAt': Timestamp.fromDate(DateTime.utc(2026, 11, 1)),
  'serverUpdatedAt': Timestamp(1793491200, 123456789),
  'location': '테스트 방파제',
  'startAt': Timestamp.fromDate(DateTime.utc(2026, 11, 1, 8)),
  'endAt': Timestamp.fromDate(DateTime.utc(2026, 11, 1, 12)),
  'genreName': '루어',
  'tide': null,
  'weather': null,
  'airTemperature': null,
  'waterTemperature': null,
  'catches': <Object>[],
  'memo': null,
  'photoUploadPending': false,
};
