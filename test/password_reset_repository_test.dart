import 'dart:async';

import 'package:fishing_build/data/auth/auth_gateway.dart';
import 'package:fishing_build/data/local/app_database.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/repositories/outbox_repository.dart';
import 'package:fishing_build/data/services/record_mutation_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_auth_test.dart' show FakeAuthGateway;
import 'support/test_database.dart';

void main() {
  final repository = AuthSessionRepository.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await resetTestDatabase();
    repository.resetAuthGatewayForTesting();
    FishingRecordRepository.instance.clearCacheOnlyForTesting();
    OutboxRepository.instance.clearCacheOnlyForTesting();
  });

  tearDown(repository.resetAuthGatewayForTesting);

  test('reset availability requires an available configured gateway', () {
    expect(repository.canSendPasswordResetEmail, isFalse);
    repository.configureAuthGateway(FakeAuthGateway());
    expect(repository.canSendPasswordResetEmail, isTrue);
    repository.configureAuthGateway(
      const UnavailableAuthGateway(
        AuthFailure(
          code: AuthFailureCode.initializationFailed,
          message: 'unavailable',
        ),
      ),
    );
    expect(repository.canSendPasswordResetEmail, isFalse);
  });

  test('normalizes the address and forwards exactly one request', () async {
    final gateway = FakeAuthGateway();
    repository.configureAuthGateway(gateway);
    final before = _sessionState(repository);

    await repository.sendPasswordResetEmail(email: '  Member@Example.COM  ');

    expect(gateway.passwordResetEmails, <String>['member@example.com']);
    expect(gateway.passwordResetCount, 1);
    expect(gateway.currentUser, isNull);
    expect(gateway.restoreCount, 0);
    expect(gateway.signOutCount, 0);
    expect(gateway.entitlementLookupCount, 0);
    expect(_sessionState(repository), before);
  });

  for (final email in <String>[
    '',
    '  ',
    'invalid',
    '@example.com',
    'a b@x.com',
  ]) {
    test(
      'rejects invalid email ${email.isEmpty ? '(empty)' : email}',
      () async {
        final gateway = FakeAuthGateway();
        repository.configureAuthGateway(gateway);
        await expectLater(
          repository.sendPasswordResetEmail(email: email),
          throwsA(
            isA<AuthFailure>().having(
              (failure) => failure.code,
              'code',
              AuthFailureCode.invalidEmail,
            ),
          ),
        );
        expect(gateway.passwordResetEmails, isEmpty);
        expect(repository.lastAuthFailure, isNull);
      },
    );
  }

  test('local accounts cannot simulate a successful reset', () async {
    await repository.registerAsFree(
      email: 'legacy@example.com',
      password: 'Password1',
      nickname: '기존회원',
    );
    final prefs = await SharedPreferences.getInstance();
    final beforePreferences = _preferences(prefs);
    final beforeSession = _sessionState(repository);
    var notifications = 0;
    void listener() => notifications += 1;
    repository.addListener(listener);
    addTearDown(() => repository.removeListener(listener));

    await expectLater(
      repository.sendPasswordResetEmail(email: 'legacy@example.com'),
      throwsA(
        isA<AuthFailure>().having(
          (failure) => failure.code,
          'code',
          AuthFailureCode.configuration,
        ),
      ),
    );

    expect(_preferences(prefs), beforePreferences);
    expect(_sessionState(repository), beforeSession);
    expect(notifications, 0);
  });

  test('unavailable reset preserves the configured typed failure', () async {
    const failure = AuthFailure(
      code: AuthFailureCode.initializationFailed,
      message: 'initialization failed',
    );
    const gateway = UnavailableAuthGateway(failure);
    repository.configureAuthGateway(gateway);
    final beforeSession = _sessionState(repository);

    await expectLater(
      repository.sendPasswordResetEmail(email: 'member@example.com'),
      throwsA(same(failure)),
    );
    await expectLater(
      gateway.sendPasswordResetEmail(email: 'member@example.com'),
      throwsA(same(failure)),
    );
    expect(_sessionState(repository), beforeSession);
  });

  for (final code in <AuthFailureCode>[
    AuthFailureCode.userNotFound,
    AuthFailureCode.userDisabled,
  ]) {
    test('does not disclose account state for ${code.name}', () async {
      final gateway = FakeAuthGateway()
        ..passwordResetFailure = AuthFailure(code: code, message: 'private');
      repository.configureAuthGateway(gateway);
      final beforeSession = _sessionState(repository);

      await repository.sendPasswordResetEmail(email: 'missing@example.com');

      expect(gateway.passwordResetEmails, <String>['missing@example.com']);
      expect(_sessionState(repository), beforeSession);
      expect(repository.lastAuthFailure, isNull);
    });
  }

  for (final code in <AuthFailureCode>[
    AuthFailureCode.networkUnavailable,
    AuthFailureCode.tooManyRequests,
    AuthFailureCode.operationNotAllowed,
    AuthFailureCode.configuration,
    AuthFailureCode.serviceUnavailable,
    AuthFailureCode.unknown,
  ]) {
    test('preserves the typed ${code.name} error', () async {
      final failure = AuthFailure(code: code, message: 'request failed');
      final gateway = FakeAuthGateway()..passwordResetFailure = failure;
      repository.configureAuthGateway(gateway);
      final beforeSession = _sessionState(repository);

      await expectLater(
        repository.sendPasswordResetEmail(email: 'member@example.com'),
        throwsA(same(failure)),
      );

      expect(gateway.passwordResetCount, 1);
      expect(_sessionState(repository), beforeSession);
    });
  }

  for (final shouldFail in <bool>[false, true]) {
    test(
      'reset ${shouldFail ? 'failure' : 'success'} preserves session and all local data',
      () async {
        // Keep a separate legacy account so its password hash is present when
        // the Firebase member asks for recovery of that same legacy address.
        await repository.registerAsFree(
          email: 'legacy@example.com',
          password: 'Legacy123',
          nickname: '로컬회원',
        );
        await repository.logout();
        final gateway = FakeAuthGateway()
          ..seedAccount(
            uid: 'member-uid',
            email: 'member@example.com',
            password: 'Password1',
            displayName: '서버회원',
          )
          ..seedEntitlement(uid: 'member-uid', plan: UserPlan.paid)
          ..passwordResetStarted = Completer<void>()
          ..passwordResetGate = Completer<void>();
        repository.configureAuthGateway(gateway);
        expect(
          await repository.signIn(
            email: 'member@example.com',
            password: 'Password1',
            rememberSession: false,
          ),
          AuthSignInResult.success,
        );
        await pumpEventQueue();
        await RecordMutationService.instance.addRecord(
          FishingRecord(
            id: 'existing-record',
            location: '부산',
            startAt: DateTime(2026, 11, 9, 9),
            endAt: DateTime(2026, 11, 9, 11),
            genreName: '바다낚시',
            catches: const <CatchRecord>[
              CatchRecord(speciesName: '우럭', lengthCm: 30),
            ],
          ),
        );
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('auth_account_password_hashes'), isNotNull);
        final beforePreferences = _preferences(prefs);
        final beforeSession = _sessionState(repository);
        final beforeDatabase = await _databaseState();
        final beforeUser = gateway.currentUser;
        final entitlementLookups = gateway.entitlementLookupCount;
        final signOuts = gateway.signOutCount;
        final records = FishingRecordRepository.instance
            .getAllRecords()
            .map((record) => record.toJson())
            .toList();
        final outbox = OutboxRepository.instance
            .getAllItems()
            .map((item) => item.toJson())
            .toList();
        expect(records, isNotEmpty);
        expect(outbox, isNotEmpty);
        var notifications = 0;
        var authEvents = 0;
        void listener() => notifications += 1;
        repository.addListener(listener);
        addTearDown(() => repository.removeListener(listener));
        final subscription = gateway.authStateChanges.listen(
          (_) => authEvents += 1,
        );
        addTearDown(subscription.cancel);
        const failure = AuthFailure(
          code: AuthFailureCode.networkUnavailable,
          message: 'offline',
        );
        if (shouldFail) gateway.passwordResetFailure = failure;

        final request = repository.sendPasswordResetEmail(
          email: ' Legacy@Example.com ',
        );
        await gateway.passwordResetStarted!.future;
        expect(_sessionState(repository), beforeSession);
        expect(_preferences(prefs), beforePreferences);
        gateway.passwordResetGate!.complete();
        if (shouldFail) {
          await expectLater(request, throwsA(same(failure)));
        } else {
          await request;
        }

        expect(gateway.passwordResetEmails, <String>['legacy@example.com']);
        expect(gateway.currentUser, same(beforeUser));
        expect(gateway.entitlementLookupCount, entitlementLookups);
        expect(gateway.signOutCount, signOuts);
        expect(_sessionState(repository), beforeSession);
        expect(_preferences(prefs), beforePreferences);
        expect(await _databaseState(), beforeDatabase);
        expect(
          FishingRecordRepository.instance.getAllRecords().map(
            (record) => record.toJson(),
          ),
          records,
        );
        expect(
          OutboxRepository.instance.getAllItems().map((item) => item.toJson()),
          outbox,
        );
        expect(notifications, 0);
        expect(authEvents, 0);
      },
    );
  }

  test('request leaves the password unchanged until link redemption', () async {
    final gateway = FakeAuthGateway()
      ..seedAccount(
        uid: 'member-uid',
        email: 'member@example.com',
        password: 'OldPassword1',
      );
    repository.configureAuthGateway(gateway);
    await repository.sendPasswordResetEmail(email: 'member@example.com');
    await gateway.signInWithEmailAndPassword(
      email: 'member@example.com',
      password: 'OldPassword1',
    );
    await gateway.signOut();
    gateway.completePasswordResetForTesting(
      email: 'member@example.com',
      password: 'NewPassword2',
    );
    await expectLater(
      gateway.signInWithEmailAndPassword(
        email: 'member@example.com',
        password: 'OldPassword1',
      ),
      throwsA(
        isA<AuthFailure>().having(
          (failure) => failure.code,
          'code',
          AuthFailureCode.invalidCredentials,
        ),
      ),
    );
    final user = await gateway.signInWithEmailAndPassword(
      email: 'member@example.com',
      password: 'NewPassword2',
    );
    expect(user.uid, 'member-uid');
    expect(gateway.passwordResetCount, 1);
  });
}

