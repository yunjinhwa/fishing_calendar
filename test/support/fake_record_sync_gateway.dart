import 'dart:async';
import 'dart:convert';

import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/outbox_item.dart';
import 'package:fishing_build/data/models/record_sync_metadata.dart';
import 'package:fishing_build/data/remote/record_sync_gateway.dart';

class FakeRecordSyncGateway implements RecordSyncGateway {
  final Map<String, Map<String, RemoteRecordRevision>> _revisionsByUser = {};
  final Map<String, Map<String, _FakeReceipt>> _receiptsByUser = {};

  final List<String> pushedOutboxIds = <String>[];
  final Set<String> failingOutboxIds = <String>{};
  int fetchCount = 0;
  bool failFetch = false;
  Completer<void>? fetchStarted;
  Future<void>? fetchGate;
  Completer<void>? pushStarted;
  Future<void>? pushGate;

  @override
  Future<RemoteRecordSnapshot> fetchSnapshot({required String uid}) async {
    fetchCount += 1;
    final started = fetchStarted;
    if (started != null && !started.isCompleted) {
      started.complete();
    }
    final gate = fetchGate;
    if (gate != null) {
      await gate;
    }
    if (failFetch) {
      throw const RecordSyncGatewayException(
        code: 'unavailable',
        message: '테스트 서버에 연결할 수 없습니다.',
      );
    }

    final revisions =
        (_revisionsByUser[uid] ?? const <String, RemoteRecordRevision>{}).values
            .toList(growable: false);
    return RemoteRecordSnapshot(
      revisions: List<RemoteRecordRevision>.unmodifiable(revisions),
    );
  }

  @override
  Future<RemoteRecordRevision?> fetchRecordRevision({
    required String uid,
    required String recordId,
  }) async {
    if (failFetch) {
      throw const RecordSyncGatewayException(
        code: 'unavailable',
        message: '테스트 서버에 연결할 수 없습니다.',
      );
    }
    return _revisionsByUser[uid]?[recordId];
  }

  @override
  Future<RecordPushResult> pushOutboxItem({
    required String uid,
    required OutboxItem item,
  }) async {
    pushedOutboxIds.add(item.id);
    final started = pushStarted;
    if (started != null && !started.isCompleted) {
      started.complete();
    }
    final gate = pushGate;
    if (gate != null) {
      await gate;
    }
    if (failingOutboxIds.contains(item.id)) {
      throw const RecordSyncGatewayException(
        code: 'test-failure',
        message: '테스트 업로드 실패',
      );
    }

    FishingRecord? record;
    if (item.operationType != OutboxOperationType.delete) {
      final payload = item.payload;
      if (payload == null) {
        throw const RecordSyncGatewayException(
          code: 'missing-payload',
          message: '테스트 payload가 없습니다.',
        );
      }
      final decodedRecord = FishingRecord.fromJson(payload);
      if (decodedRecord.id != item.recordId) {
        throw const RecordSyncGatewayException(
          code: 'record-id-mismatch',
          message: '테스트 기록 ID와 업로드 요청이 일치하지 않습니다.',
        );
      }
      record = _withoutDevicePhotos(decodedRecord);
    }

    final receipts = _receiptsByUser.putIfAbsent(
      uid,
      () => <String, _FakeReceipt>{},
    );
    final existingReceipt = receipts[item.id];
    final fingerprint = _fingerprint(item, record);
    if (existingReceipt != null) {
      if (existingReceipt.recordId != item.recordId ||
          existingReceipt.operationType != item.operationType ||
          (item.baseVersionNo != null &&
              existingReceipt.baseVersionNo != item.baseVersionNo) ||
          existingReceipt.fingerprint != fingerprint) {
        throw const RecordSyncGatewayException(
          code: 'idempotency-conflict',
          message: '같은 동기화 요청 ID에 다른 변경 내용이 있습니다.',
        );
      }
      return existingReceipt.result;
    }

    final revisions = _revisionsByUser.putIfAbsent(
      uid,
      () => <String, RemoteRecordRevision>{},
    );
    final current = revisions[item.recordId];
    final currentVersion = current?.versionNo ?? 0;
    final baseVersion = item.baseVersionNo;
    if ((baseVersion == null && current != null) ||
        (baseVersion != null && baseVersion != currentVersion)) {
      throw RecordVersionConflictException(
        recordId: item.recordId,
        baseVersionNo: baseVersion,
        remoteVersionNo: currentVersion,
        remoteStatus: current?.status ?? RemoteRecordStatus.missing,
        remoteRecord: current?.record,
      );
    }

    final effectiveBaseVersion = baseVersion ?? 0;
    final nextVersion = effectiveBaseVersion + 1;
    final status = item.operationType == OutboxOperationType.delete
        ? RemoteRecordStatus.deleted
        : RemoteRecordStatus.active;
    revisions[item.recordId] = RemoteRecordRevision(
      recordId: item.recordId,
      versionNo: nextVersion,
      status: status,
      record: status == RemoteRecordStatus.active ? record : null,
    );
    final result = RecordPushResult(versionNo: nextVersion, status: status);
    receipts[item.id] = _FakeReceipt(
      recordId: item.recordId,
      operationType: item.operationType,
      baseVersionNo: effectiveBaseVersion,
      fingerprint: fingerprint,
      result: result,
    );
    return result;
  }

