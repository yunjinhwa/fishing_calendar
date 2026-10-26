import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../local/app_database.dart';
import '../local/local_data_migration_service.dart';
import '../local/local_data_store.dart';
import '../models/outbox_item.dart';
import 'auth_session_repository.dart';

class OutboxRepository {
  OutboxRepository._();

  static final OutboxRepository instance = OutboxRepository._();

  final LocalDataStore _store = LocalDataStore.instance;
  final Map<String, List<OutboxItem>> _itemsByOwner = {};
  final Map<String, Map<String, int>> _positionsByOwner = {};
  final Map<String, SplayTreeMap<int, OutboxItem>> _unfinishedByOwner = {};
  final Map<String, Map<String, SplayTreeMap<int, OutboxItem>>>
  _unfinishedByRecord = {};
  final Set<String> _loadedOwners = {};

  String get _ownerKey => AuthSessionRepository.instance.dataOwnerKey;

  List<OutboxItem> get _items =>
      _itemsByOwner.putIfAbsent(_ownerKey, () => <OutboxItem>[]);

  Future<void> loadItems() async {
    await LocalDataMigrationService.instance.migrateIfNeeded();
    final ownerKey = _ownerKey;
    publishCommittedSnapshot(
      ownerKey: ownerKey,
      items: await _store.readOutboxItemsForOwner(ownerKey),
    );
  }

  Future<void> reloadOwner(String ownerKey) async {
    publishCommittedSnapshot(
      ownerKey: ownerKey,
      items: await _store.readOutboxItemsForOwner(ownerKey),
    );
  }

  /// Publishes items already read and decoded inside a committed transaction.
  ///
  /// Call only after that transaction succeeds, before notifying record
  /// listeners, so they observe matching record and outbox caches.
  void publishCommittedSnapshot({
    required String ownerKey,
    required List<OutboxItem> items,
  }) {
    _itemsByOwner[ownerKey] = List<OutboxItem>.of(items);
    _positionsByOwner[ownerKey] = {
      for (var index = 0; index < items.length; index++) items[index].id: index,
    };
    _unfinishedByOwner[ownerKey] = SplayTreeMap<int, OutboxItem>();
    _unfinishedByRecord[ownerKey] = {};
    for (var index = 0; index < items.length; index++) {
      _indexUnfinished(ownerKey, index, items[index]);
    }
    _loadedOwners.add(ownerKey);
  }

  /// Publishes changed rows decoded before their transaction committed.
  ///
  /// The owner's cache must already be loaded. Existing items keep their
  /// insertion order; new items must be supplied in insertion order.
  void publishCommittedItems({
    required String ownerKey,
    required List<OutboxItem> items,
  }) {
    if (!_loadedOwners.contains(ownerKey)) {
      throw StateError('Outbox cache is not loaded for $ownerKey.');
    }
    final cached = _itemsByOwner[ownerKey]!;
    final positions = _positionsByOwner[ownerKey]!;
    for (final item in items) {
      final position = positions[item.id];
      if (position == null) {
        positions[item.id] = cached.length;
        _indexUnfinished(ownerKey, cached.length, item);
        cached.add(item);
      } else {
        _removeUnfinished(ownerKey, position, cached[position]);
        cached[position] = item;
        _indexUnfinished(ownerKey, position, item);
      }
    }
  }

  List<OutboxItem> getAllItems() => List.unmodifiable(_items);

  List<OutboxItem> getAllItemsForOwner(String ownerKey) => List.unmodifiable(
    _itemsByOwner.putIfAbsent(ownerKey, () => <OutboxItem>[]),
  );

  int get pendingCount => _unfinishedByOwner[_ownerKey]?.length ?? 0;

  bool get hasUnfinishedItems => hasUnfinishedItemsForOwner(_ownerKey);

  bool hasUnfinishedItemsForOwner(String ownerKey) =>
      _unfinishedByOwner[ownerKey]?.isNotEmpty ?? false;

  /// Returns the earliest unfinished request without copying completed history.
  OutboxItem? firstUnfinishedItemForOwner(String ownerKey) {
    final unfinished = _unfinishedByOwner[ownerKey];
    final first = unfinished?.firstKey();
    return first == null ? null : unfinished![first];
  }

  /// Captures only this record's unfinished requests in insertion order.
  List<OutboxItem> getUnfinishedItemsForRecord({
    required String ownerKey,
    required String recordId,
  }) => List<OutboxItem>.unmodifiable(
    _unfinishedByRecord[ownerKey]?[recordId]?.values ?? const <OutboxItem>[],
  );

