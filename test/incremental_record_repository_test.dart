import 'package:fishing_build/data/local/app_database.dart';
import 'package:fishing_build/data/local/local_data_store.dart';
import 'package:fishing_build/data/models/conflict_item.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/outbox_item.dart';
import 'package:fishing_build/data/models/record_sync_metadata.dart';
import 'package:fishing_build/data/models/user_plan.dart';
import 'package:fishing_build/data/remote/record_sync_gateway.dart';
import 'package:fishing_build/data/repositories/auth_session_repository.dart';
import 'package:fishing_build/data/repositories/fishing_record_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  final auth = AuthSessionRepository.instance;
  final records = FishingRecordRepository.instance;
  final store = LocalDataStore.instance;
  late _CountingDatabase database;
  late String owner;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    await AppDatabase.instance.configureForTesting(
      databaseFactory: _CountingFactory(),
    );
    database = await AppDatabase.instance.database as _CountingDatabase;
    auth.clearMemoryOnlyForTesting();
    records.clearCacheOnlyForTesting();
    await auth.setSessionForTesting(
      plan: UserPlan.paid,
      email: 'incremental-repository@example.com',
    );
    owner = auth.dataOwnerKey;
  });

  tearDown(() async {
    database.onRecordWrite = null;
    await AppDatabase.instance.close();
  });

  Future<void> seed(FishingRecord record, {int version = 1}) async {
    await AppDatabase.instance.transaction((transaction) async {
      await store.insertRecord(transaction, ownerKey: owner, record: record);
      await store.writeRecordSyncMetadata(
        transaction,
        ownerKey: owner,
        metadata: RecordSyncMetadata(
          recordId: record.id,
          serverVersionNo: version,
          optimisticVersionNo: version,
          remoteStatus: RemoteRecordStatus.active,
        ),
      );
    });
    await records.reloadOwner(owner);
  }

  Future<RecordPageApplyResult> page(
    List<RemoteRecordRevision> revisions, {
    int position = 2,
    bool Function()? isCurrent,
  }) => records.applyRemotePage(
    ownerKey: owner,
    revisions: revisions,
    checkpoint: _checkpoint(position),
    isCurrentSession: isCurrent ?? () => true,
  );

  test('one changed ID uses partial SQL and preserves local photos', () async {
    final original = _record('changed', withPhoto: true);
    await seed(original);
    await seed(_record('untouched'));
    database.events.clear();

    final result = await page([
      _active('changed', version: 2, location: 'New'),
    ]);

    expect(result.applied, isTrue);
    expect(result.changedCount, 1);
    final changed = records.getRecordById('changed')!;
    expect(changed.location, 'New');
    expect(changed.photos.single.localPath, original.photos.single.localPath);
    expect(records.getRecordById('untouched')!.location, 'Original');
    expect(
      database.events
          .where(
            (event) =>
                event.operation == 'query' &&
                event.table == AppDatabase.fishingRecordsTable,
          )
          .every((event) => event.where == 'owner_key = ? AND record_id = ?'),
      isTrue,
    );
    expect(
      database.events.where(
        (event) =>
            event.operation == 'delete' &&
            event.table == AppDatabase.fishingRecordsTable,
      ),
      isEmpty,
    );
    expect((await records.readSyncCheckpoint(owner))!.cursor.seconds, 2);
  });

  test(
    'tombstones are partial and matching page replay writes nothing',
    () async {
      await seed(_record('deleted', withPhoto: true));
      await seed(_record('retained'));
      var notifications = 0;
      void listener() => notifications++;
      records.addListener(listener);
      addTearDown(() => records.removeListener(listener));
      final revision = RemoteRecordRevision(
        recordId: 'deleted',
        versionNo: 2,
        status: RemoteRecordStatus.deleted,
        record: null,
      );

      expect((await page([revision])).changedCount, 1);
      expect(records.getRecordById('deleted'), isNull);
      expect(records.getRecordById('retained'), isNotNull);
      expect(
        await database.inner.query(AppDatabase.recordPhotosTable),
        isEmpty,
      );
      expect(notifications, 1);
      database.events.clear();

      expect((await page([revision])).changedCount, 0);
      expect(
        database.events.where((event) => event.operation != 'query'),
        isEmpty,
      );
      expect(notifications, 1);
    },
  );

  test(
    'checkpoint write failure rolls back records, children and versions',
    () async {
      final original = _record('rollback', withPhoto: true);
      await seed(original);
      final before = await _persistentState(database.inner);
      await database.inner.execute('''
      CREATE TRIGGER reject_checkpoint BEFORE INSERT
      ON ${AppDatabase.localMetadataTable}
      WHEN NEW.metadata_key LIKE 'record_incremental_sync_v1:%'
      BEGIN SELECT RAISE(ABORT, 'checkpoint failure'); END
    ''');
      await expectLater(
        page([_active('rollback', version: 2, location: 'Must roll back')]),
        throwsA(isA<DatabaseException>()),
      );
      expect(await _persistentState(database.inner), before);
      expect(records.getRecordById('rollback')!.toJson(), original.toJson());
      expect(await records.readSyncCheckpoint(owner), isNull);
    },
  );

  for (final guard in ['outbox', 'conflict', 'free change']) {
    test('$guard blocks body and checkpoint together', () async {
      final original = _record('protected');
      await seed(original);
      await AppDatabase.instance.transaction((transaction) async {
        switch (guard) {
          case 'outbox':
            await store.insertOutboxItem(
              transaction,
              ownerKey: owner,
              item: OutboxItem(
                id: 'pending',
                recordId: original.id,
                operationType: OutboxOperationType.update,
                status: OutboxStatus.pending,
                createdAt: DateTime(2026, 10, 26),
                payload: original.toJson(),
              ),
            );
          case 'conflict':
            await store.insertConflict(
              transaction,
              conflict: ConflictItem(
                id: 'conflict',
                ownerKey: owner,
                recordId: original.id,
                outboxId: 'old',
                localOperationType: OutboxOperationType.update,
                baseVersionNo: 0,
                remoteVersionNo: 1,
                remoteStatus: RemoteRecordStatus.active,
                localRecord: original,
                remoteRecord: original,
                occurredAt: DateTime(2026, 10, 26),
                status: ConflictStatus.unresolved,
              ),
            );
          case 'free change':
            await store.writeLocalRecordChange(
              transaction,
              ownerKey: owner,
              record: original,
              deleted: false,
            );
        }
      });
      final before = await _persistentState(database.inner);
      final result = await page([
        _active(original.id, version: 2, location: 'Remote'),
      ]);
      expect(result.applied, isFalse);
      expect(await _persistentState(database.inner), before);
      expect(records.getRecordById(original.id)!.toJson(), original.toJson());
    });
  }

  test(
    'a changed session generation during SQL work cancels the whole page',
    () async {
      final original = _record('session');
      await seed(original);
      final before = await _persistentState(database.inner);
      var generation = 1;
      final capturedGeneration = generation;
      // Represents A -> B -> A: owner may match again, generation cannot.
      database.onRecordWrite = () => generation += 2;

      final result = await page([
        _active(original.id, version: 2, location: 'Wrong session'),
      ], isCurrent: () => generation == capturedGeneration);

      expect(result.applied, isFalse);
      expect(await _persistentState(database.inner), before);
      expect(records.getRecordById(original.id)!.toJson(), original.toJson());
    },
  );

  test(
    'explicit owner pages cannot change another account with the same ID',
    () async {
      await seed(_record('same-id'));
      await auth.setSessionForTesting(
        plan: UserPlan.paid,
        email: 'other@example.com',
      );
      final otherOwner = auth.dataOwnerKey;
      await records.addRecord(_record('same-id', location: 'Other account'));

      expect(
        (await page([
          _active('same-id', version: 2, location: 'Owner A'),
        ])).applied,
        isTrue,
      );

      expect(records.getRecordById('same-id')!.location, 'Other account');
      expect(
        (await store.readRecordForOwner(owner, 'same-id'))!.location,
        'Owner A',
      );
      expect(
        (await store.readRecordForOwner(otherOwner, 'same-id'))!.location,
        'Other account',
      );
      expect(await records.readSyncCheckpoint(otherOwner), isNull);
    },
  );

  test(
    'full snapshot diffs existing records and unchanged pulls do not notify',
    () async {
      await seed(_record('kept', withPhoto: true));
      await seed(_record('missing-on-server'));
      final snapshot = RemoteRecordSnapshot(revisions: [_active('kept')]);
      expect(
        await records.replaceWithRemoteSnapshot(
          snapshot,
          ownerKey: owner,
          checkpoint: _checkpoint(1),
        ),
        isTrue,
      );
      expect(records.getRecordById('missing-on-server'), isNull);
      expect(records.getRecordById('kept')!.photos, hasLength(1));
      expect(
        await store.readRecordSyncMetadata(owner, 'missing-on-server'),
        isNull,
      );
      var notifications = 0;
      void listener() => notifications++;
      records.addListener(listener);
      addTearDown(() => records.removeListener(listener));
      database.events.clear();

      expect(
        await records.replaceWithRemoteSnapshot(
          snapshot,
          ownerKey: owner,
          checkpoint: _checkpoint(1),
        ),
        isTrue,
      );
      expect(
        database.events.where((event) => event.operation != 'query'),
        isEmpty,
      );
      expect(notifications, 0);
    },
  );

  test(
    'memory reset keeps progress but physical cache clear invalidates it',
    () async {
      await page([_active('clear')]);
      records.clearCacheOnlyForTesting();
      expect(await records.readSyncCheckpoint(owner), isNotNull);
      await records.clear();
      expect(await records.readSyncCheckpoint(owner), isNull);
      expect(await store.readRecordsForOwner(owner), isEmpty);
    },
  );

  test(
    'stale revisions cannot undo data or move a checkpoint backwards',
    () async {
      await page([
        _active('newer', version: 3, location: 'Latest'),
      ], position: 9);
      database.events.clear();
      final result = await page([
        _active('newer', version: 2, location: 'Stale'),
      ], position: 2);
      expect(result.applied, isTrue);
      expect(result.changedCount, 0);
      expect(records.getRecordById('newer')!.location, 'Latest');
      expect((await records.readSyncCheckpoint(owner))!.cursor.seconds, 9);
      expect(
        database.events.where((event) => event.operation != 'query'),
        isEmpty,
      );
    },
  );

  test(
    'corrupted progress requests a full baseline instead of dropping records',
    () async {
      await seed(_record('preserved'));
      await AppDatabase.instance.transaction(
        (transaction) => store.writeMetadata(
          transaction,
          key: RecordSyncCheckpoint.metadataKey(owner),
          value: '{bad json',
        ),
      );
      expect(await records.readSyncCheckpoint(owner), isNull);
      expect(records.getRecordById('preserved'), isNotNull);
    },
  );
}

