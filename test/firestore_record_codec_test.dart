import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/outbox_item.dart';
import 'package:fishing_build/data/remote/firestore_record_sync_gateway.dart';
import 'package:fishing_build/data/remote/record_sync_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('active record codec matches the Firestore schema and round-trips', () {
    final record = FishingRecord(
      id: 'codec-record',
      location: '테스트 방파제',
      startAt: DateTime.parse('2026-09-28T08:00:00+09:00'),
      endAt: DateTime.parse('2026-09-28T10:00:00+09:00'),
      genreName: '바다낚시',
      tide: '3물',
      weather: '맑음',
      airTemperature: 24,
      waterTemperature: 20,
      catches: const <CatchRecord>[
        CatchRecord(speciesName: '우럭', lengthCm: 31, weightG: 820),
      ],
      photoPaths: const <String>['C:/device-only/photo.jpg'],
      memo: '코덱 테스트',
    );
    final item = OutboxItem(
      id: 'codec-outbox',
      userId: 'codec-user',
      recordId: record.id,
      operationType: OutboxOperationType.create,
      status: OutboxStatus.pending,
      createdAt: DateTime.utc(2026, 9, 28),
      payload: record.toJson(),
    );
    final createdAt = Timestamp.fromDate(DateTime.utc(2026, 9, 27));

    final encoded = FirestoreRecordSyncGateway.encodeActiveRecordForTesting(
      uid: 'codec-user',
      item: item,
      record: record,
      versionNo: 1,
      createdAt: createdAt,
    );

    expect(encoded.keys.toSet(), <String>{
      'schemaVersion',
      'ownerUid',
      'recordId',
      'recordStatus',
      'location',
      'startAt',
      'endAt',
      'genreName',
      'tide',
      'weather',
      'airTemperature',
      'waterTemperature',
      'catches',
      'memo',
      'photoUploadPending',
      'versionNo',
      'clientModifiedAt',
      'createdAt',
      'serverUpdatedAt',
      'lastOutboxId',
    });
    expect(encoded, isNot(contains('photoPaths')));
    expect(encoded['photoUploadPending'], isTrue);
    expect(encoded['createdAt'], createdAt);
    expect(encoded['startAt'], Timestamp.fromDate(record.startAt.toUtc()));
    expect(encoded['lastOutboxId'], item.id);

    final decoded = FirestoreRecordSyncGateway.decodeCloudRecordForTesting(
      Map<String, dynamic>.from(encoded),
    );
    expect(decoded.id, record.id);
    expect(decoded.location, record.location);
    expect(
      decoded.startAt.millisecondsSinceEpoch,
      record.startAt.millisecondsSinceEpoch,
    );
    expect(decoded.catches.single.speciesName, '우럭');
    expect(decoded.catches.single.weightG, 820);
    expect(decoded.photoPaths, isEmpty);
  });

  test('cloud decoder fails closed for malformed catch entries', () {
    final data = <String, dynamic>{
      'recordId': 'malformed-record',
      'location': '테스트 방파제',
      'startAt': Timestamp.fromDate(DateTime.utc(2026, 9, 28, 8)),
      'endAt': Timestamp.fromDate(DateTime.utc(2026, 9, 28, 10)),
      'genreName': '바다낚시',
      'tide': null,
      'weather': null,
      'airTemperature': null,
      'waterTemperature': null,
      'catches': <Object>[42],
      'memo': null,
    };

    expect(
      () => FirestoreRecordSyncGateway.decodeCloudRecordForTesting(data),
      throwsA(
        isA<RecordSyncGatewayException>().having(
          (error) => error.code,
          'code',
          'invalid-server-data',
        ),
      ),
    );
  });

  test('existing receipt must describe the exact idempotent mutation', () {
    final item = OutboxItem(
      id: 'receipt-outbox',
      userId: 'receipt-user',
      recordId: 'receipt-record',
      operationType: OutboxOperationType.update,
      status: OutboxStatus.pending,
      createdAt: DateTime.utc(2026, 9, 28),
    );
    final receipt = <String, dynamic>{
      'ownerUid': 'receipt-user',
      'outboxId': item.id,
      'recordId': item.recordId,
      'operationType': item.operationType.name,
      'resultingVersionNo': 2,
      'processedAt': Timestamp.fromDate(DateTime.utc(2026, 9, 28)),
    };

    expect(
      () => FirestoreRecordSyncGateway.validateExistingReceiptForTesting(
        receipt,
        uid: 'receipt-user',
        item: item,
      ),
      returnsNormally,
    );

    expect(
      () => FirestoreRecordSyncGateway.validateExistingReceiptForTesting(
        <String, dynamic>{...receipt, 'recordId': 'another-record'},
        uid: 'receipt-user',
        item: item,
      ),
      throwsA(
        isA<RecordSyncGatewayException>().having(
          (error) => error.code,
          'code',
          'idempotency-conflict',
        ),
      ),
    );
  });
}
