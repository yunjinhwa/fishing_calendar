import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../../firebase_options.dart';
import 'auth_gateway.dart';
import 'firebase_auth_gateway.dart';

abstract final class FirebaseAuthBootstrap {
  static const bool isEnabled = bool.fromEnvironment(
    'FIREBASE_AUTH_ENABLED',
    defaultValue: kReleaseMode,
  );

  static Future<AuthGateway?> initialize() async {
    if (!isEnabled) {
      return null;
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux) {
      return const UnavailableAuthGateway(
        AuthFailure(
          code: AuthFailureCode.operationNotAllowed,
          message: 'Firebase Authentication은 이 Linux 빌드에서 지원되지 않습니다.',
        ),
      );
    }

    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        );
      }

      final auth = FirebaseAuth.instance;
      final firestore = FirebaseFirestore.instance;
      const emulatorHost = String.fromEnvironment(
        'FIREBASE_AUTH_EMULATOR_HOST',
      );
      const emulatorPort = int.fromEnvironment(
        'FIREBASE_AUTH_EMULATOR_PORT',
        defaultValue: 9099,
      );
      if (emulatorHost.isNotEmpty) {
        await auth.useAuthEmulator(emulatorHost, emulatorPort);
      }

      const firestoreEmulatorHost = String.fromEnvironment(
        'FIRESTORE_EMULATOR_HOST',
      );
      const firestoreEmulatorPort = int.fromEnvironment(
        'FIRESTORE_EMULATOR_PORT',
        defaultValue: 8080,
      );
      if (firestoreEmulatorHost.isNotEmpty) {
        firestore.useFirestoreEmulator(
          firestoreEmulatorHost,
          firestoreEmulatorPort,
        );
      }

      return FirebaseAuthGateway(auth: auth, database: firestore);
    } on AuthFailure catch (failure) {
      return UnavailableAuthGateway(failure);
    } on Object catch (error, stackTrace) {
      return UnavailableAuthGateway(
        AuthFailure(
          code: AuthFailureCode.initializationFailed,
          message: 'Firebase 인증을 초기화하지 못했습니다.',
          cause: error,
          causeStackTrace: stackTrace,
        ),
      );
    }
  }
}
