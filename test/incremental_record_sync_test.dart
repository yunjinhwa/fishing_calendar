import 'dart:async';

import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/outbox_item.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/remote/record_sync_gateway.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/conflict_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/repositories/outbox_repository.dart';
import 'package:fishing_build/data/services/record_mutation_service.dart';
import 'package:fishing_build/data/services/record_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/incremental_fake_record_sync_gateway.dart';
import 'support/test_database.dart';

void main() {
  final auth = AuthSessionRepository.instance;
  final records = FishingRecordRepository.instance;
  final outbox = OutboxRepository.instance;
  late IncrementalFakeRecordSyncGateway gateway;
  late RecordSyncService sync;
  late DateTime now;
  Completer<void>? releasePush;

  RecordSyncService createService() =>
      RecordSyncService(now: () => now)..configureGateway(gateway);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await RecordSyncService.instance.resetForTesting();
    await resetTestDatabase();
    auth.clearMemoryOnlyForTesting();
    records.clearCacheOnlyForTesting();
    outbox.clearCacheOnlyForTesting();
    ConflictRepository.instance.clearCacheOnlyForTesting();
    await auth.setSessionForTesting(
      plan: UserPlan.paid,
      email: 'incremental@example.com',
    );
    now = DateTime.utc(2026, 10, 26, 12);
    releasePush = null;
    gateway = IncrementalFakeRecordSyncGateway();
    sync = createService();
  });

  tearDown(() async {
    gateway.releaseChangePage();
    final release = releasePush;
    if (release != null && !release.isCompleted) release.complete();
    await sync.resetForTesting();
    sync.dispose();
    await RecordSyncService.instance.resetForTesting();
  });

  Future<RecordSyncCheckpoint> checkpoint() async =>
      (await records.readSyncCheckpoint(auth.dataOwnerKey))!;

  Future<void> seedRepairableSnapshot() async {
    final uid = auth.memberId!;
    gateway.seedActive(
      uid,
      _record('backdated', location: 'Original'),
      cursor: _cursor('backdated', 10),
    );
    gateway.seedActive(
      uid,
      _record('physically-deleted'),
      cursor: _cursor('physically-deleted', 20),
    );
    gateway.seedActive(uid, _record('head'), cursor: _cursor('head', 30));
    expect((await sync.syncNow()).isSuccess, isTrue);
    gateway.seedActive(
      uid,
      _record('backdated', location: 'Backdated update'),
      cursor: _cursor('backdated', 9),
    );
    gateway.physicallyDelete(uid, 'physically-deleted');
  }

  test(
    'an unchanged 1000-record cache reads only its last timestamp bucket',
    () async {
      for (var index = 0; index < 1000; index++) {
        gateway.seedActive(auth.memberId!, _record('record-$index'));
      }
      expect((await sync.syncNow()).isSuccess, isTrue);
      expect(records.getAllRecords(), hasLength(1000));
      final fullFetchCount = gateway.fetchCount;
      final savedCheckpoint = (await checkpoint()).encode();
      var notifications = 0;
      void onRecordsChanged() => notifications++;
      records.addListener(onRecordsChanged);
      addTearDown(() => records.removeListener(onRecordsChanged));

      final result = await sync.syncNow();

      expect(result.isSuccess, isTrue);
      expect(result.pulledCount, 0);
      expect(gateway.fetchCount, fullFetchCount);
      expect(gateway.latestCursorFetchCount, 1);
      expect(gateway.changeRequests, hasLength(1));
      expect(gateway.changeDocumentReadCount, 1);
      expect(notifications, 0);
      expect((await checkpoint()).encode(), savedCheckpoint);
    },
  );

  test(
    'a full request made during cache notification is not consumed by the old pull',
    () async {
      final uid = auth.memberId!;
      gateway.seedActive(uid, _record('full-request-race'));
      expect((await sync.syncNow()).isSuccess, isTrue);
      final before = gateway.fetchCount;
      var requested = false;
      void requestAnotherFullPull() {
        if (requested) return;
        requested = true;
        unawaited(sync.syncNow(forceFullRefresh: true));
      }

      records.addListener(requestAnotherFullPull);
      addTearDown(() => records.removeListener(requestAnotherFullPull));
      gateway.seedActive(
        uid,
        _record('full-request-race', location: 'New full content'),
      );

      expect((await sync.syncNow(forceFullRefresh: true)).isSuccess, isTrue);

      expect(requested, isTrue);
      expect(gateway.fetchCount, before + 2);
      expect(
        records.getRecordById('full-request-race')!.location,
        'New full content',
      );
    },
  );

  test(
    'delta updates preserve local photos and tombstones remove records',
    () async {
      final uid = auth.memberId!;
      gateway.seedActive(uid, _record('updated'));
      gateway.seedActive(uid, _record('deleted'));
      expect((await sync.syncNow()).isSuccess, isTrue);
      await records.updateRecord(
        _record('updated', photoPaths: ['C:/device/retained.jpg']),
      );
      gateway.seedActive(uid, _record('updated', location: 'Remote update'));
      gateway.seedDeleted(uid, 'deleted');
      final fullFetchCount = gateway.fetchCount;

      final result = await sync.syncNow();

      expect(result.isSuccess, isTrue);
      expect(result.pulledCount, 2);
      expect(records.getRecordById('updated')!.location, 'Remote update');
      expect(records.getRecordById('updated')!.photoPaths, [
        'C:/device/retained.jpg',
      ]);
      expect(records.getRecordById('deleted'), isNull);
      expect(gateway.fetchCount, fullFetchCount);
      records.clearCacheOnlyForTesting();
      await records.reloadOwner(auth.dataOwnerKey);
      expect(records.getRecordById('updated')!.photoPaths, [
        'C:/device/retained.jpg',
      ]);
      expect(records.getRecordById('deleted'), isNull);
    },
  );

  test(
    'equal timestamps span pages and replay late lower-ID changes',
    () async {
      final uid = auth.memberId!;
      gateway.seedActive(uid, _record('z-head'), cursor: _cursor('z-head', 20));
      expect((await sync.syncNow()).isSuccess, isTrue);
      final savedCursor = (await checkpoint()).cursor.toJson();
      for (var index = 0; index < 225; index++) {
        final id = 'bucket-${index.toString().padLeft(3, '0')}';
        gateway.seedActive(uid, _record(id), cursor: _cursor(id, 20));
      }

      expect((await sync.syncNow()).isSuccess, isTrue);

      expect(records.getAllRecords(), hasLength(226));
      expect(gateway.changeRequests, hasLength(3));
      expect(gateway.changeRequests.first.after, isNull);
      expect(gateway.changeRequests[1].after!.recordId, 'bucket-099');
      expect(gateway.changeRequests[2].after!.recordId, 'bucket-199');
      expect((await checkpoint()).cursor.toJson(), savedCursor);
      gateway.seedActive(uid, _record('a-late'), cursor: _cursor('a-late', 20));

      expect((await sync.syncNow()).isSuccess, isTrue);

      expect(records.getRecordById('a-late'), isNotNull);
      expect(records.getAllRecords(), hasLength(227));
      expect(gateway.changeRequests[3].after, isNull);
      expect((await checkpoint()).cursor.toJson(), savedCursor);
    },
  );

  test(
    'a failed later page resumes from its committed SQLite checkpoint',
    () async {
      final uid = auth.memberId!;
      gateway.seedActive(uid, _record('baseline'));
      expect((await sync.syncNow()).isSuccess, isTrue);
      final fullFetchCount = gateway.fetchCount;
      for (var index = 0; index < 250; index++) {
        gateway.seedActive(uid, _record('new-$index'));
      }
      gateway.failingChangeCalls.add(2);

      expect((await sync.syncNow()).isSuccess, isFalse);

      expect(records.getAllRecords(), hasLength(100));
      final committed = await checkpoint();
      expect(committed.cursor.recordId, 'new-98');
      await sync.resetForTesting();
      sync.dispose();
      records.clearCacheOnlyForTesting();
      outbox.clearCacheOnlyForTesting();
      sync = createService();
      gateway.failingChangeCalls.clear();

      expect((await sync.syncNow()).isSuccess, isTrue);

      expect(records.getAllRecords(), hasLength(251));
      expect(gateway.fetchCount, fullFetchCount);
      expect(
        gateway.changeRequests[2].since.toJson(),
        committed.cursor.toJson(),
      );
      expect(gateway.changeRequests[2].after, isNull);
      expect((await checkpoint()).cursor.recordId, 'new-249');
    },
  );

  test(
    'an empty account keeps its origin checkpoint without repeated full reads',
    () async {
      expect((await sync.syncNow()).isSuccess, isTrue);
      final fullFetchCount = gateway.fetchCount;
      expect(
        (await checkpoint()).cursor.toJson(),
        RecordSyncCursor.origin.toJson(),
      );

      expect((await sync.syncNow()).isSuccess, isTrue);
      expect((await sync.syncNow()).isSuccess, isTrue);

      expect(gateway.fetchCount, fullFetchCount);
      expect(gateway.changeRequests, hasLength(2));
      expect(gateway.changeDocumentReadCount, 0);
      expect(records.getAllRecords(), isEmpty);
    },
  );

  test(
    'local intent arriving during a page prevents both apply and cursor advance',
    () async {
      final uid = auth.memberId!;
      gateway.seedActive(uid, _record('original', location: 'Before'));
      expect((await sync.syncNow()).isSuccess, isTrue);
      final before = (await checkpoint()).encode();
      gateway.seedActive(uid, _record('original', location: 'Remote update'));
      gateway.holdNextChangePage();
      final running = sync.syncNow();
      await gateway.changePageCaptured!.future;
      await RecordMutationService.instance.addRecord(_record('local-create'));
      releasePush = Completer<void>();
      final pushStarted = Completer<void>();
      gateway.pushStarted = pushStarted;
      gateway.pushGate = releasePush!.future;
      gateway.releaseChangePage();
      await pushStarted.future;

      expect(records.getRecordById('original')!.location, 'Before');
      expect(records.getRecordById('local-create'), isNotNull);
      expect((await checkpoint()).encode(), before);
      releasePush!.complete();

      final result = await running;

      expect(result.isSuccess, isTrue);
      expect(result.pushedCount, 1);
      expect(records.getRecordById('original')!.location, 'Remote update');
      expect(gateway.record(uid, 'local-create'), isNotNull);
      expect(outbox.getAllItems().single.status, OutboxStatus.succeeded);
      expect(
        (await checkpoint()).cursor.compareTo(
          RecordSyncCheckpoint.decode(before).cursor,
        ),
        greaterThan(0),
      );
    },
  );

  test(
    'switching A to B to A invalidates an in-flight page for the old session',
    () async {
      final uid = auth.memberId!;
      gateway.seedActive(uid, _record('session-record', location: 'Before'));
      expect((await sync.syncNow()).isSuccess, isTrue);
      final before = (await checkpoint()).encode();
      gateway.seedActive(uid, _record('session-record', location: 'After'));
      gateway.holdNextChangePage();
      final running = sync.syncNow();
      await gateway.changePageCaptured!.future;
      await auth.setSessionForTesting(
        plan: UserPlan.paid,
        email: 'b@example.com',
      );
      await auth.setSessionForTesting(
        plan: UserPlan.paid,
        email: 'incremental@example.com',
      );
      expect(auth.memberId, uid);
      gateway.releaseChangePage();

      expect((await running).skipReason, RecordSyncSkipReason.sessionChanged);
      expect(records.getRecordById('session-record')!.location, 'Before');
      expect((await checkpoint()).encode(), before);
      expect((await sync.syncNow()).isSuccess, isTrue);
      expect(records.getRecordById('session-record')!.location, 'After');
    },
  );

  test(
    'the 24-hour full repair discovers backdated changes and physical deletion',
    () async {
      await seedRepairableSnapshot();
      final fullFetchCount = gateway.fetchCount;
      expect((await sync.syncNow()).isSuccess, isTrue);
      expect(gateway.fetchCount, fullFetchCount);
      expect(records.getRecordById('backdated')!.location, 'Original');
      expect(records.getRecordById('physically-deleted'), isNotNull);
      now = now.add(const Duration(hours: 24));

      expect((await sync.syncNow()).isSuccess, isTrue);

      expect(gateway.fetchCount, fullFetchCount + 1);
      expect(records.getRecordById('backdated')!.location, 'Backdated update');
      expect(records.getRecordById('physically-deleted'), isNull);
      expect((await checkpoint()).lastFullSyncAt, now);
    },
  );

  test(
    'explicit full refresh repairs out-of-band changes before 24 hours',
    () async {
      await seedRepairableSnapshot();
      final fullFetchCount = gateway.fetchCount;
      now = now.add(const Duration(minutes: 1));

      expect((await sync.syncNow(forceFullRefresh: true)).isSuccess, isTrue);

      expect(gateway.fetchCount, fullFetchCount + 1);
      expect(gateway.changeRequests, isEmpty);
      expect(records.getRecordById('backdated')!.location, 'Backdated update');
      expect(records.getRecordById('physically-deleted'), isNull);
      expect((await checkpoint()).lastFullSyncAt, now);
    },
  );

  test(
    'a backwards device clock triggers an authoritative full repair',
    () async {
      await seedRepairableSnapshot();
      final fullFetchCount = gateway.fetchCount;
      now = now.subtract(const Duration(hours: 1));

      expect((await sync.syncNow()).isSuccess, isTrue);

      expect(gateway.fetchCount, fullFetchCount + 1);
      expect(records.getRecordById('backdated')!.location, 'Backdated update');
      expect(records.getRecordById('physically-deleted'), isNull);
      expect((await checkpoint()).lastFullSyncAt, now);
    },
  );

  test(
    'an empty hasMore page fails without advancing durable progress',
    () async {
      gateway.seedActive(auth.memberId!, _record('unchanged'));
      expect((await sync.syncNow()).isSuccess, isTrue);
      final before = (await checkpoint()).encode();
      gateway.nextChangePageOverride = const RemoteRecordChangePage(
        revisions: [],
        hasMore: true,
      );

      final result = await sync.syncNow();

      expect(result.isSuccess, isFalse);
      expect(result.failedCount, 1);
      expect(gateway.changeRequests, hasLength(1));
      expect((await checkpoint()).encode(), before);
      expect(records.getRecordById('unchanged'), isNotNull);
    },
  );

  test(
    'one pull keeps its fixed server head while new changes arrive',
    () async {
      sync.configureGateway(null);
      gateway = IncrementalFakeRecordSyncGateway(pageSize: 1);
      sync.configureGateway(gateway);
      final uid = auth.memberId!;
      gateway.seedActive(uid, _record('baseline'));
      expect((await sync.syncNow()).isSuccess, isTrue);
      gateway.seedActive(uid, _record('first-change'));
      gateway.seedActive(uid, _record('captured-head'));
      gateway.holdNextChangePage();
      final running = sync.syncNow();
      await gateway.changePageCaptured!.future;
      gateway.seedActive(uid, _record('later-change'));
      gateway.releaseChangePage();

      expect((await running).isSuccess, isTrue);

      expect(records.getRecordById('first-change'), isNotNull);
      expect(records.getRecordById('captured-head'), isNotNull);
      expect(records.getRecordById('later-change'), isNull);
      expect(gateway.changeRequests, hasLength(3));
      expect(
        gateway.changeRequests.map((request) => request.through.recordId),
        everyElement('captured-head'),
      );
      expect((await checkpoint()).cursor.recordId, 'captured-head');
      expect((await sync.syncNow()).isSuccess, isTrue);
      expect(records.getRecordById('later-change'), isNotNull);
    },
  );
}

RecordSyncCursor _cursor(String id, int seconds) =>
    RecordSyncCursor(seconds: seconds, nanoseconds: 123456789, recordId: id);

FishingRecord _record(
  String id, {
  String location = 'Test harbor',
  List<String> photoPaths = const [],
}) => FishingRecord(
  id: id,
  location: location,
  startAt: DateTime(2026, 10, 22, 8),
  endAt: DateTime(2026, 10, 22, 10),
  genreName: 'Sea fishing',
  catches: const [CatchRecord(speciesName: 'Test fish', lengthCm: 30)],
  photoPaths: photoPaths,
);
