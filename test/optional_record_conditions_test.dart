import 'package:fishing_build/data/local/local_data_store.dart';
import 'package:fishing_build/data/maps/map_location.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/outbox_item.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/conflict_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/repositories/outbox_repository.dart';
import 'package:fishing_build/data/services/record_sync_service.dart';
import 'package:fishing_build/data/water_temperature/water_temperature_models.dart';
import 'package:fishing_build/presentation/record/record_form_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_database.dart';

final _harbor = MapLocation(
  name: '선택 정보 테스트 항구',
  latitude: 35.9756,
  longitude: 126.5631,
);

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
      email: 'optional-conditions@example.com',
    );
  });

  tearDown(() async {
    await sync.resetForTesting();
  });

  Future<FishingRecord> expectDurableConditions({
    required String? tide,
    required double? waterTemperature,
    OutboxOperationType operation = OutboxOperationType.create,
  }) async {
    final saved = (await store.readRecordsForOwner(auth.dataOwnerKey)).single;
    expect(saved.tide, tide);
    expect(saved.waterTemperature, waterTemperature);
    final queued = (await store.readOutboxItemsForOwner(
      auth.dataOwnerKey,
    )).last;
    expect(queued.operationType, operation);
    expect(queued.recordId, saved.id);
    expect(queued.payload, containsPair('tide', tide));
    expect(queued.payload, containsPair('waterTemperature', waterTemperature));
    records.clearCacheOnlyForTesting();
    await records.loadRecords();
    expect(records.getRecordById(saved.id)!.tide, tide);
    expect(records.getRecordById(saved.id)!.waterTemperature, waterTemperature);
    return saved;
  }

  // The map uses these existing flags for marine and nonmarine forms.
  for (final (scope, automatic) in [
    ('marine', true),
    ('freshwater', false),
    ('inland', false),
  ]) {
    testWidgets(
      '$scope form saves blank optional conditions as durable nulls',
      (tester) async {
        await _openPage(tester, _newForm(automatic: automatic));
        expect(
          tester.widget<TextField>(_tide).decoration!.labelText,
          '물때 (선택)',
        );
        expect(
          tester.widget<TextField>(_water).decoration!.labelText,
          '수온 (선택)',
        );
        await _selectGenre(tester);
        await _enter(tester, _tide, '   ');
        await _enter(tester, _water, '   ');

        await _save(tester);

        expect(find.byType(RecordFormPage), findsNothing);
        final saved = await expectDurableConditions(
          tide: null,
          waterTemperature: null,
        );
        expect(saved.weather, '맑음');
        expect(saved.airTemperature, 22);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('entered zero and negative finite temperatures survive saving', (
    tester,
  ) async {
    FishingRecord? previous;
    for (final value in [0.0, -2.5]) {
      await _openPage(
        tester,
        previous == null ? _newForm() : RecordFormPage(editingRecord: previous),
      );
      await _selectGenre(tester);
      await _enter(tester, _tide, '  3물  ');
      await _enter(tester, _water, value.toString());

      await _save(tester);

      expect(find.byType(RecordFormPage), findsNothing);
      previous = await expectDurableConditions(
        tide: '3물',
        waterTemperature: value,
        operation: previous == null
            ? OutboxOperationType.create
            : OutboxOperationType.update,
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'editing clears existing conditions and reopening retains nulls',
    (tester) async {
      final now = DateTime.now();
      final original = FishingRecord(
        id: 'optional-conditions-edit',
        location: _harbor.name,
        latitude: _harbor.latitude,
        longitude: _harbor.longitude,
        startAt: now,
        endAt: now.add(const Duration(hours: 2)),
        genreName: '루어',
        tide: '7물',
        weather: '흐림',
        airTemperature: 20,
        waterTemperature: 16.2,
        catches: [CatchRecord(speciesName: '우럭', lengthCm: 42, weightG: 800)],
      );
      await records.addRecord(original);
      await _openPage(
        tester,
        RecordFormPage(
          editingRecord: original,
          initialWaterTemperatureObservation: _observation(),
        ),
      );
      expect(_text(tester, _tide), '7물');
      expect(_text(tester, _water), '16.2');
      await _enter(tester, _tide, '');
      await _enter(tester, _water, '');

      await _save(tester);

      expect(find.byType(RecordFormPage), findsNothing);
      final cleared = await expectDurableConditions(
        tide: null,
        waterTemperature: null,
        operation: OutboxOperationType.update,
      );
      expect(cleared.catches.single.toJson(), original.catches.single.toJson());
      await _openPage(
        tester,
        RecordFormPage(
          editingRecord: cleared,
          initialWaterTemperatureObservation: _observation(),
        ),
      );
      expect(_text(tester, _tide), isEmpty);
      expect(_text(tester, _water), isEmpty);
      await _enter(tester, _field('메모'), '선택 정보를 비워 둔 수정');
      await _save(tester);
      expect(find.byType(RecordFormPage), findsNothing);
      await expectDurableConditions(
        tide: null,
        waterTemperature: null,
        operation: OutboxOperationType.update,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('nonempty invalid temperatures never persist or queue a record', (
    tester,
  ) async {
    await _openPage(tester, _newForm());
    await _selectGenre(tester);
    for (final value in ['NaN', 'Infinity', '-Infinity', 'not a number']) {
      await _clearNotices(tester);
      await _enter(tester, _water, value);

      await _save(tester);

      expect(find.byType(RecordFormPage), findsOneWidget);
      expect(find.text('수온은 유한한 숫자로 입력하세요.'), findsOneWidget);
      expect(_text(tester, _water), value);
      expect(await store.readRecordsForOwner(auth.dataOwnerKey), isEmpty);
      expect(await store.readOutboxItemsForOwner(auth.dataOwnerKey), isEmpty);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'weather and air temperature remain required with optional blanks',
    (tester) async {
      await _openPage(tester, _newForm());
      await _selectGenre(tester);
      for (final (label, error, restored) in [
        ('날씨 *', '날씨를 입력하세요.', '맑음'),
        ('기온 *', '기온을 입력하세요.', '22'),
      ]) {
        await _clearNotices(tester);
        await _enter(tester, _field(label), '   ');

        await _save(tester);

        expect(find.byType(RecordFormPage), findsOneWidget);
        expect(find.text(error), findsOneWidget);
        expect(await store.readRecordsForOwner(auth.dataOwnerKey), isEmpty);
        expect(await store.readOutboxItemsForOwner(auth.dataOwnerKey), isEmpty);
        await _enter(tester, _field(label), restored);
      }
      await _clearNotices(tester);
      await _save(tester);
      expect(find.byType(RecordFormPage), findsNothing);
      await expectDurableConditions(tide: null, waterTemperature: null);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('manually cleared automatic conditions stay empty during save', (
    tester,
  ) async {
    await _openPage(
      tester,
      _newForm(
        automatic: true,
        initialTide: null,
        startAt: DateTime.now(),
        observation: _observation(),
      ),
    );
    expect(_text(tester, _tide), isNotEmpty);
    expect(_text(tester, _water), '16.2');
    await _selectGenre(tester);
    await _enter(tester, _tide, '');
    await _enter(tester, _water, '');
    // Trigger reconciliation after a real manual clear, then restore the place.
    await _enter(tester, _field('위치 *'), '다른 출조 장소');
    await _enter(tester, _field('위치 *'), _harbor.name);
    expect(_text(tester, _tide), isEmpty);
    expect(_text(tester, _water), isEmpty);

    await _save(tester);

    expect(find.byType(RecordFormPage), findsNothing);
    await expectDurableConditions(tide: null, waterTemperature: null);
    expect(tester.takeException(), isNull);
  });
}

RecordFormPage _newForm({
  bool automatic = false,
  String? initialTide = '',
  DateTime? startAt,
  WaterTemperatureObservation? observation,
}) => RecordFormPage(
  initialStartAt: startAt ?? DateTime(2026, 11, 2, 8),
  initialLocation: _harbor.name,
  initialLatitude: _harbor.latitude,
  initialLongitude: _harbor.longitude,
  initialTide: initialTide,
  initialWeather: '맑음',
  initialAirTemperature: 22,
  initialWaterTemperatureObservation: observation,
  allowAutomaticTide: automatic,
  allowAutomaticWaterTemperature: automatic,
);

WaterTemperatureObservation _observation() {
  final now = DateTime.now().toUtc();
  return WaterTemperatureObservation(
    location: _harbor,
    station: const WaterTemperatureStation(
      code: 'OPTIONAL_TEST',
      name: '선택 정보 테스트 관측소',
      latitude: 35.9756,
      longitude: 126.5631,
    ),
    temperatureCelsius: 16.2,
    observedAt: now.subtract(const Duration(minutes: 10)),
    fetchedAt: now,
  );
}

Finder get _tide => find.byKey(const ValueKey('record-tide'));
Finder get _water => find.byKey(const ValueKey('record-water-temperature'));

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

String _text(WidgetTester tester, Finder field) =>
    tester.widget<TextField>(field).controller!.text;

Future<void> _openPage(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = const Size(1000, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(
              context,
            ).push<bool>(MaterialPageRoute(builder: (_) => page)),
            child: const Text('Open record'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open record'));
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, Finder field, String value) async {
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
  await tester.pump();
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

Future<void> _clearNotices(WidgetTester tester) async {
  ScaffoldMessenger.of(
    tester.element(find.byType(RecordFormPage)),
  ).clearSnackBars();
  await tester.pumpAndSettle();
}
