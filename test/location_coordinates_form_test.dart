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
  final store = LocalDataStore.instance;
  final sync = RecordSyncService.instance;

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
      email: 'coordinate-form@example.com',
    );
  });

  tearDown(() async {
    await sync.resetForTesting();
  });

  testWidgets('place-only form still saves without coordinates', (
    tester,
  ) async {
    await _openPage(tester, _newForm());
    await _selectGenre(tester);

    await _save(tester);

    expect(find.byType(RecordFormPage), findsNothing);
    final saved = (await store.readRecordsForOwner(auth.dataOwnerKey)).single;
    expect(saved.location, '좌표 테스트 방파제');
    expect(saved.latitude, isNull);
    expect(saved.longitude, isNull);
    final queued = (await store.readOutboxItemsForOwner(
      auth.dataOwnerKey,
    )).single;
    expect(queued.payload!.containsKey('latitude'), isFalse);
    expect(queued.payload!.containsKey('longitude'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('prefilled coordinates save to the queue and appear on details', (
    tester,
  ) async {
    await _openPage(tester, _newForm(latitude: 35.1796, longitude: 129.0756));
    expect(_coordinateText(tester, 'record-latitude'), '35.1796');
    expect(_coordinateText(tester, 'record-longitude'), '129.0756');
    await _selectGenre(tester);

    await _save(tester);

    final saved = records.getAllRecords().single;
    expect(saved.latitude, 35.1796);
    expect(saved.longitude, 129.0756);
    final queued = (await store.readOutboxItemsForOwner(
      auth.dataOwnerKey,
    )).single;
    expect(queued.payload!['latitude'], 35.1796);
    expect(queued.payload!['longitude'], 129.0756);
    await tester.pumpWidget(MaterialApp(home: RecordDetailPage(record: saved)));
    await tester.pumpAndSettle();
    expect(find.text('위도 35.1796 · 경도 129.0756'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'editing preserves coordinates until both are explicitly cleared',
    (tester) async {
      final original = _record();
      await records.addRecord(original);
      await _openPage(tester, RecordFormPage(editingRecord: original));
      expect(_coordinateText(tester, 'record-latitude'), '35.1796');
      expect(_coordinateText(tester, 'record-longitude'), '129.0756');
      await tester.ensureVisible(_field('메모'));
      await tester.enterText(_field('메모'), '장소를 유지하고 메모만 수정');
      await _save(tester);
      final edited = records.getRecordById(original.id)!;
      expect(edited.latitude, original.latitude);
      expect(edited.longitude, original.longitude);

      await _openPage(tester, RecordFormPage(editingRecord: edited));
      final clear = find.widgetWithText(TextButton, '좌표 지우기');
      await tester.ensureVisible(clear);
      await tester.tap(clear);
      await tester.pump();
      expect(_coordinateText(tester, 'record-latitude'), isEmpty);
      expect(_coordinateText(tester, 'record-longitude'), isEmpty);
      await _save(tester);

      final cleared = (await store.readRecordForOwner(
        auth.dataOwnerKey,
        original.id,
      ))!;
      expect(cleared.location, original.location);
      expect(cleared.latitude, isNull);
      expect(cleared.longitude, isNull);
      final latest = (await store.readOutboxItemsForOwner(
        auth.dataOwnerKey,
      )).last;
      expect(latest.payload!.containsKey('latitude'), isFalse);
      expect(latest.payload!.containsKey('longitude'), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('partial invalid and non-finite coordinates cannot be saved', (
    tester,
  ) async {
    await _openPage(tester, _newForm(latitude: 35.1796, longitude: 129.0756));
    await _selectGenre(tester);
    const cases = [
      ('35', '', '위도와 경도를 함께 입력하세요.'),
      ('문자', '129', '위도와 경도는 숫자로 입력하세요.'),
      ('91', '129', '위도는 -90부터 90 사이의 유한한 숫자로 입력하세요.'),
      ('35', '-181', '경도는 -180부터 180 사이의 유한한 숫자로 입력하세요.'),
      ('NaN', '129', '위도는 -90부터 90 사이의 유한한 숫자로 입력하세요.'),
    ];
    for (final (latitude, longitude, error) in cases) {
      ScaffoldMessenger.of(
        tester.element(find.byType(RecordFormPage)),
      ).clearSnackBars();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('record-latitude')));
      await tester.enterText(
        find.byKey(const ValueKey('record-latitude')),
        latitude,
      );
      await tester.enterText(
        find.byKey(const ValueKey('record-longitude')),
        longitude,
      );

      await _save(tester);

      expect(find.byType(RecordFormPage), findsOneWidget);
      expect(find.text(error), findsOneWidget);
      expect(await store.readRecordsForOwner(auth.dataOwnerKey), isEmpty);
      expect(await store.readOutboxItemsForOwner(auth.dataOwnerKey), isEmpty);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing only coordinates prompts before discarding the draft', (
    tester,
  ) async {
    await _openPage(tester, _newForm(latitude: 35.1796, longitude: 129.0756));
    await tester.enterText(
      find.byKey(const ValueKey('record-latitude')),
      '35.2',
    );

    // Let the controller listener rebuild PopScope before platform back.
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('저장하지 않고 나가시겠습니까?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '계속 작성'));
    await tester.pumpAndSettle();
    expect(_coordinateText(tester, 'record-latitude'), '35.2');
    expect(_coordinateText(tester, 'record-longitude'), '129.0756');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '나가기'));
    await tester.pumpAndSettle();
    expect(find.byType(RecordFormPage), findsNothing);
    expect(await store.readRecordsForOwner(auth.dataOwnerKey), isEmpty);
    expect(tester.takeException(), isNull);
  });
}

RecordFormPage _newForm({double? latitude, double? longitude}) =>
    RecordFormPage(
      initialLocation: '좌표 테스트 방파제',
      initialLatitude: latitude,
      initialLongitude: longitude,
      initialTide: '3물',
      initialWeather: '맑음',
      initialAirTemperature: 22,
      initialWaterTemperature: 19,
    );

Future<void> _openPage(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = const Size(1000, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(
              context,
            ).push<bool>(MaterialPageRoute(builder: (_) => page)),
            child: const Text('Open page'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open page'));
  await tester.pumpAndSettle();
}

Future<void> _selectGenre(WidgetTester tester) async {
  final genre = find.widgetWithText(ChoiceChip, '루어');
  await tester.ensureVisible(genre);
  await tester.tap(genre);
  await tester.pump();
}

Future<void> _save(WidgetTester tester) async {
  final save = find.widgetWithText(FilledButton, '저장');
  await tester.ensureVisible(save);
  await tester.tap(save);
  await tester.pumpAndSettle();
}

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

String _coordinateText(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;

FishingRecord _record() => FishingRecord(
  id: 'coordinate-form-edit',
  location: '원래 장소',
  latitude: 35.1796,
  longitude: 129.0756,
  startAt: DateTime(2026, 11, 1, 8),
  endAt: DateTime(2026, 11, 1, 12),
  genreName: '루어',
  tide: '3물',
  weather: '맑음',
  airTemperature: 22,
  waterTemperature: 19,
);
