import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/fishing_record.dart';

class FishingRecordMemoryRepository extends ChangeNotifier {
  FishingRecordMemoryRepository._();

  static final FishingRecordMemoryRepository instance =
      FishingRecordMemoryRepository._();

  static const String _storageKey = 'fishing_records';

  final List<FishingRecord> _records = [];

  Future<void> loadRecords() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_storageKey);

    if (jsonString == null || jsonString.isEmpty) {
      if (_records.isNotEmpty) {
        _records.clear();
        notifyListeners();
      }

      return;
    }

    final jsonList = jsonDecode(jsonString) as List;

    _records
      ..clear()
      ..addAll(
        jsonList.map(
          (item) =>
              FishingRecord.fromJson(Map<String, dynamic>.from(item as Map)),
        ),
      );

    notifyListeners();
  }

  Future<void> _saveRecords() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = jsonEncode(
      _records.map((record) => record.toJson()).toList(),
    );

    await prefs.setString(_storageKey, jsonString);
  }

  List<FishingRecord> getAllRecords() {
    return List.unmodifiable(_records);
  }

  List<FishingRecord> getRecordsByDate(DateTime date) {
    return _records.where((record) => record.overlapsDate(date)).toList();
  }

  Future<void> addRecord(FishingRecord record) async {
    _records.add(record);
    await _saveRecords();
    notifyListeners();
  }

  Future<void> deleteRecord(String recordId) async {
    final previousLength = _records.length;

    _records.removeWhere((record) => record.id == recordId);
    await _saveRecords();

    if (_records.length != previousLength) {
      notifyListeners();
    }
  }

  Future<void> clear() async {
    if (_records.isEmpty) {
      await _saveRecords();
      return;
    }

    _records.clear();
    await _saveRecords();
    notifyListeners();
  }

  @visibleForTesting
  void clearMemoryOnlyForTesting() {
    _records.clear();
    notifyListeners();
  }
}
