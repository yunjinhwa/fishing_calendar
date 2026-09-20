import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/validation/auth_input_validator.dart';
import '../models/user_plan.dart';
import '../models/user_plan_policy.dart';

enum AuthSignInResult {
  success,
  accountNotFound,
  invalidCredentials,
  credentialSetupRequired,
}

class AuthSessionRepository extends ChangeNotifier {
  AuthSessionRepository._();

  static final AuthSessionRepository instance = AuthSessionRepository._();

  static const String _hasActiveSessionKey = 'auth_has_active_session';
  static const String _planKey = 'auth_plan';
  static const String _emailKey = 'auth_email';
  static const String _nicknameKey = 'auth_nickname';
  static const String _accountPlansKey = 'auth_account_plans';
  static const String _accountMigrationStatusesKey =
      'auth_account_migration_statuses';
  static const String _accountPolicyStatesKey = 'auth_account_policy_states_v1';
  static const String _accountNicknamesKey = 'auth_account_nicknames';
  static const String _accountPasswordHashesKey =
      'auth_account_password_hashes';

  bool _hasActiveSession = false;
  bool _persistsAcrossRestarts = false;
  UserPlan _plan = UserPlan.guest;
  PlanMigrationStatus _migrationStatus = PlanMigrationStatus.none;
  String? _email;
  String? _nickname;
  bool _requiresPasswordSetup = false;

  bool get hasActiveSession => _hasActiveSession;
  bool get persistsAcrossRestarts => _persistsAcrossRestarts;
  UserPlan get plan => _plan;
  PlanMigrationStatus get migrationStatus => _migrationStatus;
  String? get email => _email;
  String? get nickname => _nickname;
  bool get requiresPasswordSetup => _requiresPasswordSetup;

  String get dataOwnerKey {
    final normalizedEmail = _email == null ? '' : _normalizeEmail(_email!);
    if (isMember && normalizedEmail.isNotEmpty) {
      return 'member:$normalizedEmail';
    }

    return 'anonymous';
  }

  String? get memberId {
    if (!isMember || _email == null) {
      return null;
    }

    final normalizedEmail = _normalizeEmail(_email!);
    return normalizedEmail.isEmpty ? null : normalizedEmail;
  }

  bool get isGuest => !_hasActiveSession || _plan == UserPlan.guest;
  bool get isMember => _hasActiveSession && _plan != UserPlan.guest;
  bool get isFree => isMember && _plan == UserPlan.free;
  bool get isPaid => isMember && _plan == UserPlan.paid;
  bool get isPlanMigrationPending =>
      _migrationStatus == PlanMigrationStatus.localToCloudPending;

  UserPlanPolicy get policy =>
      UserPlanPolicy.forPlan(isGuest ? UserPlan.guest : _plan);

  bool get canManageRecords => policy.canManageRecords;
  bool get canUseOfflineRecords => policy.canUseOfflineRecords;
  bool get canUseCloudSync => policy.canUseCloudSync && !isPlanMigrationPending;
  bool get canUseOutbox => policy.usesOutbox;

