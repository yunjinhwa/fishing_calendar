import 'package:fishing_build/data/local/app_database.dart';
import 'package:fishing_build/data/local/local_data_store.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/outbox_item.dart';
import 'package:fishing_build/data/models/record_sync_metadata.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/conflict_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/repositories/outbox_repository.dart';
import 'package:fishing_build/data/services/record_mutation_service.dart';
import 'package:fishing_build/data/services/record_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  final auth = AuthSessionRepository.instance;
  final records = FishingRecordRepository.instance;
  final outbox = OutboxRepository.instance;
  final store = LocalDataStore.instance;
  final mutations = RecordMutationService.instance;
  final sync = RecordSyncService.instance;
  late _CheckedDatabase database;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await sync.resetForTesting();
    sqfliteFfiInit();
    await AppDatabase.instance.configureForTesting(
      databaseFactory: _CheckedDatabaseFactory(),
    );
    database = await AppDatabase.instance.database as _CheckedDatabase;
    auth.clearMemoryOnlyForTesting();
    records.clearCacheOnlyForTesting();
    outbox.clearCacheOnlyForTesting();
    ConflictRepository.instance.clearCacheOnlyForTesting();
  });

  tearDown(() async {
    database.rejectOutsideReads = false;
    await sync.resetForTesting();
  });

  for (final plan in <UserPlan>[UserPlan.free, UserPlan.paid]) {
    for (final operation in OutboxOperationType.values) {
      test(
        '${plan.name} ${operation.name} rolls back and retries exactly once',
        () async {
          await auth.setSessionForTesting(
            plan: plan,
            email: 'save-recovery@example.com',
          );
          final owner = auth.dataOwnerKey;
          final original = _record('target');
          final edited = _record('target', location: 'Edited harbor');
          await records.addRecord(_record('retained'));
          if (operation != OutboxOperationType.create) {
            await records.addRecord(original);
          }
          await AppDatabase.instance.transaction((transaction) async {
            await store.writeRecordSyncMetadata(
              transaction,
              ownerKey: owner,
              metadata: const RecordSyncMetadata(
                recordId: 'target',
                serverVersionNo: 7,
                optimisticVersionNo: 7,
                remoteStatus: RemoteRecordStatus.active,
              ),
            );
            await store.writeLocalRecordChange(
              transaction,
              ownerKey: owner,
              record: original,
              deleted: operation == OutboxOperationType.create,
            );
          });
          await outbox.addItem(
            OutboxItem(
              id: 'previous-request',
              userId: auth.memberId,
              recordId: 'retained',
              operationType: OutboxOperationType.update,
              status: OutboxStatus.pending,
              createdAt: DateTime(2026, 10, 24),
              baseVersionNo: 0,
              payload: _record('retained').toJson(),
            ),
          );
          final editSnapshot = operation == OutboxOperationType.create
              ? null
              : await mutations.beginEditingRecord(original);
          final before = await _persistentState(database.inner, owner);
          final beforeRecords = _recordJson(records.getAllRecords());
          final beforeOutbox = outbox
              .getAllItems()
              .map((item) => item.id)
              .toList();
          final notifications = <(String?, int)>[];
          void listener() {
            notifications.add((
              records.getRecordById('target')?.location,
              outbox
                  .getAllItems()
                  .where((item) => item.recordId == 'target')
                  .length,
            ));
          }

          records.addListener(listener);
          addTearDown(() => records.removeListener(listener));
          Future<void> mutate() => switch (operation) {
            OutboxOperationType.create => mutations.addRecord(edited),
            OutboxOperationType.update => mutations.updateRecord(
              edited,
              expectedSnapshot: editSnapshot,
            ),
            OutboxOperationType.delete => mutations.deleteRecord(
              original.id,
              expectedSnapshot: editSnapshot,
            ),
          };

          // Fail after the record/catches or cascading children were changed,
          // while the journal/outbox/version mutation is already staged.
          await database.inner.execute(
            operation == OutboxOperationType.delete
                ? '''
                  CREATE TRIGGER fail_mutation AFTER DELETE
                  ON ${AppDatabase.fishingRecordsTable}
                  WHEN OLD.record_id = 'target'
                  BEGIN SELECT RAISE(ABORT, 'injected delete failure'); END
                  '''
                : '''
                  CREATE TRIGGER fail_mutation BEFORE INSERT
                  ON ${AppDatabase.recordPhotosTable}
                  WHEN NEW.record_id = 'target'
                  BEGIN SELECT RAISE(ABORT, 'injected photo failure'); END
                  ''',
          );
          database.rejectOutsideReads = true;
          await expectLater(mutate(), throwsA(isA<DatabaseException>()));
          database.rejectOutsideReads = false;

          expect(await _persistentState(database.inner, owner), before);
          expect(_recordJson(records.getAllRecords()), beforeRecords);
          expect(outbox.getAllItems().map((item) => item.id), beforeOutbox);
          expect(notifications, isEmpty);

          await database.inner.execute('DROP TRIGGER fail_mutation');
          database.rejectOutsideReads = true;
          await mutate();
          await sync.syncNow();
          database.rejectOutsideReads = false;

          expect(database.rejectedReadCount, 0);
          expect(notifications, <(String?, int)>[
            (
              operation == OutboxOperationType.delete ? null : edited.location,
              plan == UserPlan.paid ? 1 : 0,
            ),
          ]);
          final saved = await store.readRecordsForOwner(owner);
          expect(_recordJson(saved), _recordJson(records.getAllRecords()));
          expect(
            saved.where((record) => record.id == 'target'),
            hasLength(operation == OutboxOperationType.delete ? 0 : 1),
          );
          expect(
            saved.where((record) => record.id == 'retained'),
            hasLength(1),
          );
          if (operation != OutboxOperationType.delete) {
            expect(
              saved.singleWhere((record) => record.id == 'target').toJson(),
              edited.toJson(),
            );
          }
          final metadata = (await store.readRecordSyncMetadata(
            owner,
            'target',
          ))!;
          expect(metadata.optimisticVersionNo, plan == UserPlan.paid ? 8 : 7);
          expect(metadata.serverVersionNo, 7);
          final queued = await store.readOutboxItemsForOwner(owner);
          expect(queued, hasLength(plan == UserPlan.paid ? 2 : 1));
          expect(
            queued.map((item) => item.id),
            outbox.getAllItems().map((item) => item.id),
          );
          final journal = await store.readLocalRecordChangesForOwner(owner);
          if (plan == UserPlan.paid) {
            expect(journal, isEmpty);
            final request = queued.singleWhere(
              (item) => item.recordId == 'target',
            );
            expect(request.operationType, operation);
            expect(request.baseVersionNo, 7);
          } else {
            expect(journal, hasLength(1));
            expect(
              journal.single.payload,
              (operation == OutboxOperationType.delete ? original : edited)
                  .toJson(),
            );
            expect(
              journal.single.operationType,
              operation == OutboxOperationType.delete
                  ? OutboxOperationType.delete
                  : OutboxOperationType.update,
            );
          }
        },
      );
    }
  }

  for (final corruptOutbox in <bool>[false, true]) {
    test(
      '${corruptOutbox ? 'outbox' : 'record'} decoding failure rolls back before commit',
      () async {
        await auth.setSessionForTesting(
          plan: corruptOutbox ? UserPlan.paid : UserPlan.free,
          email: 'decode-recovery@example.com',
        );
        final owner = auth.dataOwnerKey;
        final before = await _persistentState(database.inner, owner);
        final record = _record('decode-target');
        var notifications = 0;
        void listener() => notifications += 1;
        records.addListener(listener);
        addTearDown(() => records.removeListener(listener));
        await database.inner.execute(
          corruptOutbox
              ? '''
                CREATE TRIGGER corrupt_decoding AFTER INSERT
                ON ${AppDatabase.outboxItemsTable}
                BEGIN
                  UPDATE ${AppDatabase.outboxItemsTable}
                  SET payload_json = 'invalid JSON'
                  WHERE outbox_id = NEW.outbox_id;
                END
                '''
              : '''
                CREATE TRIGGER corrupt_decoding AFTER INSERT
                ON ${AppDatabase.fishingRecordsTable}
                BEGIN
                  UPDATE ${AppDatabase.fishingRecordsTable}
                  SET start_at = 'invalid date'
                  WHERE owner_key = NEW.owner_key AND record_id = NEW.record_id;
                END
                ''',
        );
        database.rejectOutsideReads = true;
        await expectLater(
          mutations.addRecord(record),
          throwsA(isA<FormatException>()),
        );
        database.rejectOutsideReads = false;

        expect(await _persistentState(database.inner, owner), before);
        expect(records.getAllRecords(), isEmpty);
        expect(outbox.getAllItems(), isEmpty);
        expect(notifications, 0);
        await database.inner.execute('DROP TRIGGER corrupt_decoding');
        database.rejectOutsideReads = true;
        await mutations.addRecord(record);
        await sync.syncNow();
        database.rejectOutsideReads = false;

        expect(database.rejectedReadCount, 0);
        expect(notifications, 1);
        expect(records.getAllRecords().single.toJson(), record.toJson());
        expect(
          (await store.readRecordsForOwner(owner)).single.toJson(),
          record.toJson(),
        );
        expect(outbox.getAllItems(), hasLength(corruptOutbox ? 1 : 0));
      },
    );
  }
}

