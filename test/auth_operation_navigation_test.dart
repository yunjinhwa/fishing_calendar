import 'dart:async';

import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/presentation/auth/login_choice_page.dart';
import 'package:fishing_build/presentation/auth/login_page.dart';
import 'package:fishing_build/presentation/auth/password_reset_page.dart';
import 'package:fishing_build/presentation/auth/signup_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_auth_test.dart' show FakeAuthGateway;
import 'support/test_database.dart';

void main() {
  final auth = AuthSessionRepository.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await resetTestDatabase();
    auth.resetAuthGatewayForTesting();
  });

  tearDown(auth.resetAuthGatewayForTesting);

  testWidgets('pending login blocks back and signup until login finishes', (
    tester,
  ) async {
    final gate = Completer<void>();
    final gateway = FakeAuthGateway()
      ..signInGate = gate
      ..signInStarted = Completer<void>();
    auth.configureAuthGateway(gateway);
    await _openPage(tester, const LoginPage(returnToPrevious: true));
    await _enterFields(tester, const {
      '이메일': 'missing@example.com',
      '비밀번호': 'Password1',
    });
    final resetLink = find.widgetWithText(TextButton, '비밀번호를 잊으셨나요?');
    final openReset = tester.widget<TextButton>(resetLink).onPressed!;

    final submit = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '로그인'))
        .onPressed!;
    submit();
    submit();
    await tester.pumpAndSettle();
    expect(gateway.signInStarted!.isCompleted, isTrue);
    expect(tester.widget<TextButton>(resetLink).onPressed, isNull);
    openReset();
    await tester.pumpAndSettle();
    expect(find.byType(PasswordResetPage), findsNothing);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '회원가입'))
          .onPressed,
      isNull,
    );

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(LoginPage), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('가입된 계정을 찾을 수 없습니다.'), findsOneWidget);
    expect(tester.widget<TextButton>(resetLink).onPressed, isNotNull);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '회원가입'))
          .onPressed,
      isNotNull,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Previous route'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending signup blocks back, login, and policy navigation', (
    tester,
  ) async {
    final gate = Completer<void>();
    final gateway = FakeAuthGateway()
      ..seedAccount(
        uid: 'existing-member',
        email: 'existing@example.com',
        password: 'Password1',
        displayName: 'Existing Member',
      )
      ..registrationGate = gate
      ..registrationStarted = Completer<void>();
    auth.configureAuthGateway(gateway);
    await _openPage(tester, const SignupPage(returnToPrevious: true));
    await _enterFields(tester, const {
      '이메일': 'existing@example.com',
      '비밀번호': 'Password1',
      '비밀번호 확인': 'Password1',
      '닉네임': 'New Member',
    });
    for (final consent in ['이용약관 동의 (필수)', '개인정보 처리방침 동의 (필수)']) {
      final tile = find.widgetWithText(CheckboxListTile, consent);
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pump();
    }
    final submitButton = find.widgetWithText(FilledButton, '가입하기');
    await tester.ensureVisible(submitButton);
    final submit = tester.widget<FilledButton>(submitButton).onPressed!;
    submit();
    submit();
    await tester.pumpAndSettle();
    expect(gateway.registrationStarted!.isCompleted, isTrue);

    for (final button in [
      find.widgetWithText(TextButton, '로그인'),
      find.byKey(const ValueKey('signup-view-terms')),
      find.byKey(const ValueKey('signup-view-privacy')),
    ]) {
      expect(tester.widget<TextButton>(button).onPressed, isNull);
    }
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(SignupPage), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('이미 가입된 이메일입니다. 로그인해 주세요.'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '로그인'))
          .onPressed,
      isNotNull,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Previous route'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'login choice follows auth busy state and ignores duplicate guests',
    (tester) async {
      final signInGate = Completer<void>();
      final gateway = _GatedGuestGateway()..signInGate = signInGate;
      auth.configureAuthGateway(gateway);
      await tester.pumpWidget(const MaterialApp(home: LoginChoicePage()));

      final signIn = auth.signIn(
        email: 'missing@example.com',
        password: 'Password1',
      );
      await tester.pumpAndSettle();
      _expectChoiceButtonsEnabled(tester, enabled: false);

      signInGate.complete();
      expect(await signIn, AuthSignInResult.accountNotFound);
      await tester.pumpAndSettle();
      _expectChoiceButtonsEnabled(tester, enabled: true);

      final startGuest = tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, '비회원으로 시작하기'),
          )
          .onPressed!;
      startGuest();
      startGuest();
      await tester.pumpAndSettle();
      expect(gateway.guestSignOutCalls, 1);
      _expectChoiceButtonsEnabled(tester, enabled: false);

      // Dispose before releasing the guest transition to avoid opening the shell.
      await tester.pumpWidget(const SizedBox());
      gateway.guestSignOutGate.complete();
      await tester.pumpAndSettle();
      expect(auth.isGuest, isTrue);
      expect(auth.hasActiveSession, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _openPage(WidgetTester tester, Widget page) async {
  await tester.binding.setSurfaceSize(const Size(800, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final navigatorKey = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigatorKey,
      home: const Scaffold(body: Text('Previous route')),
    ),
  );
  unawaited(
    navigatorKey.currentState!.push<bool>(
      MaterialPageRoute<bool>(builder: (_) => page),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _enterFields(
  WidgetTester tester,
  Map<String, String> values,
) async {
  for (final entry in values.entries) {
    final field = find.widgetWithText(TextField, entry.key);
    await tester.ensureVisible(field);
    await tester.enterText(field, entry.value);
  }
  tester.testTextInput.hide();
  await tester.pumpAndSettle();
}

void _expectChoiceButtonsEnabled(WidgetTester tester, {required bool enabled}) {
  final callbacks = [
    tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
    tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
    tester.widget<TextButton>(find.byType(TextButton)).onPressed,
  ];
  for (final callback in callbacks) {
    expect(callback, enabled ? isNotNull : isNull);
  }
}

class _GatedGuestGateway extends FakeAuthGateway {
  final guestSignOutGate = Completer<void>();
  int guestSignOutCalls = 0;

  @override
  Future<void> signOut() async {
    guestSignOutCalls += 1;
    await guestSignOutGate.future;
    await super.signOut();
  }
}