Map<String, Object?> _preferences(SharedPreferences preferences) => {
  for (final key in preferences.getKeys()) key: preferences.get(key),
};

Map<String, Object?> _sessionState(AuthSessionRepository repository) => {
  'hasActiveSession': repository.hasActiveSession,
  'sessionGeneration': repository.sessionGeneration,
  'persistsAcrossRestarts': repository.persistsAcrossRestarts,
  'plan': repository.plan,
  'migrationStatus': repository.migrationStatus,
  'email': repository.email,
  'nickname': repository.nickname,
  'memberId': repository.memberId,
  'ownerKey': repository.dataOwnerKey,
  'requiresPasswordSetup': repository.requiresPasswordSetup,
  'isDeletingAccount': repository.isDeletingAccount,
  'hasPendingAccountDeletion': repository.hasPendingAccountDeletion,
  'lastAuthFailure': repository.lastAuthFailure,
  'planEntitlementSource': repository.planEntitlementSource,
  'planEntitlementCheckedAt': repository.planEntitlementCheckedAt,
  'planEntitlementExpiresAt': repository.planEntitlementExpiresAt,
  'planEntitlementProvider': repository.planEntitlementProvider,
  'lastPlanEntitlementFailure': repository.lastPlanEntitlementFailure,
};

Future<Map<String, List<Map<String, Object?>>>> _databaseState() async {
  final database = await AppDatabase.instance.database;
  return {
    for (final table in <String>[
      AppDatabase.localMetadataTable,
      AppDatabase.fishingRecordsTable,
      AppDatabase.recordCatchesTable,
      AppDatabase.recordPhotosTable,
      AppDatabase.recordPhotoArchivesTable,
      AppDatabase.outboxItemsTable,
      AppDatabase.recordSyncStatesTable,
      AppDatabase.recordConflictsTable,
      AppDatabase.localRecordChangesTable,
    ])
      table: await database.query(table, orderBy: 'rowid'),
  };
}
