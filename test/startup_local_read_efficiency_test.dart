import 'dart:convert';

import 'package:fishing_build/data/local/app_database.dart';
import 'package:fishing_build/data/local/local_data_migration_service.dart';
import 'package:fishing_build/data/local/local_data_store.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/outbox_item.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:fishing_build/data/repositories/outbox_repository.dart';
import 'package:fishing_build/data/services/plan_policy_service.dart';
import 'package:fishing_build/data/services/record_mutation_service.dart';
import 'package:fishing_build/data/services/record_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Test-only platform injection exercises failed durable preference writes.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final auth = AuthSessionRepository.instance;
  final records = FishingRecordRepository.instance;
  final outbox = OutboxRepository.instance;
  final migration = LocalDataMigrationService.instance;
  final store = LocalDataStore.instance;
  final mutations = RecordMutationService.instance;
  final plans = PlanPolicyService.instance;
  late _CountedDatabase database;
  late _FailingPreferencesStore preferenceStore;
  late String owner;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferenceStore = _FailingPreferencesStore();
    SharedPreferencesStorePlatform.instance = preferenceStore;
    await RecordSyncService.instance.resetForTesting();
    sqfliteFfiInit();
    await AppDatabase.instance.configureForTesting(
      databaseFactory: _CountedFactory(),
    );
    database = await AppDatabase.instance.database as _CountedDatabase;
    auth.resetAuthGatewayForTesting();
    records.clearCacheOnlyForTesting();
    outbox.clearCacheOnlyForTesting();
    await auth.setSessionForTesting(
      plan: UserPlan.paid,
      email: 'startup-efficiency@example.com',
    );
    owner = auth.dataOwnerKey;
    database.resetCounts();
  });

  tearDown(() async {
    await RecordSyncService.instance.resetForTesting();
    auth.resetAuthGatewayForTesting();
    await AppDatabase.instance.close();
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'warm local recovery keeps fresh transaction reads without reloading',
    () async {
      final record = _record('existing', 'Existing');
      await database.inner.transaction((transaction) async {
        await store.insertRecord(transaction, ownerKey: owner, record: record);
        await store.insertOutboxItem(
          transaction,
          ownerKey: owner,
          item: _item('finished', record, status: OutboxStatus.succeeded),
        );
      });

      await records.loadRecords();
      await outbox.loadItems();
      expect(database.migrationReads, 2);
      final loadedRecord = records.getAllRecords().single;
      final loadedItem = outbox.getAllItems().single;
      database.resetCounts();

      await mutations.reconcileOutboxWithLocalRecords();
      await plans.resumePendingMigration();
      await migration.migrateIfNeeded();

      expect(database.migrationReads, 0);
      expect(
        database.reads(AppDatabase.localRecordChangesTable, inside: true),
        2,
      );
      expect(database.reads(AppDatabase.outboxItemsTable, inside: true), 1);
      expect(database.reads(AppDatabase.fishingRecordsTable, inside: false), 0);
      expect(database.reads(AppDatabase.recordCatchesTable, inside: false), 0);
      expect(database.reads(AppDatabase.recordPhotosTable, inside: false), 0);
      expect(database.reads(AppDatabase.outboxItemsTable, inside: false), 0);
      expect(identical(records.getAllRecords().single, loadedRecord), isTrue);
      expect(identical(outbox.getAllItems().single, loadedItem), isTrue);

      // A cold owner still needs the complete cache, even after a no-op recovery.
      records.clearCacheOnlyForTesting();
      outbox.clearCacheOnlyForTesting();
      database.resetCounts();
      await mutations.reconcileOutboxWithLocalRecords();
      await plans.resumePendingMigration();
      expect(records.isOwnerLoaded(owner), isTrue);
      expect(outbox.isOwnerLoaded(owner), isTrue);
      expect(records.getAllRecords().single.id, record.id);
      expect(outbox.getAllItems().single.id, 'finished');
      expect(database.reads(AppDatabase.fishingRecordsTable, inside: false), 1);
      expect(database.reads(AppDatabase.recordCatchesTable, inside: false), 1);
      expect(database.reads(AppDatabase.recordPhotosTable, inside: false), 1);
      expect(database.reads(AppDatabase.outboxItemsTable, inside: false), 1);

      // New scoped preferences invalidate an otherwise completed migration pass.
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        LocalDataMigrationService.scopedRecordsPreferencesKey,
        '{}',
      );
      database.resetCounts();
      await migration.migrateIfNeeded();
      expect(database.migrationReads, 2);
      expect(
        preferences.containsKey(
          LocalDataMigrationService.scopedRecordsPreferencesKey,
        ),
        isFalse,
      );
      database.resetCounts();
      await migration.migrateIfNeeded();
      expect(database.migrationReads, 0);
    },
  );

  test(
    'malformed data and failed backup or cleanup never cache completion',
    () async {
      final preferences = await SharedPreferences.getInstance();
      const sourceKey = LocalDataMigrationService.scopedRecordsPreferencesKey;
      await preferences.setString(sourceKey, 'not-json');
      await migration.migrateIfNeeded();
      database.resetCounts();
      await migration.migrateIfNeeded();
      expect(database.migrationReads, 2);
      expect(preferences.getString(sourceKey), 'not-json');

      final record = _record('recovered', 'Recovered');
      final source = jsonEncode({
        owner: [
          record.toJson(),
          {'broken': true},
        ],
      });
      await preferences.setString(sourceKey, source);
      preferenceStore.failNextSetKey =
          'flutter.${LocalDataMigrationService.recordsMigrationBackupKey}';
      database.resetCounts();
      await migration.migrateIfNeeded();
      expect(database.migrationReads, 2);
      expect(await store.readRecordsForOwner(owner), isEmpty);
      // SharedPreferences caches writes before their durable result is known.
      await preferences.reload();
      expect(
        preferences.getString(
          LocalDataMigrationService.recordsMigrationBackupKey,
        ),
        isNull,
      );

      preferenceStore.failNextRemoveKey = 'flutter.$sourceKey';
      database.resetCounts();
      await migration.migrateIfNeeded();
      expect(database.migrationReads, 2);
      expect((await store.readRecordsForOwner(owner)).single.id, record.id);
      expect(
        preferences.getString(
          LocalDataMigrationService.recordsMigrationBackupKey,
        ),
        source,
      );

      // A failed removal cleared the preferences cache, but must still retry SQL
      // metadata and durable cleanup on the next call.
      database.resetCounts();
      await migration.migrateIfNeeded();
      expect(database.migrationReads, 2);
      await preferences.reload();
      expect(preferences.containsKey(sourceKey), isFalse);
      database.resetCounts();
      await migration.migrateIfNeeded();
      expect(database.migrationReads, 0);
    },
  );

  test(
    'failed SQL and replacement or reopened databases retry migration',
    () async {
      database.failNextMigrationRead = true;
      await expectLater(migration.migrateIfNeeded(), throwsStateError);
      expect(database.migrationReads, 1);
      database.resetCounts();
      await migration.migrateIfNeeded();
      expect(database.migrationReads, 2);
      database.resetCounts();
      await migration.migrateIfNeeded();
      expect(database.migrationReads, 0);

      final previousDatabase = database;
      await AppDatabase.instance.close();
      database = await AppDatabase.instance.database as _CountedDatabase;
      expect(identical(database, previousDatabase), isFalse);
      await migration.migrateIfNeeded();
      expect(database.migrationReads, 2);

      await AppDatabase.instance.configureForTesting(
        databaseFactory: _CountedFactory(),
      );
      database = await AppDatabase.instance.database as _CountedDatabase;
      final record = _record('replacement', 'Replacement database');
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        LocalDataMigrationService.scopedRecordsPreferencesKey,
        jsonEncode({
          owner: [record.toJson()],
        }),
      );
      await migration.migrateIfNeeded();
      expect(database.migrationReads, 2);
      expect((await store.readRecordsForOwner(owner)).single.id, record.id);
      database.resetCounts();
      await migration.migrateIfNeeded();
      expect(database.migrationReads, 0);
    },
  );

  test(
    'durable pending requests replay edits and deletes after caches load',
    () async {
      final original = _record('edited', 'Original');
      final deleted = _record('deleted', 'Delete me');
      const otherOwner = 'member:other@example.com';
      await database.inner.transaction((transaction) async {
        for (final record in [original, deleted]) {
          await store.insertRecord(
            transaction,
            ownerKey: owner,
            record: record,
          );
        }
        await store.insertRecord(
          transaction,
          ownerKey: otherOwner,
          record: original,
        );
      });
      await records.loadRecords();
      await outbox.loadItems();

      final edited = _record('edited', 'Latest durable edit');
      final created = _record('created', 'Recovered create');
      await database.inner.transaction((transaction) async {
        for (final item in [
          _item('edit-request', edited, operation: OutboxOperationType.update),
          _item('create-request', created),
          _item(
            'delete-request',
            deleted,
            operation: OutboxOperationType.delete,
          ),
        ]) {
          await store.insertOutboxItem(
            transaction,
            ownerKey: owner,
            item: item,
          );
        }
      });
      expect(outbox.getAllItems(), isEmpty);
      database.resetCounts();

      await mutations.reconcileOutboxWithLocalRecords();

      expect(database.reads(AppDatabase.outboxItemsTable, inside: true), 1);
      expect(database.reads(AppDatabase.fishingRecordsTable, inside: false), 1);
      expect(records.getRecordById(edited.id)!.location, edited.location);
      expect(records.getRecordById(created.id)!.location, created.location);
      expect(records.getRecordById(deleted.id), isNull);
      expect(
        (await store.readRecordsForOwner(otherOwner)).single.location,
        'Original',
      );
    },
  );

  test(
    'plan recovery publishes newly queued edits and durable deletions',
    () async {
      final edited = _record('edited', 'Latest free edit');
      final deleted = _record('deleted', 'Previous paid record');
      await database.inner.transaction((transaction) async {
        await store.insertRecord(transaction, ownerKey: owner, record: edited);
        await store.insertOutboxItem(
          transaction,
          ownerKey: owner,
          item: _item(
            'old-delete-target',
            deleted,
            status: OutboxStatus.succeeded,
          ),
        );
      });
      await records.loadRecords();
      await outbox.loadItems();
      await database.inner.transaction((transaction) async {
        await store.writeLocalRecordChange(
          transaction,
          ownerKey: owner,
          record: edited,
          deleted: false,
        );
        await store.writeLocalRecordChange(
          transaction,
          ownerKey: owner,
          record: deleted,
          deleted: true,
        );
      });
      database.resetCounts();

      await plans.resumePendingMigration();

      expect(database.reads(AppDatabase.outboxItemsTable, inside: false), 1);
      final pending = outbox
          .getAllItems()
          .where((item) => item.isMigration)
          .toList();
      expect(pending, hasLength(2));
      expect(
        pending
            .singleWhere((item) => item.recordId == edited.id)
            .payload!['location'],
        edited.location,
      );
      expect(
        pending
            .singleWhere((item) => item.recordId == deleted.id)
            .operationType,
        OutboxOperationType.delete,
      );
      expect(await store.readLocalRecordChangesForOwner(owner), isEmpty);
      final pendingIds = pending.map((item) => item.id).toSet();
      outbox.clearCacheOnlyForTesting();
      database.resetCounts();
      await plans.resumePendingMigration();
      expect(database.reads(AppDatabase.outboxItemsTable, inside: false), 1);
      expect(
        outbox
            .getAllItems()
            .where((item) => item.isMigration)
            .map((item) => item.id)
            .toSet(),
        pendingIds,
      );
    },
  );
}

