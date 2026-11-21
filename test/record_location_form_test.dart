import 'dart:async';

import 'package:fishing_build/data/local/local_data_store.dart';
import 'package:fishing_build/data/maps/map_location.dart';
import 'package:fishing_build/data/models/external_data.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/conflict_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/repositories/outbox_repository.dart';
import 'package:fishing_build/data/services/record_location_conditions_service.dart';
import 'package:fishing_build/data/services/record_photo_cleanup_service.dart';
import 'package:fishing_build/data/services/record_sync_service.dart';
import 'package:fishing_build/data/water_temperature/water_temperature_models.dart';
import 'package:fishing_build/presentation/record/record_form_page.dart';
import 'package:fishing_build/presentation/record/record_location_search_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_database.dart';

final _origin = MapLocation(
  name: '기존 출조 항구',
  latitude: 35.9756,
  longitude: 126.5631,
);
final _destination = MapLocation(
  name: '새로운 출조 항구',
  latitude: 35.061,
  longitude: 129.073,
);
const _searchButton = ValueKey('record-location-search');

void main() {
  final auth = AuthSessionRepository.instance;
  final records = FishingRecordRepository.instance;
  final store = LocalDataStore.instance;
  final sync = RecordSyncService.instance;
  final cleanup = RecordPhotoCleanupService.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await sync.resetForTesting();
    await cleanup.resetForTesting();
    await resetTestDatabase();
    auth.clearMemoryOnlyForTesting();
    records.clearCacheOnlyForTesting();
    OutboxRepository.instance.clearCacheOnlyForTesting();
    ConflictRepository.instance.clearCacheOnlyForTesting();
    await auth.setSessionForTesting(
      plan: UserPlan.free,
      email: 'record-location@example.com',
    );
  });

  tearDown(() async {
    await sync.resetForTesting();
    await cleanup.resetForTesting();
  });

  for (final plan in [UserPlan.free, UserPlan.paid]) {
    testWidgets('a searched location saves its coordinates for $plan', (
      tester,
    ) async {
      await auth.setSessionForTesting(
        plan: plan,
        email: 'record-location@example.com',
      );
      await _open(tester, _form(withCoordinates: false));
      await _selectGenre(tester);
      await _openSearch(tester);
      await _returnLocation(tester, _destination);
      expect(_text(tester, '위치 *'), _destination.name);
      expect(_text(tester, '어종'), '우럭');

      await _save(tester);

      final saved = (await store.readRecordsForOwner(auth.dataOwnerKey)).single;
      _expectLocation(saved, _destination);
      final outbox = await store.readOutboxItemsForOwner(auth.dataOwnerKey);
      if (plan == UserPlan.paid) {
        expect(outbox.single.payload!['latitude'], _destination.latitude);
        expect(outbox.single.payload!['longitude'], _destination.longitude);
      } else {
        expect(outbox, isEmpty);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('marine selection prefills and saves conditions for the trip', (
    tester,
  ) async {
    final startAt = DateTime(2026, 11, 21, 8);
    final weatherRequests = <(MapLocation, DateTime)>[];
    final waterRequests = <(MapLocation, DateTime)>[];
    await _open(
      tester,
      RecordFormPage(
        initialStartAt: startAt,
        // A previous inland map entry does not govern a new search selection.
        allowAutomaticTide: false,
        allowAutomaticWaterTemperature: false,
        locationConditionsService: _LocationConditions(
          lookupWeather: (location, requestedAt) async {
            weatherRequests.add((location, requestedAt));
            return (weather: '흐림', airTemperature: 12.5);
          },
          classifyMarine: (_) async => true,
          lookupWater: (location, requestedAt) async {
            waterRequests.add((location, requestedAt));
            return 16.2;
          },
        ),
      ),
    );
    await tester.enterText(_field('위치 별칭 (선택)'), '내 포인트');
    await _openSearch(tester);
    await _returnLocation(tester, _destination);

    expect(_text(tester, '위치 별칭 (선택)'), '내 포인트');
    expect(weatherRequests, [(_destination, startAt)]);
    expect(waterRequests, [(_destination, startAt)]);
    expect(_text(tester, '날씨 *'), '흐림');
    expect(_text(tester, '기온 *'), '12.5');
    expect(_text(tester, '수온 (선택)'), '16.2');
    final tide = _text(tester, '물때 (선택)');
    expect(tide, isNotEmpty);

    await _selectGenre(tester);
    await _save(tester);
    final saved = (await store.readRecordsForOwner(auth.dataOwnerKey)).single;
    _expectLocation(saved, _destination);
    expect(saved.locationAlias, '내 포인트');
    expect(saved.weather, '흐림');
    expect(saved.airTemperature, 12.5);
    expect(saved.tide, tide);
    expect(saved.waterTemperature, 16.2);
  });

  testWidgets('nonmarine selection prefills weather without requesting water', (
    tester,
  ) async {
    var waterRequests = 0;
    await _open(
      tester,
      RecordFormPage(
        locationConditionsService: _LocationConditions(
          lookupWeather: (_, _) async => (weather: '맑음', airTemperature: 15.0),
          lookupWater: (_, _) async {
            waterRequests++;
            return 16;
          },
        ),
      ),
    );
    await _openSearch(tester);
    await _returnLocation(tester, _destination);

    expect(_text(tester, '날씨 *'), '맑음');
    expect(_text(tester, '기온 *'), '15.0');
    expect(_text(tester, '물때 (선택)'), isEmpty);
    expect(_text(tester, '수온 (선택)'), isEmpty);
    expect(waterRequests, 0);
  });

  testWidgets('water service failure still prefills weather and tide', (
    tester,
  ) async {
    await _open(
      tester,
      RecordFormPage(
        initialStartAt: DateTime(2026, 11, 21, 8),
        locationConditionsService: _LocationConditions(
          lookupWeather: (_, _) async => (weather: '흐림', airTemperature: 12.0),
          classifyMarine: (_) async => true,
          lookupWater: (_, _) async => throw StateError('service unavailable'),
        ),
      ),
    );
    await _openSearch(tester);
    await _returnLocation(tester, _destination);

    expect(_text(tester, '날씨 *'), '흐림');
    expect(_text(tester, '기온 *'), '12.0');
    expect(_text(tester, '물때 (선택)'), isNotEmpty);
    expect(_text(tester, '수온 (선택)'), isEmpty);
    expect(find.textContaining('일부 정보를 자동으로 입력하지 못했습니다'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('weather typed during the lookup is preserved', (tester) async {
    final pending = Completer<RecordLocationWeather?>();
    await _open(
      tester,
      RecordFormPage(
        locationConditionsService: _LocationConditions(
          lookupWeather: (_, _) => pending.future,
        ),
      ),
    );
    await _openSearch(tester);
    await _returnLocation(tester, _destination, settle: false);
    expect(find.textContaining('외부 정보를 불러오는 중입니다'), findsOneWidget);
    await tester.enterText(_field('날씨 *'), '직접 관측한 날씨');

    pending.complete((weather: '흐림', airTemperature: 18.0));
    await tester.pumpAndSettle();

    expect(_text(tester, '날씨 *'), '직접 관측한 날씨');
    expect(_text(tester, '기온 *'), '18.0');
  });

  testWidgets('a late response cannot replace another location’s weather', (
    tester,
  ) async {
    final pending = Completer<RecordLocationWeather?>();
    await _open(
      tester,
      RecordFormPage(
        locationConditionsService: _LocationConditions(
          lookupWeather: (location, _) async => location == _destination
              ? pending.future
              : (weather: '새 위치 날씨', airTemperature: 16.0),
        ),
      ),
    );
    await _openSearch(tester);
    await _returnLocation(tester, _destination);
    await _openSearch(tester);
    await _returnLocation(tester, _origin);
    expect(_text(tester, '날씨 *'), '새 위치 날씨');

    pending.complete((weather: '늦게 도착한 날씨', airTemperature: 19.0));
    await tester.pumpAndSettle();

    expect(_text(tester, '위치 *'), _origin.name);
    expect(_text(tester, '날씨 *'), '새 위치 날씨');
    expect(_text(tester, '기온 *'), '16.0');
  });

  testWidgets('typing a different location discards a pending weather lookup', (
    tester,
  ) async {
    final pending = Completer<RecordLocationWeather?>();
    await _open(
      tester,
      RecordFormPage(
        locationConditionsService: _LocationConditions(
          lookupWeather: (_, _) => pending.future,
        ),
      ),
    );
    await _openSearch(tester);
    await _returnLocation(tester, _destination, settle: false);
    await tester.enterText(_field('위치 *'), '직접 입력한 장소');

    pending.complete((weather: '이전 위치 날씨', airTemperature: 19.0));
    await tester.pumpAndSettle();

    expect(_text(tester, '위치 *'), '직접 입력한 장소');
    expect(_text(tester, '날씨 *'), isEmpty);
    expect(_text(tester, '기온 *'), isEmpty);
    expect(find.textContaining('외부 정보를 불러오는 중입니다'), findsNothing);
  });

  testWidgets('changing the start time fetches conditions for the new time', (
    tester,
  ) async {
    final originalStart = DateTime(2026, 11, 21, 8);
    final newStart = DateTime(2026, 11, 20, 11, 30);
    final previousRequest = Completer<RecordLocationWeather?>();
    final receivedStarts = <DateTime>[];
    await _open(
      tester,
      RecordFormPage(
        initialStartAt: originalStart,
        locationConditionsService: _LocationConditions(
          lookupWeather: (_, startAt) async {
            receivedStarts.add(startAt);
            if (startAt == originalStart) return previousRequest.future;
            return (weather: '바뀐 시간의 날씨', airTemperature: 12.0);
          },
        ),
      ),
    );
    await _openSearch(tester);
    await _returnLocation(tester, _destination, settle: false);
    final startField = find.ancestor(
      of: find.text('시작 시간 *'),
      matching: find.byType(InkWell),
    );
    await tester.ensureVisible(startField);
    await tester.tap(startField);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    Navigator.of(tester.element(find.byType(DatePickerDialog))).pop(newStart);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    Navigator.of(
      tester.element(find.byType(TimePickerDialog)),
    ).pop(TimeOfDay.fromDateTime(newStart));
    await tester.pumpAndSettle();

    expect(receivedStarts, [originalStart, newStart]);
    expect(_text(tester, '날씨 *'), '바뀐 시간의 날씨');
    previousRequest.complete((weather: '이전 시간의 날씨', airTemperature: 17.0));
    await tester.pumpAndSettle();

    expect(_text(tester, '날씨 *'), '바뀐 시간의 날씨');
    expect(_text(tester, '기온 *'), '12.0');
  });

  for (final sameName in [false, true]) {
    testWidgets(
      'selection invalidates old automatic data when same name is $sameName',
      (tester) async {
        final now = DateTime.now().toUtc();
        final selected = MapLocation(
          name: sameName ? _origin.name : _destination.name,
          latitude: _destination.latitude,
          longitude: _destination.longitude,
        );
        await _open(tester, _automaticForm(now));
        expect(_text(tester, '날씨 *'), '흐림');
        expect(_text(tester, '기온 *'), '20.0');
        expect(_text(tester, '수온 (선택)'), '16.2');
        await _openSearch(tester);
        await _returnLocation(tester, selected);

        expect(_text(tester, '날씨 *'), isEmpty);
        expect(_text(tester, '기온 *'), isEmpty);
        expect(_text(tester, '수온 (선택)'), isEmpty);
        expect(_text(tester, '물때 (선택)'), isEmpty);
        await tester.enterText(_field('날씨 *'), '맑음');
        await tester.enterText(_field('기온 *'), '22');
        await _selectGenre(tester);
        await _save(tester);
        _expectLocation(
          (await store.readRecordsForOwner(auth.dataOwnerKey)).single,
          selected,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('cancelling preserves an existing draft including its photo', (
    tester,
  ) async {
    final original = _record('cancel-location', withPhoto: true);
    await records.addRecord(original);
    await _open(
      tester,
      RecordFormPage(
        editingRecord: original,
        locationConditionsService: const _LocationConditions(),
      ),
    );
    await tester.enterText(_field('메모'), '검색 전에 작성한 메모');
    await _openSearch(tester);
    await _returnLocation(tester, null);

    expect(_text(tester, '위치 *'), original.location);
    expect(_text(tester, '메모'), '검색 전에 작성한 메모');
    expect(_text(tester, '어종'), '우럭');
    expect(find.text('사진 추가 (1/10)'), findsOneWidget);
    await _save(tester);
    final saved = records.getRecordById(original.id)!;
    _expectLocation(saved, _origin);
    expect(saved.memo, '검색 전에 작성한 메모');
    expect(saved.photos.single.toJson(), original.photos.single.toJson());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'typing a different place after selection drops its coordinates',
    (tester) async {
      await _open(tester, _form());
      await _openSearch(tester);
      await _returnLocation(tester, _destination);
      await tester.enterText(_field('위치 *'), '직접 입력한 다른 장소');
      await _selectGenre(tester);
      await _save(tester);

      final saved = (await store.readRecordsForOwner(auth.dataOwnerKey)).single;
      expect(saved.location, '직접 입력한 다른 장소');
      expect(saved.latitude, isNull);
      expect(saved.longitude, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'selection preserves manual weather, temperature and tide values',
    (tester) async {
      await _open(tester, _automaticForm(DateTime.now().toUtc()));
      await tester.enterText(_field('날씨 *'), '직접 확인한 비');
      await tester.enterText(_field('기온 *'), '11.5');
      await tester.enterText(_field('수온 (선택)'), '');
      await tester.enterText(_field('물때 (선택)'), '직접 확인한 물때');
      await _openSearch(tester);
      await _returnLocation(tester, _destination);

      expect(_text(tester, '날씨 *'), '직접 확인한 비');
      expect(_text(tester, '기온 *'), '11.5');
      expect(_text(tester, '수온 (선택)'), isEmpty);
      expect(_text(tester, '물때 (선택)'), '직접 확인한 물때');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'editing applies a new location and preserves stored conditions',
    (tester) async {
      final original = _record('edit-location');
      await records.addRecord(original);
      await _open(
        tester,
        RecordFormPage(
          editingRecord: original,
          locationConditionsService: const _LocationConditions(),
        ),
      );
      await _openSearch(tester);
      await _returnLocation(tester, _destination);
      await _save(tester);

      final saved = records.getRecordById(original.id)!;
      _expectLocation(saved, _destination);
      expect(saved.tide, original.tide);
      expect(saved.weather, original.weather);
      expect(saved.airTemperature, original.airTemperature);
      expect(saved.waterTemperature, original.waterTemperature);
      expect(tester.takeException(), isNull);
    },
  );

  for (final allowed in [false, true]) {
    testWidgets(
      'a newly selected unclassified location does not calculate tide ($allowed)',
      (tester) async {
        await _open(
          tester,
          RecordFormPage(
            initialLocation: _origin.name,
            initialLatitude: _origin.latitude,
            initialLongitude: _origin.longitude,
            allowAutomaticTide: allowed,
            locationConditionsService: const _LocationConditions(),
          ),
        );
        await _openSearch(tester);
        await _returnLocation(tester, _destination);
        expect(_text(tester, '물때 (선택)'), isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('a changed selection requires confirmation before discarding', (
    tester,
  ) async {
    await _open(tester, _form());
    await _openSearch(tester);
    await _returnLocation(tester, _destination);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('저장하지 않고 나가시겠습니까?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '계속 작성'));
    await tester.pumpAndSettle();
    expect(_text(tester, '위치 *'), _destination.name);
    expect(tester.takeException(), isNull);
  });

  testWidgets('confirming the same location leaves an untouched form clean', (
    tester,
  ) async {
    await _open(tester, _form());
    await _openSearch(tester);
    await _returnLocation(tester, _origin);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(RecordFormPage), findsNothing);
    expect(find.text('저장하지 않고 나가시겠습니까?'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'pending search rejects captured save and duplicate search calls',
    (tester) async {
      await _open(tester, _form());
      await _selectGenre(tester);
      final search = tester
          .widget<IconButton>(find.byKey(_searchButton))
          .onPressed!;
      final save = tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '저장'))
          .onPressed!;
      await _openSearch(tester);
      search();
      save();
      await tester.pumpAndSettle();

      expect(
        find.byType(RecordLocationSearchPage, skipOffstage: false),
        findsOneWidget,
      );
      expect(await store.readRecordsForOwner(auth.dataOwnerKey), isEmpty);
      await _returnLocation(tester, null);
      expect(_text(tester, '위치 *'), _origin.name);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a changed account ignores a result from its old search route', (
    tester,
  ) async {
    await _open(tester, _form());
    await _openSearch(tester);
    await auth.setSessionForTesting(
      plan: UserPlan.free,
      email: 'another-record-location@example.com',
    );
    await tester.pumpAndSettle();
    await _returnLocation(tester, _destination);

    expect(_text(tester, '위치 *'), _origin.name);
    expect(await store.readRecordsForOwner(auth.dataOwnerKey), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposing the form ignores a late location result', (
    tester,
  ) async {
    await _open(tester, _form());
    final formRoute = ModalRoute.of<bool>(
      tester.element(find.byType(RecordFormPage)),
    )!;
    await _openSearch(tester);
    final navigator = Navigator.of(
      tester.element(find.byType(RecordLocationSearchPage)),
    );
    navigator.removeRoute(formRoute);
    await tester.pumpAndSettle();
    navigator.pop<MapLocation>(_destination);
    await tester.pumpAndSettle();

    expect(find.byType(RecordFormPage), findsNothing);
    expect(await store.readRecordsForOwner(auth.dataOwnerKey), isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final deleted in [false, true]) {
    testWidgets(
      'an edit conflict while searching ignores selection (deleted: $deleted)',
      (tester) async {
        final original = _record('conflicted-location');
        await records.addRecord(original);
        await _open(
          tester,
          RecordFormPage(
            editingRecord: original,
            locationConditionsService: const _LocationConditions(),
          ),
        );
        await _openSearch(tester);
        if (deleted) {
          await records.deleteRecord(original.id);
        } else {
          await records.updateRecord(
            _record(original.id, location: '다른 기기에서 변경한 장소'),
          );
        }
        await tester.pumpAndSettle();
        await _returnLocation(tester, _destination);

        expect(_text(tester, '위치 *'), original.location);
        expect(
          records.getRecordById(original.id)?.location,
          deleted ? isNull : '다른 기기에서 변경한 장소',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}

RecordFormPage _form({bool withCoordinates = true}) => RecordFormPage(
  initialLocation: _origin.name,
  initialLatitude: withCoordinates ? _origin.latitude : null,
  initialLongitude: withCoordinates ? _origin.longitude : null,
  initialTide: '3물',
  initialWeather: '맑음',
  initialAirTemperature: 22,
  initialWaterTemperature: 19,
  initialFishName: '우럭',
  locationConditionsService: const _LocationConditions(),
);

RecordFormPage _automaticForm(DateTime now) {
  final hour = DateTime.utc(now.year, now.month, now.day, now.hour);
  return RecordFormPage(
    initialStartAt: now,
    initialLocation: _origin.name,
    initialLatitude: _origin.latitude,
    initialLongitude: _origin.longitude,
    locationConditionsService: const _LocationConditions(),
    initialExternalData: ExternalData(
      locationName: _origin.name,
      latitude: _origin.latitude!,
      longitude: _origin.longitude!,
      weather: '흐림',
      airTemperature: 20,
      gridX: 98,
      gridY: 74,
      issuedAt: hour.subtract(const Duration(minutes: 30)),
      validAt: hour,
      fetchedAt: now,
    ),
    initialWaterTemperatureObservation: WaterTemperatureObservation(
      location: _origin,
      station: const WaterTemperatureStation(
        code: 'location-test-station',
        name: '테스트 관측소',
        latitude: 35.98,
        longitude: 126.56,
      ),
      temperatureCelsius: 16.2,
      observedAt: now.subtract(const Duration(minutes: 5)),
      fetchedAt: now,
    ),
  );
}

FishingRecord _record(String id, {String? location, bool withPhoto = false}) =>
    FishingRecord(
      id: id,
      location: location ?? _origin.name,
      latitude: _origin.latitude,
      longitude: _origin.longitude,
      startAt: DateTime(2026, 11, 1, 8),
      endAt: DateTime(2026, 11, 1, 12),
      genreName: '루어',
      tide: '3물',
      weather: '맑음',
      airTemperature: 22,
      waterTemperature: 19,
      catches: const [CatchRecord(speciesName: '우럭')],
      photos: withPhoto
          ? const [
              RecordPhoto(
                id: 'retained-photo',
                localPath: 'record-location-search-retained.png',
              ),
            ]
          : const [],
    );

Future<void> _open(WidgetTester tester, RecordFormPage page) async {
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

Future<void> _openSearch(WidgetTester tester) async {
  final search = find.byKey(_searchButton);
  await tester.ensureVisible(search);
  await tester.tap(search);
  await tester.pumpAndSettle();
  expect(find.byType(RecordLocationSearchPage), findsOneWidget);
}

Future<void> _returnLocation(
  WidgetTester tester,
  MapLocation? location, {
  bool settle = true,
}) async {
  Navigator.of(
    tester.element(find.byType(RecordLocationSearchPage)),
  ).pop<MapLocation>(location);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }
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

String _text(WidgetTester tester, String label) =>
    tester.widget<TextField>(_field(label)).controller!.text;

void _expectLocation(FishingRecord record, MapLocation location) {
  expect(record.location, location.name);
  expect(record.latitude, location.latitude);
  expect(record.longitude, location.longitude);
}

class _LocationConditions extends RecordLocationConditionsService {
  const _LocationConditions({
    this.lookupWeather,
    this.classifyMarine,
    this.lookupWater,
  });

  final Future<RecordLocationWeather?> Function(MapLocation, DateTime)?
  lookupWeather;
  final Future<bool> Function(MapLocation)? classifyMarine;
  final Future<double?> Function(MapLocation, DateTime)? lookupWater;

  @override
  Future<RecordLocationWeather?> fetchWeather(
    MapLocation location,
    DateTime startAt,
  ) async => lookupWeather?.call(location, startAt);

  @override
  Future<bool> isMarine(MapLocation location) async =>
      classifyMarine?.call(location) ?? false;

  @override
  Future<double?> fetchMarineWaterTemperature(
    MapLocation location,
    DateTime startAt,
  ) async => lookupWater?.call(location, startAt);
}
