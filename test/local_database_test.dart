import 'dart:convert';

import 'package:fishing_build/data/local/app_database.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/outbox_item.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/repositories/outbox_repository.dart';
import 'package:fishing_build/data/services/record_mutation_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'support/test_database.dart';

void main() {
  final authSession = AuthSessionRepository.instance;
  final recordRepository = FishingRecordRepository.instance;
  final outboxRepository = OutboxRepository.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await resetTestDatabase();
    authSession.clearMemoryOnlyForTesting();
    recordRepository.clearCacheOnlyForTesting();
    outboxRepository.clearCacheOnlyForTesting();
  });

  test('record fields and ordered children survive a SQLite reload', () async {
    await authSession.setSessionForTesting(
      plan: UserPlan.free,
      email: 'sqlite@example.com',
    );
    final original = _record(
      id: 'sqlite-record',
      catches: const <CatchRecord>[
        CatchRecord(speciesName: '농어', lengthCm: 42.5, weightG: 1300),
        CatchRecord(speciesName: '광어', lengthCm: 51, weightG: 2200),
      ],
      photoPaths: const <String>['first.jpg', 'second.jpg'],
    );

    await recordRepository.addRecord(original);
    recordRepository.clearCacheOnlyForTesting();
    await recordRepository.loadRecords();

    final restored = recordRepository.getAllRecords().single;
    expect(restored.id, original.id);
    expect(restored.location, original.location);
    expect(restored.startAt, original.startAt);
    expect(restored.endAt, original.endAt);
    expect(restored.genreName, original.genreName);
    expect(restored.tide, original.tide);
    expect(restored.weather, original.weather);
    expect(restored.airTemperature, original.airTemperature);
    expect(restored.waterTemperature, original.waterTemperature);
    expect(restored.memo, original.memo);
    expect(restored.catches.map((item) => item.speciesName), <String>[
      '농어',
      '광어',
    ]);
    expect(restored.photoPaths, <String>['first.jpg', 'second.jpg']);

    final updated = _record(
      id: original.id,
      catches: const <CatchRecord>[
        CatchRecord(speciesName: '참돔', lengthCm: 38, weightG: 900),
      ],
      photoPaths: const <String>['updated.jpg'],
    );
    await recordRepository.updateRecord(updated);

    final database = await AppDatabase.instance.database;
    expect(
      Sqflite.firstIntValue(
        await database.rawQuery(
          'SELECT COUNT(*) FROM ${AppDatabase.recordCatchesTable}',
        ),
      ),
      1,
    );
    expect(
      Sqflite.firstIntValue(
        await database.rawQuery(
          'SELECT COUNT(*) FROM ${AppDatabase.recordPhotosTable}',
        ),
      ),
      1,
    );

    await recordRepository.deleteRecord(original.id);
    expect(
      Sqflite.firstIntValue(
        await database.rawQuery(
          'SELECT COUNT(*) FROM ${AppDatabase.recordCatchesTable}',
        ),
      ),
      0,
    );
    expect(
      Sqflite.firstIntValue(
        await database.rawQuery(
          'SELECT COUNT(*) FROM ${AppDatabase.recordPhotosTable}',
        ),
      ),
      0,
    );
  });

  test('scoped SharedPreferences data migrates once into SQLite', () async {
    final recordA = _record(id: 'legacy-a');
    final recordB = _record(id: 'legacy-b');
    final outboxItem = OutboxItem(
      id: 'legacy-outbox',
      userId: 'a@example.com',
      recordId: recordA.id,
      operationType: OutboxOperationType.create,
      status: OutboxStatus.pending,
      createdAt: DateTime(2026, 9, 21, 10),
      payload: recordA.toJson(),
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      'fishing_records_by_account_v1': jsonEncode(<String, Object>{
        'member:a@example.com': <Object>[recordA.toJson()],
        'member:b@example.com': <Object>[recordB.toJson()],
      }),
      'outbox_items_by_account_v1': jsonEncode(<String, Object>{
        'member:a@example.com': <Object>[outboxItem.toJson()],
      }),
    });
    await authSession.setSessionForTesting(
      plan: UserPlan.paid,
      email: 'a@example.com',
    );

    await recordRepository.loadRecords();
    await outboxRepository.loadItems();

    expect(recordRepository.getAllRecords().single.id, recordA.id);
    expect(outboxRepository.getAllItems().single.id, outboxItem.id);

    await authSession.setSessionForTesting(
      plan: UserPlan.free,
      email: 'b@example.com',
    );
    await recordRepository.loadRecords();
    await outboxRepository.loadItems();
    expect(recordRepository.getAllRecords().single.id, recordB.id);
    expect(outboxRepository.getAllItems(), isEmpty);

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('fishing_records_by_account_v1'), isNull);
    expect(preferences.getString('outbox_items_by_account_v1'), isNull);

    await recordRepository.loadRecords();
    final database = await AppDatabase.instance.database;
    expect(
      Sqflite.firstIntValue(
        await database.rawQuery(
          'SELECT COUNT(*) FROM ${AppDatabase.fishingRecordsTable}',
        ),
      ),
      2,
    );
  });

  test(
    'valid legacy records migrate while damaged data is preserved',
    () async {
      final validRecord = _record(id: 'valid-legacy-record');
      final recordsSource = jsonEncode(<String, Object>{
        'member:recover@example.com': <Object>[
          validRecord.toJson(),
          <String, Object>{'broken': true},
        ],
      });
      SharedPreferences.setMockInitialValues(<String, Object>{
        'fishing_records_by_account_v1': recordsSource,
        'outbox_items_by_account_v1': 'not-json',
      });
      await authSession.setSessionForTesting(
        plan: UserPlan.free,
        email: 'recover@example.com',
      );

      await recordRepository.loadRecords();

      expect(recordRepository.getAllRecords().single.id, validRecord.id);
      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getString('fishing_records_sqlite_migration_backup_v1'),
        recordsSource,
      );
      expect(preferences.getString('fishing_records_by_account_v1'), isNull);
      expect(preferences.getString('outbox_items_by_account_v1'), 'not-json');
    },
  );

  test('paid record and outbox writes are atomic', () async {
    await authSession.setSessionForTesting(
      plan: UserPlan.paid,
      email: 'atomic@example.com',
    );
    final record = _record(id: 'atomic-record');
    final database = await AppDatabase.instance.database;
    await database.execute('''
      CREATE TEMP TRIGGER force_outbox_failure
      BEFORE INSERT ON ${AppDatabase.outboxItemsTable}
      WHEN NEW.record_id = '${record.id}'
      BEGIN
        SELECT RAISE(ABORT, 'forced outbox failure');
      END
    ''');

    await expectLater(
      RecordMutationService.instance.addRecord(record),
      throwsA(isA<DatabaseException>()),
    );

    recordRepository.clearCacheOnlyForTesting();
    outboxRepository.clearCacheOnlyForTesting();
    await recordRepository.loadRecords();
    await outboxRepository.loadItems();

    expect(recordRepository.getAllRecords(), isEmpty);
    expect(outboxRepository.getAllItems(), isEmpty);
  });

  test('foreign keys are enabled for every database connection', () async {
    final database = await AppDatabase.instance.database;
    final result = await database.rawQuery('PRAGMA foreign_keys');
    expect(Sqflite.firstIntValue(result), 1);
  });
}

FishingRecord _record({
  required String id,
  List<CatchRecord> catches = const <CatchRecord>[],
  List<String> photoPaths = const <String>[],
}) {
  return FishingRecord(
    id: id,
    location: '테스트 방파제',
    startAt: DateTime(2026, 9, 21, 6, 30),
    endAt: DateTime(2026, 9, 21, 9, 45),
    genreName: '루어',
    tide: '7물',
    weather: '맑음',
    airTemperature: 22.5,
    waterTemperature: 19.2,
    catches: catches,
    photoPaths: photoPaths,
    memo: 'SQLite 왕복 테스트',
  );
}
