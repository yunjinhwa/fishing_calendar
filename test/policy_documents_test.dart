import 'dart:async';

import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/presentation/auth/signup_page.dart';
import 'package:fishing_build/presentation/legal/policy_document_page.dart';
import 'package:fishing_build/presentation/my_page/my_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final authSession = AuthSessionRepository.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    authSession.resetAuthGatewayForTesting();
  });

  tearDown(authSession.resetAuthGatewayForTesting);

  for (final document in PolicyDocument.values) {
    testWidgets('${document.name} displays its real bundled draft offline', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(home: PolicyDocumentPage(document: document)),
      );
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AppBar, document.title), findsOneWidget);
      final body = tester.widget<SelectableText>(find.byType(SelectableText));
      expect(body.data, contains(document.title));
      expect(body.data, matches(RegExp(r'DRAFT|초안')));
      expect(find.text('다시 시도'), findsNothing);
      expect(find.byType(Checkbox), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('rebuilds retain the pending and completed asset future', (
    tester,
  ) async {
    final pending = Completer<String>();
    final bundle = _PolicyBundle((_, _) => pending.future);

    await tester.pumpWidget(_policyApp(bundle: bundle));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(bundle.requests, [PolicyDocument.terms.assetPath]);

    await tester.pumpWidget(
      _policyApp(bundle: bundle, brightness: Brightness.dark),
    );
    expect(bundle.requests, [PolicyDocument.terms.assetPath]);

    pending.complete('이용약관 테스트 초안');
    await tester.pumpAndSettle();
    expect(find.text('이용약관 테스트 초안'), findsOneWidget);

    await tester.pumpWidget(_policyApp(bundle: bundle));
    await tester.pumpAndSettle();
    expect(bundle.requests, [PolicyDocument.terms.assetPath]);
    expect(find.text('이용약관 테스트 초안'), findsOneWidget);
  });

  testWidgets('an asset failure can be retried without reopening the page', (
    tester,
  ) async {
    final bundle = _PolicyBundle((_, attempt) async {
      if (attempt == 1) {
        throw FlutterError('Test asset unavailable');
      }
      return '다시 불러온 이용약관 초안';
    });

    await tester.pumpWidget(_policyApp(bundle: bundle));
    await tester.pumpAndSettle();
    expect(find.textContaining('문서를 불러오지 못했습니다'), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
    expect(bundle.requests, hasLength(1));
    expect(tester.takeException(), isNull);

    await tester.tap(find.widgetWithText(FilledButton, '다시 시도'));
    await tester.pumpAndSettle();

    expect(find.text('다시 불러온 이용약관 초안'), findsOneWidget);
    expect(find.text('다시 시도'), findsNothing);
    expect(bundle.requests, [
      PolicyDocument.terms.assetPath,
      PolicyDocument.terms.assetPath,
    ]);
    expect(bundle.cacheRequests, [false, false]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing the document ignores a late previous asset result', (
    tester,
  ) async {
    final terms = Completer<String>();
    final bundle = _PolicyBundle((key, _) async {
      if (key == PolicyDocument.terms.assetPath) {
        return terms.future;
      }
      return '개인정보 처리방침 테스트 초안';
    });

    await tester.pumpWidget(_policyApp(bundle: bundle));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pumpWidget(
      _policyApp(bundle: bundle, document: PolicyDocument.privacy),
    );
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, '개인정보 처리방침'), findsOneWidget);
    expect(find.text('개인정보 처리방침 테스트 초안'), findsOneWidget);

    terms.complete('늦게 도착한 이용약관 초안');
    await tester.pumpAndSettle();
    expect(find.text('개인정보 처리방침 테스트 초안'), findsOneWidget);
    expect(find.text('늦게 도착한 이용약관 초안'), findsNothing);
    expect(bundle.requests, [
      PolicyDocument.terms.assetPath,
      PolicyDocument.privacy.assetPath,
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reading either policy preserves signup inputs and consent', (
    tester,
  ) async {
    const inputValues = <String, String>{
      '이메일': 'policy-reader@example.com',
      '비밀번호': 'Password1',
      '비밀번호 확인': 'Password1',
      '닉네임': '정책읽기',
    };
    final controllers = <String, TextEditingController>{};
    await tester.pumpWidget(const MaterialApp(home: SignupPage()));

    for (final entry in inputValues.entries) {
      final field = find.widgetWithText(TextField, entry.key);
      await tester.scrollUntilVisible(
        field,
        180,
        scrollable: find.byType(Scrollable).first,
      );
      controllers[entry.key] = tester.widget<TextField>(field).controller!;
      await tester.enterText(field, entry.value);
    }
    tester.testTextInput.hide();
    await tester.pumpAndSettle();

    for (final termsChecked in [false, true]) {
      if (termsChecked) {
        final terms = find.widgetWithText(CheckboxListTile, '이용약관 동의 (필수)');
        await tester.scrollUntilVisible(
          terms,
          180,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(terms);
        await tester.pump();
      }

      for (final document in PolicyDocument.values) {
        final viewButton = find.byKey(ValueKey('signup-view-${document.name}'));
        await tester.scrollUntilVisible(
          viewButton,
          180,
          scrollable: find.byType(Scrollable).first,
        );
        _expectConsent(tester, terms: termsChecked, privacy: false);

        await tester.tap(viewButton);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<PolicyDocumentPage>(find.byType(PolicyDocumentPage))
              .document,
          document,
        );
        expect(find.byType(SelectableText), findsOneWidget);
        expect(find.byType(CheckboxListTile), findsNothing);

        await tester.pageBack();
        await tester.pumpAndSettle();
        _expectConsent(tester, terms: termsChecked, privacy: false);

        for (final entry in inputValues.entries) {
          final field = find.widgetWithText(TextField, entry.key);
          await tester.scrollUntilVisible(
            field,
            -180,
            scrollable: find.byType(Scrollable).first,
          );
          final controller = tester.widget<TextField>(field).controller;
          expect(controller, same(controllers[entry.key]));
          expect(controller!.text, entry.value);
        }
      }
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('signup policy links work with large text', (tester) async {
    _useSmallScreen(tester);
    await tester.pumpWidget(_largeTextApp(home: const SignupPage()));
    for (final document in PolicyDocument.values) {
      final button = find.byKey(ValueKey('signup-view-${document.name}'));
      await tester.scrollUntilVisible(
        button,
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, document.title), findsOneWidget);
      expect(find.byType(SelectableText), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      final checkbox = find.widgetWithText(
        CheckboxListTile,
        document == PolicyDocument.terms ? '이용약관 동의 (필수)' : '개인정보 처리방침 동의 (필수)',
      );
      expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('a narrow policy viewer scrolls with large system text', (
    tester,
  ) async {
    _useSmallScreen(tester);
    final longText = List.generate(
      40,
      (index) => '${index + 1}. 작은 화면에서도 읽을 수 있는 개인정보 처리방침 초안입니다.',
    ).join('\n\n');
    final bundle = _PolicyBundle((_, _) async => longText);

    await tester.pumpWidget(
      _largeTextApp(
        home: PolicyDocumentPage(
          document: PolicyDocument.privacy,
          bundle: bundle,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final scrollView = find.byType(SingleChildScrollView);
    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: scrollView, matching: find.byType(Scrollable)).first,
    );
    expect(scrollable.position.maxScrollExtent, greaterThan(0));
    expect(
      tester.widget<SelectableText>(find.byType(SelectableText)).data,
      longText,
    );

    await tester.drag(scrollView, const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  for (final plan in UserPlan.values) {
    testWidgets('MyPage opens both policies for ${plan.name} users', (
      tester,
    ) async {
      await authSession.setSessionForTesting(
        plan: plan,
        email: plan == UserPlan.guest
            ? null
            : 'policy-${plan.name}@example.com',
        nickname: plan == UserPlan.guest ? null : '정책읽기',
      );
      final hadActiveSession = authSession.hasActiveSession;
      final owner = authSession.dataOwnerKey;
      await tester.pumpWidget(const MaterialApp(home: MyPage()));

      for (final document in PolicyDocument.values) {
        final tile = find.widgetWithText(ListTile, document.title);
        await tester.scrollUntilVisible(
          tile,
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(tile);
        await tester.pumpAndSettle();

        expect(
          tester
              .widget<PolicyDocumentPage>(find.byType(PolicyDocumentPage))
              .document,
          document,
        );
        expect(find.byType(SelectableText), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
        expect(authSession.plan, plan);
        expect(authSession.hasActiveSession, hadActiveSession);
        expect(authSession.dataOwnerKey, owner);

        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.byType(MyPage), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }
}

void _useSmallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _largeTextApp({required Widget home}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: const TextScaler.linear(2)),
    child: child!,
  ),
  home: home,
);

Widget _policyApp({
  required AssetBundle bundle,
  PolicyDocument document = PolicyDocument.terms,
  Brightness brightness = Brightness.light,
}) => MaterialApp(
  theme: ThemeData(brightness: brightness),
  home: PolicyDocumentPage(document: document, bundle: bundle),
);

void _expectConsent(
  WidgetTester tester, {
  required bool terms,
  required bool privacy,
}) {
  expect(
    tester
        .widget<CheckboxListTile>(
          find.widgetWithText(CheckboxListTile, '이용약관 동의 (필수)'),
        )
        .value,
    terms,
  );
  expect(
    tester
        .widget<CheckboxListTile>(
          find.widgetWithText(CheckboxListTile, '개인정보 처리방침 동의 (필수)'),
        )
        .value,
    privacy,
  );
}

class _PolicyBundle extends CachingAssetBundle {
  _PolicyBundle(this.read);

  final Future<String> Function(String key, int attempt) read;
  final requests = <String>[];
  final cacheRequests = <bool>[];

  @override
  Future<String> loadString(String key, {bool cache = true}) {
    requests.add(key);
    cacheRequests.add(cache);
    final attempt = requests.where((request) => request == key).length;
    return read(key, attempt);
  }

  @override
  Future<ByteData> load(String key) => throw UnsupportedError(
    'These tests load policy text through loadString.',
  );
}
