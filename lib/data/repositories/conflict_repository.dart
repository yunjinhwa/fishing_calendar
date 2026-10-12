import 'package:flutter/foundation.dart';

import '../local/app_database.dart';
import '../local/local_data_store.dart';
import '../models/conflict_item.dart';
import 'auth_session_repository.dart';

class ConflictRepository extends ChangeNotifier {
  ConflictRepository._();

  static final ConflictRepository instance = ConflictRepository._();

  final LocalDataStore _store = LocalDataStore.instance;
  final Map<String, List<ConflictItem>> _itemsByOwner = {};

  String get _ownerKey => AuthSessionRepository.instance.dataOwnerKey;

  List<ConflictItem> get _items =>
      _itemsByOwner.putIfAbsent(_ownerKey, () => <ConflictItem>[]);

  Future<void> loadItems() => reloadOwner(_ownerKey);

  Future<void> reloadOwner(String ownerKey) async {
    _itemsByOwner[ownerKey] = await _store.readConflictsForOwner(ownerKey);
    notifyListeners();
  }

  List<ConflictItem> getAllItems() => List.unmodifiable(_items);

  List<ConflictItem> getPendingItems() => List.unmodifiable(
    _items.where((item) => item.status != ConflictStatus.resolved),
  );

  int get unresolvedCount =>
      _items.where((item) => item.status != ConflictStatus.resolved).length;

  bool hasPendingConflictForRecord(String recordId, {String? ownerKey}) {
    final resolvedOwner = ownerKey ?? _ownerKey;
    return _itemsByOwner
        .putIfAbsent(resolvedOwner, () => <ConflictItem>[])
        .any(
          (item) =>
              item.recordId == recordId &&
              item.status != ConflictStatus.resolved,
        );
  }

  ConflictItem? findById(String id) {
    for (final item in _items) {
      if (item.id == id) {
        return item;
      }
    }
    return null;
  }

  Future<void> recordDetectedConflict(ConflictItem conflict) async {
    final now = DateTime.now();
    await AppDatabase.instance.transaction((transaction) async {
      await _store.completeResolvingConflictForOutbox(
        transaction,
        ownerKey: conflict.ownerKey,
        outboxId: conflict.outboxId,
        resolvedAt: now,
      );
      await _store.markOutboxItemsConflicted(
        transaction,
        ownerKey: conflict.ownerKey,
        recordId: conflict.recordId,
        triedAt: now,
        message: '다른 기기에서 변경된 기록과 충돌했습니다.',
      );
      await _store.insertConflict(transaction, conflict: conflict);
    });
    await reloadOwner(conflict.ownerKey);
  }

  Future<void> markResolutionSucceeded({
    required String ownerKey,
    required String outboxId,
  }) async {
    await AppDatabase.instance.transaction((transaction) async {
      await _store.completeResolvingConflictForOutbox(
        transaction,
        ownerKey: ownerKey,
        outboxId: outboxId,
        resolvedAt: DateTime.now(),
      );
    });
    await reloadOwner(ownerKey);
  }

  Future<void> clearAll() async {
    final ownerKey = _ownerKey;
    await AppDatabase.instance.transaction((transaction) {
      return _store.deleteAllConflicts(transaction, ownerKey: ownerKey);
    });
    await reloadOwner(ownerKey);
  }

  @visibleForTesting
  void clearCacheOnlyForTesting() {
    _itemsByOwner.clear();
    notifyListeners();
  }
}
