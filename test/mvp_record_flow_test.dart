import 'package:fishing_build/data/local/local_data_store.dart';
import 'package:fishing_build/data/maps/current_location_gateway.dart';
import 'package:fishing_build/data/maps/map_location.dart';
import 'package:fishing_build/data/maps/water_area.dart';
import 'package:fishing_build/data/models/external_data.dart';
import 'package:fishing_build/data/models/personal_best_record.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/conflict_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/repositories/outbox_repository.dart';
import 'package:fishing_build/data/services/external_data_service.dart';
import 'package:fishing_build/data/services/network_status_service.dart';
import 'package:fishing_build/data/services/record_sync_service.dart';
import 'package:fishing_build/presentation/calendar/calendar_page.dart';
import 'package:fishing_build/presentation/calendar/daily_record_list_page.dart';
import 'package:fishing_build/presentation/map/map_page.dart';
import 'package:fishing_build/presentation/map/map_selection_controller.dart';
import 'package:fishing_build/presentation/personal_best/personal_best_detail_page.dart';
import 'package:fishing_build/presentation/personal_best/personal_best_page.dart';
import 'package:fishing_build/presentation/record/record_detail_page.dart';
import 'package:fishing_build/presentation/record/record_form_page.dart';
import 'package:fishing_build/presentation/share/share_record_card.dart';
import 'package:fishing_build/presentation/share/share_record_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fixed_water_area_service.dart';
import 'support/test_database.dart';

