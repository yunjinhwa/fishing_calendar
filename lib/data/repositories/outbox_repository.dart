import 'package:flutter/foundation.dart';

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

  String get _ownerKey => AuthSessionRepository.instance.dataOwnerKey;

  List<OutboxItem> get _items =>
      _itemsByOwner.putIfAbsent(_ownerKey, () => <OutboxItem>[]);

  Future<void> loadItems() async {
    await LocalDataMigrationService.instance.migrateIfNeeded();
    final ownerKey = _ownerKey;
    _itemsByOwner[ownerKey] = await _store.readOutboxItemsForOwner(ownerKey);
  }

  Future<void> reloadOwner(String ownerKey) async {
    _itemsByOwner[ownerKey] = await _store.readOutboxItemsForOwner(ownerKey);
  }

  List<OutboxItem> getAllItems() => List.unmodifiable(_items);

  int get pendingCount =>
      _items.where((item) => item.status != OutboxStatus.succeeded).length;

  bool get hasUnfinishedItems =>
      _items.any((item) => item.status != OutboxStatus.succeeded);

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

  Future<void> addItem(OutboxItem item) async {
    final ownerKey = _ownerKey;
    await AppDatabase.instance.transaction((transaction) async {
      await _store.insertOutboxItem(
        transaction,
        ownerKey: ownerKey,
        item: item,
      );
    });
    await reloadOwner(ownerKey);
  }

  Future<void> replaceItem(OutboxItem item) async {
    if (!_items.any((savedItem) => savedItem.id == item.id)) {
      throw StateError('Outbox item not found: ${item.id}');
    }

    final ownerKey = _ownerKey;
    await AppDatabase.instance.transaction((transaction) async {
      await _store.insertOutboxItem(
        transaction,
        ownerKey: ownerKey,
        item: item,
        replace: true,
      );
    });
    await reloadOwner(ownerKey);
  }

  Future<void> updateItemStatus({
    required String itemId,
    required OutboxStatus status,
    String? errorMessage,
  }) async {
    final item = _findItem(itemId);
    if (item == null) {
      return;
    }

    await replaceItem(
      item.copyWith(
        status: status,
        lastTriedAt: DateTime.now(),
        errorMessage: errorMessage,
        clearErrorMessage:
            errorMessage == null && status != OutboxStatus.failed,
      ),
    );
  }

  Future<void> retryItem(String itemId) async {
    final item = _findItem(itemId);
    if (item == null) {
      return;
    }

    await replaceItem(
      item.copyWith(
        status: OutboxStatus.pending,
        lastTriedAt: DateTime.now(),
        retryCount: item.retryCount + 1,
        clearErrorMessage: true,
      ),
    );
  }

  Future<void> clearSucceeded({bool includeMigration = true}) async {
    final ownerKey = _ownerKey;
    await AppDatabase.instance.transaction((transaction) async {
      await _store.deleteOutboxItems(
        transaction,
        ownerKey: ownerKey,
        where: includeMigration
            ? 'status = ?'
            : 'status = ? AND is_migration = 0',
        whereArgs: <Object?>[OutboxStatus.succeeded.name],
      );
    });
    await reloadOwner(ownerKey);
  }

  Future<void> removeObsoleteMigrationItems(Set<String> recordIds) async {
    final ownerKey = _ownerKey;
    final placeholders = List.filled(recordIds.length, '?').join(', ');
    final recordFilter = recordIds.isEmpty
        ? ''
        : ' AND record_id NOT IN ($placeholders)';

    await AppDatabase.instance.transaction((transaction) async {
      await _store.deleteOutboxItems(
        transaction,
        ownerKey: ownerKey,
        where: 'is_migration = 1 AND operation_type = ?$recordFilter',
        whereArgs: <Object?>[OutboxOperationType.create.name, ...recordIds],
      );
    });
    await reloadOwner(ownerKey);
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
    await reloadOwner(ownerKey);
  }

  OutboxItem? _findItem(String itemId) {
    for (final item in _items) {
      if (item.id == itemId) {
        return item;
      }
    }
    return null;
  }

  @visibleForTesting
  void clearCacheOnlyForTesting() {
    _itemsByOwner.clear();
  }
}
