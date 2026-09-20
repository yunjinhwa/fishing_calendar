import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/outbox_item.dart';
import 'auth_session_repository.dart';

class OutboxMemoryRepository {
  OutboxMemoryRepository._();

  static final OutboxMemoryRepository instance = OutboxMemoryRepository._();

  static const String _storageKey = 'outbox_items_by_account_v1';

  final Map<String, List<OutboxItem>> _itemsByOwner = {};

  String get _ownerKey => AuthSessionRepository.instance.dataOwnerKey;

  List<OutboxItem> get _items =>
      _itemsByOwner.putIfAbsent(_ownerKey, () => <OutboxItem>[]);

  Future<void> loadItems() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_storageKey);

    _itemsByOwner.clear();
    if (jsonString == null || jsonString.isEmpty) {
      return;
    }

    try {
      final decoded = jsonDecode(jsonString);
      if (decoded is! Map) {
        return;
      }

      for (final entry in decoded.entries) {
        if (entry.value is! List) {
          continue;
        }

        final items = <OutboxItem>[];
        for (final value in entry.value as List) {
          try {
            items.add(
              OutboxItem.fromJson(Map<String, dynamic>.from(value as Map)),
            );
          } on FormatException {
            continue;
          } on ArgumentError {
            continue;
          } on TypeError {
            continue;
          }
        }
        _itemsByOwner[entry.key.toString()] = items;
      }
    } on FormatException {
      return;
    }
  }

  Future<void> _saveItems() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = jsonEncode(
      _itemsByOwner.map(
        (owner, items) =>
            MapEntry(owner, items.map((item) => item.toJson()).toList()),
      ),
    );
    final saved = await prefs.setString(_storageKey, jsonString);
    if (!saved) {
      throw StateError('Failed to persist outbox items.');
    }
  }

  List<OutboxItem> getAllItems() {
    return List.unmodifiable(_items);
  }

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
    _items.add(item);
    try {
      await _saveItems();
    } catch (_) {
      _items.removeLast();
      rethrow;
    }
  }

  Future<void> replaceItem(OutboxItem item) async {
    final index = _items.indexWhere((savedItem) => savedItem.id == item.id);
    if (index == -1) {
      throw StateError('Outbox item not found: ${item.id}');
    }

    final previousItem = _items[index];
    _items[index] = item;
    try {
      await _saveItems();
    } catch (_) {
      _items[index] = previousItem;
      rethrow;
    }
  }

  Future<void> updateItemStatus({
    required String itemId,
    required OutboxStatus status,
    String? errorMessage,
  }) async {
    final index = _items.indexWhere((item) => item.id == itemId);

    if (index == -1) {
      return;
    }

    final previousItem = _items[index];
    _items[index] = previousItem.copyWith(
      status: status,
      lastTriedAt: DateTime.now(),
      errorMessage: errorMessage,
      clearErrorMessage: errorMessage == null && status != OutboxStatus.failed,
    );
    try {
      await _saveItems();
    } catch (_) {
      _items[index] = previousItem;
      rethrow;
    }
  }

  Future<void> retryItem(String itemId) async {
    final index = _items.indexWhere((item) => item.id == itemId);
    if (index == -1) {
      return;
    }

    final item = _items[index];
    _items[index] = item.copyWith(
      status: OutboxStatus.pending,
      lastTriedAt: DateTime.now(),
      retryCount: item.retryCount + 1,
      clearErrorMessage: true,
    );
    try {
      await _saveItems();
    } catch (_) {
      _items[index] = item;
      rethrow;
    }
  }

  Future<void> clearSucceeded({bool includeMigration = true}) async {
    final previousItems = List<OutboxItem>.of(_items);
    _items.removeWhere(
      (item) =>
          item.status == OutboxStatus.succeeded &&
          (includeMigration || !item.isMigration),
    );
    try {
      await _saveItems();
    } catch (_) {
      _items
        ..clear()
        ..addAll(previousItems);
      rethrow;
    }
  }

  Future<void> removeObsoleteMigrationItems(Set<String> recordIds) async {
    final previousItems = List<OutboxItem>.of(_items);
    _items.removeWhere(
      (item) =>
          item.isMigration &&
          item.operationType == OutboxOperationType.create &&
          !recordIds.contains(item.recordId),
    );

    if (_items.length == previousItems.length) {
      return;
    }

    try {
      await _saveItems();
    } catch (_) {
      _items
        ..clear()
        ..addAll(previousItems);
      rethrow;
    }
  }

  Future<void> clearAll() async {
    final previousItems = List<OutboxItem>.of(_items);
    _items.clear();
    try {
      await _saveItems();
    } catch (_) {
      _items.addAll(previousItems);
      rethrow;
    }
  }

  @visibleForTesting
  void clearMemoryOnlyForTesting() {
    _itemsByOwner.clear();
  }
}