void main() {
  final auth = AuthSessionRepository.instance;
  final records = FishingRecordRepository.instance;
  final sync = RecordSyncService.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await sync.resetForTesting();
    await NetworkStatusService.instance.resetForTesting();
    await resetTestDatabase();
    auth.clearMemoryOnlyForTesting();
    records.clearCacheOnlyForTesting();
    OutboxRepository.instance.clearCacheOnlyForTesting();
    ConflictRepository.instance.clearCacheOnlyForTesting();
    await auth.setSessionForTesting(
      plan: UserPlan.free,
      email: 'mvp-flow@example.com',
    );
  });

  tearDown(() async {
    await sync.resetForTesting();
  });

  testWidgets(
    'map-created catches survive reload and retain their own calendar and share evidence',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final place = MapLocation(
        name: 'MVP lake',
        latitude: 35.1796,
        longitude: 129.0756,
      );
      final controller = MapSelectionController(
        locationGateway: _NoLocationPermission(),
        initialSelection: place,
      );
      addTearDown(controller.dispose);
      addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));

      await tester.pumpWidget(
        MaterialApp(
          home: MapPage(
            controller: controller,
            mapBuilder: (_, _, _) => const SizedBox(height: 200),
            externalDataService: _Weather(),
            waterAreaService: const FixedWaterAreaService(WaterArea.freshwater),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _tap(tester, find.text('기록 작성'));
      expect(find.byType(RecordFormPage), findsOneWidget);
      expect(
        tester.widget<TextField>(_field('위치 *')).controller!.text,
        place.name,
      );
      await _tap(tester, find.widgetWithText(ChoiceChip, '루어'));

      // These are two individual fish from one trip. Their maxima differ.
      await _enter(tester, _field('어종').at(0), 'Bass');
      await _enter(tester, _field('크기').at(0), '60');
      await _enter(tester, _field('무게').at(0), '400');
      await _tap(tester, find.text('조과 추가'));
      await _enter(tester, _field('어종').at(1), 'Bass');
      await _enter(tester, _field('크기').at(1), '40');
      await _enter(tester, _field('무게').at(1), '1200');
      await _tap(tester, find.widgetWithText(FilledButton, '저장'));
      expect(find.byType(RecordFormPage), findsNothing);

      final persisted = (await LocalDataStore.instance.readRecordsForOwner(
        auth.dataOwnerKey,
      )).single;
      expect(persisted.location, place.name);
      expect(persisted.latitude, place.latitude);
      expect(persisted.longitude, place.longitude);
      expect(persisted.weather, '맑음');
      expect(persisted.airTemperature, 22);
      expect(persisted.tide, isNull);
      expect(persisted.waterTemperature, isNull);
      expect(persisted.catches, hasLength(2));
      expect(persisted.catches.map((fish) => fish.lengthCm), [60, 40]);
      expect(persisted.catches.map((fish) => fish.weightG), [400, 1200]);

      // Remove the form's published cache so later pages must use SQLite data.
      await tester.pumpWidget(const SizedBox.shrink());
      records.clearCacheOnlyForTesting();
      await records.loadRecords();
      await tester.pumpWidget(const MaterialApp(home: CalendarPage()));
      await tester.pumpAndSettle();
      // Overnight trips may span multiple week rows and calendar months.
      expect(find.text(persisted.summaryTitle), findsWidgets);
      final day = DateTime.now();
      final dateKey =
          '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
      await _tap(tester, find.byKey(ValueKey('calendar-day-$dateKey')));
      expect(find.byType(DailyRecordListPage), findsOneWidget);
      await _tap(tester, find.widgetWithText(ListTile, persisted.summaryTitle));
      expect(find.byType(RecordDetailPage), findsOneWidget);
      expect(
        tester
            .widget<RecordDetailPage>(find.byType(RecordDetailPage))
            .record
            .id,
        persisted.id,
      );
      expect(find.text('위도 35.1796 · 경도 129.0756'), findsOneWidget);

      // Use default repositories and change listeners, as the real tabs do.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(const MaterialApp(home: PersonalBestPage()));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('최고 크기 60.0 cm · 최고 무게 1200 g'),
        findsOneWidget,
      );
      await _tap(tester, find.widgetWithText(ListTile, 'Bass'));
      expect(find.byType(PersonalBestDetailPage), findsOneWidget);
      await _tap(tester, find.text('공유 이미지 미리보기'));
      await _settleShare(tester);
      expect(find.byType(ShareRecordPage), findsOneWidget);
      var card = tester.widget<ShareRecordCard>(find.byType(ShareRecordCard));
      expect(card.data.recordId, persisted.id);
      expect(card.data.catchIndex, 0);
      expect(card.data.criterion, PersonalBestSortType.length);
      expect(card.data.lengthCm, 60);
      expect(card.data.weightG, 400);
      expect(card.options.showLocation, isFalse);
      expect(card.options.showDate, isFalse);

      await _tap(tester, find.byType(BackButton));
      await _tap(tester, find.widgetWithText(ChoiceChip, '무게 기록'));
      await _tap(tester, find.text('공유 이미지 미리보기'));
      await _settleShare(tester);
      card = tester.widget<ShareRecordCard>(find.byType(ShareRecordCard));
      expect(card.data.recordId, persisted.id);
      expect(card.data.catchIndex, 1);
      expect(card.data.criterion, PersonalBestSortType.weight);
      expect(card.data.lengthCm, 40);
      expect(card.data.weightG, 1200);
      expect(tester.takeException(), isNull);
    },
  );
}

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Future<void> _enter(WidgetTester tester, Finder field, String value) async {
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
  await tester.pump();
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _settleShare(WidgetTester tester) async {
  await tester.runAsync(
    () => precacheImage(
      ShareRecordCard.backgroundProvider,
      tester.element(find.byType(ShareRecordCard)),
    ),
  );
  await tester.pumpAndSettle();
}

class _Weather implements ExternalDataService {
  @override
  Future<ExternalData> fetchCurrentData({
    required MapLocation location,
    bool forceRefresh = false,
  }) async {
    // Keep this fake valid across an hour boundary while opening the form.
    final validAt = DateTime.now().toUtc();
    return ExternalData(
      locationName: location.name,
      latitude: location.latitude!,
      longitude: location.longitude!,
      weather: '맑음',
      airTemperature: 22,
      gridX: 98,
      gridY: 76,
      issuedAt: validAt.subtract(const Duration(minutes: 30)),
      validAt: validAt,
      fetchedAt: validAt,
    );
  }
}

class _NoLocationPermission implements CurrentLocationGateway {
  @override
  Future<MapLocation> currentLocation({bool requestPermission = true}) async {
    throw const CurrentLocationException(CurrentLocationFailure.denied);
  }

  @override
  Future<bool> openAppSettings() async => true;

  @override
  Future<bool> openLocationSettings() async => true;
}
