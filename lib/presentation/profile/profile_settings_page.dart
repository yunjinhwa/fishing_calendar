import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/validation/auth_input_validator.dart';
import '../../data/auth/auth_gateway.dart';
import '../../data/auth/nickname_policy.dart';
import '../../data/repositories/auth_session_repository.dart';
import '../auth/account_management_dialogs.dart';
import '../auth/auth_error_message.dart';
import '../auth/login_choice_page.dart';
import '../common/top_card_notification.dart';

class ProfileSettingsPage extends StatefulWidget {
  const ProfileSettingsPage({super.key});

  @override
  State<ProfileSettingsPage> createState() => _ProfileSettingsPageState();
}

class _ProfileSettingsPageState extends State<ProfileSettingsPage> {
  final _auth = AuthSessionRepository.instance;
  final _nicknameController = TextEditingController();
  late final String _ownerKey;
  late final int _generation;
  late final String _email;
  late String _baselineNickname;
  String? _error;
  bool _isSaving = false;
  bool _isRefreshing = false;
  bool _isUpdatingController = false;
  bool _hasExternalChange = false;
  bool _isManagingAccount = false;

  bool get _sameSession =>
      _ownerKey == _auth.dataOwnerKey && _generation == _auth.sessionGeneration;
  bool get _allowed => _sameSession && _auth.canEditProfile;
  bool get _canResumeDeletion =>
      _sameSession && _auth.isMember && _auth.canResumeAccountDeletion;
  bool get _busy =>
      _sameSession &&
      (_isSaving ||
          _isRefreshing ||
          _isManagingAccount ||
          _auth.isAuthOperationInProgress);
  bool get _dirty =>
      NicknamePolicy.displayValue(_nicknameController.text) !=
      _baselineNickname;

  @override
  void initState() {
    super.initState();
    _ownerKey = _auth.dataOwnerKey;
    _generation = _auth.sessionGeneration;
    _email = _auth.email ?? '';
    _baselineNickname = _auth.nickname ?? '';
    _nicknameController.text = _baselineNickname;
    _nicknameController.addListener(_onDraftChanged);
    _auth.addListener(_onSessionChanged);
  }

  @override
  void dispose() {
    _auth.removeListener(_onSessionChanged);
    _nicknameController.removeListener(_onDraftChanged);
    _nicknameController.dispose();
    super.dispose();
  }

  void _replaceDraft(String nickname) {
    _isUpdatingController = true;
    _baselineNickname = nickname;
    _nicknameController.value = TextEditingValue(
      text: nickname,
      selection: TextSelection.collapsed(offset: nickname.length),
    );
    _isUpdatingController = false;
  }

  void _onDraftChanged() {
    if (_isUpdatingController || !mounted) return;
    setState(() => _error = null);
  }

  void _onSessionChanged() {
    if (!mounted) return;
    if (!_allowed) {
      _replaceDraft('');
      setState(() {
        _hasExternalChange = false;
        _error = null;
      });
      return;
    }
    final nickname = _auth.nickname ?? '';
    if (nickname != _baselineNickname) {
      final isOwnSave =
          _isSaving &&
          nickname == NicknamePolicy.displayValue(_nicknameController.text);
      if (!_dirty || isOwnSave) {
        _replaceDraft(nickname);
        _hasExternalChange = false;
        _error = null;
      } else {
        _hasExternalChange = true;
      }
    } else if (_hasExternalChange) {
      _hasExternalChange = false;
    }
    setState(() {});
  }

