import 'dart:async';

import 'package:fishing_build/data/auth/auth_gateway.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_auth_test.dart' show FakeAuthGateway;
import 'support/test_database.dart';

void main() {
  final auth = AuthSessionRepository.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await resetTestDatabase();
    auth.resetAuthGatewayForTesting();
  });

  tearDown(auth.resetAuthGatewayForTesting);

  test(
    'nickname failure cannot roll back an overlapping account login',
    () async {
      final gateway = _DelayedNicknameGateway()
        ..seedAccount(
          uid: 'existing-account',
          email: 'existing@example.com',
          password: 'Password1',
          displayName: 'Existing',
        );
      auth.configureAuthGateway(gateway);

      final registration = auth.registerAsFree(
        email: 'new@example.com',
        password: 'Password1',
        nickname: 'Existing',
      );
      final registrationFailure = expectLater(
        registration,
        throwsA(
          isA<AuthFailure>().having(
            (e) => e.code,
            'code',
            AuthFailureCode.nicknameAlreadyInUse,
          ),
        ),
      );
      await gateway.claimStarted.future;
      Object? overlapError;
      try {
        await auth.signIn(email: 'existing@example.com', password: 'Password1');
      } catch (error) {
        overlapError = error;
      } finally {
        gateway.claimRelease.complete();
      }
      await registrationFailure;

      expect(overlapError, _busyFailure);
      expect(gateway.hasAccount('existing@example.com'), isTrue);
      expect(gateway.hasAccount('new@example.com'), isFalse);
      expect(gateway.deleteCount, 1);

      expect(
        await auth.signIn(email: 'existing@example.com', password: 'Password1'),
        AuthSignInResult.success,
      );
      expect(gateway.currentUser?.uid, 'existing-account');
      expect(auth.memberId, 'existing-account');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth_member_id'), 'existing-account');
      expect(prefs.getString('auth_email'), 'existing@example.com');
    },
  );

  final transitions = <String, Future<void> Function()>{
    'restore': () => auth.loadSession(),
    'guest': () => auth.continueAsGuest(),
    'logout': () => auth.logout(),
    'password change': () => auth.setPasswordForCurrentMember('Changed123'),
    'registration': () async {
      await auth.registerAsFree(
        email: 'second@example.com',
        password: 'Password1',
        nickname: 'Second',
      );
    },
    'account deletion': () => auth.deleteCurrentAccount(
      password: 'Password1',
      prepareLocalDataDeletion: (_, _, _) async {},
      purgeLocalData: (_, _, _) async {},
    ),
  };

  for (final entry in transitions.entries) {
    test('${entry.key} cannot overlap a pending native sign-in', () async {
      final gateway = _seedGateway()
        ..signInStarted = Completer<void>()
        ..signInGate = Completer<void>();
      auth.configureAuthGateway(gateway);
      final signIn = auth.signIn(
        email: 'first@example.com',
        password: 'Password1',
      );
      await gateway.signInStarted!.future;
      Object? overlapError;
      try {
        await entry.value();
      } catch (error) {
        overlapError = error;
      } finally {
        gateway.signInGate!.complete();
      }
      expect(await signIn, AuthSignInResult.success);
      expect(overlapError, _busyFailure);
      expect(auth.memberId, 'first-account');
      expect(gateway.currentUser?.uid, 'first-account');
      expect(gateway.signOutCount, 0);
      expect(gateway.deleteCount, 0);
    });
  }

  test(
    'failed sign-in holds exclusivity until sign-out cleanup completes',
    () async {
      final gateway = _DelayedSignOutGateway()
        ..seedAccount(
          uid: 'first-account',
          email: 'first@example.com',
          password: 'Password1',
          displayName: 'First',
        )
        ..seedAccount(
          uid: 'second-account',
          email: 'second@example.com',
          password: 'Password1',
          displayName: 'Second',
        )
        ..nicknameLookupFailure = const AuthFailure(
          code: AuthFailureCode.networkUnavailable,
          message: 'offline',
        );
      auth.configureAuthGateway(gateway);
      final failure = expectLater(
        auth.signIn(email: 'first@example.com', password: 'Password1'),
        throwsA(isA<AuthFailure>()),
      );
      await gateway.signOutStarted.future;
      Object? overlapError;
      try {
        await auth.signIn(email: 'second@example.com', password: 'Password1');
      } catch (error) {
        overlapError = error;
      } finally {
        gateway.signOutRelease.complete();
      }
      await failure;
      expect(overlapError, _busyFailure);

      gateway.nicknameLookupFailure = null;
      expect(
        await auth.signIn(email: 'second@example.com', password: 'Password1'),
        AuthSignInResult.success,
      );
      expect(auth.memberId, 'second-account');
      expect(gateway.currentUser?.uid, 'second-account');
      expect(gateway.signOutCount, 1);
    },
  );

  test('a pending sign-in prevents replacement of its gateway', () async {
    final gateway = _seedGateway()
      ..signInStarted = Completer<void>()
      ..signInGate = Completer<void>();
    auth.configureAuthGateway(gateway);
    final signIn = auth.signIn(
      email: 'first@example.com',
      password: 'Password1',
    );
    await gateway.signInStarted!.future;
    Object? replacementError;
    try {
      auth.configureAuthGateway(FakeAuthGateway());
    } catch (error) {
      replacementError = error;
    } finally {
      gateway.signInGate!.complete();
    }
    expect(await signIn, AuthSignInResult.success);
    expect(replacementError, _busyFailure);
    expect(await auth.getIdToken(), 'token-first-account');
  });

  test('registration cleanup leaves a replaced native user signed in', () async {
    final gateway = _DelayedNicknameGateway()
      ..seedAccount(
        uid: 'existing-account',
        email: 'existing@example.com',
        password: 'Password1',
        displayName: 'Existing',
      );
    auth.configureAuthGateway(gateway);
    final failure = expectLater(
      auth.registerAsFree(
        email: 'new@example.com',
        password: 'Password1',
        nickname: 'Existing',
      ),
      throwsA(isA<AuthFailure>()),
    );
    await gateway.claimStarted.future;
    // Simulate a change outside the repository, bypassing its transition guard.
    try {
      await gateway.signInWithEmailAndPassword(
        email: 'existing@example.com',
        password: 'Password1',
      );
    } finally {
      gateway.claimRelease.complete();
    }
    await failure;
    expect(gateway.currentUser?.uid, 'existing-account');
    expect(gateway.hasAccount('existing@example.com'), isTrue);
    expect(gateway.deleteCount, 0);
    expect(gateway.signOutCount, 0);
    expect(auth.isAuthOperationInProgress, isFalse);
  });

  test(
    'display name completion cannot mix another UID with the first email',
    () async {
      final gateway = _ReplacedDisplayNameGateway()
        ..seedAccount(
          uid: 'first-account',
          email: 'first@example.com',
          password: 'Password1',
          displayName: 'First',
        )
        ..seedAccount(
          uid: 'second-account',
          email: 'second@example.com',
          password: 'Password1',
          displayName: 'Second',
        );
      auth.configureAuthGateway(gateway);
      await expectLater(
        auth.signIn(email: 'first@example.com', password: 'Password1'),
        throwsA(
          isA<AuthFailure>().having(
            (e) => e.code,
            'code',
            AuthFailureCode.sessionExpired,
          ),
        ),
      );
      expect(gateway.currentUser?.uid, 'second-account');
      expect(gateway.signOutCount, 0);
      expect(auth.hasActiveSession, isFalse);
      expect(auth.isAuthOperationInProgress, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth_member_id'), isNull);
      expect(prefs.getString('auth_email'), isNull);
    },
  );
}

