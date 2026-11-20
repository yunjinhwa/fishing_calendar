import 'dart:async';
import 'dart:convert';

import 'package:fishing_build/data/auth/auth_gateway.dart';
import 'package:fishing_build/data/auth/nickname_policy.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Test-only failed durable writes verify committed server profile behavior.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'firebase_auth_test.dart' show FakeAuthGateway;
import 'support/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final auth = AuthSessionRepository.instance;
  late _FailingPreferencesStore preferences;
  final gateways = <_ProfileGateway>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = _FailingPreferencesStore();
    SharedPreferencesStorePlatform.instance = preferences;
    await resetTestDatabase();
    auth.resetAuthGatewayForTesting();
    gateways.clear();
  });

  tearDown(() async {
    auth.resetAuthGatewayForTesting();
    await _flush();
    for (final gateway in gateways) {
      await gateway.close();
    }
  });

  Future<_ProfileGateway> firebaseMember({
    bool watchThrows = false,
    bool cancelThrows = false,
  }) async {
    final gateway = _ProfileGateway();
    gateway.watchThrows = watchThrows;
    gateway.cancelThrows = cancelThrows;
    gateways.add(gateway);
    gateway.seedEntitlement(uid: 'uid-1', plan: UserPlan.paid);
    auth.configureAuthGateway(gateway);
    await auth.registerAsFree(
      email: 'profile@example.com',
      password: 'Password1',
      nickname: 'Initial',
    );
    return gateway;
  }

  test(
    'local rename preserves ownership and plan and survives restoration',
    () async {
      await auth.setSessionForTesting(
        plan: UserPlan.paid,
        email: 'profile@example.com',
        nickname: 'Initial',
      );
      final owner = auth.dataOwnerKey;
      final generation = auth.sessionGeneration;
      expect(
        await auth.updateNickname('  Renamed  ', expectedNickname: 'Initial'),
        isTrue,
      );
      expect(auth.displayName, 'Renamed');
      expect(auth.dataOwnerKey, owner);
      expect(auth.sessionGeneration, generation);
      expect(auth.isPaid, isTrue);
      auth.clearMemoryOnlyForTesting();
      await auth.loadSession();
      expect(auth.displayName, 'Renamed');
      expect(auth.dataOwnerKey, owner);
      expect(auth.isPaid, isTrue);
    },
  );

  test(
    'local duplicate, invalid and unchanged names preserve the original',
    () async {
      await auth.setSessionForTesting(
        plan: UserPlan.free,
        email: 'other@example.com',
        nickname: 'Taken',
      );
      await auth.setSessionForTesting(
        plan: UserPlan.free,
        email: 'profile@example.com',
        nickname: 'Initial',
      );
      await expectLater(
        auth.updateNickname('taken', expectedNickname: 'Initial'),
        throwsA(_failure(AuthFailureCode.nicknameAlreadyInUse)),
      );
      await expectLater(
        auth.updateNickname('/', expectedNickname: 'Initial'),
        throwsA(_failure(AuthFailureCode.invalidProfile)),
      );
      expect(
        await auth.updateNickname(' Initial ', expectedNickname: 'Initial'),
        isFalse,
      );
      expect(auth.displayName, 'Initial');
      expect(
        await auth.updateNickname('INITIAL', expectedNickname: 'Initial'),
        isTrue,
      );
      expect(auth.displayName, 'INITIAL');
    },
  );

  test(
    'local preference failure restores both account and session nickname',
    () async {
      await auth.setSessionForTesting(
        plan: UserPlan.free,
        email: 'profile@example.com',
        nickname: 'Initial',
      );
      preferences.failNextSetKey = 'flutter.auth_nickname';
      await expectLater(
        auth.updateNickname('Renamed', expectedNickname: 'Initial'),
        throwsA(isA<StateError>()),
      );
      expect(auth.displayName, 'Initial');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth_nickname'), 'Initial');
      final accountNicknames =
          jsonDecode(prefs.getString('auth_account_nicknames')!)
              as Map<String, Object?>;
      expect(accountNicknames['profile@example.com'], 'Initial');
    },
  );

  test(
    'first local nickname write failure restores the preferences cache',
    () async {
      await auth.setSessionForTesting(
        plan: UserPlan.free,
        email: 'profile@example.com',
        nickname: 'Initial',
      );
      for (final throwsBeforeResult in [false, true]) {
        if (throwsBeforeResult) {
          preferences.throwNextSetKey = 'flutter.auth_account_nicknames';
        } else {
          preferences.failNextSetKey = 'flutter.auth_account_nicknames';
        }
        await expectLater(
          auth.updateNickname('Renamed', expectedNickname: 'Initial'),
          throwsA(isA<StateError>()),
        );
        final prefs = await SharedPreferences.getInstance();
        expect(auth.displayName, 'Initial');
        expect(prefs.getString('auth_nickname'), 'Initial');
        final accountNicknames =
            jsonDecode(prefs.getString('auth_account_nicknames')!)
                as Map<String, Object?>;
        expect(accountNicknames['profile@example.com'], 'Initial');
        final durable = await preferences.getAll();
        final durableNicknames =
            jsonDecode(durable['flutter.auth_account_nicknames']! as String)
                as Map<String, Object?>;
        expect(durableNicknames['profile@example.com'], 'Initial');
      }
    },
  );

  test('guest and account-deletion locks reject profile writes', () async {
    await auth.continueAsGuest();
    expect(auth.canEditProfile, isFalse);
    await expectLater(
      auth.updateNickname('Renamed', expectedNickname: ''),
      throwsA(_failure(AuthFailureCode.noCurrentUser)),
    );
    await auth.setSessionForTesting(
      plan: UserPlan.free,
      email: 'profile@example.com',
      nickname: 'Initial',
    );
    auth.setAccountDeletionStateForTesting(
      isPending: true,
      initiatedLocally: false,
    );
    expect(auth.canEditProfile, isFalse);
    await expectLater(
      auth.updateNickname('Renamed', expectedNickname: 'Initial'),
      throwsA(_failure(AuthFailureCode.noCurrentUser)),
    );
  });

  test(
    'Firebase commit changes only nickname and UID cache, keeping identity and plan',
    () async {
      final gateway = await firebaseMember();
      final uid = auth.memberId;
      final owner = auth.dataOwnerKey;
      final generation = auth.sessionGeneration;
      final plan = auth.plan;
      final migration = auth.migrationStatus;
      expect(
        await auth.updateNickname('Renamed', expectedNickname: 'Initial'),
        isTrue,
      );
      expect(auth.displayName, 'Renamed');
      expect(gateway.profiles[uid], 'Renamed');
      expect(auth.memberId, uid);
      expect(auth.dataOwnerKey, owner);
      expect(auth.sessionGeneration, generation);
      expect(auth.plan, plan);
      expect(auth.migrationStatus, migration);
      final prefs = await SharedPreferences.getInstance();
      final firebaseNicknames =
          jsonDecode(prefs.getString('auth_firebase_nicknames_v1')!)
              as Map<String, Object?>;
      expect(firebaseNicknames[uid], 'Renamed');
      // Firestore is authoritative. Optional Auth display-name repair can wait.
      expect(gateway.currentUser!.displayName, 'Initial');
      expect(gateway.activeWatches, 1);
    },
  );

  test(
    'failed Firebase transactions leave nickname and cache untouched',
    () async {
      final gateway = await firebaseMember();
      gateway.profiles['another-uid'] = 'Taken';
      await expectLater(
        auth.updateNickname('TAKEN', expectedNickname: 'Initial'),
        throwsA(_failure(AuthFailureCode.nicknameAlreadyInUse)),
      );
      gateway.changeFailure = const AuthFailure(
        code: AuthFailureCode.networkUnavailable,
        message: 'offline',
      );
      await expectLater(
        auth.updateNickname('Renamed', expectedNickname: 'Initial'),
        throwsA(_failure(AuthFailureCode.networkUnavailable)),
      );
      expect(auth.displayName, 'Initial');
      expect(gateway.profiles[auth.memberId], 'Initial');
      final prefs = await SharedPreferences.getInstance();
      final firebaseNicknames =
          jsonDecode(prefs.getString('auth_firebase_nicknames_v1')!)
              as Map<String, Object?>;
      expect(firebaseNicknames[auth.memberId], 'Initial');
    },
  );

  test(
    'duplicate auth operations cannot interleave a pending rename',
    () async {
      final gateway = await firebaseMember();
      gateway.changeGate = Completer<void>();
      gateway.changeStarted = Completer<void>();
      final updating = auth.updateNickname(
        'Renamed',
        expectedNickname: 'Initial',
      );
      await gateway.changeStarted!.future;
      expect(auth.isAuthOperationInProgress, isTrue);
      await expectLater(
        auth.logout(),
        throwsA(_failure(AuthFailureCode.operationInProgress)),
      );
      await expectLater(
        auth.updateNickname('Other', expectedNickname: 'Initial'),
        throwsA(_failure(AuthFailureCode.operationInProgress)),
      );
      gateway.changeGate!.complete();
      expect(await updating, isTrue);
      expect(auth.isAuthOperationInProgress, isFalse);
    },
  );

  test(
    'another device updates the UI and cache without changing session generation',
    () async {
      final gateway = await firebaseMember();
      final generation = auth.sessionGeneration;
      gateway.emitNickname(auth.memberId!, 'Remote');
      await _flush();
      expect(auth.displayName, 'Remote');
      expect(auth.sessionGeneration, generation);
      expect(gateway.watchCount, 1);
      final prefs = await SharedPreferences.getInstance();
      final firebaseNicknames =
          jsonDecode(prefs.getString('auth_firebase_nicknames_v1')!)
              as Map<String, Object?>;
      expect(firebaseNicknames[auth.memberId], 'Remote');
      gateway.nicknameLookupFailure = const AuthFailure(
        code: AuthFailureCode.networkUnavailable,
        message: 'offline',
      );
      auth.clearMemoryOnlyForTesting();
      await auth.loadSession();
      expect(auth.displayName, 'Remote');
      expect(gateway.activeWatches, 1);
    },
  );

  test('external profile changes invalidate an editor baseline', () async {
    final gateway = await firebaseMember();
    gateway.emitNickname(auth.memberId!, 'Remote');
    await _flush();
    await expectLater(
      auth.updateNickname('My draft', expectedNickname: 'Initial'),
      throwsA(_failure(AuthFailureCode.accountConflict)),
    );
    expect(auth.displayName, 'Remote');
    expect(gateway.changeCount, 0);
  });

  test(
    'an older transaction response cannot overwrite a newer watched nickname',
    () async {
      final gateway = await firebaseMember();
      gateway.returnGate = Completer<void>();
      gateway.committed = Completer<void>();
      final updating = auth.updateNickname(
        'Renamed',
        expectedNickname: 'Initial',
      );
      await gateway.committed!.future;
      gateway.emitNickname(auth.memberId!, 'Newer remote');
      await _flush();
      gateway.returnGate!.complete();
      expect(await updating, isTrue);
      expect(auth.displayName, 'Newer remote');
    },
  );

  test('an externally changed session rejects a late rename result', () async {
    final gateway = await firebaseMember();
    gateway.changeGate = Completer<void>();
    gateway.changeStarted = Completer<void>();
    final updating = auth.updateNickname(
      'Renamed',
      expectedNickname: 'Initial',
    );
    await gateway.changeStarted!.future;
    await auth.setSessionForTesting(
      plan: UserPlan.free,
      email: 'other@example.com',
      nickname: 'Other member',
    );
    gateway.changeGate!.complete();
    await expectLater(
      updating,
      throwsA(_failure(AuthFailureCode.sessionExpired)),
    );
    expect(auth.displayName, 'Other member');
    expect(auth.email, 'other@example.com');
    expect(gateway.activeWatches, 0);
  });

  test(
    'logout, account-deletion and gateway reset release profile watches',
    () async {
      var gateway = await firebaseMember();
      expect(gateway.activeWatches, 1);
      await auth.logout();
      expect(gateway.activeWatches, 0);
      auth.resetAuthGatewayForTesting();
      gateway = await firebaseMember();
      auth.setAccountDeletionStateForTesting(
        isPending: true,
        initiatedLocally: false,
      );
      expect(gateway.activeWatches, 0);
      auth.resetAuthGatewayForTesting();
      expect(gateway.activeWatches, 0);
    },
  );

  test(
    'failed or closed watches restart only after a successful refresh',
    () async {
      final gateway = await firebaseMember(watchThrows: true);
      expect(auth.displayName, 'Initial');
      expect(auth.isMember, isTrue);
      expect(gateway.activeWatches, 0);
      expect(gateway.watchCount, 1);
      gateway.watchThrows = false;
      await auth.refreshNickname();
      expect(gateway.activeWatches, 1);
      expect(gateway.watchCount, 2);
      gateway.emitWatchError(auth.memberId!);
      await _flush();
      expect(gateway.activeWatches, 0);
      expect(gateway.watchCount, 2);
      expect(auth.displayName, 'Initial');
      await auth.refreshNickname();
      expect(gateway.activeWatches, 1);
      expect(gateway.watchCount, 3);
      await gateway.closeWatch(auth.memberId!);
      await _flush();
      expect(gateway.activeWatches, 0);
      expect(gateway.watchCount, 3);
      await auth.refreshNickname();
      expect(gateway.activeWatches, 1);
      expect(gateway.watchCount, 4);
      gateway.emitNickname(auth.memberId!, 'Remote recovered');
      await _flush();
      expect(auth.displayName, 'Remote recovered');
    },
  );

  test(
    'watch cancellation failures do not fail logout or leak subscriptions',
    () async {
      final gateway = await firebaseMember(cancelThrows: true);
      expect(gateway.activeWatches, 1);
      await auth.logout();
      await _flush();
      expect(auth.isGuest, isTrue);
      expect(gateway.activeWatches, 0);
    },
  );

  test(
    'unchanged watch events do not repeat successful cache writes',
    () async {
      final gateway = await firebaseMember();
      final initialWrites = preferences.firebaseNicknameWrites;
      for (var index = 0; index < 3; index++) {
        gateway.emitNickname(auth.memberId!, 'Initial');
      }
      await _flush();
      await auth.refreshNickname();
      expect(preferences.firebaseNicknameWrites, initialWrites);
      for (var index = 0; index < 3; index++) {
        gateway.emitNickname(auth.memberId!, 'Changed once');
      }
      await _flush();
      expect(preferences.firebaseNicknameWrites, initialWrites + 1);
      await auth.refreshNickname();
      expect(preferences.firebaseNicknameWrites, initialWrites + 1);
    },
  );

  test('refresh failures preserve the last verified nickname', () async {
    final gateway = await firebaseMember();
    gateway.nicknameLookupFailure = const AuthFailure(
      code: AuthFailureCode.networkUnavailable,
      message: 'offline',
    );
    await expectLater(
      auth.refreshNickname(),
      throwsA(_failure(AuthFailureCode.networkUnavailable)),
    );
    expect(auth.displayName, 'Initial');
    gateway.nicknameLookupFailure = null;
    gateway.profiles[auth.memberId!] = 'Refreshed';
    await auth.refreshNickname();
    expect(auth.displayName, 'Refreshed');
  });

  test(
    'a committed server rename remains successful if its local cache write fails',
    () async {
      final gateway = await firebaseMember();
      preferences.failNextSetKey = 'flutter.auth_firebase_nicknames_v1';
      expect(
        await auth.updateNickname('Renamed', expectedNickname: 'Initial'),
        isTrue,
      );
      expect(auth.displayName, 'Renamed');
      expect(gateway.profiles[auth.memberId], 'Renamed');
      await auth.refreshNickname();
      final durable = await preferences.getAll();
      final firebaseNicknames =
          jsonDecode(durable['flutter.auth_firebase_nicknames_v1']! as String)
              as Map<String, Object?>;
      expect(firebaseNicknames[auth.memberId], 'Renamed');
    },
  );
}

