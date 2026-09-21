enum AuthGatewayAvailability { available, unavailable }

enum AuthFailureCode {
  initializationFailed,
  configuration,
  invalidEmail,
  invalidCredentials,
  userNotFound,
  emailAlreadyInUse,
  weakPassword,
  userDisabled,
  tooManyRequests,
  networkUnavailable,
  operationNotAllowed,
  requiresRecentLogin,
  noCurrentUser,
  sessionExpired,
  accountConflict,
  invalidProfile,
  nicknameAlreadyInUse,
  nicknameRequired,
  serviceUnavailable,
  unknown,
}

class AuthFailure implements Exception {
  final AuthFailureCode code;
  final String message;
  final String? providerCode;
  final Object? cause;
  final StackTrace? causeStackTrace;

  const AuthFailure({
    required this.code,
    required this.message,
    this.providerCode,
    this.cause,
    this.causeStackTrace,
  });

  @override
  String toString() => 'AuthFailure(${code.name}): $message';
}

class AuthUser {
  final String uid;
  final String? email;
  final String? displayName;
  final String? photoUrl;
  final bool isEmailVerified;
  final bool isAnonymous;

  const AuthUser({
    required this.uid,
    required this.email,
    required this.displayName,
    required this.photoUrl,
    required this.isEmailVerified,
    required this.isAnonymous,
  });

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is AuthUser &&
            uid == other.uid &&
            email == other.email &&
            displayName == other.displayName &&
            photoUrl == other.photoUrl &&
            isEmailVerified == other.isEmailVerified &&
            isAnonymous == other.isAnonymous;
  }

  @override
  int get hashCode => Object.hash(
    uid,
    email,
    displayName,
    photoUrl,
    isEmailVerified,
    isAnonymous,
  );
}

abstract interface class AuthGateway {
  AuthGatewayAvailability get availability;

  AuthFailure? get availabilityFailure;

  AuthUser? get currentUser;

  Stream<AuthUser?> get authStateChanges;

  Future<AuthUser?> restoreUser();

  Future<AuthUser> signInWithEmailAndPassword({
    required String email,
    required String password,
  });

  Future<AuthUser> registerWithEmailAndPassword({
    required String email,
    required String password,
  });

  Future<AuthUser> updateDisplayName(String? displayName);

  Future<AuthUser> updatePassword(String password);

  Future<String?> getRegisteredNickname(String uid);

  Future<String> claimNickname({required String uid, required String nickname});

  Future<void> releaseNickname({required String uid, required String nickname});

  Future<void> deleteCurrentUser();

  Future<void> signOut();

  Future<String> getIdToken({bool forceRefresh = false});
}

/// Used when Firebase was explicitly enabled but could not be initialized.
/// This prevents a silent fallback to the legacy local password store.
class UnavailableAuthGateway implements AuthGateway {
  final AuthFailure failure;

  const UnavailableAuthGateway(this.failure);

  @override
  AuthGatewayAvailability get availability =>
      AuthGatewayAvailability.unavailable;

  @override
  AuthFailure get availabilityFailure => failure;

  @override
  AuthUser? get currentUser => null;

  @override
  Stream<AuthUser?> get authStateChanges => Stream<AuthUser?>.error(failure);

  @override
  Future<AuthUser?> restoreUser() => Future<AuthUser?>.error(failure);

  @override
  Future<String> getIdToken({bool forceRefresh = false}) =>
      Future<String>.error(failure);

  @override
  Future<AuthUser> registerWithEmailAndPassword({
    required String email,
    required String password,
  }) => Future<AuthUser>.error(failure);

  @override
  Future<AuthUser> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) => Future<AuthUser>.error(failure);

  @override
  Future<void> signOut() => Future<void>.error(failure);

  @override
  Future<AuthUser> updateDisplayName(String? displayName) =>
      Future<AuthUser>.error(failure);

  @override
  Future<AuthUser> updatePassword(String password) =>
      Future<AuthUser>.error(failure);

  @override
  Future<String?> getRegisteredNickname(String uid) =>
      Future<String?>.error(failure);

  @override
  Future<String> claimNickname({
    required String uid,
    required String nickname,
  }) => Future<String>.error(failure);

  @override
  Future<void> releaseNickname({
    required String uid,
    required String nickname,
  }) => Future<void>.error(failure);

  @override
  Future<void> deleteCurrentUser() => Future<void>.error(failure);
}
