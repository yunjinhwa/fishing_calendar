import 'package:cloud_firestore/cloud_firestore.dart' as firestore;
import 'package:firebase_auth/firebase_auth.dart' as firebase;
import 'package:firebase_core/firebase_core.dart' show FirebaseException;

import 'auth_gateway.dart';
import 'nickname_policy.dart';

class FirebaseAuthGateway implements AuthGateway {
  static const String _nicknameClaimsCollection = 'nickname_claims';
  static const String _userProfilesCollection = 'user_profiles';

  final firebase.FirebaseAuth _auth;
  final firestore.FirebaseFirestore _firestore;

  FirebaseAuthGateway({
    firebase.FirebaseAuth? auth,
    firestore.FirebaseFirestore? database,
  }) : _auth = auth ?? firebase.FirebaseAuth.instance,
       _firestore = database ?? firestore.FirebaseFirestore.instance;

  @override
  AuthGatewayAvailability get availability => AuthGatewayAvailability.available;

  @override
  AuthFailure? get availabilityFailure => null;

  @override
  AuthUser? get currentUser => _toAuthUserOrNull(_auth.currentUser);

  @override
  Stream<AuthUser?> get authStateChanges =>
      _auth.authStateChanges().map(_toAuthUserOrNull);

  @override
  Future<AuthUser?> restoreUser() async {
    try {
      // The first auth-state event is emitted after Firebase has restored any
      // persisted native credentials. Reading currentUser immediately during
      // cold start can otherwise report a transient null session.
      return _toAuthUserOrNull(await _auth.authStateChanges().first);
    } on firebase.FirebaseAuthException catch (error, stackTrace) {
      throw _mapFirebaseError(error, stackTrace);
    } on Object catch (error, stackTrace) {
      throw _unknownFailure(error, stackTrace);
    }
  }

