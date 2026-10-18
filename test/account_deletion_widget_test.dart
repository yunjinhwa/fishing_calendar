import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/presentation/my_page/my_page.dart';
import 'package:fishing_build/presentation/shell/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final authSession = AuthSessionRepository.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    authSession.resetAuthGatewayForTesting();
    await authSession.setSessionForTesting(
      plan: UserPlan.free,
      email: 'delete-widget@example.com',
      nickname: 'Delete Widget',
      password: 'Password1',
    );
  });

  tearDown(authSession.resetAuthGatewayForTesting);

  testWidgets('account deletion requires impact confirmation and password', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: MyPage()));
    final entry = find.text('회원 탈퇴');
    await tester.scrollUntilVisible(entry, 300);
    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.textContaining('되돌릴 수 없습니다'), findsOneWidget);
    expect(find.textContaining('UID와 요청 시각'), findsOneWidget);
    var deleteButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '영구 삭제'),
    );
    expect(deleteButton.onPressed, isNull);

    await tester.enterText(
      find.widgetWithText(TextField, '현재 비밀번호'),
      'Password1',
    );
    await tester.enterText(
      find.widgetWithText(TextField, '확인을 위해 탈퇴 입력'),
      '탈퇴',
    );
    await tester.pump();

    deleteButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '영구 삭제'),
    );
    expect(deleteButton.onPressed, isNotNull);

    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(authSession.isMember, isTrue);
    expect(find.text('회원 탈퇴'), findsOneWidget);
  });

  testWidgets('a remotely deleted account only offers logout', (tester) async {
    authSession.setAccountDeletionStateForTesting(
      isPending: true,
      initiatedLocally: false,
    );

    await tester.pumpWidget(const MaterialApp(home: MyPage()));
    await tester.pump();

    expect(find.text('해당 계정은 탈퇴되었습니다'), findsOneWidget);
    expect(find.textContaining('로그아웃해 주세요'), findsOneWidget);
    expect(find.text('회원 탈퇴 계속하기'), findsNothing);
    expect(find.text('회원 탈퇴 처리가 중단되었습니다'), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.widgetWithText(FilledButton, '로그아웃'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '로그아웃'));
    await tester.pumpAndSettle();
    expect(authSession.hasActiveSession, isFalse);
  });

  testWidgets('the app shell opens the remote-deleted logout page', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: AppShell(initialIndex: 1)));
    await tester.pump();

    authSession.setAccountDeletionStateForTesting(
      isPending: true,
      initiatedLocally: false,
    );
    await tester.pumpAndSettle();

    expect(find.text('해당 계정은 탈퇴되었습니다'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '로그아웃'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('회원 탈퇴 계속하기'), findsNothing);
  });

  testWidgets('this device can still resume its interrupted deletion', (
    tester,
  ) async {
    authSession.setAccountDeletionStateForTesting(
      isPending: true,
      initiatedLocally: true,
    );

    await tester.pumpWidget(const MaterialApp(home: MyPage()));
    await tester.pump();

    await tester.scrollUntilVisible(find.text('회원 탈퇴 처리가 중단되었습니다'), 300);
    expect(find.text('회원 탈퇴 처리가 중단되었습니다'), findsOneWidget);
    expect(find.text('회원 탈퇴 계속하기'), findsOneWidget);
    expect(find.text('해당 계정은 탈퇴되었습니다'), findsNothing);
  });
}
