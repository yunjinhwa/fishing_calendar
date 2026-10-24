import 'dart:async';

import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/remote/record_sync_gateway.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/conflict_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/repositories/outbox_repository.dart';
import 'package:fishing_build/data/services/record_sync_service.dart';
import 'package:fishing_build/presentation/calendar/calendar_page.dart';
import 'package:fishing_build/presentation/calendar/daily_record_list_page.dart';
import 'package:fishing_build/presentation/record/record_detail_page.dart';
import 'package:fishing_build/presentation/record/record_form_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_record_sync_gateway.dart';
import 'support/test_database.dart';

void main() {
  final auth = AuthSessionRepository.instance;
  final records = FishingRecordRepository.instance;
  final sync = RecordSyncService.instance;
  late _WatchingGateway gateway;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await sync.resetForTesting();
    await resetTestDatabase();
    auth.clearMemoryOnlyForTesting();
    records.clearCacheOnlyForTesting();
    OutboxRepository.instance.clearCacheOnlyForTesting();
    ConflictRepository.instance.clearCacheOnlyForTesting();
    await auth.setSessionForTesting(
      plan: UserPlan.paid,
      email: 'foreground@example.com',
    );
    gateway = _WatchingGateway();
    sync.configureGateway(gateway);
  });

  tearDown(() async {
    gateway.releaseSnapshot();
    await sync.resetForTesting();
    await gateway.close();
  });

  Future<void> seedOriginal(FishingRecord record) async {
    gateway.seedActive(auth.memberId!, record, versionNo: 1);
    expect((await sync.syncNow()).isSuccess, isTrue);
  }

  testWidgets(
    'foreground deletion reaches detail, daily list, and calendar without a manual refresh',
    (tester) async {
      final original = _record('foreground-delete');
      await seedOriginal(original);
      await _openDetailFromCalendar(tester, original);
      expect(gateway.activeWatchCount, 1);

      gateway.seedDeleted(auth.memberId!, original.id);
      await gateway.emitRemoteChange(auth.memberId!, original.id);
      await _pumpUntil(
        tester,
        () => find.text('이 기록은 삭제되었습니다.').evaluate().isNotEmpty,
      );

      expect(records.getRecordById(original.id), isNull);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(DailyRecordListPage), findsOneWidget);
      expect(find.text('저장된 출조 기록이 없습니다.'), findsOneWidget);
      expect(find.text(original.summaryTitle), findsNothing);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(CalendarPage), findsOneWidget);
      expect(find.text(original.summaryTitle), findsNothing);
      expect(gateway.activeWatchCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'foreground edits update detail while keeping the open form draft',
    (tester) async {
      _useTallSurface(tester);
      final original = _record('foreground-edit');
      await seedOriginal(original);
      await tester.pumpWidget(
        MaterialApp(home: RecordDetailPage(record: original)),
      );
      await tester.pumpAndSettle();

      gateway.seedActive(
        auth.memberId!,
        _record(original.id, location: 'Remote revision two'),
      );
      await gateway.emitRemoteChange(auth.memberId!, original.id);
      await _pumpUntil(
        tester,
        () => find.text('Remote revision two').evaluate().isNotEmpty,
      );
      await tester.tap(find.byTooltip('수정'));
      await tester.pumpAndSettle();
      expect(find.byType(RecordFormPage), findsOneWidget);
      expect(gateway.activeWatchCount, 1);
      expect(gateway.watchCallCount, 1);
      await tester.enterText(_locationField(), 'My foreground draft');

      gateway.seedActive(
        auth.memberId!,
        _record(original.id, location: 'Remote revision three'),
      );
      await gateway.emitRemoteChange(auth.memberId!, original.id);
      await _pumpUntil(
        tester,
        () => find.textContaining('편집 중 기록이 변경되었습니다.').evaluate().isNotEmpty,
      );

      expect(
        tester.widget<TextField>(_locationField()).controller!.text,
        'My foreground draft',
      );
      expect(
        records.getRecordById(original.id)!.location,
        'Remote revision three',
      );
      expect(OutboxRepository.instance.getAllItems(), isEmpty);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Remote revision three'), findsOneWidget);
      expect(gateway.activeWatchCount, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(gateway.activeWatchCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('returning from detail without saving refreshes the daily list', (
    tester,
  ) async {
    final original = _record('return-without-save');
    await seedOriginal(original);
    await _openDetailFromCalendar(tester, original);
    gateway.seedDeleted(auth.memberId!, original.id);

    // No watch event is emitted: returning from the route must request a pull.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await _pumpUntil(
      tester,
      () => find.text('저장된 출조 기록이 없습니다.').evaluate().isNotEmpty,
    );

    expect(find.byType(DailyRecordListPage), findsOneWidget);
    expect(records.getRecordById(original.id), isNull);
    expect(find.text(original.summaryTitle), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test(
    'leases share one subscription and cancel after the final release',
    () async {
      final original = _record('shared-lease');
      await seedOriginal(original);
      final firstRelease = sync.observeRecord(original.id);
      final secondRelease = sync.observeRecord(original.id);
      await _eventually(() => gateway.activeWatchCount == 1);
      expect(gateway.watchCallCount, 1);

      firstRelease();
      expect(gateway.activeWatchCount, 1);
      secondRelease();
      await _eventually(() => gateway.activeWatchCount == 0);
      expect(gateway.cancelCount, 1);
      firstRelease();
      secondRelease();
      expect(gateway.cancelCount, 1);

      final fetchCount = gateway.fetchCount;
      gateway.seedDeleted(auth.memberId!, original.id);
      await gateway.emitRemoteChange(auth.memberId!, original.id);
      await _flushMicrotasks();
      expect(gateway.fetchCount, fetchCount);
      expect(records.getRecordById(original.id), isNotNull);
    },
  );

  for (final changeAccount in <bool>[true, false]) {
    test(
      'a ${changeAccount ? 'change of account' : 'plan downgrade'} cancels the old watch',
      () async {
        final original = _record('session-watch');
        await seedOriginal(original);
        final originalUid = auth.memberId!;
        final release = sync.observeRecord(original.id);
        await _eventually(() => gateway.activeWatchCount == 1);

        await auth.setSessionForTesting(
          plan: changeAccount ? UserPlan.paid : UserPlan.free,
          email: changeAccount ? 'other@example.com' : auth.email,
        );
        await _eventually(() => gateway.activeWatchCount == 0);
        final fetchCount = gateway.fetchCount;
        gateway.seedDeleted(originalUid, original.id);
        await gateway.emitRemoteChange(originalUid, original.id);
        await _flushMicrotasks();

        expect(gateway.fetchCount, fetchCount);
        expect(gateway.cancelCount, 1);
        release();
        expect(gateway.cancelCount, 1);
      },
    );
  }

  test(
    'a revision arriving during a stale snapshot fetch forces a follow-up pull',
    () async {
      final original = _record('snapshot-event-race');
      await seedOriginal(original);
      final release = sync.observeRecord(original.id);
      addTearDown(release);
      await _eventually(() => gateway.activeWatchCount == 1);
      final fetchCount = gateway.fetchCount;
      gateway.holdNextSnapshot();
      final runningSync = sync.syncNow();
      await gateway.snapshotCaptured!.future;

      gateway.seedActive(
        auth.memberId!,
        _record(original.id, location: 'Changed during snapshot fetch'),
      );
      await gateway.emitRemoteChange(auth.memberId!, original.id);
      await _flushMicrotasks();
      gateway.releaseSnapshot();
      await runningSync;
      await _eventually(
        () =>
            records.getRecordById(original.id)?.location ==
            'Changed during snapshot fetch',
      );

      expect(gateway.fetchCount, greaterThanOrEqualTo(fetchCount + 2));
      expect(OutboxRepository.instance.getAllItems(), isEmpty);
    },
  );
}

class _WatchingGateway extends FakeRecordSyncGateway
    implements RecordRevisionWatchGateway {
  final _watches = <_RevisionWatch>[];
  int watchCallCount = 0;
  int activeWatchCount = 0;
  int cancelCount = 0;
  Completer<void>? snapshotCaptured;
  Completer<void>? _snapshotGate;
  bool _holdNext = false;

  @override
  Stream<RemoteRecordRevision?> watchRecordRevision({
    required String uid,
    required String recordId,
  }) {
    watchCallCount += 1;
    final controller = StreamController<RemoteRecordRevision?>.broadcast(
      sync: true,
      onListen: () => activeWatchCount += 1,
      onCancel: () {
        activeWatchCount -= 1;
        cancelCount += 1;
      },
    );
    _watches.add(_RevisionWatch(uid, recordId, controller));
    return controller.stream;
  }

  Future<void> emitRemoteChange(String uid, String recordId) async {
    final revision = await fetchRecordRevision(uid: uid, recordId: recordId);
    for (final watch in List<_RevisionWatch>.of(_watches)) {
      if (watch.uid == uid &&
          watch.recordId == recordId &&
          !watch.controller.isClosed) {
        watch.controller.add(revision);
      }
    }
  }

  void holdNextSnapshot() {
    _holdNext = true;
    snapshotCaptured = Completer<void>();
    _snapshotGate = Completer<void>();
  }

  void releaseSnapshot() {
    final gate = _snapshotGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  Future<RemoteRecordSnapshot> fetchSnapshot({required String uid}) async {
    // Capture before waiting so the response can be older than the watch event.
    final captured = await super.fetchSnapshot(uid: uid);
    if (_holdNext) {
      _holdNext = false;
      snapshotCaptured!.complete();
      await _snapshotGate!.future;
    }
    return captured;
  }

  Future<void> close() async {
    for (final watch in _watches) {
      await watch.controller.close();
    }
  }
}

class _RevisionWatch {
  final String uid;
  final String recordId;
  final StreamController<RemoteRecordRevision?> controller;

  _RevisionWatch(this.uid, this.recordId, this.controller);
}

Future<void> _openDetailFromCalendar(
  WidgetTester tester,
  FishingRecord original,
) async {
  _useTallSurface(tester);
  await tester.pumpWidget(const MaterialApp(home: CalendarPage()));
  await tester.pumpAndSettle();
  expect(find.text(original.summaryTitle), findsOneWidget);
  await tester.tap(find.text('오늘의 요약'));
  await tester.pumpAndSettle();
  expect(find.byType(DailyRecordListPage), findsOneWidget);
  await tester.tap(find.byType(ListTile));
  await tester.pumpAndSettle();
  expect(find.byType(RecordDetailPage), findsOneWidget);
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() complete) async {
  for (var attempt = 0; attempt < 60 && !complete(); attempt += 1) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(complete(), isTrue, reason: 'Expected refresh did not reach the UI.');
  await tester.pumpAndSettle();
}

Future<void> _eventually(bool Function() complete) async {
  for (var attempt = 0; attempt < 100 && !complete(); attempt += 1) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(
    complete(),
    isTrue,
    reason: 'Expected watch or refresh did not complete.',
  );
}

Future<void> _flushMicrotasks() async {
  for (var turn = 0; turn < 10; turn += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

Finder _locationField() => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == '위치 *',
);

void _useTallSurface(WidgetTester tester) {
  addTearDown(tester.view.reset);
  tester.view.physicalSize = const Size(1000, 3000);
  tester.view.devicePixelRatio = 1;
}

FishingRecord _record(
  String id, {
  String location = 'Original foreground harbor',
}) {
  final now = DateTime.now();
  return FishingRecord(
    id: id,
    location: location,
    startAt: DateTime(now.year, now.month, now.day, 8),
    endAt: DateTime(now.year, now.month, now.day, 10),
    genreName: '루어',
    tide: '3물',
    weather: '맑음',
    airTemperature: 24,
    waterTemperature: 20,
    catches: const <CatchRecord>[CatchRecord(speciesName: 'RefreshFish')],
  );
}
