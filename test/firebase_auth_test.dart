import 'dart:async';
import 'dart:convert';

import 'package:fishing_build/data/auth/auth_gateway.dart';
import 'package:fishing_build/data/auth/nickname_policy.dart';
import 'package:fishing_build/data/local/app_database.dart';
import 'package:fishing_build/data/local/data_owner_key.dart';
import 'package:fishing_build/data/local/local_data_store.dart';
import 'package:fishing_build/data/models/conflict_item.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/outbox_item.dart';
import 'package:fishing_build/data/models/plan_entitlement.dart';
import 'package:fishing_build/data/models/record_sync_metadata.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/repositories/outbox_repository.dart';
import 'package:fishing_build/data/services/plan_policy_service.dart';
import 'package:fishing_build/data/services/record_mutation_service.dart';
import 'package:fishing_build/presentation/auth/login_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_database.dart';

void main() {
  final authSession = AuthSessionRepository.instance;
  final recordRepository = FishingRecordRepository.instance;
  final outboxRepository = OutboxRepository.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await resetTestDatabase();
    authSession.resetAuthGatewayForTesting();
    recordRepository.clearCacheOnlyForTesting();
    outboxRepository.clearCacheOnlyForTesting();
  });

  tearDown(() {
    authSession.resetAuthGatewayForTesting();
  });

  test(
    'Firebase registration uses UID ownership and exposes an ID token',
    () async {
      final gateway = FakeAuthGateway();
      authSession.configureAuthGateway(gateway);

      final registered = await authSession.registerAsFree(
        email: 'Member@Example.com',
        password: 'Password1',
        nickname: '낚시왕',
      );

      expect(registered, isTrue);
      expect(authSession.isFree, isTrue);
      expect(authSession.email, 'member@example.com');
      expect(authSession.memberId, 'uid-1');
      expect(authSession.dataOwnerKey, 'member:uid:uid-1');
      expect(authSession.displayName, '낚시왕');
      expect(await authSession.getIdToken(), 'token-uid-1');

      final prefs = await SharedPreferences.getInstance();
      final hashes =
          jsonDecode(prefs.getString('auth_account_password_hashes') ?? '{}')
              as Map<String, dynamic>;
      expect(hashes, isNot(contains('member@example.com')));
    },
  );

  test('Firebase restores its native session on app restart', () async {
    final gateway = FakeAuthGateway();
    authSession.configureAuthGateway(gateway);
    await authSession.registerAsFree(
      email: 'restore@example.com',
      password: 'Password1',
      nickname: '복원회원',
    );

    authSession.clearMemoryOnlyForTesting();
    await authSession.loadSession();

    expect(authSession.isFree, isTrue);
    expect(authSession.memberId, 'uid-1');
    expect(authSession.displayName, '복원회원');
    expect(gateway.restoreCount, 1);
  });

  test(
    'Firebase session restoration uses the nickname cache offline',
    () async {
      final gateway = FakeAuthGateway();
      authSession.configureAuthGateway(gateway);
      await authSession.registerAsFree(
        email: 'offline-restore@example.com',
        password: 'Password1',
        nickname: '오프라인회원',
      );
      gateway.nicknameLookupFailure = const AuthFailure(
        code: AuthFailureCode.networkUnavailable,
        message: 'offline',
      );

      authSession.clearMemoryOnlyForTesting();
      await authSession.loadSession();

      expect(authSession.isFree, isTrue);
      expect(authSession.memberId, 'uid-1');
      expect(authSession.displayName, '오프라인회원');
    },
  );

  test(
    'interactive Firebase sign-in still requires the nickname server',
    () async {
      final gateway = FakeAuthGateway();
      authSession.configureAuthGateway(gateway);
      await authSession.registerAsFree(
        email: 'online-sign-in@example.com',
        password: 'Password1',
        nickname: '온라인회원',
      );
      await authSession.logout();
      gateway.nicknameLookupFailure = const AuthFailure(
        code: AuthFailureCode.networkUnavailable,
        message: 'offline',
      );

      await expectLater(
        authSession.signIn(
          email: 'online-sign-in@example.com',
          password: 'Password1',
        ),
        throwsA(
          isA<AuthFailure>().having(
            (failure) => failure.code,
            'code',
            AuthFailureCode.networkUnavailable,
          ),
        ),
      );
      expect(authSession.hasActiveSession, isFalse);
    },
  );

  test(
    'interactive Firebase sign-in requires the deletion marker server check',
    () async {
      final gateway = FakeAuthGateway();
      authSession.configureAuthGateway(gateway);
      await authSession.registerAsFree(
        email: 'deletion-check@example.com',
        password: 'Password1',
        nickname: '삭제확인회원',
      );
      await authSession.logout();
      gateway.accountDeletionLookupFailure = const AuthFailure(
        code: AuthFailureCode.networkUnavailable,
        message: 'offline',
      );

      await expectLater(
        authSession.signIn(
          email: 'deletion-check@example.com',
          password: 'Password1',
        ),
        throwsA(
          isA<AuthFailure>().having(
            (failure) => failure.code,
            'code',
            AuthFailureCode.networkUnavailable,
          ),
        ),
      );
      expect(authSession.hasActiveSession, isFalse);
    },
  );

  test(
    'Firebase rejects duplicate nicknames after trimming and lowercasing',
    () async {
      final gateway = FakeAuthGateway();
      authSession.configureAuthGateway(gateway);

      expect(
        await authSession.registerAsFree(
          email: 'first@example.com',
          password: 'Password1',
          nickname: 'Fisher',
        ),
        isTrue,
      );
      await authSession.logout();

      await expectLater(
        authSession.registerAsFree(
          email: 'second@example.com',
          password: 'Password1',
          nickname: ' fisher ',
        ),
        throwsA(
          isA<AuthFailure>().having(
            (failure) => failure.code,
            'code',
            AuthFailureCode.nicknameAlreadyInUse,
          ),
        ),
      );

      expect(gateway.hasAccount('first@example.com'), isTrue);
      expect(gateway.hasAccount('second@example.com'), isFalse);
      expect(gateway.deleteCount, 1);
      expect(gateway.currentUser, isNull);
    },
  );

  test(
    'an existing account can replace an unclaimed duplicate nickname',
    () async {
      final gateway = FakeAuthGateway()
        ..seedAccount(
          uid: 'nickname-owner',
          email: 'owner@example.com',
          password: 'Password1',
          displayName: '낚시왕',
        )
        ..seedAccount(
          uid: 'legacy-user',
          email: 'legacy-user@example.com',
          password: 'Password1',
          displayName: '낚시왕',
          claimNickname: false,
        );
      authSession.configureAuthGateway(gateway);

      await expectLater(
        authSession.signIn(
          email: 'legacy-user@example.com',
          password: 'Password1',
        ),
        throwsA(
          isA<AuthFailure>().having(
            (failure) => failure.code,
            'code',
            AuthFailureCode.nicknameAlreadyInUse,
          ),
        ),
      );

      expect(
        await authSession.signIn(
          email: 'legacy-user@example.com',
          password: 'Password1',
          nickname: '새낚시왕',
        ),
        AuthSignInResult.success,
      );
      expect(authSession.displayName, '새낚시왕');
      expect(await gateway.getRegisteredNickname('legacy-user'), '새낚시왕');
    },
  );

  testWidgets('login prompts for a replacement when a nickname is taken', (
    tester,
  ) async {
    final gateway = FakeAuthGateway()
      ..seedAccount(
        uid: 'nickname-owner',
        email: 'owner@example.com',
        password: 'Password1',
        displayName: '중복닉네임',
      )
      ..seedAccount(
        uid: 'login-user',
        email: 'login-user@example.com',
        password: 'Password1',
        displayName: '중복닉네임',
        claimNickname: false,
      );
    authSession.configureAuthGateway(gateway);

    await tester.pumpWidget(const MaterialApp(home: LoginPage()));
    final loginFields = find.byType(TextField);
    await tester.enterText(loginFields.at(0), 'login-user@example.com');
    await tester.enterText(loginFields.at(1), 'Password1');
    await tester.tap(find.widgetWithText(FilledButton, '로그인'));
    await tester.pumpAndSettle();

    expect(find.text('닉네임 설정'), findsOneWidget);
    expect(find.textContaining('이미 사용 중입니다'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '새로그인회원');
    await tester.tap(find.widgetWithText(FilledButton, '확인'));
    await tester.pumpAndSettle();

    expect(authSession.isFree, isTrue);
    expect(authSession.displayName, '새로그인회원');
    expect(find.text('닉네임 설정'), findsNothing);
  });

  test(
    'legacy records remain recoverable when nickname migration conflicts',
    () async {
      const email = 'nickname-migration@example.com';
      await authSession.setSessionForTesting(
        plan: UserPlan.free,
        email: email,
        nickname: '중복회원',
        password: 'Password1',
      );
      await recordRepository.addRecord(_record('nickname-conflict-record'));
      await authSession.logout();

      final gateway = FakeAuthGateway()
        ..seedAccount(
          uid: 'nickname-owner',
          email: 'owner@example.com',
          password: 'Password1',
          displayName: '중복회원',
        );
      authSession.configureAuthGateway(gateway);

      await expectLater(
        authSession.signIn(email: email, password: 'Password1'),
        throwsA(
          isA<AuthFailure>().having(
            (failure) => failure.code,
            'code',
            AuthFailureCode.nicknameAlreadyInUse,
          ),
        ),
      );

      expect(
        await authSession.signIn(
          email: email,
          password: 'Password1',
          nickname: '이전완료회원',
        ),
        AuthSignInResult.success,
      );
      await recordRepository.loadRecords();
      expect(
        recordRepository.getAllRecords().single.id,
        'nickname-conflict-record',
      );
      expect(authSession.displayName, '이전완료회원');
    },
  );

  test(
    'remember-login off signs the native Firebase user out on restart',
    () async {
      final gateway = FakeAuthGateway();
      authSession.configureAuthGateway(gateway);
      await authSession.registerAsFree(
        email: 'temporary@example.com',
        password: 'Password1',
        nickname: '임시회원',
        rememberSession: false,
      );

      expect(authSession.isFree, isTrue);
      expect(authSession.persistsAcrossRestarts, isFalse);

      authSession.clearMemoryOnlyForTesting();
      await authSession.loadSession();

      expect(authSession.hasActiveSession, isFalse);
      expect(gateway.currentUser, isNull);
      expect(gateway.signOutCount, 1);
    },
  );

  test(
    'remember-login off is saved before Firebase sign-in completes',
    () async {
      final gateway = FakeAuthGateway()
        ..seedAccount(
          uid: 'existing-uid',
          email: 'early-marker@example.com',
          password: 'Password1',
          displayName: '기존회원',
        )
        ..signInGate = Completer<void>()
        ..signInStarted = Completer<void>();
      authSession.configureAuthGateway(gateway);

      final signIn = authSession.signIn(
        email: 'early-marker@example.com',
        password: 'Password1',
        rememberSession: false,
      );
      await gateway.signInStarted!.future;

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('auth_sign_out_on_restart'), isTrue);

      gateway.signInGate!.complete();
      expect(await signIn, AuthSignInResult.success);
    },
  );

  test(
    'remember-login off is saved before Firebase registration completes',
    () async {
      final gateway = FakeAuthGateway()
        ..registrationGate = Completer<void>()
        ..registrationStarted = Completer<void>();
      authSession.configureAuthGateway(gateway);

      final registration = authSession.registerAsFree(
        email: 'early-registration-marker@example.com',
        password: 'Password1',
        nickname: '가입회원',
        rememberSession: false,
      );
      await gateway.registrationStarted!.future;

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('auth_sign_out_on_restart'), isTrue);

      gateway.registrationGate!.complete();
      expect(await registration, isTrue);
    },
  );

  test('guest choice keeps a pending sign-out when Firebase is down', () async {
    final availableGateway = FakeAuthGateway()
      ..seedAccount(
        uid: 'cached-uid',
        email: 'cached@example.com',
        password: 'Password1',
      );
    await availableGateway.signInWithEmailAndPassword(
      email: 'cached@example.com',
      password: 'Password1',
    );
    authSession.configureAuthGateway(
      const UnavailableAuthGateway(
        AuthFailure(
          code: AuthFailureCode.networkUnavailable,
          message: 'offline',
        ),
      ),
    );

    await authSession.continueAsGuest();
    var prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('auth_sign_out_on_restart'), isTrue);
    expect(authSession.isGuest, isTrue);

    authSession.configureAuthGateway(availableGateway);
    authSession.clearMemoryOnlyForTesting();
    await authSession.loadSession();

    prefs = await SharedPreferences.getInstance();
    expect(availableGateway.currentUser, isNull);
    expect(prefs.getBool('auth_sign_out_on_restart'), isNull);
    expect(authSession.hasActiveSession, isTrue);
    expect(authSession.isGuest, isTrue);
  });

  test(
    'legacy email records, outbox, plan, and nickname migrate to Firebase UID',
    () async {
      await authSession.setSessionForTesting(
        plan: UserPlan.paid,
        email: 'legacy@example.com',
        nickname: '기존회원',
        password: 'Password1',
        migrationStatus: PlanMigrationStatus.localToCloudPending,
      );
      await RecordMutationService.instance.addRecord(_record('legacy-record'));
      await authSession.logout();

      final gateway = FakeAuthGateway()
        ..seedEntitlement(uid: 'uid-1', plan: UserPlan.paid);
      authSession.configureAuthGateway(gateway);
      final result = await authSession.signIn(
        email: 'LEGACY@example.com',
        password: 'Password1',
      );
      await recordRepository.loadRecords();
      await outboxRepository.loadItems();

      expect(result, AuthSignInResult.success);
      expect(authSession.memberId, 'uid-1');
      expect(authSession.isPaid, isTrue);
      expect(authSession.isPlanMigrationPending, isTrue);
      expect(authSession.displayName, '기존회원');
      final migratedRecord = recordRepository.getAllRecords().single;
      expect(migratedRecord.id, 'legacy-record');
      expect(migratedRecord.catches.single.speciesName, '농어');
      expect(migratedRecord.photoPaths.single, '/tmp/catch.jpg');
      expect(outboxRepository.getAllItems().single.userId, 'uid-1');

      final store = LocalDataStore.instance;
      final database = await AppDatabase.instance.database;
      expect(
        await store.readRecordsForOwner(
          DataOwnerKey.legacyEmail('legacy@example.com'),
        ),
        isEmpty,
      );
      expect(
        await store.readOutboxItemsForOwner(
          DataOwnerKey.legacyEmail('legacy@example.com'),
        ),
        isEmpty,
      );
      expect(
        await store.readRecordsForOwner(authSession.dataOwnerKey),
        hasLength(1),
      );
      expect(database.isOpen, isTrue);
    },
  );

  test(
    'legacy session without a password can set one and migrate to Firebase UID',
    () async {
      const email = 'password-setup@example.com';
      SharedPreferences.setMockInitialValues(<String, Object>{
        'auth_has_active_session': true,
        'auth_plan': UserPlan.paid.storageValue,
        'auth_email': email,
        'auth_nickname': 'Legacy member',
      });
      final gateway = FakeAuthGateway();
      authSession.configureAuthGateway(gateway);

      await authSession.loadSession();

      expect(authSession.isPaid, isTrue);
      expect(authSession.requiresPasswordSetup, isTrue);
      expect(authSession.dataOwnerKey, DataOwnerKey.legacyEmail(email));
      expect(authSession.canUseCloudSync, isFalse);
      await expectLater(authSession.logout(), throwsStateError);

      await RecordMutationService.instance.addRecord(
        _record('password-setup-record'),
      );
      await authSession.setPasswordForCurrentMember('Password1');
      expect(authSession.requiresPasswordSetup, isFalse);
      await authSession.logout();

      expect(
        await authSession.signIn(email: email, password: 'Password1'),
        AuthSignInResult.success,
      );
      await recordRepository.loadRecords();
      await outboxRepository.loadItems();

      expect(authSession.memberId, 'uid-1');
      expect(authSession.dataOwnerKey, DataOwnerKey.firebaseUid('uid-1'));
      expect(
        recordRepository.getAllRecords().single.id,
        'password-setup-record',
      );
      expect(outboxRepository.getAllItems().single.userId, 'uid-1');
      expect(
        await LocalDataStore.instance.readRecordsForOwner(
          DataOwnerKey.legacyEmail(email),
        ),
        isEmpty,
      );
    },
  );

  test(
    'an existing Firebase account cannot claim legacy data without its local password',
    () async {
      const email = 'protected@example.com';
      await authSession.setSessionForTesting(
        plan: UserPlan.paid,
        email: email,
        nickname: '로컬회원',
        password: 'Password1',
      );
      await recordRepository.addRecord(_record('protected-record'));
      await authSession.logout();

      final gateway = FakeAuthGateway()
        ..seedAccount(
          uid: 'existing-firebase-uid',
          email: email,
          password: 'Different2',
          displayName: 'Firebase회원',
        );
      authSession.configureAuthGateway(gateway);
      final result = await authSession.signIn(
        email: email,
        password: 'Different2',
      );
      await recordRepository.loadRecords();

      expect(result, AuthSignInResult.success);
      expect(authSession.memberId, 'existing-firebase-uid');
      expect(authSession.isFree, isTrue);
      expect(authSession.displayName, 'Firebase회원');
      expect(recordRepository.getAllRecords(), isEmpty);
      expect(
        await LocalDataStore.instance.readRecordsForOwner(
          DataOwnerKey.legacyEmail(email),
        ),
        hasLength(1),
      );
      final prefs = await SharedPreferences.getInstance();
      final hashes =
          jsonDecode(prefs.getString('auth_account_password_hashes')!)
              as Map<String, dynamic>;
      expect(hashes, contains(email));
    },
  );

  test('identity migration is idempotent for the same Firebase UID', () async {
    await authSession.setSessionForTesting(
      plan: UserPlan.free,
      email: 'repeat@example.com',
      nickname: '반복회원',
      password: 'Password1',
    );
    await recordRepository.addRecord(_record('repeat-record'));
    await authSession.logout();

    final gateway = FakeAuthGateway();
    authSession.configureAuthGateway(gateway);
    await authSession.signIn(
      email: 'repeat@example.com',
      password: 'Password1',
    );
    await authSession.logout();
    await authSession.signIn(
      email: 'repeat@example.com',
      password: 'Password1',
    );
    await recordRepository.loadRecords();

    expect(recordRepository.getAllRecords().single.id, 'repeat-record');
  });

  test('identity migration moves sync metadata and conflicts', () async {
    const email = 'sync-identity@example.com';
    await authSession.setSessionForTesting(
      plan: UserPlan.paid,
      email: email,
      nickname: '동기화회원',
      password: 'Password1',
    );
    final sourceOwner = authSession.dataOwnerKey;
    final record = _record('sync-identity-record');
    await RecordMutationService.instance.addRecord(record);
    final outboxItem = outboxRepository.getAllItems().single;
    await AppDatabase.instance.transaction((transaction) {
      return LocalDataStore.instance.insertConflict(
        transaction,
        conflict: ConflictItem(
          id: 'sync-identity-conflict',
          ownerKey: sourceOwner,
          recordId: record.id,
          outboxId: outboxItem.id,
          localOperationType: OutboxOperationType.create,
          baseVersionNo: 0,
          remoteVersionNo: 0,
          remoteStatus: RemoteRecordStatus.missing,
          localRecord: record,
          remoteRecord: null,
          occurredAt: DateTime(2026, 9, 28),
          status: ConflictStatus.unresolved,
        ),
      );
    });
    await authSession.logout();

    final gateway = FakeAuthGateway();
    authSession.configureAuthGateway(gateway);
    expect(
      await authSession.signIn(email: email, password: 'Password1'),
      AuthSignInResult.success,
    );
    final targetOwner = authSession.dataOwnerKey;

    expect(targetOwner, isNot(sourceOwner));
    expect(
      await LocalDataStore.instance.readRecordSyncMetadata(
        targetOwner,
        record.id,
      ),
      isNotNull,
    );
    expect(
      await LocalDataStore.instance.readConflictsForOwner(targetOwner),
      hasLength(1),
    );
    expect(
      await LocalDataStore.instance.readRecordSyncMetadata(
        sourceOwner,
        record.id,
      ),
      isNull,
    );
    expect(
      await LocalDataStore.instance.readConflictsForOwner(sourceOwner),
      isEmpty,
    );
  });

  test('owner-key collisions roll back without mixing account data', () async {
    const email = 'collision@example.com';
    await authSession.setSessionForTesting(
      plan: UserPlan.free,
      email: email,
      password: 'Password1',
    );
    await recordRepository.addRecord(_record('same-id', location: 'legacy'));
    await authSession.logout();

    final gateway = FakeAuthGateway()
      ..seedAccount(uid: 'remote-uid', email: email, password: 'Password1');
    final targetOwner = DataOwnerKey.firebaseUid('remote-uid');
    await AppDatabase.instance.transaction((transaction) async {
      await LocalDataStore.instance.insertRecord(
        transaction,
        ownerKey: targetOwner,
        record: _record('same-id', location: 'firebase'),
      );
    });
    authSession.configureAuthGateway(gateway);

    await expectLater(
      authSession.signIn(email: email, password: 'Password1'),
      throwsA(
        isA<AuthFailure>().having(
          (failure) => failure.code,
          'code',
          AuthFailureCode.accountConflict,
        ),
      ),
    );

    expect(authSession.hasActiveSession, isFalse);
    expect(
      (await LocalDataStore.instance.readRecordsForOwner(
        DataOwnerKey.legacyEmail(email),
      )).single.location,
      'legacy',
    );
    expect(
      (await LocalDataStore.instance.readRecordsForOwner(
        targetOwner,
      )).single.location,
      'firebase',
    );
  });

  test(
    'outbox record collisions roll back before target UID data can be changed',
    () async {
      const email = 'outbox-collision@example.com';
      const recordId = 'shared-record-id';
      await authSession.setSessionForTesting(
        plan: UserPlan.free,
        email: email,
        password: 'Password1',
      );
      await authSession.logout();

      final sourceOwner = DataOwnerKey.legacyEmail(email);
      final targetOwner = DataOwnerKey.firebaseUid('remote-uid');
      await AppDatabase.instance.transaction((transaction) async {
        await LocalDataStore.instance.insertOutboxItem(
          transaction,
          ownerKey: sourceOwner,
          item: OutboxItem(
            id: 'legacy-delete-request',
            userId: email,
            recordId: recordId,
            operationType: OutboxOperationType.delete,
            status: OutboxStatus.pending,
            createdAt: DateTime(2026, 9, 22),
          ),
        );
        await LocalDataStore.instance.insertRecord(
          transaction,
          ownerKey: targetOwner,
          record: _record(recordId, location: 'firebase'),
        );
      });

      final gateway = FakeAuthGateway()
        ..seedAccount(uid: 'remote-uid', email: email, password: 'Password1');
      authSession.configureAuthGateway(gateway);

      await expectLater(
        authSession.signIn(email: email, password: 'Password1'),
        throwsA(
          isA<AuthFailure>().having(
            (failure) => failure.code,
            'code',
            AuthFailureCode.accountConflict,
          ),
        ),
      );

      expect(authSession.hasActiveSession, isFalse);
      expect(
        (await LocalDataStore.instance.readRecordsForOwner(
          targetOwner,
        )).single.location,
        'firebase',
      );
      expect(
        (await LocalDataStore.instance.readOutboxItemsForOwner(
          sourceOwner,
        )).single.recordId,
        recordId,
      );
      expect(
        await LocalDataStore.instance.readOutboxItemsForOwner(targetOwner),
        isEmpty,
      );
    },
  );

  test(
    'an unavailable Firebase gateway never falls back to local passwords',
    () async {
      await authSession.setSessionForTesting(
        plan: UserPlan.free,
        email: 'local@example.com',
        password: 'Password1',
      );
      await authSession.logout();
      const failure = AuthFailure(
        code: AuthFailureCode.initializationFailed,
        message: 'not configured',
      );
      authSession.configureAuthGateway(const UnavailableAuthGateway(failure));

      await expectLater(
        authSession.signIn(email: 'local@example.com', password: 'Password1'),
        throwsA(
          isA<AuthFailure>().having(
            (error) => error.code,
            'code',
            AuthFailureCode.initializationFailed,
          ),
        ),
      );
      expect(authSession.hasActiveSession, isFalse);
    },
  );

  test('Firebase sessions use the active server entitlement', () async {
    final gateway = FakeAuthGateway()
      ..seedAccount(
        uid: 'paid-uid',
        email: 'paid-server@example.com',
        password: 'Password1',
        displayName: '서버유료회원',
      )
      ..seedEntitlement(uid: 'paid-uid', plan: UserPlan.paid);
    authSession.configureAuthGateway(gateway);

    expect(
      await authSession.signIn(
        email: 'paid-server@example.com',
        password: 'Password1',
      ),
      AuthSignInResult.success,
    );

    expect(authSession.isPaid, isTrue);
    expect(authSession.planEntitlementSource, PlanEntitlementSource.server);
    expect(authSession.isPlanMigrationPending, isTrue);
  });

  test('missing, expired, and suspended entitlements are free', () async {
    final cases = <(String, PlanEntitlement?)>[
      ('missing', null),
      (
        'expired',
        PlanEntitlement(
          plan: UserPlan.paid,
          status: PlanEntitlementStatus.active,
          expiresAt: DateTime.utc(2020),
        ),
      ),
      (
        'suspended',
        const PlanEntitlement(
          plan: UserPlan.paid,
          status: PlanEntitlementStatus.suspended,
        ),
      ),
    ];

    for (final entry in cases) {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      authSession.resetAuthGatewayForTesting();
      final uid = '${entry.$1}-uid';
      final gateway = FakeAuthGateway()
        ..seedAccount(
          uid: uid,
          email: '${entry.$1}@example.com',
          password: 'Password1',
          displayName: '${entry.$1}회원',
        );
      final entitlement = entry.$2;
      if (entitlement != null) {
        gateway.seedEntitlement(
          uid: uid,
          plan: entitlement.plan,
          status: entitlement.status,
          expiresAt: entitlement.expiresAt,
          source: entitlement.source,
        );
      }
      authSession.configureAuthGateway(gateway);

      expect(
        await authSession.signIn(
          email: '${entry.$1}@example.com',
          password: 'Password1',
        ),
        AuthSignInResult.success,
      );
      expect(authSession.isFree, isTrue, reason: entry.$1);
      await authSession.logout();
    }
  });

  test(
    'offline restore tolerates an unavailable deletion marker check',
    () async {
      final gateway = FakeAuthGateway()
        ..seedEntitlement(uid: 'uid-1', plan: UserPlan.paid);
      authSession.configureAuthGateway(gateway);
      await authSession.registerAsFree(
        email: 'cached-plan@example.com',
        password: 'Password1',
        nickname: '캐시회원',
      );
      expect(authSession.isPaid, isTrue);

      gateway.entitlementLookupFailure = const AuthFailure(
        code: AuthFailureCode.networkUnavailable,
        message: 'offline',
      );
      gateway.nicknameLookupFailure = const AuthFailure(
        code: AuthFailureCode.networkUnavailable,
        message: 'offline',
      );
      gateway.accountDeletionLookupFailure = const AuthFailure(
        code: AuthFailureCode.networkUnavailable,
        message: 'offline',
      );
      authSession.clearMemoryOnlyForTesting();
      await authSession.loadSession();

      expect(authSession.isPaid, isTrue);
      expect(authSession.hasPendingAccountDeletion, isFalse);
      expect(
        authSession.planEntitlementSource,
        PlanEntitlementSource.deviceCache,
      );

      gateway.setPendingAccountDeletion('uid-1', isPending: true);
      await pumpEventQueue();

      expect(authSession.hasPendingAccountDeletion, isTrue);
      expect(authSession.isAccountDeletedRemotely, isTrue);
      expect(authSession.canResumeAccountDeletion, isFalse);
      expect(authSession.canManageRecords, isFalse);
      expect(authSession.canUseOutbox, isFalse);
      expect(authSession.canUseCloudSync, isFalse);
    },
  );

  test('offline first lookup falls back to free', () async {
    final gateway = FakeAuthGateway()
      ..seedAccount(
        uid: 'offline-new-uid',
        email: 'offline-new@example.com',
        password: 'Password1',
        displayName: '오프라인신규',
      )
      ..entitlementLookupFailure = const AuthFailure(
        code: AuthFailureCode.networkUnavailable,
        message: 'offline',
      );
    authSession.configureAuthGateway(gateway);

    expect(
      await authSession.signIn(
        email: 'offline-new@example.com',
        password: 'Password1',
      ),
      AuthSignInResult.success,
    );

    expect(authSession.isFree, isTrue);
    expect(
      authSession.planEntitlementSource,
      PlanEntitlementSource.defaultFree,
    );
  });

  test('server downgrade preserves unfinished outbox items', () async {
    final gateway = FakeAuthGateway()
      ..seedEntitlement(uid: 'uid-1', plan: UserPlan.paid);
    authSession.configureAuthGateway(gateway);
    await authSession.registerAsFree(
      email: 'downgrade-server@example.com',
      password: 'Password1',
      nickname: '강등회원',
    );
    await recordRepository.loadRecords();
    await outboxRepository.loadItems();
    await PlanPolicyService.instance.resumePendingMigration();
    expect(authSession.isPlanMigrationPending, isFalse);
    await RecordMutationService.instance.addRecord(
      _record('server-downgrade-record'),
    );
    expect(outboxRepository.hasUnfinishedItems, isTrue);

    gateway.seedEntitlement(uid: 'uid-1', plan: UserPlan.free);
    await PlanPolicyService.instance.refreshServerPlan();

    expect(authSession.isFree, isTrue);
    expect(outboxRepository.hasUnfinishedItems, isTrue);
    expect(
      outboxRepository.getAllItems().single.recordId,
      'server-downgrade-record',
    );
  });

  test(
    'concurrent server plan refreshes share one entitlement lookup',
    () async {
      final gateway = FakeAuthGateway()
        ..seedEntitlement(uid: 'uid-1', plan: UserPlan.paid);
      authSession.configureAuthGateway(gateway);
      await authSession.registerAsFree(
        email: 'single-flight-plan@example.com',
        password: 'Password1',
        nickname: 'Single Flight',
      );
      expect(gateway.entitlementLookupCount, 1);

      gateway.entitlementLookupStarted = Completer<void>();
      gateway.entitlementLookupGate = Completer<void>();
      final first = PlanPolicyService.instance.refreshServerPlan();
      final second = PlanPolicyService.instance.refreshServerPlan();
      await gateway.entitlementLookupStarted!.future;

      expect(identical(first, second), isTrue);
      expect(gateway.entitlementLookupCount, 2);

      gateway.entitlementLookupGate!.complete();
      await Future.wait(<Future<PlanEntitlementRefreshResult>>[first, second]);
      expect(gateway.entitlementLookupCount, 2);
    },
  );

  test(
    'a late entitlement response cannot restore a signed-out session',
    () async {
      final gateway = FakeAuthGateway()
        ..seedEntitlement(uid: 'uid-1', plan: UserPlan.paid);
      authSession.configureAuthGateway(gateway);
      await authSession.registerAsFree(
        email: 'late-plan@example.com',
        password: 'Password1',
        nickname: 'Late Plan',
      );

      gateway.entitlementLookupStarted = Completer<void>();
      gateway.entitlementLookupGate = Completer<void>();
      final refresh = authSession.refreshServerPlan();
      await gateway.entitlementLookupStarted!.future;
      await authSession.logout();
      gateway.entitlementLookupGate!.complete();
      await refresh;

      expect(authSession.hasActiveSession, isFalse);
      expect(authSession.plan, UserPlan.guest);
      expect(
        authSession.planEntitlementSource,
        PlanEntitlementSource.localDevelopment,
      );
    },
  );

  test(
    're-upgrade reuses a pending mutation with the latest free-plan edit',
    () async {
      final gateway = FakeAuthGateway()
        ..seedEntitlement(uid: 'uid-1', plan: UserPlan.paid);
      authSession.configureAuthGateway(gateway);
      await authSession.registerAsFree(
        email: 're-upgrade@example.com',
        password: 'Password1',
        nickname: 'Re Upgrade',
      );
      await recordRepository.loadRecords();
      await outboxRepository.loadItems();
      await PlanPolicyService.instance.resumePendingMigration();

      const recordId = 're-upgrade-record';
      await RecordMutationService.instance.addRecord(
        _record(recordId, location: 'paid edit'),
      );
      expect(outboxRepository.getAllItems(), hasLength(1));

      gateway.seedEntitlement(uid: 'uid-1', plan: UserPlan.free);
      await PlanPolicyService.instance.refreshServerPlan();
      await RecordMutationService.instance.updateRecord(
        _record(recordId, location: 'latest free edit'),
      );

      recordRepository.clearCacheOnlyForTesting();
      outboxRepository.clearCacheOnlyForTesting();
      await recordRepository.loadRecords();
      await outboxRepository.loadItems();
      await RecordMutationService.instance.reconcileOutboxWithLocalRecords();
      expect(
        recordRepository.getRecordById(recordId)?.location,
        'latest free edit',
      );

      gateway.seedEntitlement(uid: 'uid-1', plan: UserPlan.paid);
      await PlanPolicyService.instance.refreshServerPlan();

      final items = outboxRepository.getAllItems();
      expect(items, hasLength(1));
      expect(items.single.isMigration, isTrue);
      expect(items.single.status, OutboxStatus.pending);
      expect(items.single.payload?['location'], 'latest free edit');
      expect(authSession.isPlanMigrationPending, isTrue);
    },
  );

  test('wrong Firebase password does not start account deletion', () async {
    final gateway = FakeAuthGateway();
    authSession.configureAuthGateway(gateway);
    await authSession.registerAsFree(
      email: 'delete-wrong-password@example.com',
      password: 'Password1',
      nickname: 'Delete Wrong',
    );
    var purged = false;

    await expectLater(
      authSession.deleteCurrentAccount(
        password: 'WrongPassword1',
        prepareLocalDataDeletion: (_, _, _) async {},
        purgeLocalData: (_, _, _) async {
          purged = true;
        },
      ),
      throwsA(
        isA<AuthFailure>().having(
          (failure) => failure.code,
          'code',
          AuthFailureCode.invalidCredentials,
        ),
      ),
    );

    expect(purged, isFalse);
    expect(gateway.hasAccount('delete-wrong-password@example.com'), isTrue);
    expect(gateway._pendingAccountDeletionUids, isEmpty);
    expect(authSession.isMember, isTrue);
    expect(authSession.hasPendingAccountDeletion, isFalse);
  });

  test('an uncertain deletion request stays locked for a safe retry', () async {
    final gateway = FakeAuthGateway();
    authSession.configureAuthGateway(gateway);
    await authSession.registerAsFree(
      email: 'delete-uncertain@example.com',
      password: 'Password1',
      nickname: 'Delete Uncertain',
    );
    gateway.deleteAccountDataFailure = const AuthFailure(
      code: AuthFailureCode.networkUnavailable,
      message: 'request result unknown',
    );
    gateway.accountDeletionLookupFailure = const AuthFailure(
      code: AuthFailureCode.networkUnavailable,
      message: 'marker lookup unavailable',
    );

    await expectLater(
      authSession.deleteCurrentAccount(
        password: 'Password1',
        prepareLocalDataDeletion: (_, _, _) async {},
        purgeLocalData: (_, _, _) async {},
      ),
      throwsA(
        isA<AuthFailure>().having(
          (failure) => failure.code,
          'code',
          AuthFailureCode.networkUnavailable,
        ),
      ),
    );

    expect(authSession.hasPendingAccountDeletion, isTrue);
    expect(authSession.canResumeAccountDeletion, isTrue);
    expect(authSession.isAccountDeletedRemotely, isFalse);
    expect(authSession.canManageRecords, isFalse);
    expect(authSession.canUseCloudSync, isFalse);
  });

  test(
    'a remote deletion during failed reauthentication stays remote',
    () async {
      String? cleanedUid;
      final gateway = FakeAuthGateway();
      authSession.configureAuthGateway(gateway);
      authSession.configureRemoteAccountDeletionCleanup(({
        required String ownerKey,
        required String email,
        required String firebaseUid,
      }) async {
        cleanedUid = firebaseUid;
      });
      await authSession.registerAsFree(
        email: 'delete-race@example.com',
        password: 'Password1',
        nickname: 'Delete Race',
      );
      gateway.reauthenticationStarted = Completer<void>();
      gateway.reauthenticationGate = Completer<void>();

      final deletion = authSession.deleteCurrentAccount(
        password: 'WrongPassword1',
        prepareLocalDataDeletion: (_, _, _) async {},
        purgeLocalData: (_, _, _) async {},
      );
      await gateway.reauthenticationStarted!.future;
      gateway.setPendingAccountDeletion('uid-1', isPending: true);
      gateway.reauthenticationGate!.complete();

      await expectLater(
        deletion,
        throwsA(
          isA<AuthFailure>().having(
            (failure) => failure.code,
            'code',
            AuthFailureCode.invalidCredentials,
          ),
        ),
      );
      await pumpEventQueue();

      expect(authSession.hasPendingAccountDeletion, isTrue);
      expect(authSession.isAccountDeletedRemotely, isTrue);
      expect(authSession.canResumeAccountDeletion, isFalse);
      expect(cleanedUid, 'uid-1');
    },
  );

  test(
    'a remote deletion tombstone immediately locks an active device',
    () async {
      String? cleanedOwnerKey;
      String? cleanedEmail;
      String? cleanedUid;
      final gateway = FakeAuthGateway()
        ..seedAccount(
          uid: 'live-delete-uid',
          email: 'live-delete@example.com',
          password: 'Password1',
          displayName: 'Live Delete',
        )
        ..seedEntitlement(uid: 'live-delete-uid', plan: UserPlan.paid);
      authSession.configureAuthGateway(gateway);
      authSession.configureRemoteAccountDeletionCleanup(({
        required String ownerKey,
        required String email,
        required String firebaseUid,
      }) async {
        cleanedOwnerKey = ownerKey;
        cleanedEmail = email;
        cleanedUid = firebaseUid;
      });

      expect(
        await authSession.signIn(
          email: 'live-delete@example.com',
          password: 'Password1',
        ),
        AuthSignInResult.success,
      );
      await pumpEventQueue();
      expect(authSession.isPaid, isTrue);
      expect(authSession.canManageRecords, isTrue);
      expect(authSession.canUseOutbox, isTrue);

      gateway.setPendingAccountDeletion('live-delete-uid', isPending: true);
      await pumpEventQueue();

      expect(authSession.hasPendingAccountDeletion, isTrue);
      expect(authSession.isAccountDeletedRemotely, isTrue);
      expect(authSession.canResumeAccountDeletion, isFalse);
      expect(authSession.canManageRecords, isFalse);
      expect(authSession.canUseOutbox, isFalse);
      expect(authSession.canUseCloudSync, isFalse);
      expect(cleanedOwnerKey, 'member:uid:live-delete-uid');
      expect(cleanedEmail, 'live-delete@example.com');
      expect(cleanedUid, 'live-delete-uid');
      await expectLater(
        RecordMutationService.instance.addRecord(_record('blocked-delete')),
        throwsStateError,
      );
      expect(recordRepository.getAllRecords(), isEmpty);
      expect(outboxRepository.getAllItems(), isEmpty);
      await expectLater(
        authSession.deleteCurrentAccount(
          password: 'Password1',
          prepareLocalDataDeletion: (_, _, _) async {},
          purgeLocalData: (_, _, _) async {},
        ),
        throwsA(
          isA<AuthFailure>().having(
            (failure) => failure.code,
            'code',
            AuthFailureCode.noCurrentUser,
          ),
        ),
      );

      gateway.accountDeletionLookupFailure = const AuthFailure(
        code: AuthFailureCode.networkUnavailable,
        message: 'offline',
      );
      authSession.clearMemoryOnlyForTesting();
      await authSession.loadSession();
      expect(authSession.isAccountDeletedRemotely, isTrue);
      expect(authSession.canResumeAccountDeletion, isFalse);
      gateway.accountDeletionLookupFailure = null;

      gateway.setPendingAccountDeletion('live-delete-uid', isPending: false);
      await pumpEventQueue();
      expect(authSession.hasPendingAccountDeletion, isTrue);

      await authSession.logout();
      gateway.setPendingAccountDeletion('live-delete-uid', isPending: true);
      await pumpEventQueue();
      expect(authSession.hasPendingAccountDeletion, isFalse);
    },
  );

  test('Firebase account deletion clears auth and session state', () async {
    final gateway = FakeAuthGateway();
    authSession.configureAuthGateway(gateway);
    await authSession.registerAsFree(
      email: 'delete-success@example.com',
      password: 'Password1',
      nickname: 'Delete Success',
    );
    String? purgedOwner;
    String? purgedEmail;
    String? purgedUid;

    await authSession.deleteCurrentAccount(
      password: 'Password1',
      prepareLocalDataDeletion: (_, _, _) async {},
      purgeLocalData: (ownerKey, email, uid) async {
        purgedOwner = ownerKey;
        purgedEmail = email;
        purgedUid = uid;
      },
    );

    expect(purgedOwner, DataOwnerKey.firebaseUid('uid-1'));
    expect(purgedEmail, 'delete-success@example.com');
    expect(purgedUid, 'uid-1');
    expect(gateway.hasAccount('delete-success@example.com'), isFalse);
    expect(gateway.deleteCount, 1);
    expect(authSession.hasActiveSession, isFalse);
    expect(authSession.hasPendingAccountDeletion, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('auth_has_active_session'), isNull);
    expect(prefs.getString('auth_firebase_nicknames_v1'), isNull);
  });

  test('a deletion tombstone restores a resumable member session', () async {
    final gateway = FakeAuthGateway();
    authSession.configureAuthGateway(gateway);
    await authSession.registerAsFree(
      email: 'delete-resume@example.com',
      password: 'Password1',
      nickname: 'Delete Resume',
    );
    await expectLater(
      authSession.deleteCurrentAccount(
        password: 'Password1',
        prepareLocalDataDeletion: (_, _, _) async {},
        purgeLocalData: (_, _, _) async {
          throw StateError('simulated interruption');
        },
      ),
      throwsStateError,
    );
    expect(authSession.hasPendingAccountDeletion, isTrue);
    expect(authSession.canResumeAccountDeletion, isTrue);
    expect(authSession.isAccountDeletedRemotely, isFalse);

    authSession.clearMemoryOnlyForTesting();
    await authSession.loadSession();

    expect(authSession.isMember, isTrue);
    expect(authSession.hasPendingAccountDeletion, isTrue);
    expect(authSession.canResumeAccountDeletion, isTrue);
    expect(authSession.isAccountDeletedRemotely, isFalse);
    expect(authSession.canManageRecords, isFalse);
    expect(authSession.canUseCloudSync, isFalse);

    await authSession.deleteCurrentAccount(
      password: 'Password1',
      prepareLocalDataDeletion: (_, _, _) async {},
      purgeLocalData: (_, _, _) async {},
    );
    expect(gateway.hasAccount('delete-resume@example.com'), isFalse);
    expect(authSession.hasActiveSession, isFalse);
  });

  test('local account deletion preserves other local accounts', () async {
    await authSession.registerAsFree(
      email: 'delete-local@example.com',
      password: 'Password1',
      nickname: 'Delete Local',
    );
    await authSession.logout();
    await authSession.registerAsFree(
      email: 'keep-local@example.com',
      password: 'Password2',
      nickname: 'Keep Local',
    );
    await authSession.logout();
    expect(
      await authSession.signIn(
        email: 'delete-local@example.com',
        password: 'Password1',
      ),
      AuthSignInResult.success,
    );

    await authSession.deleteCurrentAccount(
      password: 'Password1',
      prepareLocalDataDeletion: (_, _, _) async {},
      purgeLocalData: (_, _, _) async {},
    );

    expect(
      await authSession.signIn(
        email: 'delete-local@example.com',
        password: 'Password1',
      ),
      AuthSignInResult.accountNotFound,
    );
    expect(
      await authSession.signIn(
        email: 'keep-local@example.com',
        password: 'Password2',
      ),
      AuthSignInResult.success,
    );
  });
}