FishingRecord _record(String id, String location) => FishingRecord(
  id: id,
  location: location,
  startAt: DateTime(2026, 11, 16, 8),
  endAt: DateTime(2026, 11, 16, 10),
  genreName: 'Sea fishing',
  catches: const [CatchRecord(speciesName: 'Rockfish', lengthCm: 31)],
  photoPaths: const ['existing-photo.jpg'],
);

OutboxItem _item(
  String id,
  FishingRecord record, {
  OutboxStatus status = OutboxStatus.pending,
  OutboxOperationType operation = OutboxOperationType.create,
}) => OutboxItem(
  id: id,
  userId: 'startup-efficiency@example.com',
  recordId: record.id,
  operationType: operation,
  status: status,
  createdAt: DateTime(2026, 11, 16, 12),
  payload: record.toJson(),
);

class _FailingPreferencesStore extends InMemorySharedPreferencesStore {
  _FailingPreferencesStore() : super.empty();

  String? failNextSetKey;
  String? failNextRemoveKey;

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    if (key == failNextSetKey) {
      failNextSetKey = null;
      return Future.value(false);
    }
    return super.setValue(valueType, key, value);
  }

  @override
  Future<bool> remove(String key) {
    if (key == failNextRemoveKey) {
      failNextRemoveKey = null;
      return Future.value(false);
    }
    return super.remove(key);
  }
}