RecordSyncCheckpoint _checkpoint(int seconds) => RecordSyncCheckpoint(
  cursor: RecordSyncCursor(
    seconds: seconds,
    nanoseconds: 123456789,
    recordId: 'last',
  ),
  lastFullSyncAt: DateTime.utc(2026, 10, 26),
);

RemoteRecordRevision _active(
  String id, {
  int version = 1,
  String location = 'Original',
}) => RemoteRecordRevision(
  recordId: id,
  versionNo: version,
  status: RemoteRecordStatus.active,
  record: _record(id, location: location),
);

FishingRecord _record(
  String id, {
  String location = 'Original',
  bool withPhoto = false,
}) => FishingRecord(
  id: id,
  location: location,
  startAt: DateTime(2026, 10, 21, 18),
  endAt: DateTime(2026, 10, 22, 3),
  genreName: '루어',
  catches: const [CatchRecord(speciesName: '우럭', lengthCm: 31)],
  photos: [
    if (withPhoto)
      const RecordPhoto(id: 'photo', localPath: 'C:/device/local.jpg'),
  ],
);

Future<Map<String, List<Map<String, Object?>>>> _persistentState(
  Database database,
) async => {
  for (final table in [
    AppDatabase.fishingRecordsTable,
    AppDatabase.recordCatchesTable,
    AppDatabase.recordPhotosTable,
    AppDatabase.recordSyncStatesTable,
    AppDatabase.localMetadataTable,
  ])
    table: await database.query(table, orderBy: 'rowid'),
};

