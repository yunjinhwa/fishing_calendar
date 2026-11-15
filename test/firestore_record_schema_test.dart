import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/outbox_item.dart';
import 'package:fishing_build/data/remote/firestore_record_sync_gateway.dart';
import 'package:fishing_build/data/remote/record_sync_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

const _uid = 'private-schema-owner';
const _through = RecordSyncCursor(
  seconds: 300,
  nanoseconds: 0,
  recordId: 'head',
);

void main() {
  test(
    'v3 writes and reads preserve zero or 100 catches with optional coordinates',
    () {
      for (final count in [0, 100]) {
        for (final coordinates in [false, true]) {
          final catches = List.generate(
            count,
            (index) => CatchRecord(
              speciesName: '어종 $index',
              lengthCm: index + 0.5,
              weightG: index,
            ),
          );
          final record = _newRecord(
            'v3-$count-$coordinates',
            catches: catches,
            latitude: coordinates ? 0 : null,
            longitude: coordinates ? 0 : null,
          );
          final data = _encodedDocument(record);
          expect(data['schemaVersion'], 3);
          expect(data['catchesJson'], isA<String>());
          expect(data.containsKey('catches'), isFalse);
          final decoded = _decode(data).record!;
          expect(
            decoded.catches.map((value) => value.toJson()).toList(),
            catches.map((value) => value.toJson()).toList(),
          );
          expect(decoded.latitude, coordinates ? 0 : null);
          expect(decoded.longitude, coordinates ? 0 : null);
        }
      }
    },
  );

  test('v3 wire encoding preserves logical numeric mutation fingerprints', () {
    final record = _newRecord(
      'v3-fingerprint',
      catches: const [
        CatchRecord(speciesName: '우럭', lengthCm: 31.5, weightG: 820),
        CatchRecord(speciesName: '광어', lengthCm: 0, weightG: 0),
      ],
    );
    final original = _item(record);
    final fingerprint =
        FirestoreRecordSyncGateway.mutationFingerprintForTesting(original);
    final decoded = _decode(_encodedDocument(record)).record!;
    expect(
      FirestoreRecordSyncGateway.mutationFingerprintForTesting(
        original.copyWith(payload: decoded.toJson()),
      ),
      fingerprint,
    );
    final changed = _newRecord(
      record.id,
      catches: const [
        CatchRecord(speciesName: '우럭', lengthCm: 31.5, weightG: 821),
        CatchRecord(speciesName: '광어', lengthCm: 0, weightG: 0),
      ],
    );
    expect(
      FirestoreRecordSyncGateway.mutationFingerprintForTesting(
        original.copyWith(payload: changed.toJson()),
      ),
      isNot(fingerprint),
    );
  });

  test('legacy v1 and v2 array catches remain readable beside v3', () {
    final legacy = _active(
      'v1',
      catches: [
        {'speciesName': '우럭', 'weightG': 820},
      ],
    );
    final coordinates =
        _active(
            'v2',
            catches: [
              {'speciesName': '광어', 'lengthCm': 41.5},
            ],
          )
          ..['schemaVersion'] = 2
          ..['latitude'] = 35.1
          ..['longitude'] = 129.1;
    final modern = _encodedDocument(_newRecord('v3'));
    final snapshot = FirestoreRecordSyncGateway.decodeSnapshotForTesting(
      uid: _uid,
      documents: {'v1': legacy, 'v2': coordinates, 'v3': modern},
    );
    expect(snapshot.activeRecords, hasLength(3));
    expect(snapshot.revisionFor('v1')!.record!.catches.single.weightG, 820);
    expect(snapshot.revisionFor('v2')!.record!.catches.single.lengthCm, 41.5);
    expect(snapshot.revisionFor('v2')!.record!.latitude, 35.1);
    expect(snapshot.revisionFor('v3')!.record!.catches, isEmpty);
  });

  test('v3 malformed validated JSON reports its document and field', () {
    final valid = _encodedDocument(_newRecord('broken'));
    for (final value in <Object?>[
      null,
      42,
      'invalid-json',
      '[42]',
      '[{"speciesName":"우럭","lengthCm":12,"weightG":1.5}]',
    ]) {
      expect(
        () => _decode({...valid, 'catchesJson': value}),
        throwsA(_invalid('broken', 'catchesJson')),
      );
    }
  });

  test('v3 cannot smuggle a legacy catches array alongside validated JSON', () {
    final valid = _encodedDocument(_newRecord('broken'));
    expect(
      () => _decode({
        ...valid,
        'catches': <Object?>[42],
      }),
      throwsA(_invalid('broken', null)),
    );
    final missingJson = {...valid}..remove('catchesJson');
    expect(
      () => _decode({...missingJson, 'catches': <Object?>[]}),
      throwsA(_invalid('broken', null)),
    );
  });

  test('non-map catch entries report their exact position and document', () {
    for (final value in <Object?>[42, 'fish', null, <Object?>[]]) {
      final data = _active(
        'broken',
        catches: [
          const {'speciesName': '우럭'},
          value,
        ],
      );
      expect(() => _decode(data), throwsA(_invalid('broken', 'catches[1]')));
    }
  });

  test('catch species requires a nonblank string no longer than 100', () {
    final catches = <Map<String, Object?>>[
      {},
      {'speciesName': null},
      {'speciesName': 42},
      {'speciesName': ''},
      {'speciesName': ' \t\n'},
      {'speciesName': List.filled(101, '어').join()},
    ];
    for (final value in catches) {
      expect(
        () => _decode(_active('broken', catches: [value])),
        throwsA(_invalid('broken', 'catches[0].speciesName')),
      );
    }
  });

  test('catch length requires a finite nonnegative number', () {
    for (final value in <Object?>[
      '12',
      true,
      -1,
      double.nan,
      double.infinity,
    ]) {
      expect(
        () => _decode(
          _active(
            'broken',
            catches: [
              {'speciesName': '우럭', 'lengthCm': value},
            ],
          ),
        ),
        throwsA(_invalid('broken', 'catches[0].lengthCm')),
      );
    }
  });

  test('catch weight requires a nonnegative integer', () {
    for (final value in <Object?>[
      '12',
      true,
      -1,
      1.5,
      1.0,
      double.nan,
      double.infinity,
    ]) {
      expect(
        () => _decode(
          _active(
            'broken',
            catches: [
              {'speciesName': '우럭', 'weightG': value},
            ],
          ),
        ),
        throwsA(_invalid('broken', 'catches[0].weightG')),
      );
    }
  });

  test('legacy optional measures and extra catch metadata remain readable', () {
    final revision = _decode(
      _active(
        'legacy',
        catches: [
          {'speciesName': '우럭', 'legacyNote': '이전 메타데이터'},
          {'speciesName': '광어', 'lengthCm': null, 'weightG': null},
          {'speciesName': '농어', 'lengthCm': 0, 'weightG': 0},
        ],
      ),
    );
    final catches = revision.record!.catches;
    expect(catches, hasLength(3));
    expect(catches.first.lengthCm, isNull);
    expect(catches.first.weightG, isNull);
    expect(catches[1].lengthCm, isNull);
    expect(catches[1].weightG, isNull);
    expect(catches.last.lengthCm, 0);
    expect(catches.last.weightG, 0);
  });

  test('all 100 catches round-trip at the supported boundary', () {
    final catches = List.generate(
      100,
      (index) => {
        'speciesName': '어종 $index',
        'lengthCm': index + 0.5,
        'weightG': index,
      },
    );
    final record = _decode(_active('maximum', catches: catches)).record!;
    expect(record.catches, hasLength(100));
    expect(record.catches.last.speciesName, '어종 99');
    expect(record.catches.last.lengthCm, 99.5);
    expect(record.catches.last.weightG, 99);
    final encoded = FirestoreRecordSyncGateway.decodeCloudRecordForTesting(
      _active(
        'maximum',
        catches: record.catches.map((value) => value.toJson()).toList(),
      ),
    );
    expect(encoded.catches.last.toJson(), record.catches.last.toJson());
  });

  test('invalid catches container or count reports the catches field', () {
    for (final value in <Object?>[
      null,
      42,
      'fish',
      <String, Object?>{},
      List.filled(101, const {'speciesName': '우럭'}),
    ]) {
      expect(
        () => _decode(_active('broken', catches: value)),
        throwsA(_invalid('broken', 'catches')),
      );
    }
  });

  test(
    'envelope errors identify the actual document, not stored record ID',
    () {
      for (final changes in <Map<String, Object?>>[
        {'recordId': 'forged-record-id'},
        {'ownerUid': 'different-private-owner'},
        {'schemaVersion': 99},
        {'serverUpdatedAt': null},
      ]) {
        expect(
          () => FirestoreRecordSyncGateway.decodeRevisionForTesting(
            uid: _uid,
            recordId: 'actual-document',
            data: {..._active('actual-document'), ...changes},
          ),
          throwsA(_invalid('actual-document', null)),
        );
      }
    },
  );

  test(
    'diagnostic message names the document and field without owner or body',
    () {
      final data = _active(
        'broken',
        catches: [
          {'speciesName': '우럭', 'weightG': 'private-invalid-value'},
        ],
      );
      try {
        _decode(data);
        fail('Malformed catch must fail before producing a record.');
      } on RecordSyncGatewayException catch (error) {
        expect(error.message, contains('broken'));
        expect(error.message, contains('catches[0].weightG'));
        expect(error.message, isNot(contains(_uid)));
        expect(error.message, isNot(contains('private-invalid-value')));
        expect(error.toString(), isNot(contains(_uid)));
      }
    },
  );

  test('a full snapshot fails instead of returning a partial valid view', () {
    expect(
      () => FirestoreRecordSyncGateway.decodeSnapshotForTesting(
        uid: _uid,
        documents: _partiallyInvalidDocuments(),
      ),
      throwsA(_invalid('broken', 'catches[0].weightG')),
    );
  });

  test('a delta page fails instead of returning a partial valid page', () {
    expect(
      () => FirestoreRecordSyncGateway.decodeChangePageForTesting(
        uid: _uid,
        since: RecordSyncCursor.origin,
        through: _through,
        documents: _partiallyInvalidDocuments(),
      ),
      throwsA(_invalid('broken', 'catches[0].weightG')),
    );
  });

  test('a range page fails instead of returning a partial valid month', () {
    expect(
      () => FirestoreRecordSyncGateway.decodeRangePageForTesting(
        uid: _uid,
        from: DateTime.utc(2026, 11),
        to: DateTime.utc(2026, 12),
        documents: _partiallyInvalidDocuments(),
      ),
      throwsA(_invalid('broken', 'catches[0].weightG')),
    );
  });
}

