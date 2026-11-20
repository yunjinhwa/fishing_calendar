import 'dart:io';

import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/presentation/common/hold_to_reveal_password_field.dart';
import 'package:fishing_build/presentation/auth/login_choice_page.dart';
import 'package:fishing_build/presentation/my_page/my_page.dart';
import 'package:fishing_build/presentation/profile/profile_settings_page.dart';
import 'package:fishing_build/presentation/shell/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_database.dart';

void main() {
  final authSession = AuthSessionRepository.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await resetTestDatabase();
    authSession.resetAuthGatewayForTesting();
    FishingRecordRepository.instance.clearCacheOnlyForTesting();
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
    await _openProfile(tester);
    final entry = find.byKey(const ValueKey('profile-delete-account'));
    await tester.scrollUntilVisible(entry, 300, scrollable: _profileScroll);
    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.textContaining('되돌릴 수 없습니다'), findsOneWidget);
    expect(find.textContaining('UID와 요청 시각'), findsOneWidget);
    expect(find.byType(HoldToRevealPasswordField), findsOneWidget);
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
    expect(find.byType(ProfileSettingsPage), findsOneWidget);
    expect(
      find.byKey(const ValueKey('profile-delete-account')),
      findsOneWidget,
    );
  });

  testWidgets(
    'deleting from the profile returns to login and removes only its records',
    (tester) async {
      final support = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('profile-delete-widget-'),
      ))!;
      const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        pathChannel,
        (call) async => support.path,
      );
      addTearDown(() async {
        messenger.setMockMethodCallHandler(pathChannel, null);
        await support.delete();
      });
      final records = FishingRecordRepository.instance;
      final owner = authSession.dataOwnerKey;
      await records.addRecord(_record('profile-delete-success'));
      await _openProfile(tester);
      final entry = find.byKey(const ValueKey('profile-delete-account'));
      await tester.scrollUntilVisible(entry, 300, scrollable: _profileScroll);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '현재 비밀번호'),
        'Password1',
      );
      await tester.enterText(
        find.widgetWithText(TextField, '확인을 위해 탈퇴 입력'),
        '탈퇴',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '영구 삭제'));
      for (
        var attempt = 0;
        attempt < 200 && find.byType(LoginChoicePage).evaluate().isEmpty;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(authSession.hasActiveSession, isFalse);
      expect(
        find.byType(LoginChoicePage),
        findsOneWidget,
        reason: find
            .byType(Text)
            .evaluate()
            .map((element) => (element.widget as Text).data)
            .join('\n'),
      );
      expect(records.getAllRecordsForOwner(owner), isEmpty);
      expect(find.byType(ProfileSettingsPage), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

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

  testWidgets(
    'an old deletion confirmation cannot delete a replacement account',
    (tester) async {
      final records = FishingRecordRepository.instance;
      final originalOwner = authSession.dataOwnerKey;
      final original = _record('original-profile-owner');
      await records.addRecord(original);
      await authSession.setSessionForTesting(
        plan: UserPlan.free,
        email: 'replacement@example.com',
        nickname: 'Replacement',
        password: 'Password1',
      );
      final replacementOwner = authSession.dataOwnerKey;
      final replacement = _record('replacement-profile-owner');
      await records.addRecord(replacement);
      await authSession.setSessionForTesting(
        plan: UserPlan.free,
        email: 'delete-widget@example.com',
        nickname: 'Delete Widget',
        password: 'Password1',
      );
      await _openProfile(tester);
      final entry = find.byKey(const ValueKey('profile-delete-account'));
      await tester.scrollUntilVisible(entry, 200, scrollable: _profileScroll);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '현재 비밀번호'),
        'Password1',
      );
      await tester.enterText(
        find.widgetWithText(TextField, '확인을 위해 탈퇴 입력'),
        '탈퇴',
      );
      await tester.pump();
      final confirmation = find.widgetWithText(FilledButton, '영구 삭제');
      final staleDelete = tester.widget<FilledButton>(confirmation).onPressed!;

      await authSession.setSessionForTesting(
        plan: UserPlan.free,
        email: 'replacement@example.com',
        nickname: 'Replacement',
        password: 'Password1',
      );
      await tester.pump();
      expect(tester.widget<FilledButton>(confirmation).onPressed, isNull);
      staleDelete();
      await tester.pumpAndSettle();

      expect(authSession.isMember, isTrue);
      expect(authSession.email, 'replacement@example.com');
      expect(
        records.getAllRecordsForOwner(originalOwner).map((record) => record.id),
        [original.id],
      );
      expect(
        records
            .getAllRecordsForOwner(replacementOwner)
            .map((record) => record.id),
        [replacement.id],
      );
      await tester.tap(find.widgetWithText(TextButton, '취소'));
      await tester.pumpAndSettle();
      expect(find.textContaining('로그인 정보가 변경되었습니다.'), findsOneWidget);
    },
  );

  testWidgets('the app shell opens the remote-deleted logout page', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: AppShell(initialIndex: 1)));
    await tester.pump();

    authSession.setAccountDeletionStateForTesting(
      isPending: true,
      initiatedLocally: false,
    );
    // The hidden map no longer renders a spinner while its sample request ends.
    await tester.pump(const Duration(seconds: 1));
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

    await _openProfile(tester);
    await tester.scrollUntilVisible(
      find.text('회원 탈퇴 처리가 중단되었습니다'),
      300,
      scrollable: _profileScroll,
    );
    expect(find.text('회원 탈퇴 처리가 중단되었습니다'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('회원 탈퇴 계속하기'),
      200,
      scrollable: _profileScroll,
    );
    expect(find.text('회원 탈퇴 계속하기'), findsOneWidget);
    expect(find.text('해당 계정은 탈퇴되었습니다'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('profile-delete-account')));
    await tester.pumpAndSettle();
    expect(find.text('이전에 시작한 탈퇴 처리를 완료합니다.'), findsOneWidget);
    expect(find.byType(HoldToRevealPasswordField), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(authSession.canResumeAccountDeletion, isTrue);
    expect(find.byType(ProfileSettingsPage), findsOneWidget);
  });
}

Finder get _profileScroll => find
    .descendant(
      of: find.byType(ProfileSettingsPage),
      matching: find.byType(Scrollable),
    )
    .first;

Future<void> _openProfile(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: MyPage()));
  await tester.pump();
  expect(find.text('회원 탈퇴'), findsNothing);
  expect(find.text('회원 탈퇴 계속하기'), findsNothing);
  expect(find.text('회원 탈퇴 처리가 중단되었습니다'), findsNothing);
  final profile = find.byKey(const ValueKey('my-page-profile-settings'));
  await tester.scrollUntilVisible(profile, 200);
  await tester.tap(profile);
  await tester.pumpAndSettle();
  expect(find.byType(ProfileSettingsPage), findsOneWidget);
}

FishingRecord _record(String id) => FishingRecord(
  id: id,
  location: 'Profile test harbor',
  genreName: '루어',
  startAt: DateTime(2026, 11, 16, 8),
  endAt: DateTime(2026, 11, 16, 10),
);
