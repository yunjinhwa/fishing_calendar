import 'package:fishing_build/data/local/local_data_store.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/conflict_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/repositories/outbox_repository.dart';
import 'package:fishing_build/data/services/record_sync_service.dart';
import 'package:fishing_build/presentation/record/record_detail_page.dart';
import 'package:fishing_build/presentation/record/record_form_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_database.dart';

void main() {
  final auth = AuthSessionRepository.instance;
  final records = FishingRecordRepository.instance;
  final sync = RecordSyncService.instance;
  final store = LocalDataStore.instance;

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
      email: 'editor-widget@example.com',
    );
  });

  tearDown(() async {
    await sync.resetForTesting();
  });

  testWidgets(
    'changed records retain the draft and reject save without an outbox item',
    (tester) async {
      final original = _record('changed-record');
      await records.addRecord(original);
      await _openForm(tester, original);
      await tester.enterText(_field('위치 *'), 'My unsaved draft');

      final latest = _record(original.id, location: 'Other device harbor');
      await records.updateRecord(latest);
      await tester.pumpAndSettle();
      expect(find.textContaining('편집 중 기록이 변경되었습니다.'), findsOneWidget);
      expect(_fieldValue(tester, '위치 *'), 'My unsaved draft');
      final beforeOutbox = await store.readOutboxItemsForOwner(
        auth.dataOwnerKey,
      );

      await _save(tester);

      expect(find.byType(RecordFormPage), findsOneWidget);
      expect(_fieldValue(tester, '위치 *'), 'My unsaved draft');
      expect(records.getRecordById(original.id)!.toJson(), latest.toJson());
      expect(
        (await store.readOutboxItemsForOwner(
          auth.dataOwnerKey,
        )).map((item) => item.toJson()).toList(),
        beforeOutbox.map((item) => item.toJson()).toList(),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'explicit reload preserves a cancelled draft then loads and saves the latest fields',
    (tester) async {
      final original = _record('reload-record');
      await records.addRecord(original);
      await _openForm(tester, original);
      await tester.enterText(_field('위치 *'), 'Draft before reload');

      final latest = _record(
        original.id,
        location: 'Latest harbor',
        memo: 'Latest remote memo',
        weather: '비',
        species: '광어',
      );
      await records.updateRecord(latest);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, '최신 기록 불러오기'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '입력 유지'));
      await tester.pumpAndSettle();
      expect(_fieldValue(tester, '위치 *'), 'Draft before reload');

      await tester.tap(find.widgetWithText(TextButton, '최신 기록 불러오기'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('불러오기'));
      await tester.pumpAndSettle();

      expect(_fieldValue(tester, '위치 *'), 'Latest harbor');
      expect(_fieldValue(tester, '날씨 *'), '비');
      expect(find.text('Latest remote memo'), findsOneWidget);
      expect(find.text('광어'), findsOneWidget);
      expect(find.textContaining('편집 중 기록이 변경되었습니다.'), findsNothing);

      await tester.enterText(_field('위치 *'), 'Edited after reload');
      await _save(tester);

      expect(find.byType(RecordFormPage), findsNothing);
      expect(find.text('Open editor'), findsOneWidget);
      final saved = records.getRecordById(original.id)!;
      expect(saved.location, 'Edited after reload');
      expect(saved.memo, latest.memo);
      expect(saved.weather, latest.weather);
      expect(
        saved.catches.single.speciesName,
        latest.catches.single.speciesName,
      );
      final queued = await store.readOutboxItemsForOwner(auth.dataOwnerKey);
      expect(queued, hasLength(1));
      expect(queued.single.payload!['location'], 'Edited after reload');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'deletion during editing retains the draft and cannot resurrect the record',
    (tester) async {
      final original = _record('deleted-record');
      await records.addRecord(original);
      await _openForm(tester, original);
      await tester.enterText(_field('위치 *'), 'Draft after deletion');

      await records.deleteRecord(original.id);
      await tester.pumpAndSettle();
      expect(find.textContaining('이 기록은 삭제되었습니다.'), findsOneWidget);
      expect(_fieldValue(tester, '위치 *'), 'Draft after deletion');

      await _save(tester);

      expect(find.byType(RecordFormPage), findsOneWidget);
      expect(_fieldValue(tester, '위치 *'), 'Draft after deletion');
      expect(records.getRecordById(original.id), isNull);
      expect(await store.readRecordsForOwner(auth.dataOwnerKey), isEmpty);
      expect(await store.readOutboxItemsForOwner(auth.dataOwnerKey), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'detail follows live changes and disables actions after deletion',
    (tester) async {
      _useTallSurface(tester);
      final original = _record('detail-record');
      await records.addRecord(original);
      await tester.pumpWidget(
        MaterialApp(home: RecordDetailPage(record: original)),
      );
      await tester.pumpAndSettle();
      expect(find.text(original.location), findsOneWidget);

      await records.updateRecord(
        _record(original.id, location: 'Live detail harbor'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Live detail harbor'), findsOneWidget);
      expect(find.text(original.location), findsNothing);

      await records.deleteRecord(original.id);
      await tester.pumpAndSettle();
      expect(find.text('이 기록은 삭제되었습니다.'), findsOneWidget);
      expect(find.text('Live detail harbor'), findsNothing);
      _expectDetailActionsDisabled(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a remote change during delete confirmation keeps the latest record',
    (tester) async {
      _useTallSurface(tester);
      final original = _record('delete-confirmation-record');
      await records.addRecord(original);
      await tester.pumpWidget(
        MaterialApp(home: RecordDetailPage(record: original)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('삭제'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);

      final latest = _record(
        original.id,
        location: 'Changed while confirming deletion',
      );
      await records.updateRecord(latest);
      await tester.pumpAndSettle();
      final beforeOutbox = await store.readOutboxItemsForOwner(
        auth.dataOwnerKey,
      );

      await tester.tap(find.widgetWithText(FilledButton, '삭제'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(RecordDetailPage), findsOneWidget);
      expect(find.text(latest.location), findsOneWidget);
      expect(find.textContaining('편집 중 기록이 변경되었습니다.'), findsOneWidget);
      expect(records.getRecordById(original.id)!.toJson(), latest.toJson());
      expect(
        (await store.readRecordsForOwner(auth.dataOwnerKey)).single.toJson(),
        latest.toJson(),
      );
      expect(
        (await store.readOutboxItemsForOwner(
          auth.dataOwnerKey,
        )).map((item) => item.toJson()).toList(),
        beforeOutbox.map((item) => item.toJson()).toList(),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'switching accounts blocks an open form and its underlying detail with the same ID',
    (tester) async {
      _useTallSurface(tester);
      final original = _record('same-account-id', location: 'Account A harbor');
      await records.addRecord(original);
      final ownerA = auth.dataOwnerKey;
      await tester.pumpWidget(
        MaterialApp(home: RecordDetailPage(record: original)),
      );
      await tester.tap(find.byTooltip('수정'));
      await tester.pumpAndSettle();
      await tester.enterText(_field('위치 *'), 'Account A unsaved draft');

      await auth.setSessionForTesting(
        plan: UserPlan.paid,
        email: 'other-widget@example.com',
      );
      final otherRecord = _record(original.id, location: 'Account B harbor');
      await records.addRecord(otherRecord);
      await tester.pumpAndSettle();

      await _save(tester);

      expect(find.byType(RecordFormPage), findsOneWidget);
      expect(_fieldValue(tester, '위치 *'), 'Account A unsaved draft');
      expect(
        records.getRecordById(original.id)!.toJson(),
        otherRecord.toJson(),
      );
      expect(await store.readOutboxItemsForOwner(auth.dataOwnerKey), isEmpty);
      expect(
        (await store.readRecordsForOwner(ownerA)).single.toJson(),
        original.toJson(),
      );

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(RecordDetailPage), findsOneWidget);
      expect(find.text('Account A harbor'), findsNothing);
      expect(find.text('Account B harbor'), findsNothing);
      _expectDetailActionsDisabled(tester);
      expect(tester.takeException(), isNull);
    },
  );

  for (final editForm in <bool>[true, false]) {
    testWidgets(
      '${editForm ? 'form' : 'detail'} removes listeners when disposed',
      (tester) async {
        _useTallSurface(tester);
        final original = _record('disposed-record');
        await records.addRecord(original);
        await tester.pumpWidget(
          MaterialApp(
            home: editForm
                ? RecordFormPage(editingRecord: original)
                : RecordDetailPage(record: original),
          ),
        );
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox.shrink());

        await records.updateRecord(
          _record(original.id, location: 'Changed after disposal'),
        );
        await auth.setSessionForTesting(
          plan: UserPlan.paid,
          email: 'disposed-widget@example.com',
        );
        await tester.pump();

        expect(tester.takeException(), isNull);
      },
    );
  }
}

Future<void> _openForm(WidgetTester tester, FishingRecord record) async {
  _useTallSurface(tester);
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push<bool>(
              MaterialPageRoute<bool>(
                builder: (_) => RecordFormPage(editingRecord: record),
              ),
            ),
            child: const Text('Open editor'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open editor'));
  await tester.pumpAndSettle();
}

Future<void> _save(WidgetTester tester) async {
  final saveButton = find.widgetWithText(FilledButton, '저장');
  await tester.ensureVisible(saveButton);
  await tester.tap(saveButton);
  await tester.pumpAndSettle();
}

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

String _fieldValue(WidgetTester tester, String label) =>
    tester.widget<TextField>(_field(label)).controller!.text;

void _expectDetailActionsDisabled(WidgetTester tester) {
  for (final tooltip in <String>['수정', '삭제']) {
    final action = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == tooltip,
    );
    expect(tester.widget<IconButton>(action).onPressed, isNull);
  }
}

void _useTallSurface(WidgetTester tester) {
  addTearDown(tester.view.reset);
  tester.view.physicalSize = const Size(1000, 3000);
  tester.view.devicePixelRatio = 1;
}

FishingRecord _record(
  String id, {
  String location = 'Original harbor',
  String memo = 'Original memo',
  String weather = '맑음',
  String species = '우럭',
}) => FishingRecord(
  id: id,
  location: location,
  startAt: DateTime(2026, 9, 22, 8),
  endAt: DateTime(2026, 9, 22, 10),
  genreName: '루어',
  tide: '3물',
  weather: weather,
  airTemperature: 24,
  waterTemperature: 20,
  catches: <CatchRecord>[
    CatchRecord(speciesName: species, lengthCm: 31, weightG: 820),
  ],
  memo: memo,
);
