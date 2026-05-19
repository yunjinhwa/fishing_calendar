import '../models/outbox_item.dart';

class OutboxMemoryRepository {
  OutboxMemoryRepository._();

  static final OutboxMemoryRepository instance = OutboxMemoryRepository._();

  final List<OutboxItem> _items = [];

  List<OutboxItem> getAllItems() {
    return List.unmodifiable(_items);
  }

  int get pendingCount {
    return _items
        .where((item) =>
            item.status == OutboxStatus.pending ||
            item.status == OutboxStatus.failed)
        .length;
  }

  void addItem(OutboxItem item) {
    _items.add(item);
  }

  void updateItemStatus({
    required String itemId,
    required OutboxStatus status,
    String? errorMessage,
  }) {
    final index = _items.indexWhere((item) => item.id == itemId);

    if (index == -1) {
      return;
    }

    _items[index] = _items[index].copyWith(
      status: status,
      lastTriedAt: DateTime.now(),
      errorMessage: errorMessage,
    );
  }

  void retryItem(String itemId) {
    updateItemStatus(
      itemId: itemId,
      status: OutboxStatus.pending,
      errorMessage: null,
    );
  }

  void clearSucceeded() {
    _items.removeWhere((item) => item.status == OutboxStatus.succeeded);
  }

  void clearAll() {
    _items.clear();
  }

  void seedMockItemsIfEmpty() {
    if (_items.isNotEmpty) {
      return;
    }

    final now = DateTime.now();

    _items.addAll([
      OutboxItem(
        id: 'outbox-${now.microsecondsSinceEpoch}-1',
        recordId: 'mock-record-1',
        operationType: OutboxOperationType.create,
        status: OutboxStatus.pending,
        createdAt: now.subtract(const Duration(minutes: 20)),
      ),
      OutboxItem(
        id: 'outbox-${now.microsecondsSinceEpoch}-2',
        recordId: 'mock-record-2',
        operationType: OutboxOperationType.update,
        status: OutboxStatus.failed,
        createdAt: now.subtract(const Duration(hours: 1)),
        lastTriedAt: now.subtract(const Duration(minutes: 10)),
        errorMessage: '네트워크 연결 실패',
      ),
    ]);
  }
}