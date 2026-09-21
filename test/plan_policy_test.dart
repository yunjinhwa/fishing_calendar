import 'dart:convert';

import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/outbox_item.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/models/user_plan_policy.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/conflict_memory_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/repositories/outbox_repository.dart';
import 'package:fishing_build/data/services/plan_policy_service.dart';
import 'package:fishing_build/data/services/record_mutation_service.dart';
import 'package:fishing_build/core/validation/auth_input_validator.dart';
import 'package:fishing_build/presentation/auth/signup_page.dart';
import 'package:fishing_build/presentation/my_page/my_page.dart';
import 'package:fishing_build/presentation/offline/offline_mode_page.dart';
import 'package:fishing_build/presentation/plan/plan_page.dart';
import 'package:fishing_build/presentation/sync/outbox_page.dart';
import 'package:fishing_build/presentation/sync/sync_conflict_page.dart';
import 'package:fishing_build/presentation/shell/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_database.dart';

void main() {
  final authSession = AuthSessionRepository.instance;
  final outboxRepository = OutboxRepository.instance;
  final conflictRepository = ConflictMemoryRepository.instance;
  final recordRepository = FishingRecordRepository.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await resetTestDatabase();
    authSession.clearMemoryOnlyForTesting();
    outboxRepository.clearCacheOnlyForTesting();
    conflictRepository.clearAll();
    recordRepository.clearCacheOnlyForTesting();
  });

  test('guest, free, and paid plans expose the expected capabilities', () {
    expect(UserPlanPolicy.guest.canManageRecords, isFalse);
    expect(UserPlanPolicy.guest.canUseOfflineRecords, isFalse);
    expect(UserPlanPolicy.guest.canUseCloudSync, isFalse);

    expect(UserPlanPolicy.free.canManageRecords, isTrue);
    expect(UserPlanPolicy.free.canUseOfflineRecords, isTrue);
    expect(UserPlanPolicy.free.storesOriginalLocally, isTrue);
    expect(UserPlanPolicy.free.canUseCloudSync, isFalse);
    expect(UserPlanPolicy.free.usesOutbox, isFalse);

    expect(UserPlanPolicy.paid.canManageRecords, isTrue);
    expect(UserPlanPolicy.paid.canUseOfflineRecords, isTrue);
    expect(UserPlanPolicy.paid.canUseCloudSync, isTrue);
    expect(UserPlanPolicy.paid.usesOutbox, isTrue);
    expect(UserPlanPolicy.paid.storesOriginalLocally, isFalse);
    expect(UserPlanPolicy.paid.localCacheDays, 31);
  });

  test(
    'changed member plan is restored on restart and the next login',
    () async {
      await authSession.registerAsFree(
        email: 'Member@Example.com',
        password: 'Password1',
        nickname: '테스터',
      );
      await PlanPolicyService.instance.changePlan(UserPlan.paid);

      authSession.clearMemoryOnlyForTesting();
      await authSession.loadSession();

      expect(authSession.isPaid, isTrue);
      expect(authSession.canUseCloudSync, isTrue);
      expect(authSession.email, 'member@example.com');

      await authSession.logout();
      await authSession.signIn(
        email: 'member@example.com',
        password: 'Password1',
      );

      expect(authSession.isPaid, isTrue);
      expect(authSession.displayName, '테스터');
    },
  );

  test('login is not restored when remember login is disabled', () async {
    await authSession.registerAsFree(
      email: 'temporary@example.com',
      password: 'Password1',
    );
    await authSession.logout();
    await authSession.signIn(
      email: 'temporary@example.com',
      password: 'Password1',
      rememberSession: false,
    );

    expect(authSession.isFree, isTrue);
    expect(authSession.persistsAcrossRestarts, isFalse);

    authSession.clearMemoryOnlyForTesting();
    await authSession.loadSession();

    expect(authSession.hasActiveSession, isFalse);
    expect(authSession.isGuest, isTrue);
  });

  test('login rejects unknown accounts and incorrect passwords', () async {
    await authSession.registerAsFree(
      email: 'login@example.com',
      password: 'Password1',
    );
    await authSession.logout();

    final unknown = await authSession.signIn(
      email: 'unknown@example.com',
      password: 'Password1',
    );
    expect(unknown, AuthSignInResult.accountNotFound);
    expect(authSession.isGuest, isTrue);

    final incorrect = await authSession.signIn(
      email: 'login@example.com',
      password: 'Password2',
    );
    expect(incorrect, AuthSignInResult.invalidCredentials);
    expect(authSession.isGuest, isTrue);

    final success = await authSession.signIn(
      email: 'LOGIN@example.com',
      password: 'Password1',
    );
    expect(success, AuthSignInResult.success);
    expect(authSession.isFree, isTrue);
  });

  test('an active legacy member sets a password before logging out', () async {
    SharedPreferences.setMockInitialValues({
      'auth_has_active_session': true,
      'auth_plan': 'free',
      'auth_email': 'legacy-member@example.com',
      'auth_nickname': '기존회원',
    });

    await authSession.loadSession();

    expect(authSession.isFree, isTrue);
    expect(authSession.requiresPasswordSetup, isTrue);
    await expectLater(authSession.logout(), throwsStateError);

    await authSession.setPasswordForCurrentMember('Password1');
    expect(authSession.requiresPasswordSetup, isFalse);
    await authSession.logout();

    final incorrect = await authSession.signIn(
      email: 'legacy-member@example.com',
      password: 'Password2',
    );
    expect(incorrect, AuthSignInResult.invalidCredentials);

    final success = await authSession.signIn(
      email: 'legacy-member@example.com',
      password: 'Password1',
    );
    expect(success, AuthSignInResult.success);
    expect(authSession.displayName, '기존회원');
  });

  testWidgets('legacy member can set a password from My Page', (tester) async {
    SharedPreferences.setMockInitialValues({
      'auth_has_active_session': true,
      'auth_plan': 'free',
      'auth_email': 'legacy-ui@example.com',
    });
    await authSession.loadSession();

    await tester.pumpWidget(const MaterialApp(home: MyPage()));
    await tester.tap(find.text('계정 비밀번호 설정 필요'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Password1');
    await tester.enterText(fields.at(1), 'Password1');
    await tester.tap(find.widgetWithText(FilledButton, '설정'));
    await tester.pumpAndSettle();

    expect(authSession.requiresPasswordSetup, isFalse);
    expect(find.text('계정 비밀번호 설정 필요'), findsNothing);
    await authSession.logout();
  });

  test(
    'a legacy account without a password rejects password enrollment',
    () async {
      SharedPreferences.setMockInitialValues({
        'auth_account_plans': jsonEncode({
          'legacy-account@example.com': 'free',
        }),
      });

      final firstAttempt = await authSession.signIn(
        email: 'legacy-account@example.com',
        password: 'Password1',
      );
      final secondAttempt = await authSession.signIn(
        email: 'legacy-account@example.com',
        password: 'Password2',
      );

      expect(firstAttempt, AuthSignInResult.credentialSetupRequired);
      expect(secondAttempt, AuthSignInResult.credentialSetupRequired);
      expect(authSession.hasActiveSession, isFalse);
    },
  );

  test('authentication input rules validate email, password, and nickname', () {
    expect(AuthInputValidator.isValidEmail('member@example.com'), isTrue);
    expect(AuthInputValidator.isValidEmail('member-at-example.com'), isFalse);
    expect(AuthInputValidator.isValidPassword('Password1'), isTrue);
    expect(AuthInputValidator.isValidPassword('password'), isFalse);
    expect(AuthInputValidator.isValidNickname('낚시왕'), isTrue);
    expect(AuthInputValidator.isValidNickname('가'), isFalse);
  });

  testWidgets('login prompt returns to the originally requested member tab', (
    tester,
  ) async {
    await authSession.registerAsFree(
      email: 'return@example.com',
      password: 'Password1',
    );
    await authSession.logout();
    await authSession.continueAsGuest();

    await tester.pumpWidget(const MaterialApp(home: AppShell(initialIndex: 1)));
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '로그인'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'return@example.com');
    await tester.enterText(fields.at(1), 'Password1');
    await tester.tap(find.widgetWithText(FilledButton, '로그인'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    final navigationBar = tester.widget<NavigationBar>(
      find.byType(NavigationBar),
    );
    expect(navigationBar.selectedIndex, 2);
    expect(authSession.isFree, isTrue);
  });

  test('duplicate signup does not overwrite an existing paid plan', () async {
    final registered = await authSession.registerAsFree(
      email: 'existing@example.com',
      password: 'Password1',
    );
    expect(registered, isTrue);
    await PlanPolicyService.instance.changePlan(UserPlan.paid);
    await authSession.logout();

    final duplicate = await authSession.registerAsFree(
      email: 'existing@example.com',
      password: 'Password2',
    );

    expect(duplicate, isFalse);
    await authSession.signIn(
      email: 'existing@example.com',
      password: 'Password1',
    );
    expect(authSession.isPaid, isTrue);
  });

  test('signup recovers from an orphaned credential write', () async {
    SharedPreferences.setMockInitialValues({
      'auth_account_password_hashes': jsonEncode({
        'retry-signup@example.com': 'incomplete-write',
      }),
    });

    final registered = await authSession.registerAsFree(
      email: 'retry-signup@example.com',
      password: 'Password1',
    );
    expect(registered, isTrue);

    await authSession.logout();
    final result = await authSession.signIn(
      email: 'retry-signup@example.com',
      password: 'Password1',
    );
    expect(result, AuthSignInResult.success);
  });

  test('member plans are kept separately by email', () async {
    await authSession.registerAsFree(
      email: 'account-a@example.com',
      password: 'Password1',
    );
    await PlanPolicyService.instance.changePlan(UserPlan.paid);
    await authSession.logout();

    await authSession.registerAsFree(
      email: 'account-b@example.com',
      password: 'Password2',
    );
    expect(authSession.isFree, isTrue);
    await authSession.logout();

    await authSession.signIn(
      email: 'account-a@example.com',
      password: 'Password1',
    );
    expect(authSession.isPaid, isTrue);
  });

  testWidgets('signup page shows a duplicate email message', (tester) async {
    await authSession.setSessionForTesting(
      plan: UserPlan.paid,
      email: 'duplicate@example.com',
      password: 'Password1',
    );
    await authSession.logout();

    await tester.pumpWidget(const MaterialApp(home: SignupPage()));
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'duplicate@example.com');
    await tester.enterText(fields.at(1), 'Password1');
    await tester.enterText(fields.at(2), 'Password1');
    await tester.enterText(fields.at(3), '닉네임');
    await tester.tap(find.text('이용약관 동의 (필수)'));
    await tester.tap(find.text('개인정보 처리방침 동의 (필수)'));
    final submitButton = find.widgetWithText(FilledButton, '가입하기');
    await tester.scrollUntilVisible(
      submitButton,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(submitButton);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(find.text('이미 가입된 이메일입니다. 로그인해 주세요.'), findsOneWidget);
    expect(authSession.hasActiveSession, isFalse);

    await authSession.signIn(
      email: 'duplicate@example.com',
      password: 'Password1',
    );
    expect(authSession.isPaid, isTrue);
  });

  test(
    'upgrade queues existing records before cloud sync is enabled',
    () async {
      await authSession.setSessionForTesting(
        plan: UserPlan.free,
        email: 'migration@example.com',
      );
      final record = _createRecord('migration-record');
      await RecordMutationService.instance.addRecord(record);

      final result = await PlanPolicyService.instance.changePlan(UserPlan.paid);

      expect(result, PlanChangeResult.changed);
      expect(authSession.isPaid, isTrue);
      expect(authSession.isPlanMigrationPending, isTrue);
      expect(authSession.canUseOutbox, isTrue);
      expect(authSession.canUseCloudSync, isFalse);
      final migrationItem = outboxRepository.getAllItems().single;
      expect(migrationItem.recordId, record.id);
      expect(migrationItem.operationType, OutboxOperationType.create);
      expect(migrationItem.isMigration, isTrue);

      await outboxRepository.updateItemStatus(
        itemId: migrationItem.id,
        status: OutboxStatus.succeeded,
      );
      await PlanPolicyService.instance.completeMigrationIfPossible();

      expect(authSession.isPlanMigrationPending, isFalse);
      expect(authSession.canUseCloudSync, isTrue);
    },
  );

  test('pending migration is restored and requeued after restart', () async {
    await authSession.setSessionForTesting(
      plan: UserPlan.free,
      email: 'restart-migration@example.com',
    );
    final record = _createRecord('restart-migration-record');
    await RecordMutationService.instance.addRecord(record);
    await PlanPolicyService.instance.changePlan(UserPlan.paid);
    final originalItem = outboxRepository.getAllItems().single;

    authSession.clearMemoryOnlyForTesting();
    outboxRepository.clearCacheOnlyForTesting();
    recordRepository.clearCacheOnlyForTesting();
    await authSession.loadSession();
    await recordRepository.loadRecords();
    await outboxRepository.loadItems();
    await PlanPolicyService.instance.resumePendingMigration();

    expect(authSession.isPlanMigrationPending, isTrue);
    expect(authSession.canUseCloudSync, isFalse);
    final item = outboxRepository.getAllItems().single;
    expect(item.id, originalItem.id);
    expect(item.recordId, record.id);
    expect(item.isMigration, isTrue);
    expect(item.payload, originalItem.payload);
  });

  test('an interrupted upgrade refreshes a stale migration payload', () async {
    await authSession.setSessionForTesting(
      plan: UserPlan.free,
      email: 'stale-migration@example.com',
    );
    final original = _createRecord(
      'stale-migration-record',
      location: '수정 전 위치',
    );
    await RecordMutationService.instance.addRecord(original);
    await outboxRepository.addItem(
      OutboxItem(
        id: 'stale-migration-item',
        userId: authSession.memberId,
        recordId: original.id,
        operationType: OutboxOperationType.create,
        status: OutboxStatus.pending,
        createdAt: DateTime(2026, 9, 20),
        isMigration: true,
        payload: original.toJson(),
      ),
    );

    await RecordMutationService.instance.updateRecord(
      _createRecord(original.id, location: '수정 후 위치'),
    );
    await PlanPolicyService.instance.changePlan(UserPlan.paid);

    final migrationItem = outboxRepository.getAllItems().single;
    expect(migrationItem.id, 'stale-migration-item');
    expect(migrationItem.payload?['location'], '수정 후 위치');
    expect(migrationItem.status, OutboxStatus.pending);
    expect(authSession.isPlanMigrationPending, isTrue);
  });

  test(
    'an interrupted upgrade removes migration items for deleted records',
    () async {
      await authSession.setSessionForTesting(
        plan: UserPlan.free,
        email: 'deleted-migration@example.com',
      );
      final record = _createRecord('deleted-migration-record');
      await RecordMutationService.instance.addRecord(record);
      await outboxRepository.addItem(
        OutboxItem(
          id: 'deleted-migration-item',
          userId: authSession.memberId,
          recordId: record.id,
          operationType: OutboxOperationType.create,
          status: OutboxStatus.pending,
          createdAt: DateTime(2026, 9, 20),
          isMigration: true,
          payload: record.toJson(),
        ),
      );

      await RecordMutationService.instance.deleteRecord(record.id);
      await PlanPolicyService.instance.changePlan(UserPlan.paid);

      expect(outboxRepository.getAllItems(), isEmpty);
      expect(authSession.isPlanMigrationPending, isFalse);
      expect(authSession.canUseCloudSync, isTrue);
    },
  );

  test(
    'restart reconciliation finishes an interrupted paid mutation',
    () async {
      await authSession.setSessionForTesting(
        plan: UserPlan.paid,
        email: 'reconcile@example.com',
      );
      final original = _createRecord('reconcile-record', location: '로컬 이전 값');
      final updated = _createRecord(original.id, location: 'Outbox 최신 값');
      await recordRepository.addRecord(original);
      await outboxRepository.addItem(
        OutboxItem(
          id: 'reconcile-update',
          userId: authSession.memberId,
          recordId: original.id,
          operationType: OutboxOperationType.update,
          status: OutboxStatus.pending,
          createdAt: DateTime(2026, 9, 20),
          payload: updated.toJson(),
        ),
      );

      recordRepository.clearCacheOnlyForTesting();
      outboxRepository.clearCacheOnlyForTesting();
      await recordRepository.loadRecords();
      await outboxRepository.loadItems();
      await RecordMutationService.instance.reconcileOutboxWithLocalRecords();

      expect(
        recordRepository.getRecordById(original.id)?.location,
        'Outbox 최신 값',
      );

      await outboxRepository.addItem(
        OutboxItem(
          id: 'reconcile-delete',
          userId: authSession.memberId,
          recordId: original.id,
          operationType: OutboxOperationType.delete,
          status: OutboxStatus.pending,
          createdAt: DateTime(2026, 9, 20, 1),
          payload: updated.toJson(),
        ),
      );
      recordRepository.clearCacheOnlyForTesting();
      outboxRepository.clearCacheOnlyForTesting();
      await recordRepository.loadRecords();
      await outboxRepository.loadItems();
      await RecordMutationService.instance.reconcileOutboxWithLocalRecords();

      expect(recordRepository.getRecordById(original.id), isNull);
    },
  );

  test('paid record mutations queue create, update, and delete', () async {
    await authSession.setSessionForTesting(
      plan: UserPlan.paid,
      email: 'paid-records@example.com',
    );
    final record = _createRecord('paid-record');

    await RecordMutationService.instance.addRecord(record);
    await RecordMutationService.instance.updateRecord(
      _createRecord(record.id, location: '수정 위치'),
    );
    await RecordMutationService.instance.deleteRecord(record.id);

    final items = outboxRepository.getAllItems();
    expect(items.map((item) => item.recordId).toSet(), {record.id});
    expect(items.map((item) => item.operationType).toList(), [
      OutboxOperationType.create,
      OutboxOperationType.update,
      OutboxOperationType.delete,
    ]);
  });

  test('free record mutations do not create outbox items', () async {
    await authSession.setSessionForTesting(
      plan: UserPlan.free,
      email: 'free-records@example.com',
    );

    await RecordMutationService.instance.addRecord(
      _createRecord('free-record'),
    );

    expect(outboxRepository.getAllItems(), isEmpty);
  });

  testWidgets('free member sees a paid plan prompt for sync', (tester) async {
    await authSession.setSessionForTesting(
      plan: UserPlan.free,
      email: 'free@example.com',
    );

    await tester.pumpWidget(const MaterialApp(home: MyPage()));
    await tester.tap(find.text('동기화/충돌 관리'));
    await tester.pumpAndSettle();

    expect(find.text('유료 플랜이 필요합니다'), findsOneWidget);
    expect(find.text('플랜 보기'), findsOneWidget);
    expect(conflictRepository.getAllItems(), isEmpty);
  });

  testWidgets('member can change from free to paid on the plan page', (
    tester,
  ) async {
    await authSession.setSessionForTesting(
      plan: UserPlan.free,
      email: 'upgrade@example.com',
    );

    await tester.pumpWidget(const MaterialApp(home: PlanPage()));
    await tester.tap(find.text('유료 플랜으로 변경'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '변경'));
    await tester.pumpAndSettle();

    expect(authSession.isPaid, isTrue);
    expect(find.text('유료 회원'), findsOneWidget);
    expect(find.text('최근 31일 로컬 캐시'), findsOneWidget);
  });

  testWidgets('offline entry opens the page for the current plan', (
    tester,
  ) async {
    await authSession.setSessionForTesting(
      plan: UserPlan.free,
      email: 'free@example.com',
    );
    await tester.pumpWidget(const MaterialApp(home: OfflineModePage()));

    expect(find.textContaining('무료 회원은 이 기기에 저장된'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await authSession.setSessionForTesting(
      plan: UserPlan.paid,
      email: 'paid@example.com',
    );
    await tester.pumpWidget(const MaterialApp(home: OfflineModePage()));

    expect(find.textContaining('유료 회원은 오프라인에서'), findsOneWidget);
  });

  testWidgets('free member cannot open outbox or conflict contents', (
    tester,
  ) async {
    await authSession.setSessionForTesting(
      plan: UserPlan.free,
      email: 'free@example.com',
    );

    await tester.pumpWidget(const MaterialApp(home: OutboxPage()));
    expect(find.text('유료 플랜이 필요합니다'), findsOneWidget);
    expect(outboxRepository.getAllItems(), isEmpty);

    await tester.pumpWidget(const MaterialApp(home: SyncConflictPage()));
    expect(find.text('유료 플랜이 필요합니다'), findsOneWidget);
    expect(conflictRepository.getAllItems(), isEmpty);
  });

  testWidgets('upgrading from the outbox gate opens an empty real queue', (
    tester,
  ) async {
    await authSession.setSessionForTesting(
      plan: UserPlan.free,
      email: 'gate-upgrade@example.com',
    );

    await tester.pumpWidget(const MaterialApp(home: OutboxPage()));
    await tester.tap(find.text('플랜 보기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('유료 플랜으로 변경'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '변경'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(authSession.isPaid, isTrue);
    expect(find.text('업로드 대기열이 비어 있습니다.'), findsOneWidget);
    expect(outboxRepository.getAllItems(), isEmpty);
  });

  testWidgets('paid member can open empty sync and outbox screens', (
    tester,
  ) async {
    await authSession.setSessionForTesting(
      plan: UserPlan.paid,
      email: 'paid@example.com',
    );

    await tester.pumpWidget(const MaterialApp(home: SyncConflictPage()));
    expect(find.text('충돌 알림'), findsOneWidget);
    expect(find.text('충돌 알림이 없습니다.'), findsOneWidget);
    expect(conflictRepository.getAllItems(), isEmpty);

    await tester.pumpWidget(const MaterialApp(home: OutboxPage()));
    expect(find.text('업로드 대기열이 비어 있습니다.'), findsOneWidget);
    expect(outboxRepository.getAllItems(), isEmpty);
  });

  testWidgets('uploading all migration items enables cloud sync', (
    tester,
  ) async {
    await authSession.setSessionForTesting(
      plan: UserPlan.free,
      email: 'upload-migration@example.com',
    );
    await RecordMutationService.instance.addRecord(
      _createRecord('upload-migration-record'),
    );
    await PlanPolicyService.instance.changePlan(UserPlan.paid);
    expect(authSession.canUseCloudSync, isFalse);

    await tester.pumpWidget(const MaterialApp(home: OutboxPage()));
    await tester.tap(find.byTooltip('전체 전송 처리'));
    await tester.pumpAndSettle();

    expect(authSession.isPlanMigrationPending, isFalse);
    expect(authSession.canUseCloudSync, isTrue);
    expect(
      outboxRepository.getAllItems().every(
        (item) => item.status == OutboxStatus.succeeded,
      ),
      isTrue,
    );
  });

  test('pending outbox blocks downgrade until uploads are completed', () async {
    await authSession.setSessionForTesting(
      plan: UserPlan.paid,
      email: 'downgrade@example.com',
    );
    final pendingItem = OutboxItem(
      id: 'pending-before-downgrade',
      recordId: 'record-before-downgrade',
      operationType: OutboxOperationType.update,
      status: OutboxStatus.pending,
      createdAt: DateTime(2026, 9, 20),
    );
    await outboxRepository.addItem(pendingItem);

    final blocked = await PlanPolicyService.instance.changePlan(UserPlan.free);

    expect(blocked, PlanChangeResult.blockedByPendingUploads);
    expect(authSession.isPaid, isTrue);

    await outboxRepository.updateItemStatus(
      itemId: pendingItem.id,
      status: OutboxStatus.succeeded,
    );
    final changed = await PlanPolicyService.instance.changePlan(UserPlan.free);

    expect(changed, PlanChangeResult.changed);
    expect(authSession.isFree, isTrue);
    expect(authSession.canManageRecords, isTrue);
    expect(authSession.canUseCloudSync, isFalse);
    expect(authSession.canUseOutbox, isFalse);
  });

  test(
    'a newly signed-in account cannot claim unowned legacy records',
    () async {
      final legacyRecord = _createRecord('unowned-legacy-record');
      SharedPreferences.setMockInitialValues({
        'fishing_records': jsonEncode([legacyRecord.toJson()]),
      });

      await authSession.registerAsFree(
        email: 'new-owner@example.com',
        password: 'Password1',
      );
      await recordRepository.loadRecords();

      expect(recordRepository.getAllRecords(), isEmpty);
      expect(recordRepository.hasQuarantinedLegacyData, isTrue);
      var prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('fishing_records'), isNotNull);

      authSession.clearMemoryOnlyForTesting();
      recordRepository.clearCacheOnlyForTesting();
      await authSession.loadSession();
      await recordRepository.loadRecords();

      expect(recordRepository.getAllRecords(), isEmpty);
      prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('fishing_records'), isNotNull);
    },
  );

  test(
    'a restored legacy member imports ownerless records only explicitly',
    () async {
      final legacyRecord = _createRecord('owned-legacy-record');
      SharedPreferences.setMockInitialValues({
        'auth_has_active_session': true,
        'auth_plan': 'free',
        'auth_email': 'legacy-owner@example.com',
        'fishing_records': jsonEncode([legacyRecord.toJson()]),
      });

      await authSession.loadSession();
      await recordRepository.loadRecords();

      expect(authSession.isFree, isTrue);
      expect(recordRepository.getAllRecords(), isEmpty);
      expect(recordRepository.quarantinedLegacyRecordCount, 1);
      var prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('fishing_records'), isNotNull);

      final importedCount = await recordRepository
          .importQuarantinedLegacyRecords();

      expect(importedCount, 1);
      expect(recordRepository.getAllRecords().single.id, legacyRecord.id);
      expect(recordRepository.hasQuarantinedLegacyData, isFalse);
      prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('fishing_records'), isNull);
    },
  );

  test('an invalid legacy identity cannot claim or orphan records', () async {
    final legacyRecord = _createRecord('invalid-owner-record');
    SharedPreferences.setMockInitialValues({
      'auth_has_active_session': true,
      'auth_plan': 'free',
      'auth_email': 'invalid-email',
      'fishing_records': jsonEncode([legacyRecord.toJson()]),
    });

    await authSession.loadSession();
    await recordRepository.loadRecords();

    expect(authSession.isGuest, isTrue);
    expect(recordRepository.getAllRecords(), isEmpty);
    await expectLater(
      recordRepository.importQuarantinedLegacyRecords(),
      throwsStateError,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('fishing_records'), isNotNull);
  });

  test('records and outbox items are isolated by member account', () async {
    await authSession.setSessionForTesting(
      plan: UserPlan.paid,
      email: 'account-a@example.com',
      password: 'Password1',
    );
    await RecordMutationService.instance.addRecord(
      _createRecord('account-a-record'),
    );

    expect(recordRepository.getAllRecords(), hasLength(1));
    expect(outboxRepository.getAllItems(), hasLength(1));

    await authSession.logout();
    await authSession.setSessionForTesting(
      plan: UserPlan.paid,
      email: 'account-b@example.com',
    );

    expect(recordRepository.getAllRecords(), isEmpty);
    expect(outboxRepository.getAllItems(), isEmpty);

    recordRepository.clearCacheOnlyForTesting();
    outboxRepository.clearCacheOnlyForTesting();
    await recordRepository.loadRecords();
    await outboxRepository.loadItems();
    expect(recordRepository.getAllRecords(), isEmpty);
    expect(outboxRepository.getAllItems(), isEmpty);

    await authSession.logout();
    await authSession.signIn(
      email: 'account-a@example.com',
      password: 'Password1',
    );
    await recordRepository.loadRecords();
    await outboxRepository.loadItems();

    expect(recordRepository.getAllRecords().single.id, 'account-a-record');
    expect(outboxRepository.getAllItems().single.recordId, 'account-a-record');
  });

  test('paid delete outbox keeps its payload across an app restart', () async {
    await authSession.setSessionForTesting(
      plan: UserPlan.paid,
      email: 'persistent-outbox@example.com',
    );
    final record = _createRecord(
      'persistent-delete-record',
      location: '삭제 전 위치',
    );

    await RecordMutationService.instance.addRecord(record);
    await RecordMutationService.instance.deleteRecord(record.id);

    final deleteItem = outboxRepository.getAllItems().singleWhere(
      (item) => item.operationType == OutboxOperationType.delete,
    );
    expect(deleteItem.userId, 'persistent-outbox@example.com');
    expect(deleteItem.payload?['location'], '삭제 전 위치');
    expect(recordRepository.getAllRecords(), isEmpty);

    outboxRepository.clearCacheOnlyForTesting();
    await outboxRepository.loadItems();

    final restoredDeleteItem = outboxRepository.getAllItems().singleWhere(
      (item) => item.operationType == OutboxOperationType.delete,
    );
    expect(restoredDeleteItem.recordId, record.id);
    expect(restoredDeleteItem.payload?['location'], '삭제 전 위치');
  });

  test('sending outbox item blocks a paid to free change', () async {
    await authSession.setSessionForTesting(
      plan: UserPlan.paid,
      email: 'sending@example.com',
    );
    await outboxRepository.addItem(
      OutboxItem(
        id: 'sending-item',
        userId: 'sending@example.com',
        recordId: 'sending-record',
        operationType: OutboxOperationType.update,
        status: OutboxStatus.sending,
        createdAt: DateTime(2026, 9, 20),
      ),
    );

    final result = await PlanPolicyService.instance.changePlan(UserPlan.free);

    expect(result, PlanChangeResult.blockedByPendingUploads);
    expect(authSession.isPaid, isTrue);
  });

  test('migration evidence is kept while migration is pending', () async {
    await authSession.setSessionForTesting(
      plan: UserPlan.free,
      email: 'migration-cleanup@example.com',
    );
    await RecordMutationService.instance.addRecord(
      _createRecord('migration-cleanup-1'),
    );
    await RecordMutationService.instance.addRecord(
      _createRecord('migration-cleanup-2'),
    );
    await PlanPolicyService.instance.changePlan(UserPlan.paid);

    final migrationItems = outboxRepository.getAllItems();
    await outboxRepository.updateItemStatus(
      itemId: migrationItems.first.id,
      status: OutboxStatus.succeeded,
    );
    await outboxRepository.clearSucceeded(includeMigration: false);

    expect(
      outboxRepository.getAllItems().any(
        (item) =>
            item.id == migrationItems.first.id &&
            item.status == OutboxStatus.succeeded,
      ),
      isTrue,
    );

    await outboxRepository.updateItemStatus(
      itemId: migrationItems.last.id,
      status: OutboxStatus.succeeded,
    );
    await PlanPolicyService.instance.completeMigrationIfPossible();

    expect(authSession.isPlanMigrationPending, isFalse);
    expect(authSession.canUseCloudSync, isTrue);
  });

  test('record mutation service rejects guest writes', () async {
    await expectLater(
      RecordMutationService.instance.addRecord(_createRecord('guest-record')),
      throwsStateError,
    );

    expect(recordRepository.getAllRecords(), isEmpty);
    expect(outboxRepository.getAllItems(), isEmpty);
  });

  test('outbox retry clears the previous failure message', () async {
    final item = OutboxItem(
      id: 'outbox-test',
      recordId: 'record-test',
      operationType: OutboxOperationType.update,
      status: OutboxStatus.failed,
      createdAt: DateTime(2026, 9, 20),
      errorMessage: '네트워크 오류',
    );
    await outboxRepository.addItem(item);

    await outboxRepository.retryItem(item.id);

    final retried = outboxRepository.getAllItems().single;
    expect(retried.status, OutboxStatus.pending);
    expect(retried.errorMessage, isNull);
    expect(retried.retryCount, 1);
  });
}

FishingRecord _createRecord(String id, {String location = '테스트 포인트'}) {
  final startAt = DateTime(2026, 9, 20, 6);
  return FishingRecord(
    id: id,
    location: location,
    startAt: startAt,
    endAt: startAt.add(const Duration(hours: 2)),
    genreName: '루어',
    tide: '7물',
    weather: '맑음',
    airTemperature: 21,
    waterTemperature: 18,
  );
}