List<Map<String, dynamic>> _recordJson(List<FishingRecord> records) =>
    records.map((record) => record.toJson()).toList();

Future<Map<String, List<Map<String, Object?>>>> _persistentState(
  Database database,
  String owner,
) async {
  final result = <String, List<Map<String, Object?>>>{};
  for (final table in <String>[
    AppDatabase.fishingRecordsTable,
    AppDatabase.recordCatchesTable,
    AppDatabase.recordPhotosTable,
    AppDatabase.outboxItemsTable,
    AppDatabase.recordSyncStatesTable,
    AppDatabase.localRecordChangesTable,
  ]) {
    result[table] = await database.query(
      table,
      where: 'owner_key = ?',
      whereArgs: <Object?>[owner],
      orderBy: 'rowid',
    );
  }
  return result;
}

FishingRecord _record(String id, {String location = 'Original harbor'}) =>
    FishingRecord(
      id: id,
      location: location,
      startAt: DateTime(2026, 10, 24, 8),
      endAt: DateTime(2026, 10, 24, 10),
      genreName: 'Sea fishing',
      catches: const <CatchRecord>[
        CatchRecord(speciesName: 'Rockfish', lengthCm: 31, weightG: 820),
      ],
      photos: const <RecordPhoto>[
        RecordPhoto(id: 'photo-1', localPath: 'C:/device/catch.jpg'),
      ],
      memo: 'Save transaction test',
    );

// Transaction callbacks use the real SQLite transaction. Blocking reads only
// on its outer database catches a post-commit reload without mocking storage.
class _CheckedDatabaseFactory implements DatabaseFactory {
  @override
  Future<Database> openDatabase(
    String path, {
    OpenDatabaseOptions? options,
  }) async => _CheckedDatabase(
    await databaseFactoryFfiNoIsolate.openDatabase(path, options: options),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CheckedDatabase implements Database {
  _CheckedDatabase(this.inner);

  final Database inner;
  bool rejectOutsideReads = false;
  int rejectedReadCount = 0;

  @override
  bool get isOpen => inner.isOpen;

  @override
  Future<void> close() => inner.close();

  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction transaction) action, {
    bool? exclusive,
  }) => inner.transaction(action, exclusive: exclusive);

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) {
    if (rejectOutsideReads) {
      rejectedReadCount += 1;
      throw StateError('Unexpected read outside mutation transaction: $table');
    }
    return inner.query(
      table,
      distinct: distinct,
      columns: columns,
      where: where,
      whereArgs: whereArgs,
      groupBy: groupBy,
      having: having,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
