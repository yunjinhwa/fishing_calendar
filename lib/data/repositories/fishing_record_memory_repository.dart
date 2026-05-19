import '../models/fishing_record.dart';

class FishingRecordMemoryRepository {
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
  }

  void clear() {
    _records.clear();
  }

  void deleteRecord(String recordId) {
    _records.removeWhere((record) => record.id == recordId);
  }
}