Matcher _invalid(String documentId, String? fieldPath) =>
    isA<RecordSyncGatewayException>()
        .having((error) => error.code, 'code', 'invalid-server-data')
        .having((error) => error.documentId, 'documentId', documentId)
        .having((error) => error.fieldPath, 'fieldPath', fieldPath);

FishingRecord _newRecord(
  String id, {
  List<CatchRecord> catches = const [],
  double? latitude,
  double? longitude,
}) => FishingRecord(
  id: id,
  location: '테스트 방파제',
  latitude: latitude,
  longitude: longitude,
  startAt: DateTime.utc(2026, 11, 15, 9),
  endAt: DateTime.utc(2026, 11, 15, 11),
  genreName: '루어',
  catches: catches,
);

OutboxItem _item(FishingRecord record) => OutboxItem(
  id: 'outbox-${record.id}',
  userId: _uid,
  recordId: record.id,
  operationType: OutboxOperationType.create,
  status: OutboxStatus.pending,
  createdAt: DateTime.utc(2026, 11, 15),
  baseVersionNo: 0,
  payload: record.toJson(),
);

Map<String, dynamic> _encodedDocument(FishingRecord record) => {
  ...FirestoreRecordSyncGateway.encodeActiveRecordForTesting(
    uid: _uid,
    item: _item(record),
    record: record,
    versionNo: 1,
    createdAt: Timestamp(90, 0),
  ),
  'serverUpdatedAt': Timestamp(100, 0),
};

