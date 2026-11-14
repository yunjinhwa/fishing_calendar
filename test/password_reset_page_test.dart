import 'dart:async';

import 'package:fishing_build/data/auth/auth_gateway.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/presentation/auth/login_page.dart';
import 'package:fishing_build/presentation/auth/password_reset_page.dart';
import 'package:fishing_build/presentation/common/hold_to_reveal_password_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_auth_test.dart' show FakeAuthGateway;

void main() {
  final auth = AuthSessionRepository.instance;
  late FakeAuthGateway gateway;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    auth.resetAuthGatewayForTesting();
    await auth.setSessionForTesting(plan: UserPlan.guest);
    gateway = FakeAuthGateway();
    auth.configureAuthGateway(gateway);
  });

  tearDown(auth.resetAuthGatewayForTesting);

  Future<void> open(WidgetTester tester, {String email = ''}) async {
    await tester.pumpWidget(
      MaterialApp(home: PasswordResetPage(initialEmail: email)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  testWidgets('empty and malformed email never trigger a reset request', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('재설정 메일 보내기'));
    await tester.pumpAndSettle();
    expect(find.text('이메일을 입력하세요.'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), 'not-an-email');
    await tester.tap(find.text('재설정 메일 보내기'));
    await tester.pumpAndSettle();
    expect(find.text('이메일 형식이 올바르지 않습니다.'), findsOneWidget);
    expect(gateway.passwordResetEmails, isEmpty);
  });

  testWidgets(
    'success keeps session unchanged and allows resend after cooldown',
    (tester) async {
      await open(tester, email: '  Member@Example.com  ');
      final owner = auth.dataOwnerKey;
      final generation = auth.sessionGeneration;
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField))
            .controller!
            .text,
        'Member@Example.com',
      );
      await tester.tap(find.text('재설정 메일 보내기'));
      await tester.pumpAndSettle();
      expect(gateway.passwordResetEmails, ['member@example.com']);
      expect(find.text('메일을 확인해 주세요'), findsOneWidget);
      expect(find.textContaining('재설정이 가능한 계정이 있다면'), findsOneWidget);
      expect(find.text('60초 후 다시 보내기'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      expect(auth.dataOwnerKey, owner);
      expect(auth.sessionGeneration, generation);
      tester.widget<TextField>(find.byType(TextField)).onSubmitted!(
        'Member@Example.com',
      );
      await tester.pump();
      expect(gateway.passwordResetCount, 1);
      await tester.pump(const Duration(seconds: 60));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('재설정 메일 다시 보내기'));
      await tester.tap(find.text('재설정 메일 다시 보내기'));
      await tester.pumpAndSettle();
      expect(gateway.passwordResetCount, 2);
      await close(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('pending request ignores rapid taps and keyboard submission', (
    tester,
  ) async {
    gateway.passwordResetGate = Completer<void>();
    await open(tester, email: 'member@example.com');
    final refresh = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == '재설정 화면 새로고침',
    );
    final staleRefresh = tester.widget<IconButton>(refresh).onPressed!;
    final send = tester
        .widget<FilledButton>(find.byType(FilledButton))
        .onPressed!;
    send();
    send();
    staleRefresh();
    tester.widget<TextField>(find.byType(TextField)).onSubmitted!(
      'member@example.com',
    );
    await tester.pump();
    expect(gateway.passwordResetCount, 1);
    expect(find.text('요청 중...'), findsOneWidget);
    expect(tester.widget<IconButton>(refresh).onPressed, isNull);
    expect(
      tester.widget<TextFormField>(find.byType(TextFormField)).enabled,
      isFalse,
    );
    gateway.passwordResetGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('메일을 확인해 주세요'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), 'another@example.com');
    await tester.pump();
    expect(find.text('메일을 확인해 주세요'), findsNothing);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    await close(tester);
  });

  testWidgets('refresh retains edited email and resets the resend countdown', (
    tester,
  ) async {
    await open(tester, email: 'first@example.com');
    await tester.tap(find.text('재설정 메일 보내기'));
    await tester.pump();
    expect(find.text('메일을 확인해 주세요'), findsOneWidget);
    expect(find.text('60초 후 다시 보내기'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    await tester.enterText(find.byType(TextFormField), 'second@example.com');

    await tester.tap(find.byTooltip('재설정 화면 새로고침'));
    await tester.pump();

    expect(
      tester.widget<TextFormField>(find.byType(TextFormField)).controller!.text,
      'second@example.com',
    );
    expect(find.text('메일을 확인해 주세요'), findsNothing);
    expect(find.textContaining('초 후 다시 보내기'), findsNothing);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
    expect(gateway.passwordResetEmails, ['first@example.com']);

    // Offset the next countdown from the old timer so a leaked callback would
    // change its value before the new countdown's first tick.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('재설정 메일 보내기'));
    await tester.pump();
    expect(gateway.passwordResetEmails, [
      'first@example.com',
      'second@example.com',
    ]);
    expect(find.text('60초 후 다시 보내기'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('60초 후 다시 보내기'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('59초 후 다시 보내기'), findsOneWidget);
    await tester.pump(const Duration(seconds: 49));
    expect(find.text('10초 후 다시 보내기'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    await close(tester);
    expect(tester.takeException(), isNull);
  });

  for (final code in [
    AuthFailureCode.userNotFound,
    AuthFailureCode.userDisabled,
  ]) {
    testWidgets('$code uses the same generic confirmation as a valid account', (
      tester,
    ) async {
      gateway.passwordResetFailure = AuthFailure(
        code: code,
        message: 'private provider message',
      );
      await open(tester, email: 'unknown@example.com');
      await tester.tap(find.text('재설정 메일 보내기'));
      await tester.pumpAndSettle();
      expect(find.text('메일을 확인해 주세요'), findsOneWidget);
      expect(find.textContaining('재설정이 가능한 계정이 있다면'), findsOneWidget);
      expect(find.textContaining('가입된 계정을 찾을 수 없습니다'), findsNothing);
      expect(find.textContaining('private provider message'), findsNothing);
      await close(tester);
    });
  }

  for (final entry in {
    AuthFailureCode.networkUnavailable: '네트워크 연결을 확인한 뒤 다시 시도해 주세요.',
    AuthFailureCode.tooManyRequests: '요청이 너무 많습니다. 잠시 후 다시 시도해 주세요.',
  }.entries) {
    testWidgets('${entry.key} offers a safe error and retry', (tester) async {
      gateway.passwordResetFailure = AuthFailure(
        code: entry.key,
        message: 'secret provider message',
      );
      await open(tester, email: 'member@example.com');
      await tester.tap(find.text('재설정 메일 보내기'));
      await tester.pumpAndSettle();
      expect(find.text(entry.value), findsOneWidget);
      expect(find.text('메일을 확인해 주세요'), findsNothing);
      expect(find.textContaining('secret provider message'), findsNothing);
      gateway.passwordResetFailure = null;
      await tester.tap(find.text('재설정 메일 보내기'));
      await tester.pumpAndSettle();
      expect(gateway.passwordResetCount, 2);
      expect(find.text('메일을 확인해 주세요'), findsOneWidget);
      await close(tester);
    });
  }

  testWidgets('local mode and unavailable auth never show fake success', (
    tester,
  ) async {
    auth.configureAuthGateway(null);
    await open(tester, email: 'member@example.com');
    expect(find.textContaining('현재 실행 환경에서는'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(find.text('메일을 확인해 주세요'), findsNothing);
    expect(gateway.passwordResetCount, 0);
    auth.configureAuthGateway(
      const UnavailableAuthGateway(
        AuthFailure(
          code: AuthFailureCode.configuration,
          message: 'private configuration',
        ),
      ),
    );
    await close(tester);
    await open(tester);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(find.textContaining('private configuration'), findsNothing);
  });

  testWidgets('closing before completion does not update a disposed page', (
    tester,
  ) async {
    gateway.passwordResetGate = Completer<void>();
    await open(tester, email: 'member@example.com');
    await tester.tap(find.text('재설정 메일 보내기'));
    await tester.pump();
    await close(tester);
    gateway.passwordResetGate!.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('메일을 확인해 주세요'), findsNothing);
  });

  testWidgets('login pre-fills email and returns without signing in', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: LoginPage(returnToPrevious: true)),
    );
    await tester.enterText(
      find.widgetWithText(TextField, '이메일'),
      'first@example.com',
    );
    final password = find.descendant(
      of: find.byType(HoldToRevealPasswordField),
      matching: find.byType(TextField),
    );
    await tester.enterText(password, 'OldPassword1');
    await tester.ensureVisible(find.text('비밀번호를 잊으셨나요?'));
    await tester.tap(find.text('비밀번호를 잊으셨나요?'));
    await tester.pumpAndSettle();
    expect(find.byType(PasswordResetPage), findsOneWidget);
    expect(
      tester.widget<TextFormField>(find.byType(TextFormField)).controller!.text,
      'first@example.com',
    );
    await tester.enterText(find.byType(TextFormField), 'correct@example.com');
    await tester.ensureVisible(find.text('로그인으로 돌아가기'));
    await tester.tap(find.text('로그인으로 돌아가기'));
    await tester.pumpAndSettle();
    expect(find.byType(LoginPage), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '이메일'))
          .controller!
          .text,
      'correct@example.com',
    );
    expect(tester.widget<TextField>(password).controller!.text, isEmpty);
    expect(auth.isMember, isFalse);
    expect(gateway.passwordResetCount, 0);
    expect(gateway.currentUser, isNull);
  });

  testWidgets(
    'small screen remains scrollable with enlarged text and keyboard',
    (tester) async {
      addTearDown(tester.view.reset);
      tester.view.physicalSize = const Size(320, 650);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 200);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.6)),
            child: child!,
          ),
          home: const PasswordResetPage(initialEmail: 'member@example.com'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('재설정 메일 보내기'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('재설정 메일 보내기'));
      await tester.pumpAndSettle();
      expect(gateway.passwordResetCount, 1);
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );
}
