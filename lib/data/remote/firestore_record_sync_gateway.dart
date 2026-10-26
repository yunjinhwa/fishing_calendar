import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../core/validation/fishing_record_validator.dart';
import '../models/fishing_record.dart';
import '../models/outbox_item.dart';
import '../models/record_sync_metadata.dart';
import 'record_sync_gateway.dart';

class FirestoreRecordSyncGateway
    implements
        RecordSyncGateway,
        RecordRevisionWatchGateway,
        IncrementalRecordSyncGateway {
  FirestoreRecordSyncGateway({FirebaseFirestore? database})
    : _database = database ?? FirebaseFirestore.instance;

  static const int schemaVersion = 1;
  static const String activeStatus = 'ACTIVE';
  static const String deletedStatus = 'DELETED';

  final FirebaseFirestore _database;

  @override
  Stream<RemoteRecordRevision?> watchRecordRevision({
    required String uid,
    required String recordId,
  }) async* {
    _validateDocumentId(uid, fieldName: 'uid');
    _validateDocumentId(recordId, fieldName: 'recordId');
    try {
      await for (final snapshot in _records(
        uid,
      ).doc(recordId).snapshots(includeMetadataChanges: true)) {
        // A cached absence or a local pending deletion must not invalidate the
        // local cache. Metadata events deliver the subsequent server result.
        if (snapshot.metadata.isFromCache ||
            snapshot.metadata.hasPendingWrites) {
          continue;
        }
        final data = snapshot.data();
        yield data == null
            ? null
            : _decodeRevision(data: data, uid: uid, recordId: recordId);
      }
    } on FirebaseException catch (error, stackTrace) {
      throw _mapFirebaseFailure(error, stackTrace);
    }
  }

  @override
  Future<RecordPushResult> pushOutboxItem({
    required String uid,
    required OutboxItem item,
  }) async {
    _validateDocumentId(uid, fieldName: 'uid');
    _validateDocumentId(item.recordId, fieldName: 'recordId');
    _validateDocumentId(item.id, fieldName: 'outboxId');

    final recordReference = _records(uid).doc(item.recordId);
    final receiptReference = _receipts(uid).doc(item.id);
    final localRecord = item.operationType == OutboxOperationType.delete
        ? null
        : _decodeLocalPayload(item.payload, item.recordId);
    RecordPushResult? result;

    try {
      await _database.runTransaction<void>((transaction) async {
        final receiptSnapshot = await transaction.get(receiptReference);
        if (receiptSnapshot.exists) {
          result = _validateExistingReceipt(
            receiptSnapshot.data(),
            uid: uid,
            item: item,
            record: localRecord,
          );
          return;
        }

        final recordSnapshot = await transaction.get(recordReference);
        final currentData = recordSnapshot.data();
        final currentRevision = currentData == null
            ? null
            : _decodeRevision(
                uid: uid,
                recordId: item.recordId,
                data: currentData,
              );
        final currentVersion = currentRevision?.versionNo ?? 0;
        final baseVersion = item.baseVersionNo;
        if (baseVersion == null && currentRevision != null ||
            baseVersion != null && baseVersion != currentVersion) {
          throw RecordVersionConflictException(
            recordId: item.recordId,
            baseVersionNo: baseVersion,
            remoteVersionNo: currentVersion,
            remoteStatus: currentRevision?.status ?? RemoteRecordStatus.missing,
            remoteRecord: currentRevision?.record,
          );
        }
        final effectiveBaseVersion = baseVersion ?? 0;
        final nextVersion = effectiveBaseVersion + 1;
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
          transaction.set(
            recordReference,
            _encodeActiveRecord(
              uid: uid,
              item: item,
              record: localRecord!,
              versionNo: nextVersion,
              createdAt: createdAt is Timestamp ? createdAt : null,
            ),
          );
        }

        transaction.set(receiptReference, <String, Object?>{
          'schemaVersion': 2,
          'ownerUid': uid,
          'outboxId': item.id,
          'recordId': item.recordId,
          'operationType': item.operationType.name,
          'baseVersionNo': effectiveBaseVersion,
          'resultingVersionNo': nextVersion,
          'mutationFingerprint': _mutationFingerprint(
            item: item,
            baseVersionNo: effectiveBaseVersion,
            record: localRecord,
          ),
          'processedAt': FieldValue.serverTimestamp(),
        });
        result = RecordPushResult(
          versionNo: nextVersion,
          status: item.operationType == OutboxOperationType.delete
              ? RemoteRecordStatus.deleted
              : RemoteRecordStatus.active,
        );
      });
      return result!;
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
      // Keep the initial read unordered: orderBy would silently omit legacy
      // documents without serverUpdatedAt rather than fail validation.
      return _decodeSnapshot(
        uid: uid,
        documents: querySnapshot.docs.map(
          (document) => MapEntry(document.id, document.data()),
        ),
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

  @override
  Future<RecordSyncCursor> fetchLatestCursor({required String uid}) async {
    _validateDocumentId(uid, fieldName: 'uid');
    try {
      final result = await _records(uid)
          .orderBy('serverUpdatedAt', descending: true)
          .orderBy(FieldPath.documentId, descending: true)
          .limit(1)
          .get(const GetOptions(source: Source.server));
      if (result.docs.isEmpty) return RecordSyncCursor.origin;
      final document = result.docs.single;
      return _decodeRevision(
        uid: uid,
        recordId: document.id,
        data: document.data(),
      ).cursor!;
    } on RecordSyncGatewayException {
      rethrow;
    } on FirebaseException catch (error, stackTrace) {
      throw _mapFirebaseFailure(error, stackTrace);
    } on Object catch (error, stackTrace) {
      throw RecordSyncGatewayException(
        code: 'read-failed',
        message: '서버 기록의 최신 변경 위치를 확인하지 못했습니다.',
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
  }

  @override
  Future<RemoteRecordChangePage> fetchChanges({
    required String uid,
    required RecordSyncCursor since,
    required RecordSyncCursor through,
    RecordSyncCursor? after,
    int limit = 100,
  }) async {
    _validateChangeRequest(
      uid: uid,
      since: since,
      through: through,
      after: after,
      limit: limit,
    );
    if (through.compareTo(RecordSyncCursor.origin) == 0) {
      return const RemoteRecordChangePage(revisions: [], hasMore: false);
    }
    try {
      var query = _records(
        uid,
      ).orderBy('serverUpdatedAt').orderBy(FieldPath.documentId);
      if (after == null) {
        // Replay the entire checkpoint timestamp bucket on every new pull.
        // A record with a lower ID may have changed at that same timestamp.
        query = query.startAt([Timestamp(since.seconds, since.nanoseconds)]);
      } else {
        query = query.startAfter([
          Timestamp(after.seconds, after.nanoseconds),
          after.recordId,
        ]);
      }
      query = query.endAt([
        Timestamp(through.seconds, through.nanoseconds),
        through.recordId,
      ]);
      final result = await query
          .limit(limit)
          .get(const GetOptions(source: Source.server));
      final revisions = <RemoteRecordRevision>[];
      var previous = after;
      for (final document in result.docs) {
        final revision = _decodeRevision(
          uid: uid,
          recordId: document.id,
          data: document.data(),
        );
        final cursor = revision.cursor!;
        if (_compareTimestamp(cursor, since) < 0 ||
            cursor.compareTo(through) > 0 ||
            (previous != null && cursor.compareTo(previous) <= 0)) {
          throw const RecordSyncGatewayException(
            code: 'invalid-server-data',
            message: '서버 변경 기록의 순서가 올바르지 않습니다.',
          );
        }
        revisions.add(revision);
        previous = cursor;
      }
      return RemoteRecordChangePage(
        revisions: List.unmodifiable(revisions),
        hasMore: revisions.length == limit,
      );
    } on RecordSyncGatewayException {
      rethrow;
    } on FirebaseException catch (error, stackTrace) {
      throw _mapFirebaseFailure(error, stackTrace);
    } on Object catch (error, stackTrace) {
      throw RecordSyncGatewayException(
        code: 'read-failed',
        message: '서버의 변경된 기록을 불러오지 못했습니다.',
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
  }

  static void _validateChangeRequest({
    required String uid,
    required RecordSyncCursor since,
    required RecordSyncCursor through,
    required RecordSyncCursor? after,
    required int limit,
  }) {
    _validateDocumentId(uid, fieldName: 'uid');
    if (limit < 1 || limit > 500) {
      throw const RecordSyncGatewayException(
        code: 'invalid-page-size',
        message: '변경 기록 조회 개수가 올바르지 않습니다.',
      );
    }
    try {
      RecordSyncCursor.fromJson(since.toJson());
      RecordSyncCursor.fromJson(through.toJson());
      if (since.recordId.isNotEmpty) {
        _validateDocumentId(since.recordId, fieldName: 'recordId');
      }
      if (through.recordId.isNotEmpty) {
        _validateDocumentId(through.recordId, fieldName: 'recordId');
      }
      if (since.compareTo(through) > 0) {
        throw const FormatException('Checkpoint exceeds the server head.');
      }
      if (after != null) {
        RecordSyncCursor.fromJson(after.toJson());
        _validateDocumentId(after.recordId, fieldName: 'recordId');
        if (_compareTimestamp(after, since) < 0 ||
            after.compareTo(through) > 0) {
          throw const FormatException('Page cursor precedes its checkpoint.');
        }
      }
    } on FormatException catch (error, stackTrace) {
      throw RecordSyncGatewayException(
        code: 'invalid-cursor',
        message: '기록 동기화 조회 위치가 올바르지 않습니다.',
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
  }

  static int _compareTimestamp(RecordSyncCursor left, RecordSyncCursor right) {
    final comparison = left.seconds.compareTo(right.seconds);
    return comparison != 0
        ? comparison
        : left.nanoseconds.compareTo(right.nanoseconds);
  }

  static RemoteRecordSnapshot _decodeSnapshot({
    required String uid,
    required Iterable<MapEntry<String, Map<String, dynamic>>> documents,
  }) {
    var cursor = RecordSyncCursor.origin;
    final revisions = <RemoteRecordRevision>[];
    for (final document in documents) {
      final revision = _decodeRevision(
        uid: uid,
        recordId: document.key,
        data: document.value,
      );
      if (revision.cursor!.compareTo(cursor) > 0) cursor = revision.cursor!;
      revisions.add(revision);
    }
    revisions.sort((left, right) {
      final leftStart = left.record?.startAt;
      final rightStart = right.record?.startAt;
      if (leftStart == null && rightStart == null) {
        return left.recordId.compareTo(right.recordId);
      }
      if (leftStart == null) return 1;
      if (rightStart == null) return -1;
      return leftStart.compareTo(rightStart);
    });
    return RemoteRecordSnapshot(
      revisions: List.unmodifiable(revisions),
      cursor: cursor,
    );
  }

  @override
  Future<RemoteRecordRevision?> fetchRecordRevision({
    required String uid,
    required String recordId,
  }) async {
    _validateDocumentId(uid, fieldName: 'uid');
    _validateDocumentId(recordId, fieldName: 'recordId');
    try {
      final snapshot = await _records(
        uid,
      ).doc(recordId).get(const GetOptions(source: Source.server));
      final data = snapshot.data();
      if (data == null) {
        return null;
      }
      return _decodeRevision(data: data, uid: uid, recordId: recordId);
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

  static RemoteRecordRevision _decodeRevision({
    required String uid,
    required String recordId,
    required Map<String, dynamic> data,
  }) {
    final storedRecordId = data['recordId'];
    final ownerUid = data['ownerUid'];
    final status = data['recordStatus'];
    if (storedRecordId is! String ||
        storedRecordId != recordId ||
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
    final updatedAt = data['serverUpdatedAt']! as Timestamp;
    return RemoteRecordRevision(
      recordId: recordId,
      versionNo: data['versionNo']! as int,
      status: status == activeStatus
          ? RemoteRecordStatus.active
          : RemoteRecordStatus.deleted,
      record: status == activeStatus ? _decodeCloudRecord(data) : null,
      cursor: RecordSyncCursor(
        seconds: updatedAt.seconds,
        nanoseconds: updatedAt.nanoseconds,
        recordId: recordId,
      ),
    );
  }

  CollectionReference<Map<String, dynamic>> _records(String uid) =>
      _database.collection('users').doc(uid).collection('records');

  CollectionReference<Map<String, dynamic>> _receipts(String uid) =>
      _database.collection('users').doc(uid).collection('sync_receipts');

  FishingRecord _decodeLocalPayload(
    Map<String, dynamic>? payload,
    String expectedRecordId,
  ) {
    try {
      if (payload == null) {
        throw const RecordSyncGatewayException(
          code: 'missing-payload',
          message: '업로드할 기록 데이터가 없습니다.',
        );
      }
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
      // Photo files and device-local paths never leave the device. The field
      // remains only for schema-v1 compatibility and is always false because
      // this app does not queue photo uploads.
      'photoUploadPending': false,
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

  @visibleForTesting
  static RemoteRecordRevision decodeRevisionForTesting({
    required String uid,
    required String recordId,
    required Map<String, dynamic> data,
  }) => _decodeRevision(uid: uid, recordId: recordId, data: data);

  @visibleForTesting
  static RemoteRecordSnapshot decodeSnapshotForTesting({
    required String uid,
    required Map<String, Map<String, dynamic>> documents,
  }) => _decodeSnapshot(uid: uid, documents: documents.entries);

  @visibleForTesting
  static void validateChangeRequestForTesting({
    required String uid,
    required RecordSyncCursor since,
    required RecordSyncCursor through,
    RecordSyncCursor? after,
    int limit = 100,
  }) => _validateChangeRequest(
    uid: uid,
    since: since,
    through: through,
    after: after,
    limit: limit,
  );

  static void _validateDocumentId(String value, {required String fieldName}) {
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

  static String _mutationFingerprint({
    required OutboxItem item,
    required int baseVersionNo,
    required FishingRecord? record,
  }) {
    final mutation = <String, Object?>{
      'recordId': item.recordId,
      'operationType': item.operationType.name,
      'baseVersionNo': baseVersionNo,
      'record': record == null
          ? null
          : <String, Object?>{
              'location': record.location,
              'startAt': record.startAt.toUtc().toIso8601String(),
              'endAt': record.endAt.toUtc().toIso8601String(),
              'genreName': record.genreName,
              'tide': record.tide,
              'weather': record.weather,
              'airTemperature': record.airTemperature,
              'waterTemperature': record.waterTemperature,
              'catches': record.catches
                  .map(
                    (item) => <String, Object?>{
                      'speciesName': item.speciesName,
                      'lengthCm': item.lengthCm,
                      'weightG': item.weightG,
                    },
                  )
                  .toList(growable: false),
              'memo': record.memo,
            },
    };
    return sha256.convert(utf8.encode(jsonEncode(mutation))).toString();
  }

  static RecordPushResult _validateExistingReceipt(
    Map<String, dynamic>? data, {
    required String uid,
    required OutboxItem item,
    required FishingRecord? record,
  }) {
    const v1Keys = <String>{
      'ownerUid',
      'outboxId',
      'recordId',
      'operationType',
      'resultingVersionNo',
      'processedAt',
    };
    const v2Keys = <String>{
      'schemaVersion',
      'ownerUid',
      'outboxId',
      'recordId',
      'operationType',
      'baseVersionNo',
      'resultingVersionNo',
      'mutationFingerprint',
      'processedAt',
    };
    final version = data?['resultingVersionNo'];
    final isV1 = data != null && _hasExactKeys(data, v1Keys);
    final isV2 = data != null && _hasExactKeys(data, v2Keys);
    var validV2 = true;
    if (isV2) {
      final receiptBaseVersion = data['baseVersionNo'];
      validV2 =
          data['schemaVersion'] == 2 &&
          receiptBaseVersion is int &&
          receiptBaseVersion >= 0 &&
          version == receiptBaseVersion + 1 &&
          (item.baseVersionNo == null ||
              item.baseVersionNo == receiptBaseVersion) &&
          data['mutationFingerprint'] ==
              _mutationFingerprint(
                item: item,
                baseVersionNo: receiptBaseVersion,
                record: record,
              );
    }
    if (data == null ||
        (!isV1 && !isV2) ||
        !validV2 ||
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
    return RecordPushResult(
      versionNo: version,
      status: item.operationType == OutboxOperationType.delete
          ? RemoteRecordStatus.deleted
          : RemoteRecordStatus.active,
    );
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
  static RecordPushResult validateExistingReceiptForTesting(
    Map<String, dynamic>? data, {
    required String uid,
    required OutboxItem item,
  }) => _validateExistingReceipt(
    data,
    uid: uid,
    item: item,
    record: item.operationType == OutboxOperationType.delete
        ? null
        : _decodePayloadForTesting(item),
  );

  @visibleForTesting
  static String mutationFingerprintForTesting(OutboxItem item) {
    return _mutationFingerprint(
      item: item,
      baseVersionNo: item.baseVersionNo ?? 0,
      record: item.operationType == OutboxOperationType.delete
          ? null
          : _decodePayloadForTesting(item),
    );
  }

  static FishingRecord? _decodePayloadForTesting(OutboxItem item) {
    final payload = item.payload;
    return payload == null ? null : FishingRecord.fromJson(payload);
  }

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
