class AuthInputValidator {
  AuthInputValidator._();

  static final RegExp _emailPattern = RegExp(
    r"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@"
    r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
    r'(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$',
  );

  static bool isValidEmail(String value) {
    return _emailPattern.hasMatch(value.trim());
  }

  static bool isValidPassword(String value) {
    return value.length >= 8 &&
        RegExp(r'[A-Za-z]').hasMatch(value) &&
        RegExp(r'\d').hasMatch(value);
  }

  static bool isValidNickname(String value) {
    final nickname = value.trim();
    return nickname.length >= 2 && nickname.length <= 20;
  }
}
