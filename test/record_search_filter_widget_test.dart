import 'package:fishing_build/core/theme/app_theme.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/presentation/record/record_form_page.dart';
import 'package:fishing_build/presentation/record/record_page.dart';
import 'package:fishing_build/presentation/search/record_search_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_database.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await resetTestDatabase();
    final auth = AuthSessionRepository.instance;
    final records = FishingRecordRepository.instance;
    auth.resetAuthGatewayForTesting();
    records.clearCacheOnlyForTesting();
    await auth.setSessionForTesting(
      plan: UserPlan.free,
      email: 'record-search-filters@example.com',
    );
    final start = DateTime(2026, 11, 10, 7);
    for (final (id, genre) in [('one', '루어'), ('two', '선상')]) {
      await records.addRecord(
        FishingRecord(
          id: id,
          location: '영도',
          startAt: start,
          endAt: start.add(const Duration(hours: 2)),
          genreName: genre,
        ),
      );
    }
  });

  testWidgets('record filters apply, dismiss, and reset on a narrow screen', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.25)),
          child: child!,
        ),
        home: const RecordSearchPage(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('검색 결과 2건'), findsOneWidget);

    Future<void> tap(Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    await tap(find.byTooltip('필터'));
    await tap(find.widgetWithText(ChoiceChip, '루어'));
    await tap(find.byType(CloseButton));
    expect(find.text('검색 결과 2건'), findsOneWidget);

    await tap(find.byTooltip('필터'));
    await tap(find.widgetWithText(ChoiceChip, '선상'));
    await tap(find.widgetWithText(ChoiceChip, '오래된순'));
    await tap(find.text('적용하기'));
    expect(find.text('검색 결과 1건'), findsOneWidget);
    expect(find.text('오래된순'), findsOneWidget);

    await tap(find.byTooltip('필터'));
    await tap(find.text('초기화'));
    await tap(find.text('적용하기'));
    expect(find.text('검색 결과 2건'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'record creation stays fixed while scrolling and hides for typing',
    (tester) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 340);
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.lightTheme, home: const RecordPage()),
      );
      await tester.pumpAndSettle();

      final create = find.widgetWithText(FilledButton, '기록 작성');
      final createBounds = tester.getRect(create);
      final results = find.byType(CustomScrollView);
      final scrollable = tester.state<ScrollableState>(
        find.descendant(of: results, matching: find.byType(Scrollable)).first,
      );
      await tester.drag(results, const Offset(0, -150));
      await tester.pumpAndSettle();
      expect(scrollable.position.pixels, greaterThan(0));
      expect(tester.getRect(create), createBounds);

      tester.view.viewInsets = const FakeViewPadding(bottom: 160);
      await tester.pumpAndSettle();
      expect(create, findsNothing);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(tester.getRect(create), createBounds);

      await tester.tap(create);
      await tester.pumpAndSettle();
      expect(find.byType(RecordFormPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
