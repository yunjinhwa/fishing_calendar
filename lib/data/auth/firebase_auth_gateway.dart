import 'package:cloud_firestore/cloud_firestore.dart' as firestore;
import 'package:firebase_auth/firebase_auth.dart' as firebase;
import 'package:firebase_core/firebase_core.dart' show FirebaseException;

import '../models/plan_entitlement.dart';
import '../models/user_plan.dart';
import 'auth_gateway.dart';
import 'nickname_policy.dart';

class FirebaseAuthGateway implements AuthGateway {
  static const String _nicknameClaimsCollection = 'nickname_claims';
  static const String _accountDeletionRequestsCollection =
      'account_deletion_requests';
  static const String _planEntitlementsCollection = 'plan_entitlements';
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
  Future<void> reauthenticateWithPassword(String password) async {
    final user = _auth.currentUser;
    final email = user?.email?.trim();
    if (user == null || email == null || email.isEmpty) {
      throw const AuthFailure(
        code: AuthFailureCode.noCurrentUser,
        message: '로그인한 이메일 회원을 확인할 수 없습니다.',
      );
    }

    try {
      final credential = firebase.EmailAuthProvider.credential(
        email: email,
        password: password,
      );
      await user.reauthenticateWithCredential(credential);
      await user.getIdToken(true);
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
  Future<PlanEntitlementSnapshot> getPlanEntitlement(String uid) async {
    if (uid.trim().isEmpty) {
      throw const AuthFailure(
        code: AuthFailureCode.invalidProfile,
        message: '플랜 정보를 조회할 계정을 확인할 수 없습니다.',
      );
    }

    try {
      final snapshot = await _firestore
          .collection(_planEntitlementsCollection)
          .doc(uid)
          .get(
            const firestore.GetOptions(source: firestore.Source.serverAndCache),
          );
      if (!snapshot.exists) {
        return PlanEntitlementSnapshot(
          entitlement: null,
          isFromCache: snapshot.metadata.isFromCache,
        );
      }

      final data = snapshot.data();
      final plan = switch (data?['planType']) {
        'FREE' => UserPlan.free,
        'PAID' => UserPlan.paid,
        _ => null,
      };
      final rawStatus = data?['status'];
      final status = PlanEntitlementStatus.fromWireValue(
        rawStatus is String ? rawStatus : null,
      );
      final rawExpiresAt = data?['expiresAt'];
      if (plan == null ||
          status == null ||
          (rawExpiresAt != null && rawExpiresAt is! firestore.Timestamp)) {
        throw const AuthFailure(
          code: AuthFailureCode.invalidProfile,
          message: '저장된 플랜 정보를 확인할 수 없습니다.',
        );
      }

      final rawUpdatedAt = data?['updatedAt'];
      final source = data?['source'];
      return PlanEntitlementSnapshot(
        entitlement: PlanEntitlement(
          plan: plan,
          status: status,
          expiresAt: rawExpiresAt is firestore.Timestamp
              ? rawExpiresAt.toDate()
              : null,
          updatedAt: rawUpdatedAt is firestore.Timestamp
              ? rawUpdatedAt.toDate()
              : null,
          source: source is String && source.trim().isNotEmpty
              ? source.trim()
              : null,
        ),
        isFromCache: snapshot.metadata.isFromCache,
      );
    } on AuthFailure {
      rethrow;
    } on FirebaseException catch (error, stackTrace) {
      throw _mapFirestoreError(error, stackTrace);
    } on Object catch (error, stackTrace) {
      throw _unknownFailure(error, stackTrace);
    }
  }

  @override
  Future<bool> hasPendingAccountDeletion(String uid) async {
    final user = _auth.currentUser;
    if (user == null || user.uid != uid) {
      throw const AuthFailure(
        code: AuthFailureCode.noCurrentUser,
        message: '로그인한 계정을 확인할 수 없습니다.',
      );
    }
    try {
      final snapshot = await _firestore
          .collection(_accountDeletionRequestsCollection)
          .doc(uid)
          .get(const firestore.GetOptions(source: firestore.Source.server));
      return snapshot.exists;
    } on FirebaseException catch (error, stackTrace) {
      throw _mapFirestoreError(error, stackTrace);
    } on Object catch (error, stackTrace) {
      throw _unknownFailure(error, stackTrace);
    }
  }

  @override
  Stream<bool> watchPendingAccountDeletion(String uid) async* {
    final user = _auth.currentUser;
    if (user == null || user.uid != uid) {
      throw const AuthFailure(
        code: AuthFailureCode.noCurrentUser,
        message: '로그인한 계정을 확인할 수 없습니다.',
      );
    }
    try {
      await for (final snapshot
          in _firestore
              .collection(_accountDeletionRequestsCollection)
              .doc(uid)
              .snapshots()) {
        yield snapshot.exists;
      }
    } on FirebaseException catch (error, stackTrace) {
      throw _mapFirestoreError(error, stackTrace);
    } on AuthFailure {
      rethrow;
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
        final fallbackNickname = NicknamePolicy.displayValue(nickname);
        final fallbackKey = NicknamePolicy.isValid(fallbackNickname)
            ? NicknamePolicy.canonicalKey(fallbackNickname)
            : null;
        final nicknameKey = storedKey ?? fallbackKey;
        if (nicknameKey == null) {
          return;
        }
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
  Future<void> deleteAccountData({required String uid}) async {
    final user = _auth.currentUser;
    if (user == null || user.uid != uid) {
      throw const AuthFailure(
        code: AuthFailureCode.noCurrentUser,
        message: '탈퇴할 로그인 계정을 확인할 수 없습니다.',
      );
    }

    try {
      await _beginAccountDeletion(uid);
      final userReference = _firestore.collection('users').doc(uid);
      await _deleteCollection(userReference.collection('records'));
      await _deleteCollection(userReference.collection('sync_receipts'));
      await _firestore
          .collection(_planEntitlementsCollection)
          .doc(uid)
          .delete();
    } on AuthFailure {
      rethrow;
    } on FirebaseException catch (error, stackTrace) {
      throw _mapFirestoreError(error, stackTrace);
    } on Object catch (error, stackTrace) {
      throw _unknownFailure(error, stackTrace);
    }
  }

  Future<void> _beginAccountDeletion(String uid) async {
    final reference = _firestore
        .collection(_accountDeletionRequestsCollection)
        .doc(uid);
    final existing = await reference.get(
      const firestore.GetOptions(source: firestore.Source.server),
    );
    if (existing.exists) {
      return;
    }
    await reference.set(<String, Object>{
      'schemaVersion': 1,
      'uid': uid,
      'status': 'REQUESTED',
      'requestedAt': firestore.FieldValue.serverTimestamp(),
    });
  }

  Future<void> _deleteCollection(
    firestore.CollectionReference<Map<String, dynamic>> collection,
  ) async {
    // Each delete rule checks the account-deletion tombstone. Keep the batch
    // below Firestore's multi-document rules access limit.
    const batchSize = 15;
    while (true) {
      final snapshot = await collection
          .limit(batchSize)
          .get(const firestore.GetOptions(source: firestore.Source.server));
      if (snapshot.docs.isEmpty) {
        return;
      }
      final batch = _firestore.batch();
      for (final document in snapshot.docs) {
        batch.delete(document.reference);
      }
      await batch.commit();
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
      message: error.message ?? 'Firestore 요청에 실패했습니다.',
      providerCode: 'firestore/${error.code}',
      cause: error,
      causeStackTrace: stackTrace,
    );
  }
}
