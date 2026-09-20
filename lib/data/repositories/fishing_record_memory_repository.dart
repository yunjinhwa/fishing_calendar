import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/fishing_record.dart';
import 'auth_session_repository.dart';

class FishingRecordMemoryRepository extends ChangeNotifier {
  FishingRecordMemoryRepository._();

  static final FishingRecordMemoryRepository instance =
      FishingRecordMemoryRepository._();

  static const String _legacyStorageKey = 'fishing_records';
  static const String _storageKey = 'fishing_records_by_account_v1';

  final Map<String, List<FishingRecord>> _recordsByOwner = {};
  List<FishingRecord>? _quarantinedLegacyRecords;
  bool _hasQuarantinedLegacyData = false;

  String get _ownerKey => AuthSessionRepository.instance.dataOwnerKey;

  List<FishingRecord> get _records =>
      _recordsByOwner.putIfAbsent(_ownerKey, () => <FishingRecord>[]);

  bool get hasQuarantinedLegacyData => _hasQuarantinedLegacyData;
  bool get canImportQuarantinedLegacyRecords =>
      _hasQuarantinedLegacyData && _quarantinedLegacyRecords != null;
  int? get quarantinedLegacyRecordCount => _quarantinedLegacyRecords?.length;

  Future<void> loadRecords() async {
    final prefs = await SharedPreferences.getInstance();
    final scopedJson = prefs.getString(_storageKey);

    _recordsByOwner.clear();

    if (scopedJson != null && scopedJson.isNotEmpty) {
      _recordsByOwner.addAll(_decodeScopedRecords(scopedJson));
    }

    final legacyJson = prefs.getString(_legacyStorageKey);
    _hasQuarantinedLegacyData =
        legacyJson != null && legacyJson.trim().isNotEmpty;
    _quarantinedLegacyRecords = _hasQuarantinedLegacyData
        ? _decodeLegacyRecords(legacyJson!)
        : <FishingRecord>[];

    notifyListeners();
  }

  Future<void> _saveRecords() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = jsonEncode(
      _recordsByOwner.map(
        (owner, records) =>
            MapEntry(owner, records.map((record) => record.toJson()).toList()),
      ),
    );

    final saved = await prefs.setString(_storageKey, jsonString);
    if (!saved) {
      throw StateError('Failed to persist fishing records.');
    }
  }

  Map<String, List<FishingRecord>> _decodeScopedRecords(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map) {
        return <String, List<FishingRecord>>{};
      }

      final recordsByOwner = <String, List<FishingRecord>>{};
      for (final entry in decoded.entries) {
        if (entry.value is! List) {
          continue;
        }

        final records = <FishingRecord>[];
        for (final item in entry.value as List) {
          try {
            records.add(
              FishingRecord.fromJson(Map<String, dynamic>.from(item as Map)),
            );
          } on FormatException {
            continue;
          } on TypeError {
            continue;
          }
        }
        recordsByOwner[entry.key.toString()] = records;
      }
      return recordsByOwner;
    } on FormatException {
      return <String, List<FishingRecord>>{};
    } on TypeError {
      return <String, List<FishingRecord>>{};
    }
  }

  List<FishingRecord>? _decodeLegacyRecords(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is! List) {
        return null;
      }

      final records = <FishingRecord>[];
      for (final item in decoded) {
        records.add(
          FishingRecord.fromJson(Map<String, dynamic>.from(item as Map)),
        );
      }
      return records;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  List<FishingRecord> getAllRecords() {
    return List.unmodifiable(_records);
  }

  FishingRecord? getRecordById(String recordId) {
    for (final record in _records) {
      if (record.id == recordId) {
        return record;
      }
    }

    return null;
  }

  List<FishingRecord> getRecordsByDate(DateTime date) {
    return _records.where((record) => record.overlapsDate(date)).toList();
  }

  Future<void> addRecord(FishingRecord record) async {
    _records.add(record);
    try {
      await _saveRecords();
    } catch (_) {
      _records.removeLast();
      rethrow;
    }
    notifyListeners();
  }

  Future<void> updateRecord(FishingRecord record) async {
    final index = _records.indexWhere(
      (savedRecord) => savedRecord.id == record.id,
    );

    if (index == -1) {
      throw StateError('Record not found: ${record.id}');
    }

    final previousRecord = _records[index];
    _records[index] = record;
    try {
      await _saveRecords();
    } catch (_) {
      _records[index] = previousRecord;
      rethrow;
    }
    notifyListeners();
  }

  Future<void> deleteRecord(String recordId) async {
    final index = _records.indexWhere((record) => record.id == recordId);
    if (index == -1) {
      return;
    }

    final removedRecord = _records.removeAt(index);
    try {
      await _saveRecords();
    } catch (_) {
      _records.insert(index, removedRecord);
      rethrow;
    }
    notifyListeners();
  }

  Future<void> clear() async {
    if (_records.isEmpty) {
      await _saveRecords();
      return;
    }

    final previousRecords = List<FishingRecord>.of(_records);
    _records.clear();
    try {
      await _saveRecords();
    } catch (_) {
      _records.addAll(previousRecords);
      rethrow;
    }
    notifyListeners();
  }

  Future<int> importQuarantinedLegacyRecords() async {
    if (!AuthSessionRepository.instance.isMember) {
      throw StateError('Only a signed-in member can import legacy records.');
    }

    if (!_hasQuarantinedLegacyData) {
      return 0;
    }

    final legacyRecords = _quarantinedLegacyRecords;
    if (legacyRecords == null) {
      throw StateError('Legacy records could not be decoded safely.');
    }

    final existingIds = _records.map((record) => record.id).toSet();
    final importedRecords = legacyRecords
        .where((record) => existingIds.add(record.id))
        .toList();
    _records.addAll(importedRecords);

    try {
      await _saveRecords();
    } catch (_) {
      _records.removeWhere(
        (record) => importedRecords.any((item) => item.id == record.id),
      );
      rethrow;
    }

    final prefs = await SharedPreferences.getInstance();
    final removed = await prefs.remove(_legacyStorageKey);
    if (!removed) {
      throw StateError('Failed to finish the legacy record import.');
    }

    _hasQuarantinedLegacyData = false;
    _quarantinedLegacyRecords = <FishingRecord>[];
    notifyListeners();
    return importedRecords.length;
  }

  @visibleForTesting
  void clearMemoryOnlyForTesting() {
    _recordsByOwner.clear();
    _quarantinedLegacyRecords = null;
    _hasQuarantinedLegacyData = false;
    notifyListeners();
  }
}
