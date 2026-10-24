import 'dart:async';

import 'package:fishing_build/data/local/app_database.dart';
import 'package:fishing_build/data/local/local_data_store.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/outbox_item.dart';
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
import 'package:sqflite/sqflite.dart';

import 'support/test_database.dart';

const _discardTitle = '저장하지 않고 나가시겠습니까?';
const _saveFailure = '기록을 저장하지 못했습니다. 입력한 내용은 유지됩니다. 다시 시도해 주세요.';

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
      email: 'save-recovery-widget@example.com',
    );
  });

  tearDown(() async {
    await sync.resetForTesting();
  });

  testWidgets('untouched new and prefilled forms leave without confirmation', (
    tester,
  ) async {
    for (final page in <RecordFormPage>[
      const RecordFormPage(),
      const RecordFormPage(
        initialLocation: 'Map harbor',
        initialTide: '3물',
        initialWeather: '맑음',
        initialAirTemperature: 22,
        initialWaterTemperature: 19,
        initialFishName: '우럭',
      ),
    ]) {
      await _openPage(tester, page);

      await _systemBack(tester);

      expect(find.byType(RecordFormPage), findsNothing);
      expect(find.text(_discardTitle), findsNothing);
      expect(find.text('Open page'), findsOneWidget);
    }
    expect(await store.readRecordsForOwner(auth.dataOwnerKey), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an untouched persisted edit leaves without confirmation', (
    tester,
  ) async {
    final original = _record('clean-edit');
    await records.addRecord(original);
    await _openPage(tester, RecordFormPage(editingRecord: original));

    await _systemBack(tester);

    expect(find.byType(RecordFormPage), findsNothing);
    expect(find.text(_discardTitle), findsNothing);
    expect(records.getRecordById(original.id)!.toJson(), original.toJson());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'dirty back confirmation preserves input or explicitly discards it',
    (tester) async {
      await _openPage(tester, const RecordFormPage());
      await tester.enterText(_field('위치 *'), 'Unsaved harbor');

      await _systemBack(tester);
      expect(find.text(_discardTitle), findsOneWidget);
      expect(find.text('작성한 내용이 저장되지 않습니다.'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '계속 작성'));
      await tester.pumpAndSettle();
      expect(_fieldValue(tester, '위치 *'), 'Unsaved harbor');
      expect(find.byType(RecordFormPage), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text(_discardTitle), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '나가기'));
      await tester.pumpAndSettle();

      expect(find.byType(RecordFormPage), findsNothing);
      expect(await store.readRecordsForOwner(auth.dataOwnerKey), isEmpty);
      expect(await store.readOutboxItemsForOwner(auth.dataOwnerKey), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('restoring the original text clears the dirty state', (
    tester,
  ) async {
    final original = _record('restored-text');
    await records.addRecord(original);
    await _openPage(tester, RecordFormPage(editingRecord: original));
    await tester.enterText(_field('위치 *'), 'Changed harbor');
    await tester.enterText(_field('위치 *'), original.location);

    await _systemBack(tester);

    expect(find.byType(RecordFormPage), findsNothing);
    expect(find.text(_discardTitle), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'time genre catch and photo changes each require discard confirmation',
    (tester) async {
      final original = _record('non-text-draft', withPhoto: true);
      await records.addRecord(original);
      final changes = <Future<void> Function()>[
        () async {
          await tester.tap(
            find.ancestor(
              of: find.text('시작 시간 *'),
              matching: find.byType(InkWell),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('23').last);
          await tester.tap(find.widgetWithText(TextButton, 'OK'));
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(TextButton, 'OK'));
          await tester.pumpAndSettle();
        },
        () async {
          await tester.tap(find.widgetWithText(ChoiceChip, '선상'));
          await tester.pumpAndSettle();
        },
        () async {
          await tester.ensureVisible(_field('어종'));
          await tester.enterText(_field('어종'), '광어');
        },
        () async {
          await tester.ensureVisible(find.byIcon(Icons.close));
          await tester.tap(find.byIcon(Icons.close));
          await tester.pumpAndSettle();
        },
      ];
      for (final change in changes) {
        await _openPage(tester, RecordFormPage(editingRecord: original));
        await change();

        await _systemBack(tester);

        expect(find.text(_discardTitle), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, '나가기'));
        await tester.pumpAndSettle();
        expect(find.byType(RecordFormPage), findsNothing);
      }
      expect(records.getRecordById(original.id)!.toJson(), original.toJson());
      expect(await store.readOutboxItemsForOwner(auth.dataOwnerKey), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'explicitly reloading the latest record establishes a clean baseline',
    (tester) async {
      final original = _record('reload-baseline');
      await records.addRecord(original);
      await _openPage(tester, RecordFormPage(editingRecord: original));
      await tester.enterText(_field('위치 *'), 'Discarded draft');
      final latest = _record(original.id, location: 'Latest harbor');
      await records.updateRecord(latest);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, '최신 기록 불러오기'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '불러오기'));
      await tester.pumpAndSettle();
      expect(_fieldValue(tester, '위치 *'), latest.location);

      await _systemBack(tester);

      expect(find.byType(RecordFormPage), findsNothing);
      expect(find.text(_discardTitle), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed create retains the draft and retry commits one record and request',
    (tester) async {
      final routeResult = await _openPage(tester, const RecordFormPage());
      await _fillRequiredFields(tester);
      final database = await AppDatabase.instance.database;
      await _rejectWrites(database);

      await _save(tester);

      expect(find.byType(RecordFormPage), findsOneWidget);
      expect(find.text(_saveFailure), findsOneWidget);
      expect(_fieldValue(tester, '위치 *'), 'New harbor');
      expect(_fieldValue(tester, '메모'), 'Keep this draft');
      expect(await store.readRecordsForOwner(auth.dataOwnerKey), isEmpty);
      expect(await store.readOutboxItemsForOwner(auth.dataOwnerKey), isEmpty);
      expect(await database.query(AppDatabase.recordSyncStatesTable), isEmpty);

      await database.execute('DROP TRIGGER reject_record_write');
      await _save(tester);

      expect(find.byType(RecordFormPage), findsNothing);
      expect(routeResult.value, isTrue);
      final saved = await store.readRecordsForOwner(auth.dataOwnerKey);
      expect(saved, hasLength(1));
      expect(saved.single.location, 'New harbor');
      expect(saved.single.memo, 'Keep this draft');
      final queued = await store.readOutboxItemsForOwner(auth.dataOwnerKey);
      expect(queued, hasLength(1));
      expect(queued.single.recordId, saved.single.id);
      expect(queued.single.operationType, OutboxOperationType.create);
      expect(queued.single.baseVersionNo, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed edit preserves persisted children and draft then retries once',
    (tester) async {
      final original = _record('retry-edit', withPhoto: true);
      await records.addRecord(original);
      final routeResult = await _openPage(
        tester,
        RecordFormPage(editingRecord: original),
      );
      await tester.enterText(_field('위치 *'), 'Edited harbor');
      final database = await AppDatabase.instance.database;
      await _rejectWrites(database);

      await _save(tester);

      expect(find.text(_saveFailure), findsOneWidget);
      expect(_fieldValue(tester, '위치 *'), 'Edited harbor');
      expect(records.getRecordById(original.id)!.toJson(), original.toJson());
      expect(
        (await store.readRecordsForOwner(auth.dataOwnerKey)).single.toJson(),
        original.toJson(),
      );
      expect(await store.readOutboxItemsForOwner(auth.dataOwnerKey), isEmpty);
      expect(await database.query(AppDatabase.recordSyncStatesTable), isEmpty);

      await database.execute('DROP TRIGGER reject_record_write');
      await _save(tester);

      expect(routeResult.value, isTrue);
      expect(find.byType(RecordFormPage), findsNothing);
      final saved = (await store.readRecordsForOwner(auth.dataOwnerKey)).single;
      expect(saved.location, 'Edited harbor');
      expect(saved.catches.single.toJson(), original.catches.single.toJson());
      expect(saved.photos.single.toJson(), original.photos.single.toJson());
      final queued = await store.readOutboxItemsForOwner(auth.dataOwnerKey);
      expect(queued, hasLength(1));
      expect(queued.single.operationType, OutboxOperationType.update);
      expect(queued.single.baseVersionNo, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'saving locks input and navigation and ignores repeated save callbacks',
    (tester) async {
      final routeResult = await _openPage(tester, const RecordFormPage());
      await _fillRequiredFields(tester);
      final saveButton = find.widgetWithText(FilledButton, '저장');
      await tester.ensureVisible(saveButton);
      final saveCallback = tester.widget<FilledButton>(saveButton).onPressed!;
      final blocker = await _holdDatabase();
      addTearDown(blocker.release);

      saveCallback();
      saveCallback();
      await tester.pump();
      expect(find.text('저장 중…'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '저장 중…'))
            .onPressed,
        isNull,
      );
      final field = tester.widget<TextField>(_field('위치 *'));
      final absorbed = find.ancestor(
        of: _field('위치 *'),
        matching: find.byWidgetPredicate(
          (widget) =>
              (widget is AbsorbPointer && widget.absorbing) ||
              (widget is IgnorePointer && widget.ignoring),
        ),
      );
      expect(
        field.readOnly ||
            field.enabled == false ||
            absorbed.evaluate().isNotEmpty,
        isTrue,
      );

      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(RecordFormPage), findsOneWidget);
      expect(find.text('기록을 저장하는 중입니다. 잠시만 기다려 주세요.'), findsOneWidget);
      expect(find.text(_discardTitle), findsNothing);

      await blocker.release();
      await tester.pumpAndSettle();

      expect(routeResult.value, isTrue);
      expect(find.byType(RecordFormPage), findsNothing);
      expect(await store.readRecordsForOwner(auth.dataOwnerKey), hasLength(1));
      expect(
        await store.readOutboxItemsForOwner(auth.dataOwnerKey),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'delete confirmation cannot be entered twice while the snapshot read waits',
    (tester) async {
      final original = _record('delete-double-confirm');
      await records.addRecord(original);
      await _openPage(tester, RecordDetailPage(record: original));
      final deleteCallback = tester
          .widget<IconButton>(_detailAction('삭제'))
          .onPressed!;
      final blocker = await _holdDatabase();
      addTearDown(blocker.release);

      deleteCallback();
      deleteCallback();
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      await blocker.release();
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '취소'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(records.getRecordById(original.id), isNotNull);
      expect(await store.readOutboxItemsForOwner(auth.dataOwnerKey), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed deletion leaves the record available and retry removes it once',
    (tester) async {
      final original = _record('retry-delete', withPhoto: true);
      await records.addRecord(original);
      final routeResult = await _openPage(
        tester,
        RecordDetailPage(record: original),
      );
      final database = await AppDatabase.instance.database;
      await database.execute('''
      CREATE TRIGGER reject_record_delete
      BEFORE DELETE ON ${AppDatabase.fishingRecordsTable}
      BEGIN SELECT RAISE(ABORT, 'test delete failure'); END
    ''');

      await _confirmDeletion(tester);
      await tester.pumpAndSettle();

      expect(find.byType(RecordDetailPage), findsOneWidget);
      expect(find.text('기록을 처리하지 못했습니다. 다시 시도해 주세요.'), findsOneWidget);
      expect(records.getRecordById(original.id)!.toJson(), original.toJson());
      expect(
        (await store.readRecordsForOwner(auth.dataOwnerKey)).single.toJson(),
        original.toJson(),
      );
      expect(await store.readOutboxItemsForOwner(auth.dataOwnerKey), isEmpty);
      expect(await database.query(AppDatabase.recordSyncStatesTable), isEmpty);
      expect(
        tester.widget<IconButton>(_detailAction('삭제')).onPressed,
        isNotNull,
      );

      await database.execute('DROP TRIGGER reject_record_delete');
      await _confirmDeletion(tester);
      await tester.pumpAndSettle();

      expect(routeResult.value, isTrue);
      expect(find.byType(RecordDetailPage), findsNothing);
      expect(records.getRecordById(original.id), isNull);
      expect(await store.readRecordsForOwner(auth.dataOwnerKey), isEmpty);
      final queued = await store.readOutboxItemsForOwner(auth.dataOwnerKey);
      expect(queued, hasLength(1));
      expect(queued.single.operationType, OutboxOperationType.delete);
      expect(queued.single.baseVersionNo, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an in-progress deletion blocks back and completes with a true route result',
    (tester) async {
      final original = _record('delete-in-flight');
      await records.addRecord(original);
      final routeResult = await _openPage(
        tester,
        RecordDetailPage(record: original),
      );
      await tester.tap(find.byTooltip('삭제'));
      await tester.pumpAndSettle();
      final blocker = await _holdDatabase();
      addTearDown(blocker.release);
      await tester.tap(find.widgetWithText(FilledButton, '삭제'));
      await tester.pump(const Duration(milliseconds: 400));

      await tester.binding.handlePopRoute();
      await tester.pump();

      expect(find.byType(RecordDetailPage), findsOneWidget);
      expect(routeResult.value, isNull);
      expect(tester.widget<IconButton>(_detailAction('수정')).onPressed, isNull);
      expect(tester.widget<IconButton>(_detailAction('삭제')).onPressed, isNull);

      await blocker.release();
      await tester.pumpAndSettle();

      expect(routeResult.value, isTrue);
      expect(find.byType(RecordDetailPage), findsNothing);
      expect(await store.readRecordsForOwner(auth.dataOwnerKey), isEmpty);
      final queued = await store.readOutboxItemsForOwner(auth.dataOwnerKey);
      expect(queued, hasLength(1));
      expect(queued.single.operationType, OutboxOperationType.delete);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<ValueNotifier<bool?>> _openPage(WidgetTester tester, Widget page) async {
  _useTallSurface(tester);
  final result = ValueNotifier<bool?>(null);
  addTearDown(result.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              result.value = await Navigator.of(
                context,
              ).push<bool>(MaterialPageRoute<bool>(builder: (_) => page));
            },
            child: const Text('Open page'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open page'));
  await tester.pumpAndSettle();
  return result;
}

Future<void> _systemBack(WidgetTester tester) async {
  await tester.pump();
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
}

Future<void> _fillRequiredFields(WidgetTester tester) async {
  for (final entry in <String, String>{
    '위치 *': 'New harbor',
    '물때 *': '3물',
    '날씨 *': '맑음',
    '기온 *': '22',
    '수온 *': '19',
    '메모': 'Keep this draft',
  }.entries) {
    await tester.ensureVisible(_field(entry.key));
    await tester.enterText(_field(entry.key), entry.value);
  }
  await tester.ensureVisible(find.widgetWithText(ChoiceChip, '루어'));
  await tester.tap(find.widgetWithText(ChoiceChip, '루어'));
  await tester.pump();
}

Future<void> _save(WidgetTester tester) async {
  final saveButton = find.widgetWithText(FilledButton, '저장');
  await tester.ensureVisible(saveButton);
  await tester.tap(saveButton);
  await tester.pumpAndSettle();
}

Future<void> _confirmDeletion(WidgetTester tester) async {
  await tester.tap(find.byTooltip('삭제'));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, '삭제'));
}

Future<void> _rejectWrites(Database database) => database.execute('''
  CREATE TRIGGER reject_record_write
  BEFORE INSERT ON ${AppDatabase.fishingRecordsTable}
  BEGIN SELECT RAISE(ABORT, 'test write failure'); END
''');

Future<_DatabaseBlocker> _holdDatabase() async {
  final database = await AppDatabase.instance.database;
  final entered = Completer<void>();
  final released = Completer<void>();
  final finished = database.transaction((transaction) async {
    entered.complete();
    await released.future;
  });
  await entered.future;
  return _DatabaseBlocker(released, finished);
}

class _DatabaseBlocker {
  const _DatabaseBlocker(this.released, this.finished);

  final Completer<void> released;
  final Future<void> finished;

  Future<void> release() async {
    if (released.isCompleted) return;
    released.complete();
    await finished;
  }
}

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Finder _detailAction(String tooltip) => find.byWidgetPredicate(
  (widget) => widget is IconButton && widget.tooltip == tooltip,
);

String _fieldValue(WidgetTester tester, String label) =>
    tester.widget<TextField>(_field(label)).controller!.text;

void _useTallSurface(WidgetTester tester) {
  addTearDown(tester.view.reset);
  tester.view.physicalSize = const Size(1000, 3000);
  tester.view.devicePixelRatio = 1;
}

FishingRecord _record(
  String id, {
  String location = 'Original harbor',
  bool withPhoto = false,
}) => FishingRecord(
  id: id,
  location: location,
  startAt: DateTime(2026, 9, 22, 8),
  endAt: DateTime(2026, 9, 22, 10),
  genreName: '루어',
  tide: '3물',
  weather: '맑음',
  airTemperature: 22,
  waterTemperature: 19,
  catches: <CatchRecord>[
    CatchRecord(speciesName: '우럭', lengthCm: 31, weightG: 820),
  ],
  photos: withPhoto
      ? const <RecordPhoto>[
          RecordPhoto(
            id: 'test-photo',
            localPath: 'C:/missing/save-recovery-photo.jpg',
            contentType: 'image/jpeg',
            sizeBytes: 1024,
            checksum:
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          ),
        ]
      : const <RecordPhoto>[],
  memo: 'Original memo',
);
