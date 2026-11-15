import 'dart:async';

import 'package:fishing_build/data/auth/auth_gateway.dart';
import 'package:fishing_build/data/models/plan_entitlement.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_auth_test.dart' show FakeAuthGateway;
import 'support/test_database.dart';

void main() {
  final auth = AuthSessionRepository.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await resetTestDatabase();
    auth.resetAuthGatewayForTesting();
  });

  tearDown(auth.resetAuthGatewayForTesting);

  test(
    'restore joins concurrent reads only after the deletion barrier',
    () async {
      final gateway = _GatedGateway();
      _seedFirstAccount(gateway);
      await _signInNative(gateway);
      auth.configureAuthGateway(gateway);

      final restore = auth.loadSession();
      try {
        await gateway.deletionStarted.future;
        expect(gateway.planStarted.isCompleted, isFalse);
        expect(gateway.nicknameStarted.isCompleted, isFalse);
        expect(auth.hasActiveSession, isFalse);

        gateway.deletionRelease.complete();
        await _bothReadsStarted(gateway);
        expect(gateway.planFinished.isCompleted, isFalse);
        expect(gateway.nicknameFinished.isCompleted, isFalse);
        expect(auth.isAuthOperationInProgress, isTrue);

        gateway.planRelease.complete();
        await gateway.planFinished.future;
        expect(gateway.nicknameFinished.isCompleted, isFalse);
        expect(auth.hasActiveSession, isFalse);
        expect(auth.isAuthOperationInProgress, isTrue);
      } finally {
        gateway.releaseAll();
        await restore;
      }

      expect(auth.memberId, 'first-account');
      expect(auth.plan, UserPlan.paid);
      expect(auth.displayName, 'FirstFisher');
      expect(auth.isAuthOperationInProgress, isFalse);
    },
  );

  test('read failure keeps auth locked until the other read joins', () async {
    final gateway = _GatedGateway()
      ..nicknameLookupFailure = const AuthFailure(
        code: AuthFailureCode.invalidProfile,
        message: 'invalid server nickname',
      );
    _seedFirstAccount(gateway);
    auth.configureAuthGateway(gateway);

    var operationFinished = false;
    final signIn = auth.signIn(
      email: 'first@example.com',
      password: 'Password1',
    );
    final observedCompletion = signIn.then<void>(
      (_) => operationFinished = true,
      onError: (Object error, StackTrace stackTrace) {
        operationFinished = true;
      },
    );
    final failure = expectLater(
      signIn,
      throwsA(_authFailure(AuthFailureCode.invalidProfile)),
    );
    try {
      await gateway.deletionStarted.future;
      gateway.deletionRelease.complete();
      await _bothReadsStarted(gateway);
      gateway.nicknameRelease.complete();
      await gateway.nicknameFinished.future;
      // Let the released error traverse the async wrappers before checking
      // that the still-pending plan read keeps the operation exclusive.
      await Future<void>(() {});

      expect(operationFinished, isFalse);
      expect(gateway.planFinished.isCompleted, isFalse);
      expect(gateway.currentUser?.uid, 'first-account');
      expect(gateway.signOutCount, 0);
      expect(auth.isAuthOperationInProgress, isTrue);
      await expectLater(
        auth.logout(),
        throwsA(_authFailure(AuthFailureCode.operationInProgress)),
      );
      expect(gateway.signOutCount, 0);
    } finally {
      gateway.releaseAll();
      await failure;
      await observedCompletion;
    }

    expect(operationFinished, isTrue);
    expect(gateway.signOutCount, 1);
    expect(gateway.currentUser, isNull);
    expect(auth.hasActiveSession, isFalse);
    expect(auth.isAuthOperationInProgress, isFalse);
  });

  test(
    'native UID replacement prevents applying completed startup reads',
    () async {
      final gateway = _GatedGateway()
        ..seedAccount(
          uid: 'second-account',
          email: 'second@example.com',
          password: 'Password2',
          displayName: 'SecondFisher',
        );
      _seedFirstAccount(gateway);
      await _signInNative(gateway);
      auth.configureAuthGateway(gateway);
      final prefs = await SharedPreferences.getInstance();
      final originalSession = _persistedIdentity(prefs);

      final restore = auth.loadSession();
      try {
        await gateway.deletionStarted.future;
        gateway.deletionRelease.complete();
        await _bothReadsStarted(gateway);
        // Simulate native authentication changing outside the repository lock.
        await gateway.signInWithEmailAndPassword(
          email: 'second@example.com',
          password: 'Password2',
        );
      } finally {
        gateway.releaseAll();
        await restore;
      }

      expect(gateway.currentUser?.uid, 'second-account');
      expect(gateway.currentUser?.displayName, 'SecondFisher');
      expect(gateway.signOutCount, 0);
      expect(gateway.displayNameUpdates, isEmpty);
      expect(auth.hasActiveSession, isFalse);
      expect(auth.memberId, isNull);
      expect(auth.nickname, isNull);
      expect(auth.plan, UserPlan.guest);
      expect(auth.lastAuthFailure?.code, AuthFailureCode.sessionExpired);
      expect(_persistedIdentity(prefs), originalSession);
      expect(auth.isAuthOperationInProgress, isFalse);
    },
  );

  test(
    'restore uses server nickname while interactive auth repairs its mirror',
    () async {
      final gateway = _ObservedGateway();
      _seedFirstAccount(gateway);
      await _signInNative(gateway);
      // Auth's display name can lag behind the authoritative profile nickname.
      await gateway.updateDisplayName('StaleMirror');
      gateway.displayNameUpdates.clear();
      auth.configureAuthGateway(gateway);

      await auth.loadSession();

      expect(auth.memberId, 'first-account');
      expect(auth.displayName, 'FirstFisher');
      expect(auth.nickname, 'FirstFisher');
      expect(gateway.currentUser?.displayName, 'StaleMirror');
      expect(gateway.displayNameUpdates, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth_nickname'), 'FirstFisher');
      expect(prefs.getString('auth_member_id'), 'first-account');

      auth.clearMemoryOnlyForTesting();
      expect(
        await auth.signIn(email: 'first@example.com', password: 'Password1'),
        AuthSignInResult.success,
      );
      expect(gateway.displayNameUpdates, <String?>['FirstFisher']);
      expect(gateway.currentUser?.uid, 'first-account');
      expect(gateway.currentUser?.displayName, 'FirstFisher');
      expect(auth.displayName, 'FirstFisher');

      await auth.logout();
      expect(
        await auth.registerAsFree(
          email: 'new@example.com',
          password: 'Password1',
          nickname: 'NewFisher',
        ),
        isTrue,
      );
      expect(gateway.displayNameUpdates, <String?>['FirstFisher', 'NewFisher']);
      expect(gateway.currentUser?.displayName, 'NewFisher');
      expect(auth.displayName, 'NewFisher');
      expect(prefs.getString('auth_member_id'), gateway.currentUser?.uid);
      expect(prefs.getString('auth_email'), 'new@example.com');
    },
  );
}

