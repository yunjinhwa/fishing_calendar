import 'dart:async';

import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/outbox_item.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/repositories/outbox_repository.dart';
import 'package:fishing_build/data/remote/record_sync_gateway.dart';
import 'package:fishing_build/data/services/record_mutation_service.dart';
import 'package:fishing_build/data/services/record_sync_service.dart';
import 'package:fishing_build/presentation/sync/outbox_page.dart';
import 'package:fishing_build/presentation/sync/sync_conflict_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_record_sync_gateway.dart';
import 'support/test_database.dart';

void main() {
  final authSession = AuthSessionRepository.instance;
  final recordRepository = FishingRecordRepository.instance;
  final outboxRepository = OutboxRepository.instance;
  final syncService = RecordSyncService.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await syncService.resetForTesting();
    await resetTestDatabase();
    authSession.clearMemoryOnlyForTesting();
    recordRepository.clearCacheOnlyForTesting();
    outboxRepository.clearCacheOnlyForTesting();
  });

  test('pushes create, update, and delete in durable outbox order', () async {
    await _signInAsPaid(authSession, 'ordered@example.com');
    final record = _record('ordered-record', location: '처음 위치');
    await RecordMutationService.instance.addRecord(record);
    await RecordMutationService.instance.updateRecord(
      _record(record.id, location: '수정 위치'),
    );
    await RecordMutationService.instance.deleteRecord(record.id);
    await syncService.syncNow();

    final queuedIds = outboxRepository
        .getAllItems()
        .map((item) => item.id)
        .toList();
    final gateway = FakeRecordSyncGateway();
    syncService.configureGateway(gateway);

    final result = await syncService.syncNow();

    expect(result.isSuccess, isTrue);
    expect(result.pushedCount, 3);
    expect(gateway.pushedOutboxIds, queuedIds);
    expect(gateway.record(authSession.memberId!, record.id), isNull);
    expect(
      outboxRepository.getAllItems().every(
        (item) => item.status == OutboxStatus.succeeded,
      ),
      isTrue,
    );
    expect(recordRepository.getAllRecords(), isEmpty);
  });

  test('stops at the first failed mutation and retries it later', () async {
    await _signInAsPaid(authSession, 'retry@example.com');
    await RecordMutationService.instance.addRecord(_record('retry-first'));
    await RecordMutationService.instance.addRecord(_record('retry-second'));
    await syncService.syncNow();

    final initialItems = outboxRepository.getAllItems();
    final gateway = FakeRecordSyncGateway()
      ..failingOutboxIds.add(initialItems.first.id);
    syncService.configureGateway(gateway);

    final failedResult = await syncService.syncNow();

    expect(failedResult.isSuccess, isFalse);
    expect(outboxRepository.getAllItems().first.status, OutboxStatus.failed);
    expect(outboxRepository.getAllItems()[1].status, OutboxStatus.pending);
    expect(gateway.pushedOutboxIds, <String>[initialItems.first.id]);

    gateway.failingOutboxIds.clear();
    final retryResult = await syncService.syncNow();

    expect(retryResult.isSuccess, isTrue);
    expect(outboxRepository.getAllItems().first.retryCount, 1);
    expect(
      outboxRepository.getAllItems().every(
        (item) => item.status == OutboxStatus.succeeded,
      ),
      isTrue,
    );
  });

  test('fake gateway does not acknowledge an invalid mutation', () async {
    const uid = 'fake-transaction-user';
    final gateway = FakeRecordSyncGateway();
    final createdAt = DateTime(2026, 9, 28);
    final invalid = OutboxItem(
      id: 'same-outbox-id',
      userId: uid,
      recordId: 'fake-transaction-record',
      operationType: OutboxOperationType.create,
      status: OutboxStatus.pending,
      createdAt: createdAt,
    );

    await expectLater(
      gateway.pushOutboxItem(uid: uid, item: invalid),
      throwsA(isA<RecordSyncGatewayException>()),
    );

    final mismatched = OutboxItem(
      id: invalid.id,
      userId: uid,
      recordId: invalid.recordId,
      operationType: invalid.operationType,
      status: OutboxStatus.pending,
      createdAt: createdAt,
      payload: _record('different-record-id').toJson(),
    );
    await expectLater(
      gateway.pushOutboxItem(uid: uid, item: mismatched),
      throwsA(
        isA<RecordSyncGatewayException>().having(
          (error) => error.code,
          'code',
          'record-id-mismatch',
        ),
      ),
    );

    final record = _record(invalid.recordId);
    final valid = OutboxItem(
      id: invalid.id,
      userId: uid,
      recordId: invalid.recordId,
      operationType: invalid.operationType,
      status: OutboxStatus.pending,
      createdAt: createdAt,
      payload: record.toJson(),
    );
    await gateway.pushOutboxItem(uid: uid, item: valid);

    expect(gateway.record(uid, record.id)?.location, record.location);
  });

  test('uploads a mutation added while a sync is already running', () async {
    await _signInAsPaid(authSession, 'concurrent@example.com');
    final original = _record('concurrent-record', location: '처음 위치');
    await RecordMutationService.instance.addRecord(original);
    await syncService.syncNow();

    final pushStarted = Completer<void>();
    final releasePush = Completer<void>();
    final gateway = FakeRecordSyncGateway()
      ..pushStarted = pushStarted
      ..pushGate = releasePush.future;
    syncService.configureGateway(gateway);

    final runningSync = syncService.syncNow();
    await pushStarted.future;
    await RecordMutationService.instance.updateRecord(
      _record(original.id, location: '동기화 중 수정 위치'),
    );
    releasePush.complete();
    await runningSync;

    expect(
      gateway.record(authSession.memberId!, original.id)?.location,
      '동기화 중 수정 위치',
    );
    expect(
      outboxRepository.getAllItems().every(
        (item) => item.status == OutboxStatus.succeeded,
      ),
      isTrue,
    );
    expect(
      recordRepository.getRecordById(original.id)?.location,
      '동기화 중 수정 위치',
    );
  });

  test(
    'does not overwrite a mutation committed during snapshot pull',
    () async {
      await _signInAsPaid(authSession, 'snapshot-race@example.com');
      final original = _record('snapshot-race-record', location: '서버 이전 값');
      await RecordMutationService.instance.addRecord(original);
      await syncService.syncNow();

      final gateway = FakeRecordSyncGateway();
      syncService.configureGateway(gateway);
      expect((await syncService.syncNow()).isSuccess, isTrue);

      final fetchStarted = Completer<void>();
      final releaseFetch = Completer<void>();
      gateway
        ..fetchStarted = fetchStarted
        ..fetchGate = releaseFetch.future;

      final runningSync = syncService.syncNow();
      await fetchStarted.future;
      await RecordMutationService.instance.updateRecord(
        _record(original.id, location: 'pull 도중 수정 위치'),
      );
      releaseFetch.complete();
      await runningSync;

      expect(
        gateway.record(authSession.memberId!, original.id)?.location,
        'pull 도중 수정 위치',
      );
      expect(
        recordRepository.getRecordById(original.id)?.location,
        'pull 도중 수정 위치',
      );
      expect(outboxRepository.hasUnfinishedItems, isFalse);
    },
  );

  test(
    'remote replacement is refused while an outbox item is pending',
    () async {
      await _signInAsPaid(authSession, 'atomic-pull@example.com');
      final local = _record('atomic-local', location: '보존할 로컬 값');
      await recordRepository.addRecord(local);
      await outboxRepository.addItem(
        OutboxItem(
          id: 'atomic-pending',
          userId: authSession.memberId,
          recordId: local.id,
          operationType: OutboxOperationType.update,
          status: OutboxStatus.pending,
          createdAt: DateTime(2026, 9, 28),
          payload: local.toJson(),
        ),
      );

      final replaced = await recordRepository.replaceWithRemoteSnapshot(
        <FishingRecord>[_record('remote-only')],
      );

      expect(replaced, isFalse);
      expect(recordRepository.getAllRecords().single.location, local.location);
    },
  );

  test(
    'first real sync replays mock successes and keeps local photo paths',
    () async {
      await _signInAsPaid(authSession, 'upgrade@example.com');
      final record = _record(
        'mock-success-record',
        photoPaths: const <String>['C:/device/photo.jpg'],
      );
      await RecordMutationService.instance.addRecord(record);
      await syncService.syncNow();
      final item = outboxRepository.getAllItems().single;
      await outboxRepository.updateItemStatus(
        itemId: item.id,
        status: OutboxStatus.succeeded,
      );

      final gateway = FakeRecordSyncGateway();
      syncService.configureGateway(gateway);
      final result = await syncService.syncNow();

      expect(result.isSuccess, isTrue);
      expect(gateway.pushedOutboxIds, <String>[item.id]);
      expect(
        gateway.record(authSession.memberId!, record.id)?.photoPaths,
        isEmpty,
      );
      expect(
        recordRepository.getRecordById(record.id)?.photoPaths,
        record.photoPaths,
      );

      final pushCount = gateway.pushedOutboxIds.length;
      final secondResult = await syncService.syncNow();
      expect(secondResult.isSuccess, isTrue);
      expect(gateway.pushedOutboxIds, hasLength(pushCount));
    },
  );

  test('first sync bootstraps a paid local record with no outbox', () async {
    await _signInAsPaid(authSession, 'bootstrap@example.com');
    final record = _record('bootstrap-record');
    await recordRepository.addRecord(record);

    final gateway = FakeRecordSyncGateway();
    syncService.configureGateway(gateway);
    final result = await syncService.syncNow();

    expect(result.isSuccess, isTrue);
    expect(result.pushedCount, 1);
    expect(gateway.record(authSession.memberId!, record.id), isNotNull);
    expect(outboxRepository.getAllItems().single.isMigration, isTrue);
    expect(
      outboxRepository.getAllItems().single.status,
      OutboxStatus.succeeded,
    );
  });

  test('maximum record ID still produces a valid outbox ID', () async {
    await _signInAsPaid(authSession, 'long-id@example.com');
    final record = _record('r' * 200);

    await RecordMutationService.instance.addRecord(record);

    final item = outboxRepository.getAllItems().single;
    expect(item.recordId, record.id);
    expect(item.id.length, lessThanOrEqualTo(300));
    await syncService.syncNow();

    final gateway = FakeRecordSyncGateway();
    syncService.configureGateway(gateway);
    final result = await syncService.syncNow();
    expect(result.isSuccess, isTrue, reason: result.errorMessage);
  });

  test('invalid cloud-bound record is rejected before local commit', () async {
    await _signInAsPaid(authSession, 'invalid-record@example.com');
    final invalid = FishingRecord(
      id: 'invalid-record',
      location: '테스트 방파제',
      startAt: DateTime(2026, 9, 28, 8),
      endAt: DateTime(2026, 9, 28, 10),
      genreName: '바다낚시',
      airTemperature: double.nan,
    );

    await expectLater(
      RecordMutationService.instance.addRecord(invalid),
      throwsArgumentError,
    );
    expect(recordRepository.getAllRecords(), isEmpty);
    expect(outboxRepository.getAllItems(), isEmpty);
  });

  test('sync status and local queues never leak across accounts', () async {
    await _signInAsPaid(authSession, 'account-a@example.com');
    final accountAOwner = authSession.dataOwnerKey;
    final record = _record('account-a-record');
    await recordRepository.addRecord(record);

    final pushStarted = Completer<void>();
    final releasePush = Completer<void>();
    final gateway = FakeRecordSyncGateway()
      ..pushStarted = pushStarted
      ..pushGate = releasePush.future;
    syncService.configureGateway(gateway);

    final runningSync = syncService.syncNow();
    await pushStarted.future;
    await _signInAsPaid(authSession, 'account-b@example.com');
    final accountBOwner = authSession.dataOwnerKey;
    await recordRepository.reloadOwner(accountBOwner);
    await outboxRepository.reloadOwner(accountBOwner);
    releasePush.complete();

    final result = await runningSync;
    expect(result.skipReason, RecordSyncSkipReason.sessionChanged);
    expect(outboxRepository.getAllItemsForOwner(accountBOwner), isEmpty);
    expect(recordRepository.getAllRecordsForOwner(accountBOwner), isEmpty);
    expect(outboxRepository.getAllItemsForOwner(accountAOwner), hasLength(1));
    expect(syncService.state, RecordSyncState.idle);
    expect(syncService.lastSyncedAt, isNull);
    expect(syncService.lastError, isNull);
  });

  test('failed server pull leaves the local snapshot untouched', () async {
    await _signInAsPaid(authSession, 'pull-failure@example.com');
    final uid = authSession.memberId!;
    final local = _record('pull-failure-record', location: '보존할 로컬 값');
    final gateway = FakeRecordSyncGateway()..seedActive(uid, local);
    syncService.configureGateway(gateway);
    expect((await syncService.syncNow()).isSuccess, isTrue);

    gateway
      ..seedActive(uid, _record(local.id, location: '받으면 안 되는 값'))
      ..failFetch = true;
    final result = await syncService.syncNow();

    expect(result.isSuccess, isFalse);
    expect(recordRepository.getRecordById(local.id)?.location, '보존할 로컬 값');
  });

  test(
    'later pulls replace local records and apply remote tombstones',
    () async {
      await _signInAsPaid(authSession, 'pull@example.com');
      final uid = authSession.memberId!;
      final first = _record('remote-first');
      final second = _record('remote-second');
      final gateway = FakeRecordSyncGateway()..seedActive(uid, first);
      syncService.configureGateway(gateway);

      expect((await syncService.syncNow()).isSuccess, isTrue);
      expect(recordRepository.getAllRecords().single.id, first.id);

      gateway
        ..seedDeleted(uid, first.id)
        ..seedActive(uid, second);
      expect((await syncService.syncNow()).isSuccess, isTrue);

      expect(recordRepository.getAllRecords().map((record) => record.id), [
        second.id,
      ]);
    },
  );

  test('free members never invoke the remote gateway', () async {
    await authSession.setSessionForTesting(
      plan: UserPlan.free,
      email: 'free-sync@example.com',
    );
    final gateway = FakeRecordSyncGateway();
    syncService.configureGateway(gateway);

    final result = await syncService.syncNow();

    expect(result.skipReason, RecordSyncSkipReason.paidPlanRequired);
    expect(gateway.fetchCount, 0);
    expect(gateway.pushedOutboxIds, isEmpty);
  });

  test('restart reconciliation ignores already-succeeded payloads', () async {
    await _signInAsPaid(authSession, 'reconcile-sync@example.com');
    final local = _record('reconciled', location: '서버에서 받은 값');
    final stale = _record('reconciled', location: '예전 Outbox 값');
    await recordRepository.addRecord(local);
    await outboxRepository.addItem(
      OutboxItem(
        id: 'already-uploaded',
        userId: authSession.memberId,
        recordId: stale.id,
        operationType: OutboxOperationType.update,
        status: OutboxStatus.succeeded,
        createdAt: DateTime(2026, 9, 22),
        payload: stale.toJson(),
      ),
    );

    await RecordMutationService.instance.reconcileOutboxWithLocalRecords();

    expect(recordRepository.getRecordById(local.id)?.location, local.location);
  });

  testWidgets('sync screen does not claim freshness before first success', (
    tester,
  ) async {
    await _signInAsPaid(authSession, 'sync-status@example.com');

    await tester.pumpWidget(const MaterialApp(home: SyncConflictPage()));
    await tester.pump();

    expect(find.text('아직 서버 동기화 전입니다.'), findsOneWidget);
    expect(find.text('모든 데이터가 최신 상태입니다.'), findsNothing);
  });

  testWidgets('completed outbox items cannot be cleared during first sync', (
    tester,
  ) async {
    await _signInAsPaid(authSession, 'clear-race@example.com');
    await RecordMutationService.instance.addRecord(_record('clear-race'));
    await syncService.syncNow();
    final item = outboxRepository.getAllItems().single;
    await outboxRepository.updateItemStatus(
      itemId: item.id,
      status: OutboxStatus.succeeded,
    );

    final fetchStarted = Completer<void>();
    final releaseFetch = Completer<void>();
    final gateway = FakeRecordSyncGateway()
      ..fetchStarted = fetchStarted
      ..fetchGate = releaseFetch.future;
    syncService.configureGateway(gateway);
    final runningSync = syncService.syncNow();
    await fetchStarted.future;

    await tester.pumpWidget(const MaterialApp(home: OutboxPage()));
    await tester.pump();
    final clearButton = tester
        .widgetList<IconButton>(find.byType(IconButton))
        .singleWhere((button) => button.tooltip == '완료 항목 정리');
    expect(clearButton.onPressed, isNull);

    releaseFetch.complete();
    await runningSync;
    await tester.pump();
  });
}

Future<void> _signInAsPaid(AuthSessionRepository authSession, String email) {
  return authSession.setSessionForTesting(plan: UserPlan.paid, email: email);
}

FishingRecord _record(
  String id, {
  String location = '테스트 방파제',
  List<String> photoPaths = const <String>[],
}) {
  return FishingRecord(
    id: id,
    location: location,
    startAt: DateTime(2026, 9, 22, 8),
    endAt: DateTime(2026, 9, 22, 10),
    genreName: '바다낚시',
    tide: '3물',
    weather: '맑음',
    airTemperature: 24,
    waterTemperature: 20,
    catches: const <CatchRecord>[
      CatchRecord(speciesName: '우럭', lengthCm: 31, weightG: 820),
    ],
    photoPaths: photoPaths,
    memo: '동기화 테스트',
  );
}