  bool allows(UserCapability capability) {
    switch (capability) {
      case UserCapability.manageRecords:
        return canManageRecords;
      case UserCapability.cloudSync:
        return canUseCloudSync;
      case UserCapability.outbox:
        return canUseOutbox;
    }
  }

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
        persistsAcrossRestarts: false,
        plan: UserPlan.guest,
        migrationStatus: PlanMigrationStatus.none,
        email: null,
        nickname: null,
        requiresPasswordSetup: false,
        notify: false,
      );
      return;
    }

    final email = prefs.getString(_emailKey);
    final persistedPlan = UserPlan.fromStorageValue(prefs.getString(_planKey));
    final hasPersistedMemberIdentity =
        email != null &&
        AuthInputValidator.isValidEmail(email) &&
        persistedPlan != UserPlan.guest;
    var accountPlan = hasPersistedMemberIdentity
        ? await _readAccountPlan(email)
        : null;

    if (accountPlan == null && hasPersistedMemberIdentity) {
      await _writeAccountState(
        email,
        plan: persistedPlan,
        migrationStatus: PlanMigrationStatus.none,
      );
      await _writeAccountNickname(email, prefs.getString(_nicknameKey));
      accountPlan = persistedPlan;
    }

    final plan = hasPersistedMemberIdentity
        ? accountPlan ?? persistedPlan
        : UserPlan.guest;
    final migrationStatus = plan == UserPlan.paid && email != null
        ? await _readAccountMigrationStatus(email)
        : PlanMigrationStatus.none;
    final passwordHash = email == null
        ? null
        : await _readAccountPasswordHash(email);
    final requiresPasswordSetup =
        plan != UserPlan.guest &&
        email != null &&
        AuthInputValidator.isValidEmail(email) &&
        passwordHash == null;

    _applySession(
      hasActiveSession: true,
      persistsAcrossRestarts: true,
      plan: plan,
      migrationStatus: migrationStatus,
      email: email,
      nickname: prefs.getString(_nicknameKey),
      requiresPasswordSetup: requiresPasswordSetup,
      notify: false,
    );
  }

  Future<void> continueAsGuest() async {
    await _saveSession(
      plan: UserPlan.guest,
      migrationStatus: PlanMigrationStatus.none,
      email: null,
      nickname: null,
      persistSession: true,
      requiresPasswordSetup: false,
    );
  }

  Future<AuthSignInResult> signIn({
    required String email,
    required String password,
    String? nickname,
    bool rememberSession = true,
  }) async {
    final normalizedEmail = _normalizeEmail(email);
    if (!AuthInputValidator.isValidEmail(normalizedEmail) || password.isEmpty) {
      return AuthSignInResult.invalidCredentials;
    }

    final savedPlan = await _readAccountPlan(normalizedEmail);
    if (savedPlan == null) {
      return AuthSignInResult.accountNotFound;
    }

    final savedPasswordHash = await _readAccountPasswordHash(normalizedEmail);
    final passwordHash = _hashPassword(password);
    if (savedPasswordHash == null) {
      return AuthSignInResult.credentialSetupRequired;
    }

    if (savedPasswordHash != passwordHash) {
      return AuthSignInResult.invalidCredentials;
    }

    final plan = savedPlan;
    final migrationStatus = savedPlan == UserPlan.paid
        ? await _readAccountMigrationStatus(normalizedEmail)
        : PlanMigrationStatus.none;
    final accountNickname =
        nickname ?? await _readAccountNickname(normalizedEmail);

    await _writeAccountState(
      normalizedEmail,
      plan: plan,
      migrationStatus: migrationStatus,
    );

    await _saveSession(
      plan: plan,
      migrationStatus: migrationStatus,
      email: normalizedEmail,
      nickname: accountNickname,
      persistSession: rememberSession,
      requiresPasswordSetup: false,
    );
    return AuthSignInResult.success;
  }

  Future<bool> registerAsFree({
    required String email,
    required String password,
    String? nickname,
    bool rememberSession = true,
  }) async {
    final normalizedEmail = _normalizeEmail(email);
    if (!AuthInputValidator.isValidEmail(normalizedEmail)) {
      throw ArgumentError.value(email, 'email', '올바른 이메일 형식이어야 합니다.');
    }
    if (!AuthInputValidator.isValidPassword(password)) {
      throw ArgumentError('비밀번호는 8자 이상이며 영문과 숫자를 포함해야 합니다.');
    }

    if (await _readAccountPlan(normalizedEmail) != null) {
      return false;
    }

    await _writeAccountPasswordHash(normalizedEmail, _hashPassword(password));
    await _writeAccountNickname(normalizedEmail, nickname);
    await _writeAccountState(
      normalizedEmail,
      plan: UserPlan.free,
      migrationStatus: PlanMigrationStatus.none,
    );
    await _saveSession(
      plan: UserPlan.free,
      migrationStatus: PlanMigrationStatus.none,
      email: normalizedEmail,
      nickname: nickname,
      persistSession: rememberSession,
      requiresPasswordSetup: false,
    );
    return true;
  }

  Future<void> setPasswordForCurrentMember(String password) async {
    final currentEmail = _email;
    if (!isMember ||
        currentEmail == null ||
        !AuthInputValidator.isValidEmail(currentEmail)) {
      throw StateError('로그인한 회원만 비밀번호를 설정할 수 있습니다.');
    }

    if (!AuthInputValidator.isValidPassword(password)) {
      throw ArgumentError('비밀번호는 8자 이상이며 영문과 숫자를 포함해야 합니다.');
    }

    await _writeAccountPasswordHash(currentEmail, _hashPassword(password));
    if (_requiresPasswordSetup) {
      _requiresPasswordSetup = false;
      notifyListeners();
    }
  }

  Future<void> changeMemberPlan(
    UserPlan nextPlan, {
    PlanMigrationStatus migrationStatus = PlanMigrationStatus.none,
  }) async {
    if (!isMember) {
      throw StateError('로그인한 회원만 플랜을 변경할 수 있습니다.');
    }

    if (nextPlan == UserPlan.guest) {
      throw ArgumentError.value(nextPlan, 'nextPlan', '회원 플랜만 선택할 수 있습니다.');
    }

    if (_plan == nextPlan && _migrationStatus == migrationStatus) {
      return;
    }

    final currentEmail = _email;
    if (currentEmail != null && currentEmail.trim().isNotEmpty) {
      await _writeAccountState(
        currentEmail,
        plan: nextPlan,
        migrationStatus: migrationStatus,
      );
    }

    await _saveSession(
      plan: nextPlan,
      migrationStatus: migrationStatus,
      email: _email,
      nickname: _nickname,
      persistSession: _persistsAcrossRestarts,
      requiresPasswordSetup: _requiresPasswordSetup,
    );
  }

  Future<void> logout() async {
    if (isMember && _requiresPasswordSetup) {
      throw StateError('로그아웃하기 전에 계정 비밀번호를 설정해야 합니다.');
    }

    final prefs = await SharedPreferences.getInstance();
    await _clearPersistedSession(prefs);

    _applySession(
      hasActiveSession: false,
      persistsAcrossRestarts: false,
      plan: UserPlan.guest,
      migrationStatus: PlanMigrationStatus.none,
      email: null,
      nickname: null,
      requiresPasswordSetup: false,
    );
  }

  Future<void> _saveSession({
    required UserPlan plan,
    required PlanMigrationStatus migrationStatus,
    required String? email,
    required String? nickname,
    required bool persistSession,
    required bool requiresPasswordSetup,
  }) async {
    final prefs = await SharedPreferences.getInstance();

    if (persistSession) {
      _requirePreferenceSuccess(
        await prefs.setString(_planKey, plan.storageValue),
        'save session plan',
      );

      if (email == null || email.trim().isEmpty) {
        _requirePreferenceSuccess(
          await prefs.remove(_emailKey),
          'clear session email',
        );
      } else {
        _requirePreferenceSuccess(
          await prefs.setString(_emailKey, email.trim()),
          'save session email',
        );
      }

      if (nickname == null || nickname.trim().isEmpty) {
        _requirePreferenceSuccess(
          await prefs.remove(_nicknameKey),
          'clear session nickname',
        );
      } else {
        _requirePreferenceSuccess(
          await prefs.setString(_nicknameKey, nickname.trim()),
          'save session nickname',
        );
      }

      _requirePreferenceSuccess(
        await prefs.setBool(_hasActiveSessionKey, true),
        'activate session',
      );
    } else {
      await _clearPersistedSession(prefs);
    }

    _applySession(
      hasActiveSession: true,
      persistsAcrossRestarts: persistSession,
      plan: plan,
      migrationStatus: migrationStatus,
      email: email,
      nickname: nickname,
      requiresPasswordSetup: requiresPasswordSetup,
    );
  }

  Future<void> _clearPersistedSession(SharedPreferences prefs) async {
    _requirePreferenceSuccess(
      await prefs.remove(_hasActiveSessionKey),
      'deactivate session',
    );
    _requirePreferenceSuccess(
      await prefs.remove(_planKey),
      'clear session plan',
    );
    _requirePreferenceSuccess(
      await prefs.remove(_emailKey),
      'clear session email',
    );
    _requirePreferenceSuccess(
      await prefs.remove(_nicknameKey),
      'clear session nickname',
    );
  }

  Future<UserPlan?> _readAccountPlan(String email) async {
    final prefs = await SharedPreferences.getInstance();
    final policyState = _readPolicyStateFromPreferences(prefs, email);
    final policyPlan = policyState?['plan'] as String?;
    switch (policyPlan) {
      case 'free':
        return UserPlan.free;
      case 'paid':
        return UserPlan.paid;
    }

    final plans = _decodeStringMap(prefs.getString(_accountPlansKey));
    final value = plans[_normalizeEmail(email)];
    switch (value) {
      case 'free':
        return UserPlan.free;
      case 'paid':
        return UserPlan.paid;
      default:
        return null;
    }
  }

  Future<PlanMigrationStatus> _readAccountMigrationStatus(String email) async {
    final prefs = await SharedPreferences.getInstance();
    final policyState = _readPolicyStateFromPreferences(prefs, email);
    final policyMigrationStatus = policyState?['migrationStatus'] as String?;
    if (policyMigrationStatus != null) {
      return PlanMigrationStatus.fromStorageValue(policyMigrationStatus);
    }

    final statuses = _decodeStringMap(
      prefs.getString(_accountMigrationStatusesKey),
    );
    return PlanMigrationStatus.fromStorageValue(
      statuses[_normalizeEmail(email)],
    );
  }

  Future<void> _writeAccountState(
    String email, {
    required UserPlan plan,
    required PlanMigrationStatus migrationStatus,
  }) async {
    if (plan == UserPlan.guest) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final normalizedEmail = _normalizeEmail(email);
    final states = _decodeObjectMap(prefs.getString(_accountPolicyStatesKey));
    states[normalizedEmail] = <String, dynamic>{
      'plan': plan.storageValue,
      'migrationStatus': migrationStatus.storageValue,
    };
    _requirePreferenceSuccess(
      await prefs.setString(_accountPolicyStatesKey, jsonEncode(states)),
      'save account policy',
    );
  }

  Map<String, dynamic>? _readPolicyStateFromPreferences(
    SharedPreferences prefs,
    String email,
  ) {
    final states = _decodeObjectMap(prefs.getString(_accountPolicyStatesKey));
    final state = states[_normalizeEmail(email)];
    return state is Map ? Map<String, dynamic>.from(state) : null;
  }

  Future<String?> _readAccountNickname(String email) async {
    final prefs = await SharedPreferences.getInstance();
    final nicknames = _decodeStringMap(prefs.getString(_accountNicknamesKey));
    return nicknames[_normalizeEmail(email)];
  }

  Future<void> _writeAccountNickname(String email, String? nickname) async {
    final normalizedNickname = nickname?.trim();
    if (normalizedNickname == null || normalizedNickname.isEmpty) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final nicknames = _decodeStringMap(prefs.getString(_accountNicknamesKey));
    nicknames[_normalizeEmail(email)] = normalizedNickname;
    _requirePreferenceSuccess(
      await prefs.setString(_accountNicknamesKey, jsonEncode(nicknames)),
      'save account nickname',
    );
  }

  Future<String?> _readAccountPasswordHash(String email) async {
    final prefs = await SharedPreferences.getInstance();
    final hashes = _decodeStringMap(prefs.getString(_accountPasswordHashesKey));
    return hashes[_normalizeEmail(email)];
  }

  Future<void> _writeAccountPasswordHash(
    String email,
    String passwordHash,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final hashes = _decodeStringMap(prefs.getString(_accountPasswordHashesKey));
    hashes[_normalizeEmail(email)] = passwordHash;
    _requirePreferenceSuccess(
      await prefs.setString(_accountPasswordHashesKey, jsonEncode(hashes)),
      'save account password',
    );
  }

  void _requirePreferenceSuccess(bool success, String operation) {
    if (!success) {
      throw StateError('SharedPreferences failed to $operation.');
    }
  }

  Map<String, String> _decodeStringMap(String? value) {
    if (value == null || value.isEmpty) {
      return <String, String>{};
    }

    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map<String, dynamic>) {
        return <String, String>{};
      }

      return decoded.map((key, plan) => MapEntry(key, plan.toString()));
    } on FormatException {
      return <String, String>{};
    }
  }

  Map<String, dynamic> _decodeObjectMap(String? value) {
    if (value == null || value.isEmpty) {
      return <String, dynamic>{};
    }

    try {
      final decoded = jsonDecode(value);
      return decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
    } on FormatException {
      return <String, dynamic>{};
    } on TypeError {
      return <String, dynamic>{};
    }
  }

  String _normalizeEmail(String email) {
    return email.trim().toLowerCase();
  }

  String _hashPassword(String password) {
    return sha256.convert(utf8.encode(password)).toString();
  }

  void _applySession({
    required bool hasActiveSession,
    required bool persistsAcrossRestarts,
    required UserPlan plan,
    required PlanMigrationStatus migrationStatus,
    required String? email,
    required String? nickname,
    required bool requiresPasswordSetup,
    bool notify = true,
  }) {
    final changed =
        _hasActiveSession != hasActiveSession ||
        _persistsAcrossRestarts != persistsAcrossRestarts ||
        _plan != plan ||
        _migrationStatus != migrationStatus ||
        _email != email ||
        _nickname != nickname ||
        _requiresPasswordSetup != requiresPasswordSetup;

    _hasActiveSession = hasActiveSession;
    _persistsAcrossRestarts = persistsAcrossRestarts;
    _plan = plan;
    _migrationStatus = migrationStatus;
    _email = email;
    _nickname = nickname;
    _requiresPasswordSetup = requiresPasswordSetup;

    if (changed && notify) {
      notifyListeners();
    }
  }

  @visibleForTesting
  Future<void> setSessionForTesting({
    required UserPlan plan,
    String? email,
    String? nickname,
    String? password,
    bool rememberSession = true,
    PlanMigrationStatus migrationStatus = PlanMigrationStatus.none,
  }) async {
    if (plan != UserPlan.guest && email != null && email.trim().isNotEmpty) {
      await _writeAccountPasswordHash(
        email,
        _hashPassword(password ?? 'Password1'),
      );
      await _writeAccountNickname(email, nickname);
      await _writeAccountState(
        email,
        plan: plan,
        migrationStatus: migrationStatus,
      );
    }

    await _saveSession(
      plan: plan,
      migrationStatus: migrationStatus,
      email: email,
      nickname: nickname,
      persistSession: rememberSession,
      requiresPasswordSetup: false,
    );
  }

  @visibleForTesting
  void clearMemoryOnlyForTesting() {
    _applySession(
      hasActiveSession: false,
      persistsAcrossRestarts: false,
      plan: UserPlan.guest,
      migrationStatus: PlanMigrationStatus.none,
      email: null,
      nickname: null,
      requiresPasswordSetup: false,
    );
  }
}
