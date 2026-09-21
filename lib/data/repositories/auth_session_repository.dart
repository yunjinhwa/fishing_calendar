import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/validation/auth_input_validator.dart';
import '../auth/auth_gateway.dart';
import '../auth/nickname_policy.dart';
import '../local/data_owner_key.dart';
import '../local/local_identity_migration_service.dart';
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
  static const String _memberIdKey = 'auth_member_id';
  static const String _signOutOnRestartKey = 'auth_sign_out_on_restart';
  static const String _accountPlansKey = 'auth_account_plans';
  static const String _accountMigrationStatusesKey =
      'auth_account_migration_statuses';
  static const String _accountPolicyStatesKey = 'auth_account_policy_states_v1';
  static const String _accountNicknamesKey = 'auth_account_nicknames';
  static const String _accountPasswordHashesKey =
      'auth_account_password_hashes';
  static const String _firebasePolicyStatesKey =
      'auth_firebase_policy_states_v1';
  static const String _firebaseNicknamesKey = 'auth_firebase_nicknames_v1';

  AuthGateway? _authGateway;
  bool _hasActiveSession = false;
  bool _persistsAcrossRestarts = false;
  UserPlan _plan = UserPlan.guest;
  PlanMigrationStatus _migrationStatus = PlanMigrationStatus.none;
  String? _memberId;
  String? _email;
  String? _nickname;
  bool _requiresPasswordSetup = false;
  AuthFailure? _lastAuthFailure;

  bool get hasActiveSession => _hasActiveSession;
  bool get persistsAcrossRestarts => _persistsAcrossRestarts;
  UserPlan get plan => _plan;
  PlanMigrationStatus get migrationStatus => _migrationStatus;
  String? get email => _email;
  String? get nickname => _nickname;
  bool get requiresPasswordSetup => _requiresPasswordSetup;
  bool get usesFirebaseAuth => _authGateway != null;
  AuthFailure? get lastAuthFailure => _lastAuthFailure;

  String get dataOwnerKey {
    if (!isMember) {
      return DataOwnerKey.anonymous;
    }

    final uid = _memberId?.trim();
    if (_authGateway != null && uid != null && uid.isNotEmpty) {
      return DataOwnerKey.firebaseUid(uid);
    }

    final normalizedEmail = _email == null
        ? ''
        : DataOwnerKey.normalizeEmail(_email!);
    return normalizedEmail.isEmpty
        ? DataOwnerKey.anonymous
        : DataOwnerKey.legacyEmail(normalizedEmail);
  }

  String? get memberId {
    if (!isMember) {
      return null;
    }

    final id = _memberId?.trim();
    if (id != null && id.isNotEmpty) {
      return id;
    }

    final normalizedEmail = _email == null
        ? ''
        : DataOwnerKey.normalizeEmail(_email!);
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
  bool get canUseCloudSync =>
      policy.canUseCloudSync &&
      !isPlanMigrationPending &&
      (_authGateway == null || _memberId != null);
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

  /// Passing a gateway opts this repository into Firebase-backed member auth.
  /// A null gateway keeps the existing local-only development behavior.
  void configureAuthGateway(AuthGateway? gateway) {
    _authGateway = gateway;
    _lastAuthFailure = gateway?.availabilityFailure;
  }

  Future<void> loadSession() async {
    final gateway = _authGateway;
    if (gateway != null) {
      await _loadFirebaseSession(gateway);
      return;
    }
    await _loadLegacySession();
  }

  Future<void> _loadLegacySession() async {
    final prefs = await SharedPreferences.getInstance();
    final hasSession = prefs.getBool(_hasActiveSessionKey) ?? false;

    if (!hasSession) {
      _applySignedOut(notify: false);
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
      memberId: null,
      email: email,
      nickname: prefs.getString(_nicknameKey),
      requiresPasswordSetup: requiresPasswordSetup,
      notify: false,
    );
  }

  Future<void> _loadFirebaseSession(AuthGateway gateway) async {
    final prefs = await SharedPreferences.getInstance();
    _lastAuthFailure = gateway.availabilityFailure;
    if (gateway.availability == AuthGatewayAvailability.unavailable) {
      _applySignedOut(notify: false);
      return;
    }

    if (prefs.getBool(_signOutOnRestartKey) ?? false) {
      final preserveGuestSession =
          (prefs.getBool(_hasActiveSessionKey) ?? false) &&
          UserPlan.fromStorageValue(prefs.getString(_planKey)) ==
              UserPlan.guest;
      try {
        await gateway.signOut();
        await _removePreference(
          prefs,
          _signOutOnRestartKey,
          'clear restart sign-out',
        );
        if (!preserveGuestSession) {
          await _clearPersistedSession(prefs);
        }
      } on AuthFailure catch (failure) {
        _lastAuthFailure = failure;
        _applySignedOut(notify: false);
        return;
      }
    }

    AuthUser? user;
    try {
      user = await gateway.restoreUser();
    } on AuthFailure catch (failure) {
      _lastAuthFailure = failure;
      _applySignedOut(notify: false);
      return;
    }

    if (user == null) {
      if (await _restoreLegacyPasswordSetupSession(prefs)) {
        return;
      }
      final hasGuestSession =
          (prefs.getBool(_hasActiveSessionKey) ?? false) &&
          UserPlan.fromStorageValue(prefs.getString(_planKey)) ==
              UserPlan.guest;
      if (hasGuestSession) {
        _applySession(
          hasActiveSession: true,
          persistsAcrossRestarts: true,
          plan: UserPlan.guest,
          migrationStatus: PlanMigrationStatus.none,
          memberId: null,
          email: null,
          nickname: null,
          requiresPasswordSetup: false,
          notify: false,
        );
      } else {
        _applySignedOut(notify: false);
      }
      return;
    }

    try {
      await _establishFirebaseSession(
        gateway: gateway,
        user: user,
        rememberSession: true,
        migrateLegacyAccount: false,
        allowCachedNickname: true,
        notify: false,
      );
      _lastAuthFailure = null;
    } on Object catch (error, stackTrace) {
      _lastAuthFailure = _asAuthFailure(error, stackTrace);
      await _bestEffortSignOut(gateway);
      _applySignedOut(notify: false);
    }
  }

  Future<bool> _restoreLegacyPasswordSetupSession(
    SharedPreferences prefs,
  ) async {
    final hasSession = prefs.getBool(_hasActiveSessionKey) ?? false;
    final email = prefs.getString(_emailKey);
    final plan = UserPlan.fromStorageValue(prefs.getString(_planKey));
    final hasFirebaseMemberId =
        (prefs.getString(_memberIdKey)?.trim().isNotEmpty ?? false);
    final isValidLegacyMember =
        hasSession &&
        !hasFirebaseMemberId &&
        plan != UserPlan.guest &&
        email != null &&
        AuthInputValidator.isValidEmail(email);
    if (!isValidLegacyMember || await _readAccountPasswordHash(email) != null) {
      return false;
    }

    await _loadLegacySession();
    return _requiresPasswordSetup;
  }

  Future<void> continueAsGuest() async {
    final gateway = _authGateway;
    var needsSignOutRetry = false;
    if (gateway != null) {
      if (gateway.availability == AuthGatewayAvailability.available) {
        try {
          await gateway.signOut();
        } on AuthFailure catch (failure) {
          _lastAuthFailure = failure;
          needsSignOutRetry = true;
        }
      } else {
        _lastAuthFailure = gateway.availabilityFailure;
        needsSignOutRetry = true;
      }
    }

    await _saveSession(
      plan: UserPlan.guest,
      migrationStatus: PlanMigrationStatus.none,
      memberId: null,
      email: null,
      nickname: null,
      persistSession: true,
      requiresPasswordSetup: false,
    );
    final prefs = await SharedPreferences.getInstance();
    if (needsSignOutRetry) {
      _requirePreferenceSuccess(
        await prefs.setBool(_signOutOnRestartKey, true),
        'schedule guest sign-out retry',
      );
    } else {
      await _removePreference(
        prefs,
        _signOutOnRestartKey,
        'clear restart sign-out',
      );
    }
  }

  Future<AuthSignInResult> signIn({
    required String email,
    required String password,
    String? nickname,
    bool rememberSession = true,
  }) async {
    final normalizedEmail = DataOwnerKey.normalizeEmail(email);
    if (!AuthInputValidator.isValidEmail(normalizedEmail) || password.isEmpty) {
      return AuthSignInResult.invalidCredentials;
    }

    final gateway = _authGateway;
    if (gateway != null) {
      return _signInWithFirebase(
        gateway: gateway,
        email: normalizedEmail,
        password: password,
        nickname: nickname,
        rememberSession: rememberSession,
      );
    }
    return _signInLocally(
      email: normalizedEmail,
      password: password,
      nickname: nickname,
      rememberSession: rememberSession,
    );
  }

  Future<AuthSignInResult> _signInLocally({
    required String email,
    required String password,
    required String? nickname,
    required bool rememberSession,
  }) async {
    final savedPlan = await _readAccountPlan(email);
    if (savedPlan == null) {
      return AuthSignInResult.accountNotFound;
    }

    final savedPasswordHash = await _readAccountPasswordHash(email);
    if (savedPasswordHash == null) {
      return AuthSignInResult.credentialSetupRequired;
    }
    if (savedPasswordHash != _hashPassword(password)) {
      return AuthSignInResult.invalidCredentials;
    }

    final migrationStatus = savedPlan == UserPlan.paid
        ? await _readAccountMigrationStatus(email)
        : PlanMigrationStatus.none;
    final accountNickname = nickname ?? await _readAccountNickname(email);
    await _writeAccountState(
      email,
      plan: savedPlan,
      migrationStatus: migrationStatus,
    );
    await _saveSession(
      plan: savedPlan,
      migrationStatus: migrationStatus,
      memberId: null,
      email: email,
      nickname: accountNickname,
      persistSession: rememberSession,
      requiresPasswordSetup: false,
    );
    return AuthSignInResult.success;
  }

  Future<AuthSignInResult> _signInWithFirebase({
    required AuthGateway gateway,
    required String email,
    required String password,
    required String? nickname,
    required bool rememberSession,
  }) async {
    _requireAvailableGateway(gateway);
    if (!rememberSession) {
      await _scheduleRestartSignOut();
    }
    AuthUser user;
    String? resolvedNickname = nickname;
    var migrateLegacyAccount = false;

    try {
      user = await gateway.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      final localPasswordHash = await _readAccountPasswordHash(email);
      migrateLegacyAccount =
          localPasswordHash != null &&
          localPasswordHash == _hashPassword(password);
    } on AuthFailure catch (failure) {
      final canTryLegacyMigration =
          failure.code == AuthFailureCode.userNotFound ||
          failure.code == AuthFailureCode.invalidCredentials;
      if (!canTryLegacyMigration) {
        rethrow;
      }

      final legacyPlan = await _readAccountPlan(email);
      if (legacyPlan == null) {
        return failure.code == AuthFailureCode.userNotFound
            ? AuthSignInResult.accountNotFound
            : AuthSignInResult.invalidCredentials;
      }
      final legacyPasswordHash = await _readAccountPasswordHash(email);
      if (legacyPasswordHash == null) {
        return AuthSignInResult.credentialSetupRequired;
      }
      if (legacyPasswordHash != _hashPassword(password)) {
        return AuthSignInResult.invalidCredentials;
      }

      resolvedNickname ??= await _readAccountNickname(email);
      try {
        user = await gateway.registerWithEmailAndPassword(
          email: email,
          password: password,
        );
      } on AuthFailure catch (registrationFailure) {
        if (registrationFailure.code == AuthFailureCode.emailAlreadyInUse) {
          return AuthSignInResult.invalidCredentials;
        }
        rethrow;
      }
      migrateLegacyAccount = true;
    }

    try {
      await _establishFirebaseSession(
        gateway: gateway,
        user: user,
        rememberSession: rememberSession,
        nicknameOverride: resolvedNickname,
        migrateLegacyAccount: migrateLegacyAccount,
      );
      _lastAuthFailure = null;
      return AuthSignInResult.success;
    } on Object catch (error, stackTrace) {
      await _bestEffortSignOut(gateway);
      throw _asAuthFailure(error, stackTrace);
    }
  }

  Future<bool> registerAsFree({
    required String email,
    required String password,
    required String nickname,
    bool rememberSession = true,
  }) async {
    final normalizedEmail = DataOwnerKey.normalizeEmail(email);
    final normalizedNickname = NicknamePolicy.displayValue(nickname);
    if (!AuthInputValidator.isValidEmail(normalizedEmail)) {
      throw ArgumentError.value(email, 'email', '올바른 이메일 형식이어야 합니다.');
    }
    if (!AuthInputValidator.isValidPassword(password)) {
      throw ArgumentError('비밀번호는 8자 이상이며 영문과 숫자를 포함해야 합니다.');
    }
    if (!AuthInputValidator.isValidNickname(normalizedNickname)) {
      throw ArgumentError('닉네임은 2~20자의 한글, 영문, 숫자, 공백, 밑줄, 하이픈만 사용할 수 있습니다.');
    }

    final gateway = _authGateway;
    if (gateway != null) {
      return _registerWithFirebase(
        gateway: gateway,
        email: normalizedEmail,
        password: password,
        nickname: normalizedNickname,
        rememberSession: rememberSession,
      );
    }
    return _registerLocally(
      email: normalizedEmail,
      password: password,
      nickname: normalizedNickname,
      rememberSession: rememberSession,
    );
  }

  Future<bool> _registerLocally({
    required String email,
    required String password,
    required String nickname,
    required bool rememberSession,
  }) async {
    if (await _readAccountPlan(email) != null) {
      return false;
    }
    if (await _isLocalNicknameTaken(nickname)) {
      throw const AuthFailure(
        code: AuthFailureCode.nicknameAlreadyInUse,
        message: '이미 사용 중인 닉네임입니다.',
      );
    }

    await _writeAccountPasswordHash(email, _hashPassword(password));
    await _writeAccountNickname(email, nickname);
    await _writeAccountState(
      email,
      plan: UserPlan.free,
      migrationStatus: PlanMigrationStatus.none,
    );
    await _saveSession(
      plan: UserPlan.free,
      migrationStatus: PlanMigrationStatus.none,
      memberId: null,
      email: email,
      nickname: nickname,
      persistSession: rememberSession,
      requiresPasswordSetup: false,
    );
    return true;
  }

  Future<bool> _registerWithFirebase({
    required AuthGateway gateway,
    required String email,
    required String password,
    required String nickname,
    required bool rememberSession,
  }) async {
    _requireAvailableGateway(gateway);

    // Existing local accounts must prove ownership through sign-in so their
    // plan and records can be claimed safely.
    if (await _readAccountPlan(email) != null) {
      return false;
    }
    if (!rememberSession) {
      await _scheduleRestartSignOut();
    }

    AuthUser user;
    try {
      user = await gateway.registerWithEmailAndPassword(
        email: email,
        password: password,
      );
    } on AuthFailure catch (failure) {
      if (failure.code == AuthFailureCode.emailAlreadyInUse) {
        return false;
      }
      rethrow;
    }

    try {
      await _establishFirebaseSession(
        gateway: gateway,
        user: user,
        rememberSession: rememberSession,
        nicknameOverride: nickname,
        migrateLegacyAccount: false,
      );
      _lastAuthFailure = null;
      return true;
    } on Object catch (error, stackTrace) {
      final failure = _asAuthFailure(error, stackTrace);
      await _rollbackNewFirebaseRegistration(
        gateway,
        user: user,
        nickname: nickname,
        failure: failure,
      );
      throw failure;
    }
  }

  Future<void> _establishFirebaseSession({
    required AuthGateway gateway,
    required AuthUser user,
    required bool rememberSession,
    required bool migrateLegacyAccount,
    String? nicknameOverride,
    bool allowCachedNickname = false,
    bool notify = true,
  }) async {
    if (user.isAnonymous || user.uid.trim().isEmpty) {
      throw const AuthFailure(
        code: AuthFailureCode.accountConflict,
        message: '이메일 회원 계정만 사용할 수 있습니다.',
      );
    }
    final normalizedEmail = DataOwnerKey.normalizeEmail(user.email ?? '');
    if (!AuthInputValidator.isValidEmail(normalizedEmail)) {
      throw const AuthFailure(
        code: AuthFailureCode.accountConflict,
        message: '인증 계정의 이메일 정보를 확인할 수 없습니다.',
      );
    }

    await LocalIdentityMigrationService.instance.claimLegacyMemberData(
      firebaseUid: user.uid,
      authenticatedEmail: normalizedEmail,
      allowInitialClaim: migrateLegacyAccount,
    );

    var state = await _readFirebaseAccountState(user.uid);
    if (state == null) {
      final legacyPlan = migrateLegacyAccount
          ? await _readAccountPlan(normalizedEmail)
          : null;
      final plan = legacyPlan ?? UserPlan.free;
      final migrationStatus = plan == UserPlan.paid
          ? await _readAccountMigrationStatus(normalizedEmail)
          : PlanMigrationStatus.none;
      await _writeFirebaseAccountState(
        user.uid,
        plan: plan,
        migrationStatus: migrationStatus,
      );
      state = _FirebaseAccountState(
        plan: plan,
        migrationStatus: migrationStatus,
      );
    }

    String? nickname;
    try {
      nickname = await gateway.getRegisteredNickname(user.uid);
    } on AuthFailure catch (failure) {
      final canUseCache =
          allowCachedNickname &&
          failure.code == AuthFailureCode.networkUnavailable;
      if (!canUseCache) {
        rethrow;
      }
      nickname = await _readFirebaseNickname(user.uid);
      if (nickname == null || !AuthInputValidator.isValidNickname(nickname)) {
        rethrow;
      }
    }
    if (nickname == null) {
      var nicknameCandidate = nicknameOverride?.trim();
      nicknameCandidate = nicknameCandidate == null || nicknameCandidate.isEmpty
          ? user.displayName?.trim()
          : nicknameCandidate;
      nicknameCandidate =
          migrateLegacyAccount &&
              (nicknameCandidate == null || nicknameCandidate.isEmpty)
          ? await _readAccountNickname(normalizedEmail)
          : nicknameCandidate;
      if (nicknameCandidate == null ||
          !AuthInputValidator.isValidNickname(nicknameCandidate)) {
        throw const AuthFailure(
          code: AuthFailureCode.nicknameRequired,
          message: '계정을 계속 사용하려면 닉네임을 설정해야 합니다.',
        );
      }
      nickname = await gateway.claimNickname(
        uid: user.uid,
        nickname: nicknameCandidate,
      );
    }

    if (user.displayName != nickname) {
      try {
        user = await gateway.updateDisplayName(nickname);
      } on AuthFailure {
        // Firestore owns nickname uniqueness. The Firebase Auth display name
        // can be repaired on a later successful sign-in.
      }
    }
    await _writeFirebaseNickname(user.uid, nickname);

    if (migrateLegacyAccount) {
      await _removeAccountPasswordHash(normalizedEmail);
    }
    await _saveSession(
      plan: state.plan,
      migrationStatus: state.migrationStatus,
      memberId: user.uid,
      email: normalizedEmail,
      nickname: nickname,
      persistSession: rememberSession,
      requiresPasswordSetup: false,
      notify: notify,
    );

    final prefs = await SharedPreferences.getInstance();
    if (rememberSession) {
      await _removePreference(
        prefs,
        _signOutOnRestartKey,
        'clear restart sign-out',
      );
    } else {
      _requirePreferenceSuccess(
        await prefs.setBool(_signOutOnRestartKey, true),
        'schedule restart sign-out',
      );
    }
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

    final gateway = _authGateway;
    if (gateway != null && _memberId != null) {
      _requireAvailableGateway(gateway);
      await gateway.updatePassword(password);
    } else {
      await _writeAccountPasswordHash(currentEmail, _hashPassword(password));
    }

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

    final uid = _authGateway == null ? null : _memberId;
    if (uid != null && uid.trim().isNotEmpty) {
      await _writeFirebaseAccountState(
        uid,
        plan: nextPlan,
        migrationStatus: migrationStatus,
      );
    } else {
      final currentEmail = _email;
      if (currentEmail != null && currentEmail.trim().isNotEmpty) {
        await _writeAccountState(
          currentEmail,
          plan: nextPlan,
          migrationStatus: migrationStatus,
        );
      }
    }

    await _saveSession(
      plan: nextPlan,
      migrationStatus: migrationStatus,
      memberId: _memberId,
      email: _email,
      nickname: _nickname,
      persistSession: _persistsAcrossRestarts,
      requiresPasswordSetup: _requiresPasswordSetup,
    );
    if (_authGateway != null && !_persistsAcrossRestarts) {
      final prefs = await SharedPreferences.getInstance();
      _requirePreferenceSuccess(
        await prefs.setBool(_signOutOnRestartKey, true),
        'preserve restart sign-out',
      );
    }
  }

  Future<void> logout() async {
    if (isMember && _requiresPasswordSetup) {
      throw StateError('로그아웃하기 전에 계정 비밀번호를 설정해야 합니다.');
    }

    AuthFailure? signOutFailure;
    final gateway = _authGateway;
    if (gateway != null) {
      if (gateway.availability == AuthGatewayAvailability.available) {
        try {
          await gateway.signOut();
        } on AuthFailure catch (failure) {
          signOutFailure = failure;
        }
      } else {
        signOutFailure =
            gateway.availabilityFailure ??
            const AuthFailure(
              code: AuthFailureCode.serviceUnavailable,
              message: 'Firebase 로그아웃을 완료할 수 없습니다.',
            );
      }
    }

    final prefs = await SharedPreferences.getInstance();
    await _clearPersistedSession(prefs);
    if (signOutFailure == null) {
      await _removePreference(
        prefs,
        _signOutOnRestartKey,
        'clear restart sign-out',
      );
    } else {
      _requirePreferenceSuccess(
        await prefs.setBool(_signOutOnRestartKey, true),
        'schedule failed sign-out retry',
      );
    }
    _applySignedOut();

    if (signOutFailure != null) {
      _lastAuthFailure = signOutFailure;
      throw signOutFailure;
    }
  }

  Future<String?> getIdToken({bool forceRefresh = false}) async {
    final gateway = _authGateway;
    if (gateway == null || !isMember || _memberId == null) {
      return null;
    }
    _requireAvailableGateway(gateway);
    return gateway.getIdToken(forceRefresh: forceRefresh);
  }

  Future<void> _saveSession({
    required UserPlan plan,
    required PlanMigrationStatus migrationStatus,
    required String? memberId,
    required String? email,
    required String? nickname,
    required bool persistSession,
    required bool requiresPasswordSetup,
    bool notify = true,
  }) async {
    final prefs = await SharedPreferences.getInstance();

    if (persistSession) {
      _requirePreferenceSuccess(
        await prefs.setString(_planKey, plan.storageValue),
        'save session plan',
      );
      await _writeOptionalString(prefs, _memberIdKey, memberId, 'member ID');
      await _writeOptionalString(prefs, _emailKey, email, 'session email');
      await _writeOptionalString(
        prefs,
        _nicknameKey,
        nickname,
        'session nickname',
      );
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
      memberId: memberId,
      email: email,
      nickname: nickname,
      requiresPasswordSetup: requiresPasswordSetup,
      notify: notify,
    );
  }

  Future<void> _writeOptionalString(
    SharedPreferences prefs,
    String key,
    String? value,
    String label,
  ) async {
    final normalized = value?.trim();
    if (normalized == null || normalized.isEmpty) {
      await _removePreference(prefs, key, 'clear $label');
    } else {
      _requirePreferenceSuccess(
        await prefs.setString(key, normalized),
        'save $label',
      );
    }
  }

  Future<void> _clearPersistedSession(SharedPreferences prefs) async {
    for (final entry in <(String, String)>[
      (_hasActiveSessionKey, 'active session'),
      (_planKey, 'session plan'),
      (_memberIdKey, 'member ID'),
      (_emailKey, 'session email'),
      (_nicknameKey, 'session nickname'),
    ]) {
      await _removePreference(prefs, entry.$1, 'clear ${entry.$2}');
    }
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
    final value = plans[DataOwnerKey.normalizeEmail(email)];
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
      statuses[DataOwnerKey.normalizeEmail(email)],
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
    final states = _decodeObjectMap(prefs.getString(_accountPolicyStatesKey));
    states[DataOwnerKey.normalizeEmail(email)] = <String, dynamic>{
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
    final state = states[DataOwnerKey.normalizeEmail(email)];
    return state is Map ? Map<String, dynamic>.from(state) : null;
  }

  Future<_FirebaseAccountState?> _readFirebaseAccountState(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    final states = _decodeObjectMap(prefs.getString(_firebasePolicyStatesKey));
    final rawState = states[uid];
    if (rawState is! Map) {
      return null;
    }
    final state = Map<String, dynamic>.from(rawState);
    final plan = UserPlan.fromStorageValue(state['plan'] as String?);
    if (plan == UserPlan.guest) {
      return null;
    }
    return _FirebaseAccountState(
      plan: plan,
      migrationStatus: plan == UserPlan.paid
          ? PlanMigrationStatus.fromStorageValue(
              state['migrationStatus'] as String?,
            )
          : PlanMigrationStatus.none,
    );
  }

  Future<void> _writeFirebaseAccountState(
    String uid, {
    required UserPlan plan,
    required PlanMigrationStatus migrationStatus,
  }) async {
    if (plan == UserPlan.guest || uid.trim().isEmpty) {
      throw ArgumentError('Firebase 회원 정책에는 유효한 UID와 회원 플랜이 필요합니다.');
    }
    final prefs = await SharedPreferences.getInstance();
    final states = _decodeObjectMap(prefs.getString(_firebasePolicyStatesKey));
    states[uid] = <String, dynamic>{
      'plan': plan.storageValue,
      'migrationStatus': migrationStatus.storageValue,
    };
    _requirePreferenceSuccess(
      await prefs.setString(_firebasePolicyStatesKey, jsonEncode(states)),
      'save Firebase account policy',
    );
  }

  Future<String?> _readAccountNickname(String email) async {
    final prefs = await SharedPreferences.getInstance();
    final nicknames = _decodeStringMap(prefs.getString(_accountNicknamesKey));
    return nicknames[DataOwnerKey.normalizeEmail(email)];
  }

  Future<bool> _isLocalNicknameTaken(String nickname) async {
    final nicknameKey = NicknamePolicy.canonicalKey(nickname);
    final prefs = await SharedPreferences.getInstance();
    final nicknames = _decodeStringMap(prefs.getString(_accountNicknamesKey));
    return nicknames.values.any(
      (storedNickname) =>
          AuthInputValidator.isValidNickname(storedNickname) &&
          NicknamePolicy.canonicalKey(storedNickname) == nicknameKey,
    );
  }

  Future<void> _writeAccountNickname(String email, String? nickname) async {
    final normalizedNickname = nickname == null
        ? null
        : NicknamePolicy.displayValue(nickname);
    if (normalizedNickname == null || normalizedNickname.isEmpty) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final nicknames = _decodeStringMap(prefs.getString(_accountNicknamesKey));
    nicknames[DataOwnerKey.normalizeEmail(email)] = normalizedNickname;
    _requirePreferenceSuccess(
      await prefs.setString(_accountNicknamesKey, jsonEncode(nicknames)),
      'save account nickname',
    );
  }

  Future<String?> _readFirebaseNickname(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    return _decodeStringMap(prefs.getString(_firebaseNicknamesKey))[uid];
  }

  Future<void> _writeFirebaseNickname(String uid, String nickname) async {
    final normalizedNickname = NicknamePolicy.displayValue(nickname);
    if (normalizedNickname.isEmpty) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final nicknames = _decodeStringMap(prefs.getString(_firebaseNicknamesKey));
    nicknames[uid] = normalizedNickname;
    _requirePreferenceSuccess(
      await prefs.setString(_firebaseNicknamesKey, jsonEncode(nicknames)),
      'save Firebase account nickname',
    );
  }

  Future<String?> _readAccountPasswordHash(String email) async {
    final prefs = await SharedPreferences.getInstance();
    final hashes = _decodeStringMap(prefs.getString(_accountPasswordHashesKey));
    return hashes[DataOwnerKey.normalizeEmail(email)];
  }

  Future<void> _writeAccountPasswordHash(
    String email,
    String passwordHash,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final hashes = _decodeStringMap(prefs.getString(_accountPasswordHashesKey));
    hashes[DataOwnerKey.normalizeEmail(email)] = passwordHash;
    _requirePreferenceSuccess(
      await prefs.setString(_accountPasswordHashesKey, jsonEncode(hashes)),
      'save account password',
    );
  }

  Future<void> _removeAccountPasswordHash(String email) async {
    final prefs = await SharedPreferences.getInstance();
    final rawHashes = prefs.getString(_accountPasswordHashesKey);
    if (rawHashes == null) {
      return;
    }
    final hashes = _decodeStringMap(rawHashes);
    if (hashes.remove(DataOwnerKey.normalizeEmail(email)) == null) {
      return;
    }
    _requirePreferenceSuccess(
      await prefs.setString(_accountPasswordHashesKey, jsonEncode(hashes)),
      'remove migrated local password',
    );
  }

  void _requireAvailableGateway(AuthGateway gateway) {
    final failure = gateway.availabilityFailure;
    if (gateway.availability == AuthGatewayAvailability.unavailable) {
      throw failure ??
          const AuthFailure(
            code: AuthFailureCode.serviceUnavailable,
            message: 'Firebase 인증을 사용할 수 없습니다.',
          );
    }
  }

  Future<void> _bestEffortSignOut(AuthGateway gateway) async {
    try {
      await gateway.signOut();
    } on Object {
      // The original operation error is more useful to the caller.
    }
  }

  Future<void> _rollbackNewFirebaseRegistration(
    AuthGateway gateway, {
    required AuthUser user,
    required String nickname,
    required AuthFailure failure,
  }) async {
    var canDeleteAccount = failure.code == AuthFailureCode.nicknameAlreadyInUse;
    if (!canDeleteAccount) {
      try {
        await gateway.releaseNickname(uid: user.uid, nickname: nickname);
        canDeleteAccount = true;
      } on Object {
        // Keep the account recoverable when the nickname store is unavailable.
      }
    }

    if (canDeleteAccount) {
      try {
        await gateway.deleteCurrentUser();
      } on Object {
        // The original registration failure is more useful to the caller.
      }
    }
    await _bestEffortSignOut(gateway);
  }

  Future<void> _scheduleRestartSignOut() async {
    final prefs = await SharedPreferences.getInstance();
    _requirePreferenceSuccess(
      await prefs.setBool(_signOutOnRestartKey, true),
      'schedule restart sign-out',
    );
  }

  AuthFailure _asAuthFailure(Object error, StackTrace stackTrace) {
    if (error is AuthFailure) {
      return error;
    }
    if (error is LocalIdentityMigrationConflict) {
      return AuthFailure(
        code: AuthFailureCode.accountConflict,
        message: '기존 로컬 기록을 이 Firebase 계정으로 안전하게 이전할 수 없습니다.',
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
    return AuthFailure(
      code: AuthFailureCode.unknown,
      message: '회원 인증 정보를 적용하지 못했습니다.',
      cause: error,
      causeStackTrace: stackTrace,
    );
  }

  Future<void> _removePreference(
    SharedPreferences prefs,
    String key,
    String operation,
  ) async {
    _requirePreferenceSuccess(await prefs.remove(key), operation);
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
      return decoded.map((key, item) => MapEntry(key, item.toString()));
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

  String _hashPassword(String password) {
    return sha256.convert(utf8.encode(password)).toString();
  }

  void _applySignedOut({bool notify = true}) {
    _applySession(
      hasActiveSession: false,
      persistsAcrossRestarts: false,
      plan: UserPlan.guest,
      migrationStatus: PlanMigrationStatus.none,
      memberId: null,
      email: null,
      nickname: null,
      requiresPasswordSetup: false,
      notify: notify,
    );
  }

  void _applySession({
    required bool hasActiveSession,
    required bool persistsAcrossRestarts,
    required UserPlan plan,
    required PlanMigrationStatus migrationStatus,
    required String? memberId,
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
        _memberId != memberId ||
        _email != email ||
        _nickname != nickname ||
        _requiresPasswordSetup != requiresPasswordSetup;

    _hasActiveSession = hasActiveSession;
    _persistsAcrossRestarts = persistsAcrossRestarts;
    _plan = plan;
    _migrationStatus = migrationStatus;
    _memberId = memberId;
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
      memberId: null,
      email: email,
      nickname: nickname,
      persistSession: rememberSession,
      requiresPasswordSetup: false,
    );
  }

  @visibleForTesting
  void clearMemoryOnlyForTesting() {
    _lastAuthFailure = null;
    _applySignedOut();
  }

  @visibleForTesting
  void resetAuthGatewayForTesting() {
    _authGateway = null;
    _lastAuthFailure = null;
    _applySignedOut();
  }
}

class _FirebaseAccountState {
  final UserPlan plan;
  final PlanMigrationStatus migrationStatus;

  const _FirebaseAccountState({
    required this.plan,
    required this.migrationStatus,
  });
}
