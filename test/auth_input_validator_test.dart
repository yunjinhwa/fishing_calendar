import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:fishing_build/core/validation/auth_input_validator.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_auth_test.dart' show FakeAuthGateway;
import 'support/test_database.dart';

void main() {
  group('new password validation', () {
    final validPasswords = <String, String>{
      'lowercase and digits at the minimum length': 'a1234567',
      'uppercase and digits without lowercase letters': 'ABCDEFG1',
      'mixed uppercase and lowercase letters': 'Password1',
      'optional special characters': 'abcdef1!',
    };
    for (final entry in validPasswords.entries) {
      test('accepts ${entry.key}', () {
        expect(AuthInputValidator.isValidPassword(entry.value), isTrue);
      });
    }

    final invalidPasswords = <String, String>{
      'letters without digits': 'abcdefgh',
      'digits without English letters': '12345678',
      'seven characters': 'abcde12',
      'a fullwidth digit without an ASCII digit': 'abcdefg１',
      'Korean letters and a digit without ASCII English letters': '한글비밀번호입력1',
      'an empty value': '',
    };
    for (final entry in invalidPasswords.entries) {
      test('rejects ${entry.key}', () {
        expect(AuthInputValidator.isValidPassword(entry.value), isFalse);
      });
    }
  });

  group('existing password sign-in', () {
    final authSession = AuthSessionRepository.instance;
    const oldPassword = 'ABCDEF';

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await resetTestDatabase();
      authSession.resetAuthGatewayForTesting();
    });

    tearDown(() {
      authSession.resetAuthGatewayForTesting();
    });

    test(
      'Firebase accepts an existing password below current requirements',
      () async {
        final gateway = FakeAuthGateway()
          ..seedAccount(
            uid: 'existing-password-uid',
            email: 'existing@example.com',
            password: oldPassword,
            displayName: '기존회원',
          );
        authSession.configureAuthGateway(gateway);

        expect(
          await authSession.signIn(
            email: 'existing@example.com',
            password: oldPassword,
          ),
          AuthSignInResult.success,
        );
        expect(authSession.memberId, 'existing-password-uid');
      },
    );

    test(
      'legacy storage accepts an existing password below current requirements',
      () async {
        const email = 'legacy@example.com';
        SharedPreferences.setMockInitialValues(<String, Object>{
          'auth_account_plans': jsonEncode(<String, String>{email: 'free'}),
          'auth_account_nicknames': jsonEncode(<String, String>{email: '기존회원'}),
          'auth_account_password_hashes': jsonEncode(<String, String>{
            email: sha256.convert(utf8.encode(oldPassword)).toString(),
          }),
        });

        expect(
          await authSession.signIn(email: email, password: oldPassword),
          AuthSignInResult.success,
        );
        expect(authSession.isFree, isTrue);
        expect(authSession.email, email);
      },
    );
  });
}