FishingRecord _record(String id, {String location = '부산'}) {
  return FishingRecord(
    id: id,
    location: location,
    startAt: DateTime(2026, 9, 21, 9),
    endAt: DateTime(2026, 9, 21, 11),
    genreName: '바다낚시',
    catches: const <CatchRecord>[
      CatchRecord(speciesName: '농어', lengthCm: 42, weightG: 1200),
    ],
    photoPaths: const <String>['/tmp/catch.jpg'],
  );
}

class FakeAuthGateway implements AuthGateway {
  final Map<String, _FakeAccount> _accounts = <String, _FakeAccount>{};
  final Map<String, String> _nicknameByUid = <String, String>{};
  final Map<String, String> _uidByNicknameKey = <String, String>{};
  final Map<String, PlanEntitlement> _entitlementByUid =
      <String, PlanEntitlement>{};
  final Set<String> _pendingAccountDeletionUids = <String>{};
  final Map<String, StreamController<bool>> _accountDeletionChanges =
      <String, StreamController<bool>>{};
  final StreamController<AuthUser?> _changes =
      StreamController<AuthUser?>.broadcast(sync: true);

  AuthUser? _currentUser;
  int restoreCount = 0;
  int signOutCount = 0;
  int deleteCount = 0;
  Completer<void>? signInGate;
  Completer<void>? signInStarted;
  Completer<void>? registrationGate;
  Completer<void>? registrationStarted;
  AuthFailure? nicknameLookupFailure;
  AuthFailure? entitlementLookupFailure;
  AuthFailure? accountDeletionLookupFailure;
  AuthFailure? deleteAccountDataFailure;
  Completer<void>? reauthenticationStarted;
  Completer<void>? reauthenticationGate;
  bool entitlementFromCache = false;
  int entitlementLookupCount = 0;
  Completer<void>? entitlementLookupStarted;
  Completer<void>? entitlementLookupGate;

