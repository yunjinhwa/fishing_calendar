import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/conflict_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/repositories/outbox_repository.dart';
import 'package:fishing_build/data/services/record_sync_service.dart';
import 'package:fishing_build/presentation/my_page/my_page.dart';
import 'package:fishing_build/presentation/plan/plan_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_auth_test.dart' show FakeAuthGateway;
import 'support/test_database.dart';

void main() {
  final authSession = AuthSessionRepository.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await RecordSyncService.instance.resetForTesting();
    await resetTestDatabase();
    authSession.resetAuthGatewayForTesting();
    FishingRecordRepository.instance.clearCacheOnlyForTesting();
    OutboxRepository.instance.clearCacheOnlyForTesting();
    ConflictRepository.instance.clearCacheOnlyForTesting();
  });

  tearDown(authSession.resetAuthGatewayForTesting);

  for (final plan in [UserPlan.free, UserPlan.paid]) {
    testWidgets('local ${plan.name} plan changes are hidden by default', (
      tester,
    ) async {
      await authSession.setSessionForTesting(
        plan: plan,
        email: 'default-${plan.name}@example.com',
      );

      await tester.pumpWidget(const MaterialApp(home: PlanPage()));

      expect(find.text(plan.label), findsOneWidget);
      await tester.drag(find.byType(ListView), const Offset(0, -1200));
      await tester.pumpAndSettle();
      expect(find.text('유료 플랜으로 변경'), findsNothing);
      expect(find.text('무료 플랜으로 변경'), findsNothing);
      expect(authSession.plan, plan);
    });
  }

  testWidgets('debug opt-in retains the local paid to free control', (
    tester,
  ) async {
    await authSession.setSessionForTesting(
      plan: UserPlan.paid,
      email: 'debug-paid@example.com',
    );
    await tester.pumpWidget(
      const MaterialApp(home: PlanPage(enableDevelopmentPlanControls: true)),
    );

    final downgrade = find.text('무료 플랜으로 변경');
    await tester.scrollUntilVisible(downgrade, 300);
    await tester.tap(downgrade);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '변경'));
    await tester.pumpAndSettle();

    expect(authSession.isFree, isTrue);
  });

  testWidgets(
    'MyPage keeps sync access and opens plans without debug controls',
    (tester) async {
      await authSession.setSessionForTesting(
        plan: UserPlan.paid,
        email: 'mypage@example.com',
      );

      await tester.pumpWidget(const MaterialApp(home: MyPage()));

      expect(find.text('동기화/충돌 관리'), findsOneWidget);
      await tester.tap(find.text('플랜 정보'));
      await tester.pumpAndSettle();

      expect(find.byType(PlanPage), findsOneWidget);
      expect(find.text('유료 회원'), findsOneWidget);
      await tester.drag(find.byType(ListView), const Offset(0, -1200));
      await tester.pumpAndSettle();
      expect(find.text('유료 플랜으로 변경'), findsNothing);
      expect(find.text('무료 플랜으로 변경'), findsNothing);
    },
  );

  testWidgets('server refresh remains available with development opt-in', (
    tester,
  ) async {
    final gateway = FakeAuthGateway()
      ..seedAccount(
        uid: 'server-plan-user',
        email: 'server-plan@example.com',
        password: 'Password1',
        displayName: '서버회원',
      );
    authSession.configureAuthGateway(gateway);
    expect(
      await authSession.signIn(
        email: 'server-plan@example.com',
        password: 'Password1',
      ),
      AuthSignInResult.success,
    );
    final previousLookups = gateway.entitlementLookupCount;
    await tester.pumpWidget(
      const MaterialApp(home: PlanPage(enableDevelopmentPlanControls: true)),
    );

    final refresh = find.text('서버 플랜 새로고침');
    await tester.scrollUntilVisible(refresh, 300);
    expect(find.text('유료 플랜으로 변경'), findsNothing);
    expect(find.text('무료 플랜으로 변경'), findsNothing);
    await tester.tap(refresh);
    await tester.pumpAndSettle();

    expect(gateway.entitlementLookupCount, previousLookups + 1);
    expect(authSession.isFree, isTrue);
    expect(find.text('서버에서 계정 플랜을 확인했습니다.'), findsOneWidget);
    await expectLater(
      authSession.changeMemberPlan(UserPlan.paid),
      throwsStateError,
    );
  });
}
