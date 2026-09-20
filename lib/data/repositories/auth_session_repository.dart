import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/user_plan.dart';

class AuthSessionRepository extends ChangeNotifier {
  AuthSessionRepository._();

  static final AuthSessionRepository instance = AuthSessionRepository._();

  static const String _hasActiveSessionKey = 'auth_has_active_session';
  static const String _planKey = 'auth_plan';
  static const String _emailKey = 'auth_email';
  static const String _nicknameKey = 'auth_nickname';

  bool _hasActiveSession = false;
  UserPlan _plan = UserPlan.guest;
  String? _email;
  String? _nickname;

  bool get hasActiveSession => _hasActiveSession;
  UserPlan get plan => _plan;
  String? get email => _email;
  String? get nickname => _nickname;

  bool get isGuest => !_hasActiveSession || _plan == UserPlan.guest;
  bool get isMember => _hasActiveSession && _plan != UserPlan.guest;
  bool get canManageRecords => isMember;

  String get planLabel {
    if (!_hasActiveSession) {
      return '방문 전';
    }

    return _plan.label;
  }

  String get displayName {
    if (!_hasActiveSession) {
      return '사용자';
    }

    if (_plan == UserPlan.guest) {
      return '비회원';
    }

    final savedNickname = _nickname?.trim();
    if (savedNickname != null && savedNickname.isNotEmpty) {
      return savedNickname;
    }

    final savedEmail = _email?.trim();
    if (savedEmail != null && savedEmail.isNotEmpty) {
      return savedEmail;
    }

    return _plan.label;
  }

  Future<void> loadSession() async {
    final prefs = await SharedPreferences.getInstance();
    final hasSession = prefs.getBool(_hasActiveSessionKey) ?? false;

    if (!hasSession) {
      _applySession(
        hasActiveSession: false,
        plan: UserPlan.guest,
        email: null,
        nickname: null,
        notify: false,
      );
      return;
    }

    _applySession(
      hasActiveSession: true,
      plan: UserPlan.fromStorageValue(prefs.getString(_planKey)),
      email: prefs.getString(_emailKey),
      nickname: prefs.getString(_nicknameKey),
      notify: false,
    );
  }

  Future<void> continueAsGuest() async {
    await _saveSession(plan: UserPlan.guest, email: null, nickname: null);
  }

  Future<void> signInAsFree({required String email, String? nickname}) async {
    await _saveSession(plan: UserPlan.free, email: email, nickname: nickname);
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_hasActiveSessionKey);
    await prefs.remove(_planKey);
    await prefs.remove(_emailKey);
    await prefs.remove(_nicknameKey);

    _applySession(
      hasActiveSession: false,
      plan: UserPlan.guest,
      email: null,
      nickname: null,
    );
  }

  Future<void> _saveSession({
    required UserPlan plan,
    required String? email,
    required String? nickname,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_hasActiveSessionKey, true);
    await prefs.setString(_planKey, plan.storageValue);

    if (email == null || email.trim().isEmpty) {
      await prefs.remove(_emailKey);
    } else {
      await prefs.setString(_emailKey, email.trim());
    }

    if (nickname == null || nickname.trim().isEmpty) {
      await prefs.remove(_nicknameKey);
    } else {
      await prefs.setString(_nicknameKey, nickname.trim());
    }

    _applySession(
      hasActiveSession: true,
      plan: plan,
      email: email,
      nickname: nickname,
    );
  }

  void _applySession({
    required bool hasActiveSession,
    required UserPlan plan,
    required String? email,
    required String? nickname,
    bool notify = true,
  }) {
    final changed =
        _hasActiveSession != hasActiveSession ||
        _plan != plan ||
        _email != email ||
        _nickname != nickname;

    _hasActiveSession = hasActiveSession;
    _plan = plan;
    _email = email;
    _nickname = nickname;

    if (changed && notify) {
      notifyListeners();
    }
  }

  @visibleForTesting
  Future<void> setSessionForTesting({
    required UserPlan plan,
    String? email,
    String? nickname,
  }) async {
    await _saveSession(plan: plan, email: email, nickname: nickname);
  }

  @visibleForTesting
  void clearMemoryOnlyForTesting() {
    _applySession(
      hasActiveSession: false,
      plan: UserPlan.guest,
      email: null,
      nickname: null,
    );
  }
}
