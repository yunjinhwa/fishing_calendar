import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart' as firestore;
import 'package:firebase_auth/firebase_auth.dart' as firebase;
import 'package:fishing_build/data/auth/auth_gateway.dart';
import 'package:fishing_build/data/auth/firebase_auth_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _ResetFirebaseAuth auth;
  late _UnusedFirestore database;
  late FirebaseAuthGateway gateway;

  setUp(() {
    auth = _ResetFirebaseAuth();
    database = _UnusedFirestore();
    gateway = FirebaseAuthGateway(auth: auth, database: database);
  });

  tearDown(() {
    expect(auth.unexpectedCalls, isEmpty);
    expect(database.calls, isEmpty);
  });

  test('sets Korean language before sending exactly one reset email', () async {
    auth.languageGate = Completer<void>();
    final request = gateway.sendPasswordResetEmail(email: 'member@example.com');

    await auth.languageStarted.future;
    expect(auth.languageCodes, <String?>['ko']);
    expect(auth.emails, isEmpty);

    auth.languageGate!.complete();
    await request;

    expect(auth.emails, <String>['member@example.com']);
    expect(auth.actionCodeSettings, <firebase.ActionCodeSettings?>[null]);
    expect(auth.events, <String>['language:ko', 'send:member@example.com']);
  });

  for (final providerCode in <String>['user-not-found', 'user-disabled']) {
    test('$providerCode returns the same reset acceptance result', () async {
      auth.sendFailure = firebase.FirebaseAuthException(
        code: providerCode,
        message: 'Private account information',
      );

      await expectLater(
        gateway.sendPasswordResetEmail(email: 'member@example.com'),
        completes,
      );

      expect(auth.emails, <String>['member@example.com']);
    });
  }

  final errorCodes = <String, AuthFailureCode>{
    'invalid-email': AuthFailureCode.invalidEmail,
    'network-request-failed': AuthFailureCode.networkUnavailable,
    'too-many-requests': AuthFailureCode.tooManyRequests,
    'operation-not-allowed': AuthFailureCode.operationNotAllowed,
    'invalid-api-key': AuthFailureCode.configuration,
    'app-not-authorized': AuthFailureCode.configuration,
    'internal-error': AuthFailureCode.serviceUnavailable,
    'unrecognized-provider-code': AuthFailureCode.unknown,
  };
  for (final entry in errorCodes.entries) {
    test('maps reset ${entry.key} to ${entry.value.name}', () async {
      final providerError = firebase.FirebaseAuthException(
        code: entry.key,
        message: 'Provider request failed',
      );
      auth.sendFailure = providerError;

      await expectLater(
        gateway.sendPasswordResetEmail(email: 'member@example.com'),
        throwsA(
          isA<AuthFailure>()
              .having((failure) => failure.code, 'code', entry.value)
              .having(
                (failure) => failure.providerCode,
                'providerCode',
                entry.key,
              )
              .having((failure) => failure.cause, 'cause', same(providerError))
              .having(
                (failure) => failure.causeStackTrace,
                'causeStackTrace',
                isNotNull,
              ),
        ),
      );

      expect(auth.emails, <String>['member@example.com']);
    });
  }

  test('maps unexpected reset errors while retaining their cause', () async {
    final error = StateError('Unexpected platform failure');
    auth.sendFailure = error;

    await expectLater(
      gateway.sendPasswordResetEmail(email: 'member@example.com'),
      throwsA(
        isA<AuthFailure>()
            .having((failure) => failure.code, 'code', AuthFailureCode.unknown)
            .having((failure) => failure.cause, 'cause', same(error))
            .having(
              (failure) => failure.causeStackTrace,
              'causeStackTrace',
              isNotNull,
            ),
      ),
    );

    expect(auth.emails, hasLength(1));
  });

  test('language setup failure aborts sending and remains typed', () async {
    final error = firebase.FirebaseAuthException(
      code: 'network-request-failed',
    );
    auth.languageFailure = error;

    await expectLater(
      gateway.sendPasswordResetEmail(email: 'member@example.com'),
      throwsA(
        isA<AuthFailure>()
            .having(
              (failure) => failure.code,
              'code',
              AuthFailureCode.networkUnavailable,
            )
            .having((failure) => failure.cause, 'cause', same(error)),
      ),
    );

    expect(auth.languageCodes, <String?>['ko']);
    expect(auth.emails, isEmpty);
  });
}

class _ResetFirebaseAuth implements firebase.FirebaseAuth {
  final List<String?> languageCodes = <String?>[];
  final List<String> emails = <String>[];
  final List<firebase.ActionCodeSettings?> actionCodeSettings =
      <firebase.ActionCodeSettings?>[];
  final List<String> events = <String>[];
  final List<Symbol> unexpectedCalls = <Symbol>[];
  final Completer<void> languageStarted = Completer<void>();
  Completer<void>? languageGate;
  Object? languageFailure;
  Object? sendFailure;

  @override
  Future<void> setLanguageCode(String? languageCode) async {
    languageCodes.add(languageCode);
    events.add('language:$languageCode');
    if (!languageStarted.isCompleted) {
      languageStarted.complete();
    }
    await languageGate?.future;
    final failure = languageFailure;
    if (failure != null) {
      throw failure;
    }
  }

  @override
  Future<void> sendPasswordResetEmail({
    required String email,
    firebase.ActionCodeSettings? actionCodeSettings,
  }) async {
    emails.add(email);
    this.actionCodeSettings.add(actionCodeSettings);
    events.add('send:$email');
    final failure = sendFailure;
    if (failure != null) {
      throw failure;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    unexpectedCalls.add(invocation.memberName);
    throw StateError('Unexpected Firebase Auth call: ${invocation.memberName}');
  }
}

class _UnusedFirestore implements firestore.FirebaseFirestore {
  final List<Symbol> calls = <Symbol>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add(invocation.memberName);
    throw StateError('Unexpected Firestore call: ${invocation.memberName}');
  }
}
