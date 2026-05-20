import '../models/conflict_item.dart';

class ConflictMemoryRepository {
  ConflictMemoryRepository._();

  static final ConflictMemoryRepository instance =
      ConflictMemoryRepository._();

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

  void seedMockItemsIfEmpty() {
    if (_items.isNotEmpty) {
      return;
    }

    final now = DateTime.now();

    _items.addAll([
      ConflictItem(
        id: 'conflict-${now.microsecondsSinceEpoch}-1',
        recordTitle: '루어낚시 · 광어',
        location: '부산 영도구 동삼동',
        occurredAt: now.subtract(const Duration(days: 1, hours: 2)),
        status: ConflictStatus.unresolved,
        fields: const [
          ConflictField(
            fieldName: '낚시 시간',
            mineValue: '05:30 ~ 09:20',
            theirsValue: '05:30 ~ 10:00',
          ),
          ConflictField(
            fieldName: '기온',
            mineValue: '18℃',
            theirsValue: '17℃',
          ),
          ConflictField(
            fieldName: '수온',
            mineValue: '16.2℃',
            theirsValue: '16.0℃',
          ),
          ConflictField(
            fieldName: '메모',
            mineValue: '입질 좋았음',
            theirsValue: '아침 입질 활발',
          ),
        ],
      ),
      ConflictItem(
        id: 'conflict-${now.microsecondsSinceEpoch}-2',
        recordTitle: '선상낚시 · 우럭',
        location: '통영 욕지도',
        occurredAt: now.subtract(const Duration(days: 3)),
        status: ConflictStatus.unresolved,
        fields: const [
          ConflictField(
            fieldName: '낚시 시간',
            mineValue: '19:00 ~ 23:40',
            theirsValue: '18:30 ~ 23:10',
          ),
          ConflictField(
            fieldName: '메모',
            mineValue: '바람이 강했음',
            theirsValue: '초저녁 입질 집중',
          ),
        ],
      ),
    ]);
  }

  void clearAll() {
    _items.clear();
  }
}