import 'dart:async';

import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/presentation/auth/signup_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_auth_test.dart' show FakeAuthGateway;

void main() {
  final auth = AuthSessionRepository.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    auth.resetAuthGatewayForTesting();
  });
  tearDown(auth.resetAuthGatewayForTesting);

  testWidgets('under-fourteen selection cannot start registration', (
    tester,
  ) async {
    final registrationStarted = Completer<void>();
    final gateway = FakeAuthGateway()
      ..registrationStarted = registrationStarted;
    auth.configureAuthGateway(gateway);

    await tester.pumpWidget(const MaterialApp(home: SignupPage()));
    expect(find.byType(TextField), findsNothing);
    expect(find.widgetWithText(FilledButton, '가입하기'), findsNothing);

    await tester.tap(find.widgetWithText(OutlinedButton, '만 14세 미만'));
    await tester.pumpAndSettle();
    expect(find.text('회원가입은 만 14세 이상부터 가능해요'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.widgetWithText(FilledButton, '가입하기'), findsNothing);
    expect(registrationStarted.isCompleted, isFalse);
    expect(gateway.currentUser, isNull);
    expect(auth.hasActiveSession, isFalse);

    await tester.tap(find.widgetWithText(OutlinedButton, '돌아가기'));
    await tester.pumpAndSettle();
    expect(find.text('현재 연령을 선택해 주세요.'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, '만 14세 미만'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(const MaterialApp(home: SignupPage()));
    expect(find.text('현재 연령을 선택해 주세요.'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(registrationStarted.isCompleted, isFalse);
  });

  testWidgets('changing age clears signup credentials and consent', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SignupPage()));
    final adultButton = find.widgetWithText(OutlinedButton, '만 14세 이상');
    await tester.tap(adultButton);
    await tester.pumpAndSettle();

    final email = find.widgetWithText(TextField, '이메일');
    final password = find.widgetWithText(TextField, '비밀번호');
    final terms = find.widgetWithText(CheckboxListTile, '이용약관 동의 (필수)');
    await tester.enterText(email, 'age-check@example.com');
    await tester.enterText(password, 'Password1');
    tester.testTextInput.hide();
    await tester.ensureVisible(terms);
    await tester.tap(terms);
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(terms).value, isTrue);

    await tester.tap(find.widgetWithText(TextButton, '연령 다시 선택'));
    await tester.pumpAndSettle();
    await tester.tap(adultButton);
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(email).controller!.text, isEmpty);
    expect(tester.widget<TextField>(password).controller!.text, isEmpty);
    expect(tester.widget<CheckboxListTile>(terms).value, isFalse);
  });
}
