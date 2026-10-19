import 'package:fishing_build/presentation/auth/login_page.dart';
import 'package:fishing_build/presentation/auth/signup_page.dart';
import 'package:fishing_build/presentation/common/hold_to_reveal_password_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('password is visible only while the eye icon is held', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'Password1');
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HoldToRevealPasswordField(
            controller: controller,
            decoration: const InputDecoration(labelText: '비밀번호'),
          ),
        ),
      ),
    );

    TextField passwordField() =>
        tester.widget<TextField>(find.widgetWithText(TextField, '비밀번호'));
    final visibilityControl = find.byTooltip('누르고 있는 동안 비밀번호 표시');

    expect(passwordField().obscureText, isTrue);
    final press = await tester.startGesture(
      tester.getCenter(visibilityControl),
    );
    await tester.pump();
    expect(passwordField().obscureText, isFalse);
    expect(controller.text, 'Password1');

    await press.up();
    await tester.pump();
    expect(passwordField().obscureText, isTrue);

    final cancelledPress = await tester.startGesture(
      tester.getCenter(visibilityControl),
    );
    await tester.pump();
    expect(passwordField().obscureText, isFalse);

    await cancelledPress.cancel();
    await tester.pump();
    expect(passwordField().obscureText, isTrue);
  });

  testWidgets('password fields reveal independently', (tester) async {
    final firstController = TextEditingController(text: 'Password1');
    final secondController = TextEditingController(text: 'Password1');
    addTearDown(firstController.dispose);
    addTearDown(secondController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              HoldToRevealPasswordField(
                controller: firstController,
                decoration: const InputDecoration(labelText: '비밀번호'),
              ),
              HoldToRevealPasswordField(
                controller: secondController,
                decoration: const InputDecoration(labelText: '비밀번호 확인'),
              ),
            ],
          ),
        ),
      ),
    );

    final controls = find.byTooltip('누르고 있는 동안 비밀번호 표시');
    final fields = find.byType(TextField);
    expect(controls, findsNWidgets(2));

    final firstPress = await tester.startGesture(
      tester.getCenter(controls.at(0)),
      pointer: 1,
    );
    await tester.pump();
    expect(tester.widget<TextField>(fields.at(0)).obscureText, isFalse);
    expect(tester.widget<TextField>(fields.at(1)).obscureText, isTrue);

    final secondPress = await tester.startGesture(
      tester.getCenter(controls.at(1)),
      pointer: 2,
    );
    await tester.pump();
    expect(tester.widget<TextField>(fields.at(0)).obscureText, isFalse);
    expect(tester.widget<TextField>(fields.at(1)).obscureText, isFalse);

    await firstPress.up();
    await tester.pump();
    expect(tester.widget<TextField>(fields.at(0)).obscureText, isTrue);
    expect(tester.widget<TextField>(fields.at(1)).obscureText, isFalse);

    await secondPress.up();
    await tester.pump();
    expect(tester.widget<TextField>(fields.at(1)).obscureText, isTrue);
  });

  testWidgets('eye hold blocks the toolbar without disabling text selection', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'Password1');
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: Scaffold(
          body: HoldToRevealPasswordField(
            controller: controller,
            decoration: const InputDecoration(labelText: '비밀번호'),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pump();

    final press = await tester.startGesture(
      tester.getCenter(find.byTooltip('누르고 있는 동안 비밀번호 표시')),
    );
    await tester.pump(const Duration(milliseconds: 700));
    expect(
      tester.widget<TextField>(find.byType(TextField)).obscureText,
      isFalse,
    );
    expect(find.byType(TextMagnifier), findsNothing);
    expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);

    await press.up();
    await tester.pumpAndSettle();

    expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).obscureText,
      isTrue,
    );

    await tester.longPress(find.byType(EditableText));
    await tester.pumpAndSettle();
    expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
  });

  testWidgets(
    'login and signup wire every password input to the shared field',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: LoginPage()));
      expect(find.byType(HoldToRevealPasswordField), findsOneWidget);

      await tester.pumpWidget(const MaterialApp(home: SignupPage()));
      expect(find.byType(HoldToRevealPasswordField), findsNWidgets(2));
    },
  );
}
