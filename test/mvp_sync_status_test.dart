import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/conflict_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/repositories/outbox_repository.dart';
import 'package:fishing_build/data/services/network_status_service.dart';
import 'package:fishing_build/data/services/record_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_record_sync_gateway.dart';
import 'support/test_database.dart';

void main() {
  final auth = AuthSessionRepository.instance;
  late _ConnectivityGateway connectivity;
  late NetworkStatusService network;
  late RecordSyncService sync;
  late FakeRecordSyncGateway gateway;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await RecordSyncService.instance.resetForTesting();
    await resetTestDatabase();
    auth.resetAuthGatewayForTesting();
    FishingRecordRepository.instance.clearCacheOnlyForTesting();
    OutboxRepository.instance.clearCacheOnlyForTesting();
    ConflictRepository.instance.clearCacheOnlyForTesting();
    connectivity = _ConnectivityGateway();
    network = NetworkStatusService(gateway: connectivity);
    await network.refresh();
    sync = RecordSyncService(networkStatusService: network);
    gateway = FakeRecordSyncGateway();
    sync.configureGateway(gateway);
  });

  tearDown(() {
    sync.dispose();
    network.dispose();
  });

  test(
    'a skipped sync never attributes another account success to its owner',
    () async {
      for (final plan in [UserPlan.paid, UserPlan.free]) {
        connectivity.connected = true;
        await network.refresh();
        await auth.setSessionForTesting(
          plan: UserPlan.paid,
          email: 'status-a@example.com',
        );
        expect((await sync.syncNow()).isSuccess, isTrue);
        expect(sync.lastSyncedAt, isNotNull);

        await auth.setSessionForTesting(
          plan: plan,
          email: 'status-b-${plan.name}@example.com',
        );
        expect(sync.lastSyncedAt, isNull);
        connectivity.connected = false;
        await network.refresh();

        final result = await sync.syncNow();
        expect(
          result.skipReason,
          plan == UserPlan.paid
              ? RecordSyncSkipReason.offline
              : RecordSyncSkipReason.paidPlanRequired,
        );
        expect(sync.lastSyncedAt, isNull);
        expect(sync.lastError, isNull);
        expect(sync.state, RecordSyncState.idle);
      }
    },
  );

  test(
    'an offline skip preserves the same owner last successful sync',
    () async {
      await auth.setSessionForTesting(
        plan: UserPlan.paid,
        email: 'same-owner@example.com',
      );
      expect((await sync.syncNow()).isSuccess, isTrue);
      final lastSuccess = sync.lastSyncedAt;
      expect(lastSuccess, isNotNull);
      connectivity.connected = false;
      await network.refresh();

      expect((await sync.syncNow()).skipReason, RecordSyncSkipReason.offline);
      expect(sync.lastSyncedAt, lastSuccess);
    },
  );

  test(
    'a new account failed sync does not inherit an earlier success',
    () async {
      await auth.setSessionForTesting(
        plan: UserPlan.paid,
        email: 'success-a@example.com',
      );
      expect((await sync.syncNow()).isSuccess, isTrue);
      expect(sync.lastSyncedAt, isNotNull);
      await auth.setSessionForTesting(
        plan: UserPlan.paid,
        email: 'failed-b@example.com',
      );
      gateway.failFetch = true;

      expect((await sync.syncNow()).isSuccess, isFalse);

      expect(sync.state, RecordSyncState.failed);
      expect(sync.lastError, isNotNull);
      expect(sync.lastSyncedAt, isNull);
    },
  );

  test(
    'a late old-owner skip cannot publish status for the new account',
    () async {
      await auth.setSessionForTesting(
        plan: UserPlan.paid,
        email: 'inflight-a@example.com',
      );
      expect((await sync.syncNow()).isSuccess, isTrue);
      expect(sync.lastSyncedAt, isNotNull);
      final fetchStarted = Completer<void>();
      final releaseFetch = Completer<void>();
      gateway
        ..fetchStarted = fetchStarted
        ..fetchGate = releaseFetch.future;
      final runningSync = sync.syncNow();
      await fetchStarted.future;

      await auth.setSessionForTesting(
        plan: UserPlan.paid,
        email: 'inflight-b@example.com',
      );
      releaseFetch.complete();
      expect(
        (await runningSync).skipReason,
        RecordSyncSkipReason.sessionChanged,
      );
      expect(sync.lastSyncedAt, isNull);
      expect(sync.lastResult, isNull);
      expect(sync.lastError, isNull);
      expect(sync.state, RecordSyncState.idle);
    },
  );
}

class _ConnectivityGateway implements ConnectivityGateway {
  bool connected = true;

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => [
    connected ? ConnectivityResult.wifi : ConnectivityResult.none,
  ];

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      const Stream.empty();
}
