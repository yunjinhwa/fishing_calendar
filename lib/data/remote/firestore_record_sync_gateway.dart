import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../../core/validation/fishing_record_validator.dart';
import '../models/fishing_record.dart';
import '../models/outbox_item.dart';
import 'record_sync_gateway.dart';

class FirestoreRecordSyncGateway implements RecordSyncGateway {
  FirestoreRecordSyncGateway({FirebaseFirestore? database})
    : _database = database ?? FirebaseFirestore.instance;

  static const int schemaVersion = 1;
  static const String activeStatus = 'ACTIVE';
  static const String deletedStatus = 'DELETED';

  final FirebaseFirestore _database;

  @override
  Future<void> pushOutboxItem({
    required String uid,
    required OutboxItem item,
  }) async {
    _validateDocumentId(uid, fieldName: 'uid');
    _validateDocumentId(item.recordId, fieldName: 'recordId');
    _validateDocumentId(item.id, fieldName: 'outboxId');

    final recordReference = _records(uid).doc(item.recordId);
    final receiptReference = _receipts(uid).doc(item.id);

    try {
      await _database.runTransaction<void>((transaction) async {
        final receiptSnapshot = await transaction.get(receiptReference);
        if (receiptSnapshot.exists) {
          _validateExistingReceipt(
            receiptSnapshot.data(),
            uid: uid,
            item: item,
          );
          return;
        }

        final recordSnapshot = await transaction.get(recordReference);
        final currentData = recordSnapshot.data();
        final currentVersion = currentData?['versionNo'];
        final nextVersion = currentVersion is num
            ? currentVersion.toInt() + 1
            : 1;
        final createdAt = currentData?['createdAt'];

        if (item.operationType == OutboxOperationType.delete) {
          transaction.set(recordReference, <String, Object?>{
            'schemaVersion': schemaVersion,
            'ownerUid': uid,
            'recordId': item.recordId,
            'recordStatus': deletedStatus,
            'versionNo': nextVersion,
            'clientModifiedAt': Timestamp.fromDate(item.createdAt.toUtc()),
            'createdAt': createdAt is Timestamp
                ? createdAt
                : FieldValue.serverTimestamp(),
            'serverUpdatedAt': FieldValue.serverTimestamp(),
            'lastOutboxId': item.id,
          });
        } else {
          final payload = item.payload;
          if (payload == null) {
            throw const RecordSyncGatewayException(
              code: 'missing-payload',
              message: '업로드할 기록 데이터가 없습니다.',
            );
          }

          final record = _decodeLocalPayload(payload, item.recordId);
          transaction.set(
            recordReference,
            _encodeActiveRecord(
              uid: uid,
              item: item,
              record: record,
              versionNo: nextVersion,
              createdAt: createdAt is Timestamp ? createdAt : null,
            ),
          );
        }

        transaction.set(receiptReference, <String, Object?>{
          'ownerUid': uid,
          'outboxId': item.id,
          'recordId': item.recordId,
          'operationType': item.operationType.name,
          'resultingVersionNo': nextVersion,
          'processedAt': FieldValue.serverTimestamp(),
        });
      });
    } on RecordSyncGatewayException {
      rethrow;
    } on FirebaseException catch (error, stackTrace) {
      throw _mapFirebaseFailure(error, stackTrace);
    } on Object catch (error, stackTrace) {
      throw RecordSyncGatewayException(
        code: 'write-failed',
        message: '기록을 서버에 반영하지 못했습니다.',
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
  }

  @override
  Future<RemoteRecordSnapshot> fetchSnapshot({required String uid}) async {
    _validateDocumentId(uid, fieldName: 'uid');

    try {
      final querySnapshot = await _records(
        uid,
      ).get(const GetOptions(source: Source.server));
      final activeRecords = <FishingRecord>[];
      final knownRecordIds = <String>{};

      for (final document in querySnapshot.docs) {
        final data = document.data();
        final recordId = data['recordId'];
        final ownerUid = data['ownerUid'];
        final status = data['recordStatus'];
        if (recordId is! String ||
            recordId != document.id ||
            ownerUid != uid ||
            (status != activeStatus && status != deletedStatus)) {
          throw const RecordSyncGatewayException(
            code: 'invalid-server-data',
            message: '서버 기록 형식이 올바르지 않습니다.',
          );
        }
        _validateCloudEnvelope(
          data,
          uid: uid,
          recordId: recordId,
          status: status as String,
        );

        knownRecordIds.add(recordId);
        if (status == deletedStatus) {
          continue;
        }
        activeRecords.add(_decodeCloudRecord(data));
      }

      activeRecords.sort(
        (left, right) => left.startAt.compareTo(right.startAt),
      );
      return RemoteRecordSnapshot(
        activeRecords: List<FishingRecord>.unmodifiable(activeRecords),
        knownRecordIds: Set<String>.unmodifiable(knownRecordIds),
      );
    } on RecordSyncGatewayException {
      rethrow;
    } on FirebaseException catch (error, stackTrace) {
      throw _mapFirebaseFailure(error, stackTrace);
    } on Object catch (error, stackTrace) {
      throw RecordSyncGatewayException(
        code: 'read-failed',
        message: '서버 기록을 불러오지 못했습니다.',
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
  }

  CollectionReference<Map<String, dynamic>> _records(String uid) =>
      _database.collection('users').doc(uid).collection('records');

  CollectionReference<Map<String, dynamic>> _receipts(String uid) =>
      _database.collection('users').doc(uid).collection('sync_receipts');

  FishingRecord _decodeLocalPayload(
    Map<String, dynamic> payload,
    String expectedRecordId,
  ) {
    try {
      final record = FishingRecord.fromJson(payload);
      if (record.id != expectedRecordId) {
        throw const RecordSyncGatewayException(
          code: 'record-id-mismatch',
          message: '기록 ID와 업로드 요청이 일치하지 않습니다.',
        );
      }
      final validationMessage = FishingRecordValidator.validate(record);
      if (validationMessage != null) {
        throw RecordSyncGatewayException(
          code: 'invalid-payload',
          message: validationMessage,
        );
      }
      return record;
    } on RecordSyncGatewayException {
      rethrow;
    } on Object catch (error, stackTrace) {
      throw RecordSyncGatewayException(
        code: 'invalid-payload',
        message: '업로드할 기록 데이터 형식이 올바르지 않습니다.',
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
  }

  static Map<String, Object?> _encodeActiveRecord({
    required String uid,
    required OutboxItem item,
    required FishingRecord record,
    required int versionNo,
    required Timestamp? createdAt,
  }) {
    return <String, Object?>{
      'schemaVersion': schemaVersion,
      'ownerUid': uid,
      'recordId': record.id,
      'recordStatus': activeStatus,
      'location': record.location,
      'startAt': Timestamp.fromDate(record.startAt.toUtc()),
      'endAt': Timestamp.fromDate(record.endAt.toUtc()),
      'genreName': record.genreName,
      'tide': record.tide,
      'weather': record.weather,
      'airTemperature': record.airTemperature,
      'waterTemperature': record.waterTemperature,
      'catches': record.catches
          .map(
            (catchRecord) => <String, Object?>{
              'speciesName': catchRecord.speciesName,
              'lengthCm': catchRecord.lengthCm,
              'weightG': catchRecord.weightG,
            },
          )
          .toList(growable: false),
      'memo': record.memo,
      // Device-local paths never leave the device. Object Storage support is
      // introduced separately; this flag keeps that pending work visible.
      'photoUploadPending': record.photoPaths.isNotEmpty,
      'versionNo': versionNo,
      'clientModifiedAt': Timestamp.fromDate(item.createdAt.toUtc()),
      'createdAt': createdAt ?? FieldValue.serverTimestamp(),
      'serverUpdatedAt': FieldValue.serverTimestamp(),
      'lastOutboxId': item.id,
    };
  }

  static FishingRecord _decodeCloudRecord(Map<String, dynamic> data) {
    try {
      final startAt = data['startAt'];
      final endAt = data['endAt'];
      final rawCatches = data['catches'];
      if (startAt is! Timestamp || endAt is! Timestamp || rawCatches is! List) {
        throw const FormatException('Invalid cloud record fields.');
      }

      final record = FishingRecord(
        id: data['recordId'] as String,
        location: data['location'] as String,
        startAt: startAt.toDate(),
        endAt: endAt.toDate(),
        genreName: data['genreName'] as String,
        tide: data['tide'] as String?,
        weather: data['weather'] as String?,
        airTemperature: (data['airTemperature'] as num?)?.toDouble(),
        waterTemperature: (data['waterTemperature'] as num?)?.toDouble(),
        catches: rawCatches
            .map(
              (item) =>
                  CatchRecord.fromJson(Map<String, dynamic>.from(item as Map)),
            )
            .toList(growable: false),
        // Firestore stores no device-local image path.
        photoPaths: const <String>[],
        memo: data['memo'] as String?,
      );
      final validationMessage = FishingRecordValidator.validate(record);
      if (validationMessage != null) {
        throw FormatException(validationMessage);
      }
      return record;
    } on Object catch (error, stackTrace) {
      throw RecordSyncGatewayException(
        code: 'invalid-server-data',
        message: '서버 기록 형식이 올바르지 않습니다.',
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
  }

  @visibleForTesting
  static Map<String, Object?> encodeActiveRecordForTesting({
    required String uid,
    required OutboxItem item,
    required FishingRecord record,
    required int versionNo,
    Timestamp? createdAt,
  }) => _encodeActiveRecord(
    uid: uid,
    item: item,
    record: record,
    versionNo: versionNo,
    createdAt: createdAt,
  );

  @visibleForTesting
  static FishingRecord decodeCloudRecordForTesting(Map<String, dynamic> data) =>
      _decodeCloudRecord(data);

  void _validateDocumentId(String value, {required String fieldName}) {
    final maxLength = fieldName == 'recordId'
        ? FishingRecordValidator.maxDocumentIdLength
        : 300;
    if (value.trim().isEmpty ||
        value.contains('/') ||
        value.length > maxLength) {
      throw RecordSyncGatewayException(
        code: 'invalid-document-id',
        message: '$fieldName 값이 올바르지 않습니다.',
      );
    }
  }

  static void _validateExistingReceipt(
    Map<String, dynamic>? data, {
    required String uid,
    required OutboxItem item,
  }) {
    const expectedKeys = <String>{
      'ownerUid',
      'outboxId',
      'recordId',
      'operationType',
      'resultingVersionNo',
      'processedAt',
    };
    final version = data?['resultingVersionNo'];
    if (data == null ||
        !_hasExactKeys(data, expectedKeys) ||
        data['ownerUid'] != uid ||
        data['outboxId'] != item.id ||
        data['recordId'] != item.recordId ||
        data['operationType'] != item.operationType.name ||
        version is! int ||
        version < 1 ||
        data['processedAt'] is! Timestamp) {
      throw const RecordSyncGatewayException(
        code: 'idempotency-conflict',
        message: '같은 동기화 요청 ID에 다른 서버 처리 내역이 있습니다.',
      );
    }
  }

  static void _validateCloudEnvelope(
    Map<String, dynamic> data, {
    required String uid,
    required String recordId,
    required String status,
  }) {
    const baseKeys = <String>{
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
    const activeOnlyKeys = <String>{
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
    };
    final expectedKeys = status == activeStatus
        ? <String>{...baseKeys, ...activeOnlyKeys}
        : baseKeys;
    final version = data['versionNo'];
    final lastOutboxId = data['lastOutboxId'];
    final validBase =
        _hasExactKeys(data, expectedKeys) &&
        data['schemaVersion'] == schemaVersion &&
        data['ownerUid'] == uid &&
        data['recordId'] == recordId &&
        version is int &&
        version >= 1 &&
        data['clientModifiedAt'] is Timestamp &&
        data['createdAt'] is Timestamp &&
        data['serverUpdatedAt'] is Timestamp &&
        lastOutboxId is String &&
        lastOutboxId.isNotEmpty &&
        !lastOutboxId.contains('/') &&
        lastOutboxId.length <= 300;
    final validActive =
        status != activeStatus || data['photoUploadPending'] is bool;
    if (!validBase || !validActive) {
      throw const RecordSyncGatewayException(
        code: 'invalid-server-data',
        message: '서버 기록 형식이 올바르지 않습니다.',
      );
    }
  }

  static bool _hasExactKeys(
    Map<String, dynamic> data,
    Set<String> expectedKeys,
  ) {
    final actualKeys = data.keys.toSet();
    return actualKeys.length == expectedKeys.length &&
        actualKeys.containsAll(expectedKeys);
  }

  @visibleForTesting
  static void validateExistingReceiptForTesting(
    Map<String, dynamic>? data, {
    required String uid,
    required OutboxItem item,
  }) => _validateExistingReceipt(data, uid: uid, item: item);

  RecordSyncGatewayException _mapFirebaseFailure(
    FirebaseException error,
    StackTrace stackTrace,
  ) {
    final message = switch (error.code) {
      'permission-denied' => '서버 기록 접근 권한이 없습니다.',
      'unauthenticated' => '로그인 세션이 만료되었습니다. 다시 로그인해 주세요.',
      'unavailable' => '동기화 서버에 연결할 수 없습니다.',
      'deadline-exceeded' => '동기화 요청 시간이 초과되었습니다.',
      _ => '기록 동기화 중 서버 오류가 발생했습니다.',
    };
    return RecordSyncGatewayException(
      code: error.code,
      message: message,
      cause: error,
      causeStackTrace: stackTrace,
    );
  }
}
