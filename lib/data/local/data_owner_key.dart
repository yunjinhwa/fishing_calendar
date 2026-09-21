abstract final class DataOwnerKey {
  static const String anonymous = 'anonymous';

  static String legacyEmail(String email) {
    final normalizedEmail = normalizeEmail(email);
    if (normalizedEmail.isEmpty) {
      throw ArgumentError.value(
        email,
        'email',
        'A legacy data owner email must not be empty.',
      );
    }

    return 'member:$normalizedEmail';
  }

  static String firebaseUid(String uid) {
    if (uid.trim().isEmpty) {
      throw ArgumentError.value(
        uid,
        'uid',
        'A Firebase UID must not be empty.',
      );
    }

    // Keep the Firebase UID opaque and case-sensitive. The distinct prefix
    // prevents a legacy email owner from ever sharing the same key.
    return 'member:uid:$uid';
  }

  static String normalizeEmail(String email) => email.trim().toLowerCase();
}