  void seedActive(String uid, FishingRecord record, {int? versionNo}) {
    final revisions = _revisionsByUser.putIfAbsent(
      uid,
      () => <String, RemoteRecordRevision>{},
    );
    final nextVersion =
        versionNo ?? ((revisions[record.id]?.versionNo ?? 0) + 1);
    revisions[record.id] = RemoteRecordRevision(
      recordId: record.id,
      versionNo: nextVersion,
      status: RemoteRecordStatus.active,
      record: _withoutDevicePhotos(record),
    );
  }

  void seedDeleted(String uid, String recordId, {int? versionNo}) {
    final revisions = _revisionsByUser.putIfAbsent(
      uid,
      () => <String, RemoteRecordRevision>{},
    );
    final nextVersion =
        versionNo ?? ((revisions[recordId]?.versionNo ?? 0) + 1);
    revisions[recordId] = RemoteRecordRevision(
      recordId: recordId,
      versionNo: nextVersion,
      status: RemoteRecordStatus.deleted,
      record: null,
    );
  }

  FishingRecord? record(String uid, String recordId) {
    return _revisionsByUser[uid]?[recordId]?.record;
  }

  int? version(String uid, String recordId) {
    return _revisionsByUser[uid]?[recordId]?.versionNo;
  }

  RemoteRecordStatus? status(String uid, String recordId) {
    return _revisionsByUser[uid]?[recordId]?.status;
  }

  String _fingerprint(OutboxItem item, FishingRecord? record) {
    return jsonEncode(<String, Object?>{
      'recordId': item.recordId,
      'operationType': item.operationType.name,
      'baseVersionNo': item.baseVersionNo,
      'payload': record?.toJson(),
    });
  }

  FishingRecord _withoutDevicePhotos(FishingRecord record) {
    return FishingRecord(
      id: record.id,
      location: record.location,
      startAt: record.startAt,
      endAt: record.endAt,
      genreName: record.genreName,
      tide: record.tide,
      weather: record.weather,
      airTemperature: record.airTemperature,
      waterTemperature: record.waterTemperature,
      catches: record.catches,
      photos: const <RecordPhoto>[],
      memo: record.memo,
    );
  }
}

class _FakeReceipt {
  final String recordId;
  final OutboxOperationType operationType;
  final int baseVersionNo;
  final String fingerprint;
  final RecordPushResult result;

  const _FakeReceipt({
    required this.recordId,
    required this.operationType,
    required this.baseVersionNo,
    required this.fingerprint,
    required this.result,
  });
}
