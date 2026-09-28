import 'dart:async';

import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/outbox_item.dart';
import 'package:fishing_build/data/remote/record_sync_gateway.dart';

class FakeRecordSyncGateway implements RecordSyncGateway {
  final Map<String, Map<String, FishingRecord>> _activeByUser = {};
  final Map<String, Set<String>> _knownByUser = {};
  final Map<String, Set<String>> _receiptsByUser = {};

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

    return RemoteRecordSnapshot(
      activeRecords: List<FishingRecord>.unmodifiable(
        (_activeByUser[uid] ?? const <String, FishingRecord>{}).values,
      ),
      knownRecordIds: Set<String>.unmodifiable(
        _knownByUser[uid] ?? const <String>{},
      ),
    );
  }

  @override
  Future<void> pushOutboxItem({
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

    final receipts = _receiptsByUser.putIfAbsent(uid, () => <String>{});
    if (receipts.contains(item.id)) {
      return;
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

    final active = _activeByUser.putIfAbsent(
      uid,
      () => <String, FishingRecord>{},
    );
    final known = _knownByUser.putIfAbsent(uid, () => <String>{});
    known.add(item.recordId);

    if (item.operationType == OutboxOperationType.delete) {
      active.remove(item.recordId);
    } else {
      active[item.recordId] = record!;
    }
    receipts.add(item.id);
  }

  void seedActive(String uid, FishingRecord record) {
    _knownByUser.putIfAbsent(uid, () => <String>{}).add(record.id);
    _activeByUser.putIfAbsent(uid, () => <String, FishingRecord>{})[record.id] =
        _withoutDevicePhotos(record);
  }

  void seedDeleted(String uid, String recordId) {
    _knownByUser.putIfAbsent(uid, () => <String>{}).add(recordId);
    _activeByUser
        .putIfAbsent(uid, () => <String, FishingRecord>{})
        .remove(recordId);
  }

  FishingRecord? record(String uid, String recordId) {
    return _activeByUser[uid]?[recordId];
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
      photoPaths: const <String>[],
      memo: record.memo,
    );
  }
}