  @override
  AuthGatewayAvailability get availability => AuthGatewayAvailability.available;

  @override
  AuthFailure? get availabilityFailure => null;

  @override
  AuthUser? get currentUser => _currentUser;

  @override
  Stream<AuthUser?> get authStateChanges => _changes.stream;

  void seedAccount({
    required String uid,
    required String email,
    required String password,
    String? displayName,
    bool claimNickname = true,
  }) {
    final normalizedEmail = email.trim().toLowerCase();
    _accounts[normalizedEmail] = _FakeAccount(
      password: password,
      user: _user(uid: uid, email: normalizedEmail, displayName: displayName),
    );
    if (displayName != null && claimNickname) {
      final nickname = NicknamePolicy.displayValue(displayName);
      final key = NicknamePolicy.canonicalKey(nickname);
      if (!NicknamePolicy.isValid(nickname) ||
          (_uidByNicknameKey[key] != null && _uidByNicknameKey[key] != uid)) {
        throw StateError('Invalid seeded nickname: $displayName');
      }
      _nicknameByUid[uid] = nickname;
      _uidByNicknameKey[key] = uid;
    }
  }

  bool hasAccount(String email) =>
      _accounts.containsKey(email.trim().toLowerCase());

  void seedEntitlement({
    required String uid,
    required UserPlan plan,
    PlanEntitlementStatus status = PlanEntitlementStatus.active,
    DateTime? expiresAt,
    String? source = 'TEST',
  }) {
    _entitlementByUid[uid] = PlanEntitlement(
      plan: plan,
      status: status,
      expiresAt: expiresAt,
      updatedAt: DateTime(2026, 10, 12),
      source: source,
    );
  }

