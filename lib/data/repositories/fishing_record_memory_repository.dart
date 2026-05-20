import 'package:flutter/foundation.dart';

import '../models/fishing_record.dart';

class FishingRecordMemoryRepository extends ChangeNotifier {
  FishingRecordMemoryRepository._();

  static final FishingRecordMemoryRepository instance =
      FishingRecordMemoryRepository._();

  final List<FishingRecord> _records = [];

  List<FishingRecord> getAllRecords() {
    return List.unmodifiable(_records);
  }

  List<FishingRecord> getRecordsByDate(DateTime date) {
    return _records.where((record) => record.overlapsDate(date)).toList();
  }

  void addRecord(FishingRecord record) {
    _records.add(record);
    notifyListeners();
  }

  void clear() {
    if (_records.isEmpty) {
      return;
    }

    _records.clear();
    notifyListeners();
  }

  void deleteRecord(String recordId) {
    final previousLength = _records.length;
    _records.removeWhere((record) => record.id == recordId);

    if (_records.length != previousLength) {
      notifyListeners();
    }
  }
}
