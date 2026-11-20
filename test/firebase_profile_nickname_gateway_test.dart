import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart' as firestore;
import 'package:firebase_auth/firebase_auth.dart' as firebase;
import 'package:firebase_core/firebase_core.dart' show FirebaseException;
import 'package:fishing_build/data/auth/auth_gateway.dart';
import 'package:fishing_build/data/auth/firebase_auth_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _Store store;
  late _Auth auth;
  late FirebaseAuthGateway gateway;

  setUp(() {
    store = _Store()..seed('uid-a', 'Old name');
    auth = _Auth()..user = _User('uid-a');
    gateway = FirebaseAuthGateway(auth: auth, database: store);
  });

  Future<String> change({
    String name = 'New name',
    String expected = 'Old name',
  }) => gateway.changeNickname(
    uid: 'uid-a',
    nickname: name,
    expectedNickname: expected,
  );

  test(
    'rename commits the new claim and profile and releases the old claim',
    () async {
      store.documents['users/uid-a/records/keep'] = {'memo': 'unchanged'};
      expect(await change(name: '  New name  '), 'New name');
      expect(store.documents['nickname_claims/old name'], isNull);
      expect(
        store.documents['user_profiles/uid-a'],
        _data('uid-a', 'New name'),
      );
      expect(
        store.documents['nickname_claims/new name'],
        _data('uid-a', 'New name'),
      );
      expect(store.documents['users/uid-a/records/keep'], {
        'memo': 'unchanged',
      });
      expect(store.commits, 1);
    },
  );

  test(
    'a collision leaves both accounts and the old reservation untouched',
    () async {
      store.seed('uid-b', 'New name');
      final before = Map.of(store.documents);
      await expectLater(
        change(),
        throwsA(_failure(AuthFailureCode.nicknameAlreadyInUse)),
      );
      expect(store.documents, before);
      expect(store.commits, 0);
    },
  );

  test('case-only changes update one claim and never delete it', () async {
    expect(await change(name: 'OLD NAME'), 'OLD NAME');
    expect(store.documents['user_profiles/uid-a'], _data('uid-a', 'OLD NAME'));
    expect(
      store.documents['nickname_claims/old name'],
      _data('uid-a', 'OLD NAME'),
    );
    expect(store.lastDeletes, isEmpty);
  });

  test('a stale editor cannot overwrite another device nickname', () async {
    store.documents.remove('nickname_claims/old name');
    store.seed('uid-a', 'Other device');
    await expectLater(
      change(),
      throwsA(_failure(AuthFailureCode.accountConflict)),
    );
    expect(
      store.documents['user_profiles/uid-a'],
      _data('uid-a', 'Other device'),
    );
    expect(store.documents['nickname_claims/new name'], isNull);
    expect(store.commits, 0);
  });

  test(
    'a retried transaction rechecks the expected name before committing',
    () async {
      store.retryOnce = () {
        store.documents.remove('nickname_claims/old name');
        store.seed('uid-a', 'Other device');
      };
      await expectLater(
        change(),
        throwsA(_failure(AuthFailureCode.accountConflict)),
      );
      expect(
        store.documents['user_profiles/uid-a'],
        _data('uid-a', 'Other device'),
      );
      expect(store.documents['nickname_claims/new name'], isNull);
      expect(store.commits, 0);
    },
  );

  test('commit failure preserves the original profile and claim', () async {
    store.commitError = FirebaseException(
      plugin: 'cloud_firestore',
      code: 'unavailable',
    );
    final before = Map.of(store.documents);
    await expectLater(
      change(),
      throwsA(_failure(AuthFailureCode.networkUnavailable)),
    );
    expect(store.documents, before);
    expect(store.commits, 0);
  });

  test('deleted accounts and broken ownership cannot rename', () async {
    store.documents['account_deletion_requests/uid-a'] = {'uid': 'uid-a'};
    await expectLater(
      change(),
      throwsA(_failure(AuthFailureCode.userDisabled)),
    );
    store.documents.remove('account_deletion_requests/uid-a');
    store.documents['nickname_claims/old name'] = _data('uid-b', 'Old name');
    await expectLater(
      change(),
      throwsA(_failure(AuthFailureCode.accountConflict)),
    );
    expect(store.documents['nickname_claims/new name'], isNull);
    expect(store.commits, 0);
  });

  test('wrong or changed identities cannot write profiles', () async {
    auth.user = _User('uid-b');
    await expectLater(
      change(),
      throwsA(_failure(AuthFailureCode.sessionExpired)),
    );
    expect(store.transactions, 0);
    auth.user = _User('uid-a');
    store.onRead = (path) {
      if (path == 'nickname_claims/new name') auth.user = _User('uid-b');
    };
    await expectLater(
      change(),
      throwsA(_failure(AuthFailureCode.sessionExpired)),
    );
    expect(store.commits, 0);
  });

  test(
    'watch ignores cached, pending and missing profiles and emits server values',
    () async {
      final values = <String>[];
      final stream =
          StreamController<firestore.DocumentSnapshot<Map<String, dynamic>>>();
      store.stream = stream.stream;
      final subscription = gateway.watchNickname('uid-a').listen(values.add);
      await Future<void>.delayed(Duration.zero);
      stream.add(_Snapshot(_data('uid-a', 'Cached name'), fromCache: true));
      stream.add(_Snapshot(_data('uid-a', 'Pending name'), pending: true));
      stream.add(_Snapshot(null));
      stream.add(_Snapshot(_data('uid-a', 'Server name')));
      await Future<void>.delayed(Duration.zero);
      expect(values, ['Server name']);
      expect(store.includeMetadata, isTrue);
      await subscription.cancel().timeout(const Duration(seconds: 2));
      await stream.close().timeout(const Duration(seconds: 2));
    },
  );

  test(
    'watch rejects malformed server profiles rather than displaying them',
    () async {
      store.stream = Stream.value(
        _Snapshot({'uid': 'uid-a', 'nickname': 'Bad', 'nicknameKey': 'wrong'}),
      );
      await expectLater(
        gateway.watchNickname('uid-a'),
        emitsError(_failure(AuthFailureCode.invalidProfile)),
      );
    },
  );
}