  Future<void> _useLatestNickname() async {
    if (!_allowed || _busy) return;
    setState(() {
      _isRefreshing = true;
      _error = null;
    });
    try {
      await _auth.refreshNickname();
      if (!mounted || !_allowed) return;
      setState(() {
        _replaceDraft(_auth.nickname ?? '');
        _hasExternalChange = false;
      });
    } on AuthFailure catch (failure) {
      if (mounted && _allowed) {
        setState(() => _error = authFailureMessage(failure));
      }
    } on Object {
      if (mounted && _allowed) {
        setState(() => _error = '최신 닉네임을 불러오지 못했습니다. 다시 시도해 주세요.');
      }
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  Future<void> _save() async {
    if (!_allowed || _busy || !_dirty || _hasExternalChange) return;
    final nickname = NicknamePolicy.displayValue(_nicknameController.text);
    if (!AuthInputValidator.isValidNickname(nickname)) {
      setState(
        () => _error = '닉네임은 2~20자의 한글, 영문, 숫자, 공백, 밑줄, 하이픈만 사용할 수 있습니다.',
      );
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _isSaving = true;
      _error = null;
    });
    try {
      final changed = await _auth.updateNickname(
        nickname,
        expectedNickname: _baselineNickname,
      );
      if (!mounted || !_allowed) return;
      setState(() {
        _replaceDraft(_auth.nickname ?? nickname);
        _hasExternalChange = false;
      });
      TopCardNotification.show(
        context,
        changed ? '닉네임이 변경되었습니다.' : '변경된 내용이 없습니다.',
        type: changed
            ? TopCardNotificationType.success
            : TopCardNotificationType.info,
      );
    } on AuthFailure catch (failure) {
      if (mounted && _allowed) {
        setState(() {
          if (failure.code == AuthFailureCode.accountConflict) {
            _hasExternalChange = true;
            _error = '회원 정보가 변경되었거나 충돌했습니다. 최신 닉네임을 확인해 주세요.';
          } else {
            _error = authFailureMessage(failure);
          }
        });
      }
    } on Object {
      if (mounted && _allowed) {
        setState(() => _error = '닉네임을 변경하지 못했습니다. 입력한 내용은 유지됩니다. 다시 시도해 주세요.');
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _deleteAccount() async {
    if (_busy ||
        !(_allowed || _canResumeDeletion) ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _isManagingAccount = true);
    try {
      final deleted = await showAccountDeletionConfirmation(context);
      if (deleted && mounted) {
        Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const LoginChoicePage()),
          (route) => false,
        );
      }
    } finally {
      if (mounted) setState(() => _isManagingAccount = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canSave = _allowed && !_busy && _dirty && !_hasExternalChange;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('프로필 설정'),
          leading: IconButton(
            key: const ValueKey('profile-back'),
            icon: const BackButtonIcon(),
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            onPressed: _busy ? null : () => Navigator.of(context).maybePop(),
          ),
        ),
        body: !(_allowed || _canResumeDeletion)
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _sameSession
                        ? '현재 계정 상태에서는 회원 정보를 변경할 수 없습니다.'
                        : '로그인 정보가 변경되었습니다. 이전 화면으로 돌아가 다시 열어 주세요.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : SafeArea(
                child: ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    if (_allowed) ...[
                      InputDecorator(
                        decoration: const InputDecoration(
                          labelText: '이메일',
                          border: OutlineInputBorder(),
                        ),
                        child: SelectableText(_email),
                      ),
                      const SizedBox(height: 24),
                      TextField(
                        key: const ValueKey('profile-nickname'),
                        controller: _nicknameController,
                        enabled: !_busy,
                        maxLength: 20,
                        maxLengthEnforcement: MaxLengthEnforcement.none,
                        textInputAction: TextInputAction.done,
                        autocorrect: false,
                        enableSuggestions: false,
                        onSubmitted: (_) => _save(),
                        decoration: InputDecoration(
                          labelText: '닉네임',
                          border: const OutlineInputBorder(),
                          helperText: '2~20자 · 한글, 영문, 숫자, 공백, 밑줄, 하이픈',
                          helperMaxLines: 3,
                          errorText: _error,
                          errorMaxLines: 4,
                        ),
                      ),
                      if (_hasExternalChange) ...[
                        const SizedBox(height: 16),
                        Card(
                          color: Theme.of(context).colorScheme.primaryContainer,
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('다른 기기에서 닉네임이 변경되었습니다.'),
                                const SizedBox(height: 8),
                                const Text(
                                  '입력한 내용은 유지됩니다. 최신 닉네임을 불러온 뒤 다시 수정해 주세요.',
                                ),
                                const SizedBox(height: 8),
                                TextButton(
                                  key: const ValueKey('profile-use-latest'),
                                  onPressed: _busy ? null : _useLatestNickname,
                                  child: Text(
                                    _isRefreshing ? '불러오는 중...' : '최신 닉네임 불러오기',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      FilledButton(
                        key: const ValueKey('profile-save'),
                        onPressed: canSave ? _save : null,
                        child: Text(_isSaving ? '저장 중...' : '저장'),
                      ),
                    ],
                    const SizedBox(height: 32),
                    const Divider(),
                    const SizedBox(height: 16),
                    if (_canResumeDeletion) ...[
                      Card(
                        color: Theme.of(context).colorScheme.errorContainer,
                        child: const ListTile(
                          leading: Icon(Icons.warning_amber_rounded),
                          title: Text('회원 탈퇴 처리가 중단되었습니다'),
                          subtitle: Text(
                            '클라우드 접근은 이미 차단되었습니다. 남은 정리를 완료해 주세요.',
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    OutlinedButton.icon(
                      key: const ValueKey('profile-delete-account'),
                      onPressed: _busy ? null : _deleteAccount,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.error,
                      ),
                      icon: const Icon(Icons.person_remove_outlined),
                      label: Text(_canResumeDeletion ? '회원 탈퇴 계속하기' : '회원 탈퇴'),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