class _SqlEvent {
  final String operation;
  final String table;
  final String? where;
  const _SqlEvent(this.operation, this.table, this.where);
}

class _CountingFactory implements DatabaseFactory {
  @override
  Future<Database> openDatabase(
    String path, {
    OpenDatabaseOptions? options,
  }) async => _CountingDatabase(
    await databaseFactoryFfiNoIsolate.openDatabase(path, options: options),
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CountingDatabase implements Database {
  final Database inner;
  final events = <_SqlEvent>[];
  void Function()? onRecordWrite;
  _CountingDatabase(this.inner);
  @override
  bool get isOpen => inner.isOpen;
  @override
  Future<void> close() => inner.close();
  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction transaction) action, {
    bool? exclusive,
  }) => inner.transaction(
    (transaction) => action(_CountingTransaction(transaction, this)),
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
    events.add(_SqlEvent('query', table, where));
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

class _CountingTransaction implements Transaction {
  final Transaction inner;
  final _CountingDatabase owner;
  _CountingTransaction(this.inner, this.owner);
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
    owner.events.add(_SqlEvent('query', table, where));
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
  }) async {
    owner.events.add(_SqlEvent('insert', table, null));
    final result = await inner.insert(
      table,
      values,
      nullColumnHack: nullColumnHack,
      conflictAlgorithm: conflictAlgorithm,
    );
    if (table == AppDatabase.fishingRecordsTable) owner.onRecordWrite?.call();
    return result;
  }

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) {
    owner.events.add(_SqlEvent('delete', table, where));
    return inner.delete(table, where: where, whereArgs: whereArgs);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
