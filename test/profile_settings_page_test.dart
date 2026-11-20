import 'dart:async';

import 'package:fishing_build/data/auth/auth_gateway.dart';
import 'package:fishing_build/data/auth/nickname_policy.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/presentation/my_page/my_page.dart';
import 'package:fishing_build/presentation/profile/profile_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_auth_test.dart' show FakeAuthGateway;
import 'support/test_database.dart';

void main() {
  final auth = AuthSessionRepository.instance;
  late _ProfileGateway gateway;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await resetTestDatabase();
    auth.resetAuthGatewayForTesting();
    FishingRecordRepository.instance.clearCacheOnlyForTesting();
    gateway = _ProfileGateway();
    auth.configureAuthGateway(gateway);
    await auth.registerAsFree(
      email: 'profile@example.com',
      password: 'Password1',
      nickname: 'Original Member',
    );
  });

  tearDown(() async {
    auth.resetAuthGatewayForTesting();
    await gateway.closeProfiles();
  });

  testWidgets(
    'MyPage opens the profile with read-only email and an unchanged nickname',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: MyPage()));
      final menu = find.byKey(const ValueKey('my-page-profile-settings'));
      await tester.ensureVisible(menu);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      expect(find.byType(ProfileSettingsPage), findsOneWidget);
      expect(find.text('profile@example.com'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(_draft(tester), 'Original Member');
      expect(tester.widget<FilledButton>(_save).onPressed, isNull);
      expect(gateway.changeCount, 0);
    },
  );

  testWidgets(
    'invalid nicknames never submit and whitespace-only changes are a no-op',
    (tester) async {
      await _open(tester);
      for (final nickname in ['a', 'Invalid!', 'x' * 21]) {
        await tester.enterText(_nickname, nickname);
        await _submit(tester);
        expect(find.textContaining('닉네임은 2~20자'), findsOneWidget);
        expect(_draft(tester), nickname);
      }
      await tester.enterText(_nickname, '  Original Member  ');
      await tester.pump();
      expect(tester.widget<FilledButton>(_save).onPressed, isNull);
      expect(gateway.changeCount, 0);
      expect(auth.nickname, 'Original Member');
    },
  );

  testWidgets(
    'duplicate errors preserve the draft and retry updates the visible nickname',
    (tester) async {
      await _open(tester);
      final owner = auth.dataOwnerKey;
      final generation = auth.sessionGeneration;
      gateway.changeFailure = const AuthFailure(
        code: AuthFailureCode.nicknameAlreadyInUse,
        message: 'taken',
      );
      await tester.enterText(_nickname, 'Updated Member');
      await _submit(tester);
      expect(find.textContaining('이미 사용 중인 닉네임입니다.'), findsOneWidget);
      expect(_draft(tester), 'Updated Member');
      expect(auth.nickname, 'Original Member');
      gateway.changeFailure = null;
      await _submit(tester);
      expect(find.text('닉네임이 변경되었습니다.'), findsOneWidget);
      expect(_draft(tester), 'Updated Member');
      expect(auth.nickname, 'Updated Member');
      expect(auth.dataOwnerKey, owner);
      expect(auth.sessionGeneration, generation);
      expect(auth.plan, UserPlan.free);
      expect(gateway.changeCount, 2);
      expect(tester.widget<FilledButton>(_save).onPressed, isNull);
    },
  );

  testWidgets(
    'saving ignores duplicate submissions and blocks input and back navigation',
    (tester) async {
      await _open(tester);
      await tester.enterText(_nickname, 'Pending Member');
      await tester.pump();
      final gate = Completer<void>();
      gateway.changeGate = gate;
      final submit = tester.widget<FilledButton>(_save).onPressed!;
      submit();
      submit();
      await tester.pumpAndSettle();
      expect(gateway.changeCount, 1);
      expect(tester.widget<TextField>(_nickname).enabled, isFalse);
      expect(tester.widget<FilledButton>(_save).onPressed, isNull);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      final back = find.byKey(const ValueKey('profile-back'));
      expect(tester.widget<IconButton>(back).onPressed, isNull);
      await tester.tap(back);
      await tester.pumpAndSettle();
      expect(find.byType(ProfileSettingsPage), findsOneWidget);
      gate.complete();
      await _finishAuthWork(tester);
      expect(auth.nickname, 'Pending Member');
      expect(find.text('닉네임이 변경되었습니다.'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Previous page'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'nickname saving disables deletion and rejects a captured delete callback',
    (tester) async {
      await _open(tester);
      await tester.enterText(_nickname, 'Pending Profile');
      await tester.pump();
      final save = tester.widget<FilledButton>(_save).onPressed!;
      await _showDeleteButton(tester);
      final delete = tester.widget<OutlinedButton>(_delete).onPressed!;
      final gate = Completer<void>();
      gateway.changeGate = gate;
      save();
      await tester.pumpAndSettle();

      expect(tester.widget<OutlinedButton>(_delete).onPressed, isNull);
      delete();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(gateway.deleteCount, 0);
      expect(gateway.changeCount, 1);

      gate.complete();
      await _finishAuthWork(tester);
      expect(auth.nickname, 'Pending Profile');
      await _showDeleteButton(tester);
      expect(tester.widget<OutlinedButton>(_delete).onPressed, isNotNull);
    },
  );

  testWidgets(
    'deletion confirmation locks the profile and cancel restores the draft',
    (tester) async {
      await _open(tester);
      await tester.enterText(_nickname, 'Draft Before Delete');
      await tester.pump();
      await _showDeleteButton(tester);
      await tester.tap(_delete);
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.widget<TextField>(_nickname).enabled, isFalse);
      expect(tester.widget<FilledButton>(_save).onPressed, isNull);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('profile-back')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.widgetWithText(TextButton, '취소'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      await tester.ensureVisible(_nickname);
      expect(_draft(tester), 'Draft Before Delete');
      expect(tester.widget<TextField>(_nickname).enabled, isTrue);
      expect(tester.widget<FilledButton>(_save).onPressed, isNotNull);
      expect(auth.nickname, 'Original Member');
      expect(gateway.deleteCount, 0);
      expect(gateway.changeCount, 0);
    },
  );

  testWidgets(
    'remote changes update clean forms and preserve dirty drafts until explicit reload',
    (tester) async {
      await _open(tester);
      gateway.publishNickname(auth.memberId!, 'Remote Member');
      await tester.pumpAndSettle();
      expect(_draft(tester), 'Remote Member');
      await tester.enterText(_nickname, 'My Draft');
      gateway.publishNickname(auth.memberId!, 'Latest Member');
      await tester.pumpAndSettle();
      expect(_draft(tester), 'My Draft');
      expect(find.text('다른 기기에서 닉네임이 변경되었습니다.'), findsOneWidget);
      expect(tester.widget<FilledButton>(_save).onPressed, isNull);
      final useLatest = find.byKey(const ValueKey('profile-use-latest'));
      await tester.ensureVisible(useLatest);
      await tester.tap(useLatest);
      await _finishAuthWork(tester);
      expect(_draft(tester), 'Latest Member');
      expect(useLatest, findsNothing);
      await tester.enterText(_nickname, 'After Reload');
      await _submit(tester);
      expect(gateway.lastExpectedNickname, 'Latest Member');
      expect(auth.nickname, 'After Reload');
    },
  );

  testWidgets(
    'failed latest-profile reads preserve the draft and allow retry',
    (tester) async {
      await _open(tester);
      await tester.enterText(_nickname, 'Offline Draft');
      gateway.publishNickname(auth.memberId!, 'Remote Member');
      await tester.pumpAndSettle();
      gateway.nicknameLookupFailure = const AuthFailure(
        code: AuthFailureCode.networkUnavailable,
        message: 'offline',
      );
      final useLatest = find.byKey(const ValueKey('profile-use-latest'));
      await tester.ensureVisible(useLatest);
      await tester.tap(useLatest);
      await _finishAuthWork(tester);
      expect(_draft(tester), 'Offline Draft');
      expect(find.text('네트워크 연결을 확인한 뒤 다시 시도해 주세요.'), findsOneWidget);
      gateway.nicknameLookupFailure = null;
      await tester.tap(useLatest);
      await _finishAuthWork(tester);
      expect(_draft(tester), 'Remote Member');
    },
  );

  testWidgets(
    'session replacement hides the old form and ignores its delayed result',
    (tester) async {
      await _open(tester);
      await tester.enterText(_nickname, 'Old Pending Draft');
      await tester.pump();
      final gate = Completer<void>();
      gateway.changeGate = gate;
      final submit = tester.widget<FilledButton>(_save).onPressed!;
      submit();
      await tester.pumpAndSettle();
      auth.clearMemoryOnlyForTesting();
      await tester.pumpAndSettle();
      expect(_nickname, findsNothing);
      expect(find.text('profile@example.com'), findsNothing);
      expect(find.textContaining('로그인 정보가 변경되었습니다.'), findsOneWidget);
      submit();
      gate.complete();
      await _finishAuthWork(tester);
      expect(gateway.changeCount, 1);
      expect(find.text('닉네임이 변경되었습니다.'), findsNothing);
      expect(auth.isMember, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'account deletion revokes profile editing without exposing the old fields',
    (tester) async {
      await _open(tester);
      await tester.enterText(_nickname, 'Deleted Draft');
      await tester.pump();
      final submit = tester.widget<FilledButton>(_save).onPressed!;
      auth.setAccountDeletionStateForTesting(
        isPending: true,
        initiatedLocally: false,
      );
      submit();
      await tester.pumpAndSettle();
      expect(_nickname, findsNothing);
      expect(find.text('profile@example.com'), findsNothing);
      expect(find.text('현재 계정 상태에서는 회원 정보를 변경할 수 없습니다.'), findsOneWidget);
      expect(gateway.changeCount, 0);
    },
  );

  testWidgets('guest MyPage profile access requests authentication', (
    tester,
  ) async {
    await auth.logout();
    await auth.continueAsGuest();
    await tester.pumpWidget(const MaterialApp(home: MyPage()));
    final menu = find.byKey(const ValueKey('my-page-profile-settings'));
    await tester.ensureVisible(menu);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    expect(find.text('로그인이 필요합니다'), findsOneWidget);
    expect(find.byType(ProfileSettingsPage), findsNothing);
  });

  testWidgets('narrow large-text profile stays scrollable above the keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _open(tester, textScale: 2);
    await tester.tap(_nickname);
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pumpAndSettle();
    await tester.enterText(_nickname, 'x');
    await _submit(tester);
    expect(find.textContaining('닉네임은 2~20자'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(_nickname);
    await tester.enterText(_nickname, 'Valid Narrow');
    await _submit(tester);
    expect(auth.nickname, 'Valid Narrow');
    expect(tester.takeException(), isNull);
  });
}

Finder get _nickname => find.byKey(const ValueKey('profile-nickname'));
Finder get _save => find.byKey(const ValueKey('profile-save'));
Finder get _delete => find.byKey(const ValueKey('profile-delete-account'));
String _draft(WidgetTester tester) =>
    tester.widget<TextField>(_nickname).controller!.text;

Future<void> _open(WidgetTester tester, {double textScale = 1}) async {
  // Release a simulated server request even when an assertion fails, so the
  // repository's auth-operation lock cannot leak into the next test.
  addTearDown(() async {
    final gate = _activeGateway?.changeGate;
    if (gate != null && !gate.isCompleted) gate.complete();
    await tester.pumpWidget(const SizedBox.shrink());
    await _finishAuthWork(tester);
  });
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(builder: (_) => const ProfileSettingsPage()),
            ),
            child: const Text('Previous page'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Previous page'));
  await tester.pumpAndSettle();
}

Future<void> _submit(WidgetTester tester) async {
  // enterText schedules a rebuild; interact with the enabled button from that
  // frame rather than the previous frame's disabled instance.
  await tester.pump();
  await tester.scrollUntilVisible(
    _save,
    160,
    scrollable: find
        .descendant(
          of: find.byType(ProfileSettingsPage),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.ensureVisible(_save);
  await tester.tap(_save);
  await _finishAuthWork(tester);
}

Future<void> _showDeleteButton(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    _delete,
    160,
    scrollable: find
        .descendant(
          of: find.byType(ProfileSettingsPage),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.ensureVisible(_delete);
}

Future<void> _finishAuthWork(WidgetTester tester) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump(const Duration(milliseconds: 1));
    // SharedPreferences work may have started in the real setup zone before
    // the widget test's fake clock; let that asynchronous persistence finish.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    if (!AuthSessionRepository.instance.isAuthOperationInProgress) {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail('The simulated profile request did not finish.');
}

_ProfileGateway? _activeGateway;

class _ProfileGateway extends FakeAuthGateway
    implements NicknameProfileGateway {
  _ProfileGateway() {
    _activeGateway = this;
  }
  final _nicknames = <String, String>{};
  final _changes = <String, StreamController<String>>{};
  AuthFailure? changeFailure;
  Completer<void>? changeGate;
  int changeCount = 0;
  String? lastExpectedNickname;

  @override
  Future<String?> getRegisteredNickname(String uid) async {
    if (nicknameLookupFailure != null) throw nicknameLookupFailure!;
    return _nicknames[uid] ?? await super.getRegisteredNickname(uid);
  }

  @override
  Future<String> changeNickname({
    required String uid,
    required String nickname,
    required String expectedNickname,
  }) async {
    changeCount++;
    lastExpectedNickname = expectedNickname;
    await changeGate?.future;
    if (changeFailure != null) throw changeFailure!;
    final current = await getRegisteredNickname(uid);
    if (current != expectedNickname) {
      throw const AuthFailure(
        code: AuthFailureCode.accountConflict,
        message: 'profile changed',
      );
    }
    final value = NicknamePolicy.displayValue(nickname);
    publishNickname(uid, value);
    return value;
  }

  @override
  Stream<String> watchNickname(String uid) => _changes
      .putIfAbsent(uid, () => StreamController<String>.broadcast(sync: true))
      .stream;

  void publishNickname(String uid, String nickname) {
    _nicknames[uid] = nickname;
    _changes[uid]?.add(nickname);
  }

  Future<void> closeProfiles() async {
    for (final controller in _changes.values) {
      await controller.close();
    }
  }
}