  @override
  Future<AuthUser> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    try {
      final credential = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      return _requireUser(credential.user);
    } on firebase.FirebaseAuthException catch (error, stackTrace) {
      throw _mapFirebaseError(error, stackTrace);
    } on Object catch (error, stackTrace) {
      throw _unknownFailure(error, stackTrace);
    }
  }

  @override
  Future<AuthUser> registerWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    try {
      final credential = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      return _requireUser(credential.user);
    } on firebase.FirebaseAuthException catch (error, stackTrace) {
      throw _mapFirebaseError(error, stackTrace);
    } on Object catch (error, stackTrace) {
      throw _unknownFailure(error, stackTrace);
    }
  }

  @override
  Future<AuthUser> updateDisplayName(String? displayName) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const AuthFailure(
        code: AuthFailureCode.noCurrentUser,
        message: '로그인된 사용자가 없습니다.',
      );
    }

    try {
      await user.updateDisplayName(displayName);
      await user.reload();
      return _requireUser(_auth.currentUser ?? user);
    } on firebase.FirebaseAuthException catch (error, stackTrace) {
      throw _mapFirebaseError(error, stackTrace);
    } on Object catch (error, stackTrace) {
      throw _unknownFailure(error, stackTrace);
    }
  }

  @override
  Future<AuthUser> updatePassword(String password) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const AuthFailure(
        code: AuthFailureCode.noCurrentUser,
        message: '로그인된 사용자가 없습니다.',
      );
    }

    try {
      await user.updatePassword(password);
      return _requireUser(_auth.currentUser ?? user);
    } on firebase.FirebaseAuthException catch (error, stackTrace) {
      throw _mapFirebaseError(error, stackTrace);
    } on Object catch (error, stackTrace) {
      throw _unknownFailure(error, stackTrace);
    }
  }

  @override
  Future<String?> getRegisteredNickname(String uid) async {
    try {
      final snapshot = await _firestore
          .collection(_userProfilesCollection)
          .doc(uid)
          .get(const firestore.GetOptions(source: firestore.Source.server));
      if (!snapshot.exists) {
        return null;
      }
      final data = snapshot.data();
      final nickname = data?['nickname'];
      final nicknameKey = data?['nicknameKey'];
      if (data?['uid'] != uid ||
          nickname is! String ||
          nicknameKey is! String ||
          !NicknamePolicy.isValid(nickname) ||
          NicknamePolicy.canonicalKey(nickname) != nicknameKey) {
        throw const AuthFailure(
          code: AuthFailureCode.invalidProfile,
          message: '저장된 닉네임 정보를 확인할 수 없습니다.',
        );
      }
      return NicknamePolicy.displayValue(nickname);
    } on AuthFailure {
      rethrow;
    } on FirebaseException catch (error, stackTrace) {
      throw _mapFirestoreError(error, stackTrace);
    } on Object catch (error, stackTrace) {
      throw _unknownFailure(error, stackTrace);
    }
  }

  @override
  Future<String> claimNickname({
    required String uid,
    required String nickname,
  }) async {
    final displayNickname = NicknamePolicy.displayValue(nickname);
    if (uid.trim().isEmpty || !NicknamePolicy.isValid(displayNickname)) {
      throw const AuthFailure(
        code: AuthFailureCode.invalidProfile,
        message: '사용할 수 없는 닉네임입니다.',
      );
    }

    final profileReference = _firestore
        .collection(_userProfilesCollection)
        .doc(uid);
    try {
      return await _firestore.runTransaction<String>((transaction) async {
        final profileSnapshot = await transaction.get(profileReference);
        if (profileSnapshot.exists) {
          final profile = profileSnapshot.data();
          final existingNickname = profile?['nickname'];
          final existingKey = profile?['nicknameKey'];
          if (profile?['uid'] != uid ||
              existingNickname is! String ||
              existingKey is! String ||
              !NicknamePolicy.isValid(existingNickname) ||
              NicknamePolicy.canonicalKey(existingNickname) != existingKey) {
            throw const AuthFailure(
              code: AuthFailureCode.invalidProfile,
              message: '저장된 닉네임 정보를 확인할 수 없습니다.',
            );
          }

          final existingClaimReference = _firestore
              .collection(_nicknameClaimsCollection)
              .doc(existingKey);
          final existingClaim = await transaction.get(existingClaimReference);
          if (existingClaim.exists && existingClaim.data()?['uid'] != uid) {
            throw const AuthFailure(
              code: AuthFailureCode.accountConflict,
              message: '계정의 닉네임 소유권 정보가 충돌했습니다.',
            );
          }
          final profileData = _nicknameData(
            uid: uid,
            nickname: existingNickname,
            nicknameKey: existingKey,
          );
          transaction.set(existingClaimReference, profileData);
          transaction.set(profileReference, profileData);
          return NicknamePolicy.displayValue(existingNickname);
        }

        final nicknameKey = NicknamePolicy.canonicalKey(displayNickname);
        final claimReference = _firestore
            .collection(_nicknameClaimsCollection)
            .doc(nicknameKey);
        final claimSnapshot = await transaction.get(claimReference);
        if (claimSnapshot.exists && claimSnapshot.data()?['uid'] != uid) {
          throw const AuthFailure(
            code: AuthFailureCode.nicknameAlreadyInUse,
            message: '이미 사용 중인 닉네임입니다.',
          );
        }

        final nicknameData = _nicknameData(
          uid: uid,
          nickname: displayNickname,
          nicknameKey: nicknameKey,
        );
        transaction.set(claimReference, nicknameData);
        transaction.set(profileReference, nicknameData);
        return displayNickname;
      });
    } on AuthFailure {
      rethrow;
    } on FirebaseException catch (error, stackTrace) {
      throw _mapFirestoreError(error, stackTrace);
    } on Object catch (error, stackTrace) {
      throw _unknownFailure(error, stackTrace);
    }
  }

  @override
  Future<void> releaseNickname({
    required String uid,
    required String nickname,
  }) async {
    final profileReference = _firestore
        .collection(_userProfilesCollection)
        .doc(uid);
    try {
      await _firestore.runTransaction<void>((transaction) async {
        final profileSnapshot = await transaction.get(profileReference);
        final profile = profileSnapshot.data();
        final storedNicknameKey = profile?['nicknameKey'];
        final storedKey = profile?['uid'] == uid && storedNicknameKey is String
            ? storedNicknameKey
            : null;
        final nicknameKey = storedKey ?? NicknamePolicy.canonicalKey(nickname);
        final claimReference = _firestore
            .collection(_nicknameClaimsCollection)
            .doc(nicknameKey);
        final claimSnapshot = await transaction.get(claimReference);

        if (claimSnapshot.data()?['uid'] == uid) {
          transaction.delete(claimReference);
        }
        if (profile?['uid'] == uid) {
          transaction.delete(profileReference);
        }
      });
    } on FirebaseException catch (error, stackTrace) {
      throw _mapFirestoreError(error, stackTrace);
    } on Object catch (error, stackTrace) {
      throw _unknownFailure(error, stackTrace);
    }
  }

  @override
  Future<void> deleteCurrentUser() async {
    final user = _auth.currentUser;
    if (user == null) {
      return;
    }
    try {
      await user.delete();
    } on firebase.FirebaseAuthException catch (error, stackTrace) {
      throw _mapFirebaseError(error, stackTrace);
    } on Object catch (error, stackTrace) {
      throw _unknownFailure(error, stackTrace);
    }
  }

  @override
  Future<void> signOut() async {
    try {
      await _auth.signOut();
    } on firebase.FirebaseAuthException catch (error, stackTrace) {
      throw _mapFirebaseError(error, stackTrace);
    } on Object catch (error, stackTrace) {
      throw _unknownFailure(error, stackTrace);
    }
  }

  @override
  Future<String> getIdToken({bool forceRefresh = false}) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const AuthFailure(
        code: AuthFailureCode.noCurrentUser,
        message: '로그인된 사용자가 없습니다.',
      );
    }

    try {
      final token = await user.getIdToken(forceRefresh);
      if (token == null || token.isEmpty) {
        throw const AuthFailure(
          code: AuthFailureCode.sessionExpired,
          message: '인증 토큰을 가져오지 못했습니다.',
        );
      }
      return token;
    } on firebase.FirebaseAuthException catch (error, stackTrace) {
      throw _mapFirebaseError(error, stackTrace);
    } on AuthFailure {
      rethrow;
    } on Object catch (error, stackTrace) {
      throw _unknownFailure(error, stackTrace);
    }
  }

  AuthUser _requireUser(firebase.User? user) {
    final mapped = _toAuthUserOrNull(user);
    if (mapped == null) {
      throw const AuthFailure(
        code: AuthFailureCode.sessionExpired,
        message: 'Firebase 인증 결과에 사용자 정보가 없습니다.',
      );
    }
    return mapped;
  }

  AuthUser? _toAuthUserOrNull(firebase.User? user) {
    if (user == null) {
      return null;
    }
    return AuthUser(
      uid: user.uid,
      email: user.email,
      displayName: user.displayName,
      photoUrl: user.photoURL,
      isEmailVerified: user.emailVerified,
      isAnonymous: user.isAnonymous,
    );
  }

  AuthFailure _mapFirebaseError(
    firebase.FirebaseAuthException error,
    StackTrace stackTrace,
  ) {
    final code = switch (error.code) {
      'invalid-email' => AuthFailureCode.invalidEmail,
      'invalid-credential' ||
      'wrong-password' => AuthFailureCode.invalidCredentials,
      'user-not-found' => AuthFailureCode.userNotFound,
      'email-already-in-use' => AuthFailureCode.emailAlreadyInUse,
      'weak-password' => AuthFailureCode.weakPassword,
      'user-disabled' => AuthFailureCode.userDisabled,
      'too-many-requests' => AuthFailureCode.tooManyRequests,
      'network-request-failed' => AuthFailureCode.networkUnavailable,
      'operation-not-allowed' => AuthFailureCode.operationNotAllowed,
      'requires-recent-login' => AuthFailureCode.requiresRecentLogin,
      'user-token-expired' ||
      'invalid-user-token' => AuthFailureCode.sessionExpired,
      'account-exists-with-different-credential' =>
        AuthFailureCode.accountConflict,
      'invalid-display-name' => AuthFailureCode.invalidProfile,
      'app-not-authorized' ||
      'invalid-api-key' => AuthFailureCode.configuration,
      'internal-error' ||
      'web-internal-error' => AuthFailureCode.serviceUnavailable,
      _ => AuthFailureCode.unknown,
    };

    return AuthFailure(
      code: code,
      message: error.message ?? 'Firebase 인증 요청에 실패했습니다.',
      providerCode: error.code,
      cause: error,
      causeStackTrace: stackTrace,
    );
  }

  AuthFailure _unknownFailure(Object error, StackTrace stackTrace) {
    return AuthFailure(
      code: AuthFailureCode.unknown,
      message: 'Firebase 인증 처리 중 알 수 없는 오류가 발생했습니다.',
      cause: error,
      causeStackTrace: stackTrace,
    );
  }

  Map<String, String> _nicknameData({
    required String uid,
    required String nickname,
    required String nicknameKey,
  }) {
    return <String, String>{
      'uid': uid,
      'nickname': NicknamePolicy.displayValue(nickname),
      'nicknameKey': nicknameKey,
    };
  }

  AuthFailure _mapFirestoreError(
    FirebaseException error,
    StackTrace stackTrace,
  ) {
    final code = switch (error.code) {
      'unavailable' ||
      'deadline-exceeded' ||
      'aborted' => AuthFailureCode.networkUnavailable,
      'permission-denied' ||
      'failed-precondition' ||
      'not-found' => AuthFailureCode.configuration,
      _ => AuthFailureCode.serviceUnavailable,
    };
    return AuthFailure(
      code: code,
      message: error.message ?? '닉네임 저장소 요청에 실패했습니다.',
      providerCode: 'firestore/${error.code}',
      cause: error,
      causeStackTrace: stackTrace,
    );
  }
}