Matcher _failure(AuthFailureCode code) =>
    isA<AuthFailure>().having((error) => error.code, 'code', code);

Future<void> _flush() async {
  for (var index = 0; index < 12; index++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _ProfileGateway extends FakeAuthGateway
    implements NicknameProfileGateway {
  final profiles = <String, String>{};
  final _changes = <String, List<StreamController<String>>>{};
  AuthFailure? changeFailure;
  Completer<void>? changeGate;
  Completer<void>? changeStarted;
  Completer<void>? returnGate;
  Completer<void>? committed;
  int activeWatches = 0;
  int watchCount = 0;
  int changeCount = 0;
  bool watchThrows = false;
  bool cancelThrows = false;

  @override
  Future<String?> getRegisteredNickname(String uid) async {
    final failure = nicknameLookupFailure;
    if (failure != null) throw failure;
    return profiles[uid] ?? await super.getRegisteredNickname(uid);
  }

  @override
  Future<String> claimNickname({
    required String uid,
    required String nickname,
  }) async {
    final existing = profiles[uid];
    if (existing != null) return existing;
    final display = NicknamePolicy.displayValue(nickname);
    _requireAvailableNickname(uid, display);
    profiles[uid] = display;
    return display;
  }

  @override
  Future<String> changeNickname({
    required String uid,
    required String nickname,
    required String expectedNickname,
  }) async {
    changeCount++;
    changeStarted?.complete();
    await changeGate?.future;
    final failure = changeFailure;
    if (failure != null) throw failure;
    if (profiles[uid] != expectedNickname) {
      throw const AuthFailure(
        code: AuthFailureCode.accountConflict,
        message: 'changed',
      );
    }
    final display = NicknamePolicy.displayValue(nickname);
    _requireAvailableNickname(uid, display);
    emitNickname(uid, display);
    committed?.complete();
    await returnGate?.future;
    return display;
  }

  void _requireAvailableNickname(String uid, String nickname) {
    if (!NicknamePolicy.isValid(nickname)) {
      throw const AuthFailure(
        code: AuthFailureCode.invalidProfile,
        message: 'invalid',
      );
    }
    if (profiles.entries.any(
      (entry) =>
          entry.key != uid &&
          NicknamePolicy.canonicalKey(entry.value) ==
              NicknamePolicy.canonicalKey(nickname),
    )) {
      throw const AuthFailure(
        code: AuthFailureCode.nicknameAlreadyInUse,
        message: 'duplicate',
      );
    }
  }

  @override
  Stream<String> watchNickname(String uid) {
    watchCount++;
    if (watchThrows) throw StateError('watch startup failed');
    final controller = StreamController<String>.broadcast(
      sync: true,
      onListen: () => activeWatches++,
      onCancel: () => activeWatches--,
    );
    _changes.putIfAbsent(uid, () => []).add(controller);
    return cancelThrows
        ? _CancelErrorStream(controller.stream)
        : controller.stream;
  }

  void emitNickname(String uid, String nickname) {
    profiles[uid] = nickname;
    for (final controller in _changes[uid] ?? <StreamController<String>>[]) {
      if (!controller.isClosed) controller.add(nickname);
    }
  }

  void emitWatchError(String uid) {
    _changes[uid]!.last.addError(
      StateError('watch disconnected'),
      StackTrace.current,
    );
  }

  Future<void> closeWatch(String uid) => _changes[uid]!.last.close();

  Future<void> close() async {
    for (final streams in _changes.values) {
      for (final controller in streams) {
        await controller.close();
      }
    }
  }
}

class _FailingPreferencesStore extends InMemorySharedPreferencesStore {
  _FailingPreferencesStore() : super.empty();

  String? failNextSetKey;
  String? throwNextSetKey;
  int firebaseNicknameWrites = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    if (key == 'flutter.auth_firebase_nicknames_v1') firebaseNicknameWrites++;
    if (key == throwNextSetKey) {
      throwNextSetKey = null;
      throw StateError('preferences write failed');
    }
    if (key == failNextSetKey) {
      failNextSetKey = null;
      return Future.value(false);
    }
    return super.setValue(valueType, key, value);
  }
}

class _CancelErrorStream extends Stream<String> {
  _CancelErrorStream(this.source);
  final Stream<String> source;

  @override
  StreamSubscription<String> listen(
    void Function(String)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _CancelErrorSubscription(
    source.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    ),
  );
}

class _CancelErrorSubscription extends Fake
    implements StreamSubscription<String> {
  _CancelErrorSubscription(this.source);
  final StreamSubscription<String> source;

  @override
  Future<void> cancel() async {
    await source.cancel();
    throw StateError('subscription cancellation failed');
  }
}