  void _indexUnfinished(String ownerKey, int position, OutboxItem item) {
    if (item.status == OutboxStatus.succeeded) return;
    _unfinishedByOwner[ownerKey]![position] = item;
    _unfinishedByRecord[ownerKey]!.putIfAbsent(
      item.recordId,
      () => SplayTreeMap<int, OutboxItem>(),
    )[position] = item;
  }

  void _removeUnfinished(String ownerKey, int position, OutboxItem item) {
    if (item.status == OutboxStatus.succeeded) return;
    _unfinishedByOwner[ownerKey]!.remove(position);
    final records = _unfinishedByRecord[ownerKey]!;
    final unfinished = records[item.recordId];
    unfinished?.remove(position);
    if (unfinished?.isEmpty ?? false) records.remove(item.recordId);
  }

  bool hasItem({
    required String recordId,
    required OutboxOperationType operationType,
    bool? isMigration,
  }) {
    return _items.any(
      (item) =>
          item.recordId == recordId &&
          item.operationType == operationType &&
          (isMigration == null || item.isMigration == isMigration),
    );
  }

  Future<void> addItem(OutboxItem item) => addItemForOwner(_ownerKey, item);

  Future<void> addItemForOwner(String ownerKey, OutboxItem item) async {
    await _commitItemChange(
      ownerKey: ownerKey,
      itemId: item.id,
      change: (transaction) async {
        await _store.insertOutboxItem(
          transaction,
          ownerKey: ownerKey,
          item: item,
        );
        return true;
      },
    );
  }

  Future<void> replaceItem(OutboxItem item) =>
      replaceItemForOwner(_ownerKey, item);

  Future<void> replaceItemForOwner(String ownerKey, OutboxItem item) async {
    await _commitItemChange(
      ownerKey: ownerKey,
      itemId: item.id,
      change: (transaction) async {
        final updated = await transaction.update(
          AppDatabase.outboxItemsTable,
          _encodeItem(item),
          where: 'owner_key = ? AND outbox_id = ?',
          whereArgs: <Object?>[ownerKey, item.id],
        );
        if (updated == 0) {
          throw StateError('Outbox item not found: ${item.id}');
        }
        return true;
      },
    );
  }

  Future<void> updateItemStatus({
    required String itemId,
    required OutboxStatus status,
    String? errorMessage,
  }) => updateItemStatusForOwner(
    ownerKey: _ownerKey,
    itemId: itemId,
    status: status,
    errorMessage: errorMessage,
  );

  Future<void> updateItemStatusForOwner({
    required String ownerKey,
    required String itemId,
    required OutboxStatus status,
    String? errorMessage,
  }) async {
    await _commitItemChange(
      ownerKey: ownerKey,
      itemId: itemId,
      change: (transaction) async {
        final values = <String, Object?>{
          'status': status.name,
          'last_tried_at': DateTime.now().toIso8601String(),
          if (errorMessage != null || status != OutboxStatus.failed)
            'error_message': errorMessage,
        };
        return await transaction.update(
              AppDatabase.outboxItemsTable,
              values,
              where: 'owner_key = ? AND outbox_id = ?',
              whereArgs: <Object?>[ownerKey, itemId],
            ) >
            0;
      },
    );
  }

  Future<void> retryItem(String itemId) =>
      retryItemForOwner(ownerKey: _ownerKey, itemId: itemId);

  Future<void> retryItemForOwner({
    required String ownerKey,
    required String itemId,
  }) async {
    await _commitItemChange(
      ownerKey: ownerKey,
      itemId: itemId,
      change: (transaction) async =>
          await transaction.rawUpdate(
            '''
            UPDATE ${AppDatabase.outboxItemsTable}
            SET status = ?, last_tried_at = ?, retry_count = retry_count + 1,
                error_message = NULL
            WHERE owner_key = ? AND outbox_id = ? AND status != ?
            ''',
            <Object?>[
              OutboxStatus.pending.name,
              DateTime.now().toIso8601String(),
              ownerKey,
              itemId,
              OutboxStatus.conflicted.name,
            ],
          ) >
          0,
    );
  }