class _CountedFactory implements DatabaseFactory {
  @override
  Future<Database> openDatabase(
    String path, {
    OpenDatabaseOptions? options,
  }) async => _CountedDatabase(
    await databaseFactoryFfiNoIsolate.openDatabase(path, options: options),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CountedDatabase implements Database {
  _CountedDatabase(this.inner);

  final Database inner;
  final Map<(String, bool), int> _reads = {};
  int migrationReads = 0;
  bool failNextMigrationRead = false;

  void resetCounts() {
    _reads.clear();
    migrationReads = 0;
  }

  int reads(String table, {required bool inside}) =>
      _reads[(table, inside)] ?? 0;

  void countQuery(
    String table,
    List<Object?>? whereArgs, {
    required bool inside,
  }) {
    final key = (table, inside);
    _reads[key] = (_reads[key] ?? 0) + 1;
    if (table == AppDatabase.localMetadataTable &&
        whereArgs != null &&
        whereArgs.any(
          (key) =>
              key == AppDatabase.legacyRecordsPreferencesMigrationKey ||
              key == AppDatabase.legacyOutboxPreferencesMigrationKey,
        )) {
      migrationReads++;
      if (failNextMigrationRead) {
        failNextMigrationRead = false;
        throw StateError('Injected migration metadata read failure');
      }
    }
  }

  @override
  bool get isOpen => inner.isOpen;

  @override
  Future<void> close() => inner.close();

  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction transaction) action, {
    bool? exclusive,
  }) => inner.transaction(
    (transaction) => action(_CountedTransaction(transaction, this)),
    exclusive: exclusive,
  );

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
    countQuery(table, whereArgs, inside: false);
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

class _CountedTransaction implements Transaction {
  _CountedTransaction(this.inner, this.counts);

  final Transaction inner;
  final _CountedDatabase counts;

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
    counts.countQuery(table, whereArgs, inside: true);
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
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) => inner.insert(
    table,
    values,
    nullColumnHack: nullColumnHack,
    conflictAlgorithm: conflictAlgorithm,
  );

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) => inner.update(
    table,
    values,
    where: where,
    whereArgs: whereArgs,
    conflictAlgorithm: conflictAlgorithm,
  );

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      inner.delete(table, where: where, whereArgs: whereArgs);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
