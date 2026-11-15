import 'package:fishing_build/data/local/app_database.dart';
import 'package:fishing_build/data/local/local_identity_migration_service.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/services/app_startup_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'firebase_auth_test.dart' show FakeAuthGateway;
import 'support/test_database.dart';

void main() {
  final auth = AuthSessionRepository.instance;
  final records = FishingRecordRepository.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await resetTestDatabase();
    auth.resetAuthGatewayForTesting();
    records.clearCacheOnlyForTesting();
  });

  tearDown(() async {
    auth.resetAuthGatewayForTesting();
    await AppDatabase.instance.close();
  });

  test(
    'DB failure during native session restoration preserves account for retry',
    () async {
      final gateway = FakeAuthGateway();
      auth.configureAuthGateway(gateway);
      await auth.registerAsFree(
        email: 'startup-auth@example.com',
        password: 'Password1',
        nickname: '복원회원',
      );
      final uid = auth.memberId!;
      await LocalIdentityMigrationService.instance.claimLegacyMemberData(
        firebaseUid: uid,
        authenticatedEmail: 'startup-auth@example.com',
        allowInitialClaim: true,
      );
      final record = FishingRecord(
        id: 'startup-preserved',
        location: '방파제',
        genreName: '바다낚시',
        startAt: DateTime(2026, 11, 15, 8),
        endAt: DateTime(2026, 11, 15, 9),
        photoPaths: const ['device-only.jpg'],
      );
      await records.addRecord(record);
      final prefs = await SharedPreferences.getInstance();
      final persisted = {
        for (final key in prefs.getKeys()) key: prefs.get(key),
      };
      final database = await AppDatabase.instance.database;
      await database.execute('''
      CREATE TRIGGER fail_startup_identity BEFORE INSERT ON local_metadata
      WHEN NEW.metadata_key LIKE 'firebase_owner_claim_v1:%'
      BEGIN SELECT RAISE(FAIL, 'Injected startup storage failure'); END
    ''');
      auth.clearMemoryOnlyForTesting();
      records.clearCacheOnlyForTesting();
      final controller = AppStartupController(
        steps: [
          AppStartupStep(AppStartupStage.account, auth.loadSession),
          AppStartupStep(AppStartupStage.records, records.loadRecords),
        ],
      );
      addTearDown(controller.dispose);

      await controller.start();

      expect(controller.state, AppStartupState.failed);
      expect(controller.stage, AppStartupStage.account);
      expect(controller.lastError, isA<DatabaseException>());
      expect(gateway.currentUser?.uid, uid);
      expect(gateway.signOutCount, 0);
      expect(gateway.deleteCount, 0);
      expect({
        for (final key in prefs.getKeys()) key: prefs.get(key),
      }, persisted);

      await database.execute('DROP TRIGGER fail_startup_identity');
      await controller.start();

      expect(controller.state, AppStartupState.ready);
      expect(auth.memberId, uid);
      expect(gateway.restoreCount, 2);
      expect(gateway.signOutCount, 0);
      expect(records.getAllRecords().single.id, record.id);
      expect(records.getAllRecords().single.photoPaths, record.photoPaths);
    },
  );
}
