import 'package:cloud_firestore/cloud_firestore.dart' as firestore;
import 'package:firebase_auth/firebase_auth.dart' as firebase;
import 'package:fishing_build/data/auth/auth_gateway.dart';
import 'package:fishing_build/data/auth/firebase_auth_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FirebaseAuthGateway.deleteCurrentUser', () {
    test(
      'rejects a different current user without deleting either user',
      () async {
        final expectedUser = _FakeFirebaseUser('uid-a');
        final currentUser = _FakeFirebaseUser('uid-b');
        final auth = _FakeFirebaseAuth()..user = currentUser;
        final gateway = FirebaseAuthGateway(
          auth: auth,
          database: _FakeFirebaseFirestore(),
        );

        await expectLater(
          gateway.deleteCurrentUser(expectedUid: expectedUser.uid),
          throwsA(
            isA<AuthFailure>().having(
              (failure) => failure.code,
              'code',
              AuthFailureCode.sessionExpired,
            ),
          ),
        );

        expect(expectedUser.deleteCount, 0);
        expect(currentUser.deleteCount, 0);
        expect(auth.currentUser, same(currentUser));
      },
    );

    test('deletes the current user once when the UID matches', () async {
      final user = _FakeFirebaseUser('uid-a');
      final auth = _FakeFirebaseAuth()..user = user;
      final gateway = FirebaseAuthGateway(
        auth: auth,
        database: _FakeFirebaseFirestore(),
      );

      await gateway.deleteCurrentUser(expectedUid: user.uid);

      expect(user.deleteCount, 1);
    });

    test('does nothing when there is no current user', () async {
      final gateway = FirebaseAuthGateway(
        auth: _FakeFirebaseAuth(),
        database: _FakeFirebaseFirestore(),
      );

      await expectLater(
        gateway.deleteCurrentUser(expectedUid: 'uid-a'),
        completes,
      );
    });
  });
}

class _FakeFirebaseAuth extends Fake implements firebase.FirebaseAuth {
  firebase.User? user;

  @override
  firebase.User? get currentUser => user;
}

class _FakeFirebaseUser extends Fake implements firebase.User {
  _FakeFirebaseUser(this.uid);

  @override
  final String uid;

  int deleteCount = 0;

  @override
  Future<void> delete() async {
    deleteCount += 1;
  }
}

class _FakeFirebaseFirestore extends Fake
    implements firestore.FirebaseFirestore {}
