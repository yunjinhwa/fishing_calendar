import '../models/conflict_item.dart';

class ConflictMemoryRepository {
  ConflictMemoryRepository._();

  static final ConflictMemoryRepository instance = ConflictMemoryRepository._();

  final List<ConflictItem> _items = [];

  List<ConflictItem> getAllItems() {
    return List.unmodifiable(_items);
  }

  List<ConflictItem> getUnresolvedItems() {
    return _items
        .where((item) => item.status == ConflictStatus.unresolved)
        .toList();
  }

  int get unresolvedCount {
    return _items
        .where((item) => item.status == ConflictStatus.unresolved)
        .length;
  }

  ConflictItem? findById(String id) {
    for (final item in _items) {
      if (item.id == id) {
        return item;
      }
    }

    return null;
  }

  void resolveConflict({
    required String conflictId,
    required ConflictResolutionType resolutionType,
  }) {
    final index = _items.indexWhere((item) => item.id == conflictId);

    if (index == -1) {
      return;
    }

    _items[index] = _items[index].copyWith(
      status: ConflictStatus.resolved,
      resolutionType: resolutionType,
    );
  }

  void clearAll() {
    _items.clear();
  }
}