  @override
  Future<AuthUser?> restoreUser() async {
    restoreCount += 1;
    return _currentUser;
  }

  @override
  Future<AuthUser> registerWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    final started = registrationStarted;
    if (started != null && !started.isCompleted) {
      started.complete();
    }
    await registrationGate?.future;
    final normalizedEmail = email.trim().toLowerCase();
    if (_accounts.containsKey(normalizedEmail)) {
      throw const AuthFailure(
        code: AuthFailureCode.emailAlreadyInUse,
        message: 'duplicate',
      );
    }
    final user = _user(
      uid: 'uid-${_accounts.length + 1}',
      email: normalizedEmail,
    );
    _accounts[normalizedEmail] = _FakeAccount(password: password, user: user);
    _setCurrentUser(user);
    return user;
  }

  @override
  Future<AuthUser> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    final started = signInStarted;
    if (started != null && !started.isCompleted) {
      started.complete();
    }
    await signInGate?.future;
    final account = _accounts[email.trim().toLowerCase()];
    if (account == null) {
      throw const AuthFailure(
        code: AuthFailureCode.userNotFound,
        message: 'missing',
      );
    }
    if (account.password != password) {
      throw const AuthFailure(
        code: AuthFailureCode.invalidCredentials,
        message: 'invalid',
      );
    }
    _setCurrentUser(account.user);
    return account.user;
  }

  @override
  Future<AuthUser> updateDisplayName(String? displayName) async {
    final current = _requireCurrentUser();
    final updated = _user(
      uid: current.uid,
      email: current.email!,
      displayName: displayName,
    );
    final account = _accounts[current.email]!;
    account.user = updated;
    _setCurrentUser(updated);
    return updated;
  }

  @override
  Future<AuthUser> updatePassword(String password) async {
    final current = _requireCurrentUser();
    _accounts[current.email]!.password = password;
    return current;
  }

  @override
  Future<void> reauthenticateWithPassword(String password) async {
    final current = _requireCurrentUser();
    reauthenticationStarted?.complete();
    await reauthenticationGate?.future;
    if (_accounts[current.email]?.password != password) {
      throw const AuthFailure(
        code: AuthFailureCode.invalidCredentials,
        message: 'invalid',
      );
    }
  }

  @override
  Future<String?> getRegisteredNickname(String uid) async {
    final failure = nicknameLookupFailure;
    if (failure != null) {
      throw failure;
    }
    return _nicknameByUid[uid];
  }

  @override
  Future<PlanEntitlementSnapshot> getPlanEntitlement(String uid) async {
    entitlementLookupCount += 1;
    final started = entitlementLookupStarted;
    if (started != null && !started.isCompleted) {
      started.complete();
    }
    await entitlementLookupGate?.future;
    final failure = entitlementLookupFailure;
    if (failure != null) {
      throw failure;
    }
    return PlanEntitlementSnapshot(
      entitlement: _entitlementByUid[uid],
      isFromCache: entitlementFromCache,
    );
  }

  @override
  Future<bool> hasPendingAccountDeletion(String uid) async {
    _requireCurrentUser();
    final failure = accountDeletionLookupFailure;
    if (failure != null) {
      throw failure;
    }
    return _pendingAccountDeletionUids.contains(uid);
  }

  @override
  Stream<bool> watchPendingAccountDeletion(String uid) async* {
    final current = _requireCurrentUser();
    if (current.uid != uid) {
      throw const AuthFailure(
        code: AuthFailureCode.noCurrentUser,
        message: 'wrong user',
      );
    }
    yield _pendingAccountDeletionUids.contains(uid);
    yield* _accountDeletionController(uid).stream;
  }

  void setPendingAccountDeletion(String uid, {required bool isPending}) {
    if (isPending) {
      _pendingAccountDeletionUids.add(uid);
    } else {
      _pendingAccountDeletionUids.remove(uid);
    }
    _accountDeletionController(uid).add(isPending);
  }

  @override
  Future<String> claimNickname({
    required String uid,
    required String nickname,
  }) async {
    final existingNickname = _nicknameByUid[uid];
    if (existingNickname != null) {
      return existingNickname;
    }

    final displayNickname = NicknamePolicy.displayValue(nickname);
    if (!NicknamePolicy.isValid(displayNickname)) {
      throw const AuthFailure(
        code: AuthFailureCode.invalidProfile,
        message: 'invalid nickname',
      );
    }
    final nicknameKey = NicknamePolicy.canonicalKey(displayNickname);
    final ownerUid = _uidByNicknameKey[nicknameKey];
    if (ownerUid != null && ownerUid != uid) {
      throw const AuthFailure(
        code: AuthFailureCode.nicknameAlreadyInUse,
        message: 'duplicate nickname',
      );
    }

    _nicknameByUid[uid] = displayNickname;
    _uidByNicknameKey[nicknameKey] = uid;
    return displayNickname;
  }

  @override
  Future<void> releaseNickname({
    required String uid,
    required String nickname,
  }) async {
    final storedNickname = _nicknameByUid.remove(uid);
    if (storedNickname == null) {
      return;
    }
    final nicknameKey = NicknamePolicy.canonicalKey(storedNickname);
    if (_uidByNicknameKey[nicknameKey] == uid) {
      _uidByNicknameKey.remove(nicknameKey);
    }
  }

  @override
  Future<void> deleteAccountData({required String uid}) async {
    final current = _requireCurrentUser();
    if (current.uid != uid) {
      throw const AuthFailure(
        code: AuthFailureCode.noCurrentUser,
        message: 'wrong user',
      );
    }
    final failure = deleteAccountDataFailure;
    if (failure != null) {
      throw failure;
    }
    setPendingAccountDeletion(uid, isPending: true);
    _entitlementByUid.remove(uid);
  }

  @override
  Future<void> deleteCurrentUser() async {
    final current = _currentUser;
    if (current == null) {
      return;
    }
    await releaseNickname(
      uid: current.uid,
      nickname: _nicknameByUid[current.uid] ?? '',
    );
    _accounts.remove(current.email);
    deleteCount += 1;
    _setCurrentUser(null);
  }

  @override
  Future<void> signOut() async {
    signOutCount += 1;
    _setCurrentUser(null);
  }

  @override
  Future<String> getIdToken({bool forceRefresh = false}) async {
    return 'token-${_requireCurrentUser().uid}';
  }

  AuthUser _requireCurrentUser() {
    final user = _currentUser;
    if (user == null) {
      throw const AuthFailure(
        code: AuthFailureCode.noCurrentUser,
        message: 'not signed in',
      );
    }
    return user;
  }

  void _setCurrentUser(AuthUser? user) {
    _currentUser = user;
    _changes.add(user);
  }

  StreamController<bool> _accountDeletionController(String uid) {
    return _accountDeletionChanges.putIfAbsent(
      uid,
      () => StreamController<bool>.broadcast(sync: true),
    );
  }

  AuthUser _user({
    required String uid,
    required String email,
    String? displayName,
  }) {
    return AuthUser(
      uid: uid,
      email: email,
      displayName: displayName,
      photoUrl: null,
      isEmailVerified: false,
      isAnonymous: false,
    );
  }
}

class _FakeAccount {
  String password;
  AuthUser user;

  _FakeAccount({required this.password, required this.user});
}