Matcher _authFailure(AuthFailureCode code) =>
    isA<AuthFailure>().having((failure) => failure.code, 'code', code);

void _seedFirstAccount(FakeAuthGateway gateway) {
  gateway
    ..seedAccount(
      uid: 'first-account',
      email: 'first@example.com',
      password: 'Password1',
      displayName: 'FirstFisher',
    )
    ..seedEntitlement(uid: 'first-account', plan: UserPlan.paid);
}

Future<AuthUser> _signInNative(FakeAuthGateway gateway) =>
    gateway.signInWithEmailAndPassword(
      email: 'first@example.com',
      password: 'Password1',
    );

Future<void> _bothReadsStarted(_GatedGateway gateway) async {
  await Future.wait<void>(<Future<void>>[
    gateway.planStarted.future,
    gateway.nicknameStarted.future,
  ]).timeout(const Duration(seconds: 5));
}

Map<String, Object?> _persistedIdentity(SharedPreferences prefs) =>
    <String, Object?>{
      for (final key in <String>[
        'auth_has_active_session',
        'auth_member_id',
        'auth_email',
        'auth_nickname',
        'auth_plan',
      ])
        key: prefs.get(key),
    };

class _ObservedGateway extends FakeAuthGateway {
  final List<String?> displayNameUpdates = <String?>[];

  @override
  Future<AuthUser> updateDisplayName(String? displayName) {
    displayNameUpdates.add(displayName);
    return super.updateDisplayName(displayName);
  }
}

class _GatedGateway extends _ObservedGateway {
  final deletionStarted = Completer<void>();
  final deletionRelease = Completer<void>();
  final planStarted = Completer<void>();
  final planRelease = Completer<void>();
  final planFinished = Completer<void>();
  final nicknameStarted = Completer<void>();
  final nicknameRelease = Completer<void>();
  final nicknameFinished = Completer<void>();

  @override
  Future<bool> hasPendingAccountDeletion(String uid) async {
    deletionStarted.complete();
    await deletionRelease.future;
    return super.hasPendingAccountDeletion(uid);
  }

  @override
  Future<PlanEntitlementSnapshot> getPlanEntitlement(String uid) async {
    planStarted.complete();
    await planRelease.future;
    try {
      return await super.getPlanEntitlement(uid);
    } finally {
      planFinished.complete();
    }
  }

  @override
  Future<String?> getRegisteredNickname(String uid) async {
    nicknameStarted.complete();
    await nicknameRelease.future;
    try {
      return await super.getRegisteredNickname(uid);
    } finally {
      nicknameFinished.complete();
    }
  }

  void releaseAll() {
    for (final release in <Completer<void>>[
      deletionRelease,
      planRelease,
      nicknameRelease,
    ]) {
      if (!release.isCompleted) release.complete();
    }
  }
}