  Future<void> clearSucceeded({bool includeMigration = true}) async {
    final ownerKey = _ownerKey;
    final removed = await AppDatabase.instance.transaction((transaction) async {
      final where = includeMigration
          ? 'status = ?'
          : 'status = ? AND is_migration = 0';
      final rows = await transaction.query(
        AppDatabase.outboxItemsTable,
        columns: const ['outbox_id'],
        where: 'owner_key = ? AND ($where)',
        whereArgs: <Object?>[ownerKey, OutboxStatus.succeeded.name],
      );
      await _store.deleteOutboxItems(
        transaction,
        ownerKey: ownerKey,
        where: where,
        whereArgs: <Object?>[OutboxStatus.succeeded.name],
      );
      final remaining = _loadedOwners.contains(ownerKey)
          ? null
          : await _store.readOutboxItemsForOwner(
              ownerKey,
              executor: transaction,
            );
      return (
        ids: rows.map((row) => row['outbox_id']! as String).toSet(),
        remaining: remaining,
      );
    });
    publishCommittedSnapshot(
      ownerKey: ownerKey,
      items:
          removed.remaining ??
          _itemsByOwner[ownerKey]!
              .where((item) => !removed.ids.contains(item.id))
              .toList(growable: false),
    );
  }

  Future<void> clearAll() async {
    final ownerKey = _ownerKey;
    await AppDatabase.instance.transaction((transaction) async {
      await _store.deleteOutboxItems(
        transaction,
        ownerKey: ownerKey,
        where: '1 = 1',
      );
    });
    publishCommittedSnapshot(ownerKey: ownerKey, items: const []);
  }

  Future<void> _commitItemChange({
    required String ownerKey,
    required String itemId,
    required Future<bool> Function(Transaction transaction) change,
  }) async {
    final committed = await AppDatabase.instance.transaction((
      transaction,
    ) async {
      final changed = await change(transaction);
      final rows = await transaction.query(
        AppDatabase.outboxItemsTable,
        where: 'owner_key = ? AND outbox_id = ?',
        whereArgs: <Object?>[ownerKey, itemId],
        limit: 1,
      );
      if (rows.isEmpty) {
        if (changed) throw StateError('Outbox item not found: $itemId');
        return (item: null, allItems: null);
      }
      final item = _decodeItem(rows.single);
      // Only a cold owner needs the complete cache. Decode before committing so
      // a read failure never reports an already persisted mutation as failed.
      final allItems = _loadedOwners.contains(ownerKey)
          ? null
          : await _store.readOutboxItemsForOwner(
              ownerKey,
              executor: transaction,
            );
      return (item: item, allItems: allItems);
    });
    final allItems = committed.allItems;
    if (allItems != null) {
      publishCommittedSnapshot(ownerKey: ownerKey, items: allItems);
    } else {
      final item = committed.item;
      if (item != null) {
        publishCommittedItems(ownerKey: ownerKey, items: [item]);
      } else if (_loadedOwners.contains(ownerKey)) {
        publishCommittedSnapshot(
          ownerKey: ownerKey,
          items: _itemsByOwner[ownerKey]!
              .where((item) => item.id != itemId)
              .toList(growable: false),
        );
      }
    }
  }

  Map<String, Object?> _encodeItem(OutboxItem item) => {
    'user_id': item.userId,
    'record_id': item.recordId,
    'operation_type': item.operationType.name,
    'status': item.status.name,
    'created_at': item.createdAt.toIso8601String(),
    'last_tried_at': item.lastTriedAt?.toIso8601String(),
    'error_message': item.errorMessage,
    'retry_count': item.retryCount,
    'is_migration': item.isMigration ? 1 : 0,
    'base_version_no': item.baseVersionNo,
    'payload_json': item.payload == null ? null : jsonEncode(item.payload),
  };

  OutboxItem _decodeItem(Map<String, Object?> row) => OutboxItem.fromJson({
    'id': row['outbox_id'],
    'userId': row['user_id'],
    'recordId': row['record_id'],
    'operationType': row['operation_type'],
    'status': row['status'],
    'createdAt': row['created_at'],
    'lastTriedAt': row['last_tried_at'],
    'errorMessage': row['error_message'],
    'retryCount': (row['retry_count']! as num).toInt(),
    'isMigration': (row['is_migration']! as num).toInt() == 1,
    'baseVersionNo': row['base_version_no'],
    'payload': row['payload_json'] == null
        ? null
        : jsonDecode(row['payload_json']! as String),
  });

  @visibleForTesting
  void clearCacheOnlyForTesting() {
    _itemsByOwner.clear();
    _positionsByOwner.clear();
    _unfinishedByOwner.clear();
    _unfinishedByRecord.clear();
    _loadedOwners.clear();
  }
}