Matcher _failure(AuthFailureCode code) =>
    isA<AuthFailure>().having((error) => error.code, 'code', code);

Map<String, dynamic> _data(String uid, String name) => {
  'uid': uid,
  'nickname': name,
  'nicknameKey': name.trim().toLowerCase(),
};

class _Auth extends Fake implements firebase.FirebaseAuth {
  firebase.User? user;
  @override
  firebase.User? get currentUser => user;
}

class _User extends Fake implements firebase.User {
  _User(this.uid);
  @override
  final String uid;
}

class _Store extends Fake implements firestore.FirebaseFirestore {
  final documents = <String, Map<String, dynamic>>{};
  Object? commitError;
  void Function()? retryOnce;
  void Function(String)? onRead;
  Stream<firestore.DocumentSnapshot<Map<String, dynamic>>> stream =
      const Stream.empty();
  bool? includeMetadata;
  int commits = 0;
  int transactions = 0;
  List<String> lastDeletes = [];

  void seed(String uid, String name) {
    documents['user_profiles/$uid'] = _data(uid, name);
    documents['nickname_claims/${name.toLowerCase()}'] = _data(uid, name);
  }

  @override
  firestore.CollectionReference<Map<String, dynamic>> collection(
    String collectionPath,
  ) => _Collection(this, collectionPath);

  @override
  Future<T> runTransaction<T>(
    firestore.TransactionHandler<T> transactionHandler, {
    Duration timeout = const Duration(seconds: 30),
    int maxAttempts = 5,
  }) async {
    transactions++;
    var transaction = _Transaction(this);
    var result = await transactionHandler(transaction);
    final retry = retryOnce;
    if (retry != null) {
      retryOnce = null;
      retry();
      transaction = _Transaction(this);
      result = await transactionHandler(transaction);
    }
    if (commitError != null) throw commitError!;
    for (final entry in transaction.writes.entries) {
      if (entry.value == null) {
        documents.remove(entry.key);
      } else {
        documents[entry.key] = entry.value!;
      }
    }
    lastDeletes = transaction.writes.entries
        .where((entry) => entry.value == null)
        .map((entry) => entry.key)
        .toList();
    commits++;
    return result;
  }
}

// The SDK references below are isolated test doubles, never production objects.
// ignore: subtype_of_sealed_class
class _Collection extends Fake
    implements firestore.CollectionReference<Map<String, dynamic>> {
  _Collection(this.store, this.path);
  final _Store store;
  @override
  final String path;
  @override
  firestore.DocumentReference<Map<String, dynamic>> doc([String? path]) =>
      _Reference(store, '${this.path}/$path');
}

// ignore: subtype_of_sealed_class
class _Reference extends Fake
    implements firestore.DocumentReference<Map<String, dynamic>> {
  _Reference(this.store, this.path);
  final _Store store;
  @override
  final String path;
  @override
  Stream<firestore.DocumentSnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    firestore.ListenSource source = firestore.ListenSource.defaultSource,
  }) {
    store.includeMetadata = includeMetadataChanges;
    return store.stream;
  }
}

class _Transaction extends Fake implements firestore.Transaction {
  _Transaction(this.store);
  final _Store store;
  final writes = <String, Map<String, dynamic>?>{};
  @override
  Future<firestore.DocumentSnapshot<T>> get<T extends Object?>(
    firestore.DocumentReference<T> documentReference,
  ) async {
    if (writes.isNotEmpty) {
      throw StateError('Transactions must read before writing.');
    }
    store.onRead?.call(documentReference.path);
    return _Snapshot(store.documents[documentReference.path])
        as firestore.DocumentSnapshot<T>;
  }

  @override
  firestore.Transaction set<T>(
    firestore.DocumentReference<T> documentReference,
    T data, [
    firestore.SetOptions? options,
  ]) {
    writes[documentReference.path] = Map<String, dynamic>.from(data as Map);
    return this;
  }

  @override
  firestore.Transaction delete(firestore.DocumentReference documentReference) {
    writes[documentReference.path] = null;
    return this;
  }
}

// ignore: subtype_of_sealed_class
class _Snapshot extends Fake
    implements firestore.DocumentSnapshot<Map<String, dynamic>> {
  _Snapshot(this.value, {bool fromCache = false, bool pending = false})
    : metadata = _Metadata(fromCache, pending);
  final Map<String, dynamic>? value;
  @override
  bool get exists => value != null;
  @override
  Map<String, dynamic>? data() => value;
  @override
  final firestore.SnapshotMetadata metadata;
}

class _Metadata extends Fake implements firestore.SnapshotMetadata {
  _Metadata(this.isFromCache, this.hasPendingWrites);
  @override
  final bool isFromCache;
  @override
  final bool hasPendingWrites;
}
