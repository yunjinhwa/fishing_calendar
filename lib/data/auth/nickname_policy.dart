abstract final class NicknamePolicy {
  static final RegExp _allowedCharacters = RegExp(r'^[A-Za-z0-9가-힣 _-]+$');

  static String displayValue(String value) => value.trim();

  static String canonicalKey(String value) => displayValue(value).toLowerCase();

  static bool isValid(String value) {
    final nickname = displayValue(value);
    return nickname.length >= 2 &&
        nickname.length <= 20 &&
        _allowedCharacters.hasMatch(nickname);
  }
}