RemoteRecordRevision _decode(Map<String, dynamic> data) =>
    FirestoreRecordSyncGateway.decodeRevisionForTesting(
      uid: _uid,
      recordId: data['recordId'] as String,
      data: data,
    );

Map<String, Map<String, dynamic>> _partiallyInvalidDocuments() => {
  'valid': _active('valid', serverSeconds: 100),
  'broken': _active(
    'broken',
    serverSeconds: 200,
    catches: [
      {'speciesName': '우럭', 'weightG': 1.5},
    ],
  ),
};

Map<String, dynamic> _active(
  String id, {
  Object? catches = const <Object?>[],
  int serverSeconds = 100,
}) => {
  'schemaVersion': 1,
  'ownerUid': _uid,
  'recordId': id,
  'recordStatus': 'ACTIVE',
  'versionNo': 1,
  'clientModifiedAt': Timestamp(100, 0),
  'createdAt': Timestamp(100, 0),
  'serverUpdatedAt': Timestamp(serverSeconds, 0),
  'lastOutboxId': 'outbox-$id',
  'location': '테스트 방파제',
  'startAt': Timestamp.fromDate(DateTime.utc(2026, 11, 15, 9)),
  'endAt': Timestamp.fromDate(DateTime.utc(2026, 11, 15, 11)),
  'genreName': '루어',
  'tide': null,
  'weather': null,
  'airTemperature': null,
  'waterTemperature': null,
  'catches': catches,
  'memo': null,
  'photoUploadPending': false,
};
