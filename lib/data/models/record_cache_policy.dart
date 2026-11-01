import 'fishing_record.dart';

/// Runtime retention only; eviction never represents a user's record deletion.
class RecordCachePolicy {
  RecordCachePolicy({DateTime Function()? now}) : _now = now ?? DateTime.now;

  static final instance = RecordCachePolicy();

  DateTime Function() _now;
  bool enabled = false;
  int revision = 0;
  void Function()? onPinsChanged;
  final Map<Object, (String, String)> _records = {};
  final Map<Object, (String, DateTime)> _months = {};
  final Map<Object, String> _histories = {};

  DateTime get oldestDate {
    final today = _now().toLocal();
    return DateTime(today.year, today.month, today.day - 30);
  }

  bool needsMonthQuery(DateTime month) =>
      DateTime(month.year, month.month).isBefore(oldestDate);

  bool keepsRecord(String ownerKey, FishingRecord record) {
    if (!enabled ||
        record.endAt.isAfter(oldestDate) ||
        holdsHistory(ownerKey)) {
      return true;
    }
    if (_records.values.any(
      (pin) => pin.$1 == ownerKey && pin.$2 == record.id,
    )) {
      return true;
    }
    return _months.values.any((pin) {
      final next = DateTime(pin.$2.year, pin.$2.month + 1);
      return pin.$1 == ownerKey &&
          record.startAt.isBefore(next) &&
          record.endAt.isAfter(pin.$2);
    });
  }

  bool holdsMonth(String ownerKey, DateTime month) => _months.values.any(
    (pin) => pin.$1 == ownerKey && pin.$2 == DateTime(month.year, month.month),
  );

  void Function() holdRecord(String ownerKey, String recordId) {
    final token = Object();
    _records[token] = (ownerKey, recordId);
    return _lease(() => _records.remove(token));
  }

  bool holdsHistory(String ownerKey) => _histories.containsValue(ownerKey);

  void Function() holdHistory(String ownerKey) {
    final token = Object();
    _histories[token] = ownerKey;
    return _lease(() => _histories.remove(token));
  }

  void Function() holdMonth(String ownerKey, DateTime month) {
    final token = Object();
    _months[token] = (ownerKey, DateTime(month.year, month.month));
    return _lease(() => _months.remove(token));
  }

  void Function() _lease(void Function() remove) {
    revision++;
    onPinsChanged?.call();
    var released = false;
    return () {
      if (released) return;
      released = true;
      remove();
      revision++;
      onPinsChanged?.call();
    };
  }

  void reset({DateTime Function()? now}) {
    enabled = false;
    _now = now ?? DateTime.now;
    onPinsChanged = null;
    _records.clear();
    _months.clear();
    _histories.clear();
    revision++;
  }
}
