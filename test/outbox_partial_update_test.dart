import 'package:fishing_build/data/local/app_database.dart';
import 'package:fishing_build/data/local/local_data_store.dart';
import 'package:fishing_build/data/models/outbox_item.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/outbox_repository.dart';
import 'package:fishing_build/data/services/record_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  final auth = AuthSessionRepository.instance;
  final outbox = OutboxRepository.instance;
  final store = LocalDataStore.instance;
  late _CountedDatabase database;
  late String owner;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await RecordSyncService.instance.resetForTesting();
    sqfliteFfiInit();
    await AppDatabase.instance.configureForTesting(
      databaseFactory: _CountedFactory(),
    );
    database = await AppDatabase.instance.database as _CountedDatabase;
    auth.clearMemoryOnlyForTesting();
    outbox.clearCacheOnlyForTesting();
    await auth.setSessionForTesting(
      plan: UserPlan.paid,
      email: 'partial-outbox@example.com',
    );
    owner = auth.dataOwnerKey;
  });

  tearDown(() async {
    await RecordSyncService.instance.resetForTesting();
  });

  Future<void> seed(List<OutboxItem> items, {String? ownerKey}) async {
    final resolvedOwner = ownerKey ?? owner;
    await database.inner.transaction((transaction) async {
      for (final item in items) {
        await store.insertOutboxItem(
          transaction,
          ownerKey: resolvedOwner,
          item: item,
        );
      }
    });
    await outbox.reloadOwner(resolvedOwner);
    database.resetCounts();
  }

  Future<List<Map<String, Object?>>> rows([String? ownerKey]) =>
      database.inner.query(
        AppDatabase.outboxItemsTable,
        where: 'owner_key = ?',
        whereArgs: [ownerKey ?? owner],
        orderBy: 'insertion_order',
      );

  test(
    'a status change reads one row and never rewrites payload history',
    () async {
      await seed([
        for (var index = 0; index < 200; index++) _item('item-$index'),
      ]);
      final before = outbox.getAllItems();
      final beforeRow = (await rows())[57];

      await outbox.updateItemStatus(
        itemId: 'item-57',
        status: OutboxStatus.sending,
      );

      expect(database.fullPayloadReads, 0);
      expect(database.singlePayloadReads, 1);
      expect(database.payloadWrites, 0);
      expect(database.updates, 1);
      final after = outbox.getAllItems();
      expect(after.map((item) => item.id), before.map((item) => item.id));
      expect(after[57].status, OutboxStatus.sending);
      expect(identical(after[56], before[56]), isTrue);
      expect(identical(after[58], before[58]), isTrue);
      final afterRow = (await rows())[57];
      expect(afterRow['payload_json'], beforeRow['payload_json']);
      expect(afterRow['insertion_order'], beforeRow['insertion_order']);
      expect(afterRow['base_version_no'], beforeRow['base_version_no']);
    },
  );

  test(
    'retry increments atomically and leaves conflicted requests untouched',
    () async {
      await seed([
        _item(
          'retry',
          status: OutboxStatus.failed,
          retryCount: 2,
          error: 'offline',
        ),
        _item(
          'conflict',
          status: OutboxStatus.conflicted,
          retryCount: 7,
          error: 'conflict',
        ),
      ]);
      await Future.wait([outbox.retryItem('retry'), outbox.retryItem('retry')]);
      await outbox.retryItem('conflict');

      final items = outbox.getAllItems();
      expect(items.first.status, OutboxStatus.pending);
      expect(items.first.retryCount, 4);
      expect(items.first.errorMessage, isNull);
      expect(items.last.status, OutboxStatus.conflicted);
      expect(items.last.retryCount, 7);
      expect(items.last.errorMessage, 'conflict');
      expect(database.fullPayloadReads, 0);
      expect(database.payloadWrites, 0);
      expect((await rows()).first['retry_count'], 4);
    },
  );

  test(
    'add and replace preserve insertion order and duplicate failures',
    () async {
      await seed([_item('first'), _item('second'), _item('third')]);
      final before = await rows();
      await outbox.replaceItem(
        _item('second').copyWith(payload: {'memo': 'edited'}),
      );
      await outbox.addItem(_item('fourth'));

      expect(outbox.getAllItems().map((item) => item.id), [
        'first',
        'second',
        'third',
        'fourth',
      ]);
      expect(outbox.getAllItems()[1].payload, {'memo': 'edited'});
      expect(
        (await rows())[1]['insertion_order'],
        before[1]['insertion_order'],
      );
      expect(database.fullPayloadReads, 0);
      final committed = outbox
          .getAllItems()
          .map((item) => item.toJson())
          .toList();
      await expectLater(
        outbox.addItem(_item('second')),
        throwsA(isA<DatabaseException>()),
      );
      await expectLater(outbox.replaceItem(_item('missing')), throwsStateError);
      expect(
        outbox.getAllItems().map((item) => item.toJson()).toList(),
        committed,
      );
      expect(await rows(), hasLength(4));
    },
  );

  test(
    'the same item ID stays isolated by explicit owner after account switch',
    () async {
      await seed([_item('shared')]);
      final ownerA = owner;
      await auth.setSessionForTesting(
        plan: UserPlan.paid,
        email: 'other-outbox@example.com',
      );
      final ownerB = auth.dataOwnerKey;
      await seed([_item('shared')], ownerKey: ownerB);

      await outbox.updateItemStatusForOwner(
        ownerKey: ownerA,
        itemId: 'shared',
        status: OutboxStatus.failed,
        errorMessage: 'only A',
      );

      expect(
        outbox.getAllItemsForOwner(ownerA).single.status,
        OutboxStatus.failed,
      );
      expect(outbox.getAllItems().single.status, OutboxStatus.pending);
      expect((await rows(ownerA)).single['error_message'], 'only A');
      expect((await rows(ownerB)).single['error_message'], isNull);
      expect(database.fullPayloadReads, 0);
    },
  );

  test(
    'write and post-write decoding failures roll back without cache changes',
    () async {
      await seed([
        _item('rollback', status: OutboxStatus.failed, error: 'keep me'),
      ]);
      final beforeRows = await rows();
      final beforeCache = outbox.getAllItems().single.toJson();
      await database.inner.execute('''
      CREATE TRIGGER reject_outbox_status BEFORE UPDATE
      ON ${AppDatabase.outboxItemsTable}
      BEGIN SELECT RAISE(ABORT, 'test update failure'); END
    ''');
      await expectLater(
        outbox.updateItemStatus(
          itemId: 'rollback',
          status: OutboxStatus.sending,
        ),
        throwsA(isA<DatabaseException>()),
      );
      expect(await rows(), beforeRows);
      expect(outbox.getAllItems().single.toJson(), beforeCache);
      await database.inner.execute('DROP TRIGGER reject_outbox_status');
      await database.inner.execute('''
      CREATE TRIGGER corrupt_outbox_payload AFTER UPDATE OF status
      ON ${AppDatabase.outboxItemsTable}
      BEGIN
        UPDATE ${AppDatabase.outboxItemsTable} SET payload_json = '{'
        WHERE owner_key = NEW.owner_key AND outbox_id = NEW.outbox_id;
      END
    ''');
      await expectLater(
        outbox.updateItemStatus(
          itemId: 'rollback',
          status: OutboxStatus.sending,
        ),
        throwsFormatException,
      );
      expect(await rows(), beforeRows);
      expect(outbox.getAllItems().single.toJson(), beforeCache);
      await database.inner.execute('DROP TRIGGER corrupt_outbox_payload');

      await outbox.retryItem('rollback');
      expect(outbox.getAllItems().single.retryCount, 1);
      expect(outbox.getAllItems().single.errorMessage, isNull);
    },
  );

  test(
    'a cold cache loads history once even when getters created an empty view',
    () async {
      await seed([_item('first'), _item('second'), _item('third')]);
      outbox.clearCacheOnlyForTesting();
      expect(outbox.getAllItems(), isEmpty);

      await outbox.addItem(_item('fourth'));

      expect(outbox.getAllItems().map((item) => item.id), [
        'first',
        'second',
        'third',
        'fourth',
      ]);
      expect(database.fullPayloadReads, 1);
      database.resetCounts();
      await outbox.updateItemStatus(
        itemId: 'second',
        status: OutboxStatus.sending,
      );
      expect(database.fullPayloadReads, 0);
      expect(database.singlePayloadReads, 1);
    },
  );

  test(
    'clearing completed items keeps migration evidence without decoding survivors',
    () async {
      await seed([
        _item('completed', status: OutboxStatus.succeeded),
        _item('pending'),
        _item('migration', status: OutboxStatus.succeeded, isMigration: true),
        _item('failed', status: OutboxStatus.failed),
      ]);

      await outbox.clearSucceeded(includeMigration: false);

      expect(outbox.getAllItems().map((item) => item.id), [
        'pending',
        'migration',
        'failed',
      ]);
      expect((await rows()).map((row) => row['outbox_id']), [
        'pending',
        'migration',
        'failed',
      ]);
      expect(database.fullPayloadReads, 0);
      expect(database.singlePayloadReads, 0);
      await outbox.clearSucceeded();
      expect(outbox.getAllItems().map((item) => item.id), [
        'pending',
        'failed',
      ]);
      await outbox.clearAll();
      expect(outbox.getAllItems(), isEmpty);
      expect(await rows(), isEmpty);
    },
  );

  test('missing durable rows are not resurrected from stale cache', () async {
    await seed([
      _item('removed'),
      _item('retained', status: OutboxStatus.failed, error: 'old'),
    ]);
    await database.inner.delete(
      AppDatabase.outboxItemsTable,
      where: 'outbox_id = ?',
      whereArgs: ['removed'],
    );

    await outbox.updateItemStatus(
      itemId: 'removed',
      status: OutboxStatus.sending,
    );
    await outbox.retryItem('absent');
    expect(outbox.getAllItems().map((item) => item.id), ['retained']);
    expect((await rows()).map((row) => row['outbox_id']), ['retained']);
    await outbox.updateItemStatus(
      itemId: 'retained',
      status: OutboxStatus.failed,
    );
    expect(outbox.getAllItems().single.errorMessage, 'old');
    await outbox.updateItemStatus(
      itemId: 'retained',
      status: OutboxStatus.pending,
    );
    expect(outbox.getAllItems().single.errorMessage, isNull);
  });

  test(
    'retry restores older requests to their original queue position',
    () async {
      await seed([
        for (var index = 0; index < 100; index++)
          _item('history-$index', status: OutboxStatus.succeeded),
        _item('older', recordId: 'same-record', status: OutboxStatus.succeeded),
        _item('another-record'),
        _item('newer', recordId: 'same-record'),
        _item(
          'conflicted',
          recordId: 'same-record',
          status: OutboxStatus.conflicted,
        ),
      ]);
      expect(outbox.firstUnfinishedItemForOwner(owner)!.id, 'another-record');
      expect(outbox.pendingCount, 3);
      final captured = outbox.getUnfinishedItemsForRecord(
        ownerKey: owner,
        recordId: 'same-record',
      );
      expect(captured.map((item) => item.id), ['newer', 'conflicted']);

      await outbox.retryItem('older');

      expect(outbox.firstUnfinishedItemForOwner(owner)!.id, 'older');
      expect(
        outbox
            .getUnfinishedItemsForRecord(
              ownerKey: owner,
              recordId: 'same-record',
            )
            .map((item) => item.id),
        ['older', 'newer', 'conflicted'],
      );
      expect(outbox.pendingCount, 4);
      expect(captured.map((item) => item.id), ['newer', 'conflicted']);
      await outbox.updateItemStatus(
        itemId: 'older',
        status: OutboxStatus.succeeded,
      );
      expect(outbox.firstUnfinishedItemForOwner(owner)!.id, 'another-record');
      expect(outbox.pendingCount, 3);
      expect(database.fullPayloadReads, 0);
    },
  );

  test(
    'unfinished indexes follow record replacement, clearing, and owner scope',
    () async {
      await seed([
        _item('shared', recordId: 'original-record'),
        _item('completed', status: OutboxStatus.succeeded),
      ]);
      const anotherOwner = 'member:another-index-owner';
      await seed([
        _item(
          'shared',
          recordId: 'original-record',
          status: OutboxStatus.failed,
        ),
      ], ownerKey: anotherOwner);

      await outbox.replaceItem(_item('shared', recordId: 'moved-record'));

      expect(
        outbox.getUnfinishedItemsForRecord(
          ownerKey: owner,
          recordId: 'original-record',
        ),
        isEmpty,
      );
      expect(
        outbox
            .getUnfinishedItemsForRecord(
              ownerKey: owner,
              recordId: 'moved-record',
            )
            .single
            .id,
        'shared',
      );
      expect(
        outbox
            .getUnfinishedItemsForRecord(
              ownerKey: anotherOwner,
              recordId: 'original-record',
            )
            .single
            .status,
        OutboxStatus.failed,
      );
      await outbox.updateItemStatus(
        itemId: 'shared',
        status: OutboxStatus.succeeded,
      );
      expect(outbox.hasUnfinishedItems, isFalse);
      expect(outbox.firstUnfinishedItemForOwner(owner), isNull);
      await outbox.clearSucceeded();
      expect(outbox.pendingCount, 0);
      expect(
        outbox.getUnfinishedItemsForRecord(
          ownerKey: owner,
          recordId: 'moved-record',
        ),
        isEmpty,
      );
      expect(outbox.firstUnfinishedItemForOwner(anotherOwner)!.id, 'shared');

      outbox.clearCacheOnlyForTesting();
      expect(outbox.firstUnfinishedItemForOwner(anotherOwner), isNull);
      expect(
        outbox.getUnfinishedItemsForRecord(
          ownerKey: anotherOwner,
          recordId: 'original-record',
        ),
        isEmpty,
      );
      await outbox.reloadOwner(anotherOwner);
      expect(outbox.firstUnfinishedItemForOwner(anotherOwner)!.id, 'shared');
      await database.inner.delete(
        AppDatabase.outboxItemsTable,
        where: 'owner_key = ?',
        whereArgs: [anotherOwner],
      );
      await outbox.updateItemStatusForOwner(
        ownerKey: anotherOwner,
        itemId: 'shared',
        status: OutboxStatus.sending,
      );
      expect(outbox.firstUnfinishedItemForOwner(anotherOwner), isNull);
      expect(outbox.hasUnfinishedItemsForOwner(anotherOwner), isFalse);
      expect(
        outbox.getUnfinishedItemsForRecord(
          ownerKey: anotherOwner,
          recordId: 'original-record',
        ),
        isEmpty,
      );
    },
  );
}