final _busyFailure = isA<AuthFailure>().having(
  (e) => e.code.name,
  'code',
  'operationInProgress',
);

FakeAuthGateway _seedGateway() => FakeAuthGateway()
  ..seedAccount(
    uid: 'first-account',
    email: 'first@example.com',
    password: 'Password1',
    displayName: 'First',
  );

class _DelayedNicknameGateway extends FakeAuthGateway {
  final claimStarted = Completer<void>();
  final claimRelease = Completer<void>();

  @override
  Future<String> claimNickname({
    required String uid,
    required String nickname,
  }) async {
    claimStarted.complete();
    await claimRelease.future;
    return super.claimNickname(uid: uid, nickname: nickname);
  }
}

class _DelayedSignOutGateway extends FakeAuthGateway {
  final signOutStarted = Completer<void>();
  final signOutRelease = Completer<void>();

  @override
  Future<void> signOut() async {
    signOutStarted.complete();
    await signOutRelease.future;
    await super.signOut();
  }
}

class _ReplacedDisplayNameGateway extends FakeAuthGateway {
  @override
  Future<String?> getRegisteredNickname(String uid) async =>
      uid == 'first-account'
      ? 'UpdatedFirst'
      : super.getRegisteredNickname(uid);

  @override
  Future<AuthUser> updateDisplayName(String? displayName) =>
      signInWithEmailAndPassword(
        email: 'second@example.com',
        password: 'Password1',
      );
}