OutboxItem _item(
  String id, {
  OutboxStatus status = OutboxStatus.pending,
  int retryCount = 0,
  String? error,
  bool isMigration = false,
  String? recordId,
}) => OutboxItem(
  id: id,
  recordId: recordId ?? 'record-$id',
  operationType: OutboxOperationType.update,
  status: status,
  createdAt: DateTime(2026, 10, 26),
  retryCount: retryCount,
  errorMessage: error,
  isMigration: isMigration,
  baseVersionNo: 4,
  payload: {
    'id': recordId ?? 'record-$id',
    'memo': List.filled(100, id).join(','),
  },
);

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
  int fullPayloadReads = 0;
  int singlePayloadReads = 0;
  int payloadWrites = 0;
  int updates = 0;

  void resetCounts() {
    fullPayloadReads = 0;
    singlePayloadReads = 0;
    payloadWrites = 0;
    updates = 0;
  }

  void countRead(String table, List<String>? columns, int? limit) {
    if (table != AppDatabase.outboxItemsTable || columns != null) return;
    if (limit == 1) {
      singlePayloadReads++;
    } else {
      fullPayloadReads++;
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
    countRead(table, columns, limit);
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
    counts.countRead(table, columns, limit);
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
  }) {
    if (table == AppDatabase.outboxItemsTable &&
        values.containsKey('payload_json')) {
      counts.payloadWrites++;
    }
    return inner.insert(
      table,
      values,
      nullColumnHack: nullColumnHack,
      conflictAlgorithm: conflictAlgorithm,
    );
  }

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) {
    if (table == AppDatabase.outboxItemsTable) {
      counts.updates++;
      if (values.containsKey('payload_json')) counts.payloadWrites++;
    }
    return inner.update(
      table,
      values,
      where: where,
      whereArgs: whereArgs,
      conflictAlgorithm: conflictAlgorithm,
    );
  }

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) =>
      inner.rawUpdate(sql, arguments);

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      inner.delete(table, where: where, whereArgs: whereArgs);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
