import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../local/app_database.dart';
import '../local/local_data_migration_service.dart';
import '../local/local_data_store.dart';
import '../models/fishing_record.dart';
import 'auth_session_repository.dart';

class FishingRecordRepository extends ChangeNotifier {
  FishingRecordRepository._();

  static final FishingRecordRepository instance = FishingRecordRepository._();

  static const String _legacyStorageKey = 'fishing_records';

  final LocalDataStore _store = LocalDataStore.instance;
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
    await LocalDataMigrationService.instance.migrateIfNeeded();
    final ownerKey = _ownerKey;
    _recordsByOwner[ownerKey] = await _store.readRecordsForOwner(ownerKey);
    await _loadQuarantinedLegacyRecords();
    notifyListeners();
  }

  Future<void> reloadOwner(String ownerKey) async {
    _recordsByOwner[ownerKey] = await _store.readRecordsForOwner(ownerKey);
    notifyListeners();
  }

  Future<void> _loadQuarantinedLegacyRecords() async {
    final preferences = await SharedPreferences.getInstance();
    final legacyJson = preferences.getString(_legacyStorageKey);
    _hasQuarantinedLegacyData =
        legacyJson != null && legacyJson.trim().isNotEmpty;
    _quarantinedLegacyRecords = _hasQuarantinedLegacyData
        ? _decodeLegacyRecords(legacyJson!)
        : <FishingRecord>[];
  }

  List<FishingRecord>? _decodeLegacyRecords(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is! List) {
        return null;
      }

      return decoded
          .map(
            (item) =>
                FishingRecord.fromJson(Map<String, dynamic>.from(item as Map)),
          )
          .toList();
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  List<FishingRecord> getAllRecords() => List.unmodifiable(_records);

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
    final ownerKey = _ownerKey;
    await AppDatabase.instance.transaction((transaction) async {
      await _store.insertRecord(
        transaction,
        ownerKey: ownerKey,
        record: record,
      );
    });
    await reloadOwner(ownerKey);
  }

  Future<void> updateRecord(FishingRecord record) async {
    if (getRecordById(record.id) == null) {
      throw StateError('Record not found: ${record.id}');
    }

    final ownerKey = _ownerKey;
    await AppDatabase.instance.transaction((transaction) async {
      await _store.insertRecord(
        transaction,
        ownerKey: ownerKey,
        record: record,
        replace: true,
      );
    });
    await reloadOwner(ownerKey);
  }

  Future<void> deleteRecord(String recordId) async {
    if (getRecordById(recordId) == null) {
      return;
    }

    final ownerKey = _ownerKey;
    await AppDatabase.instance.transaction((transaction) async {
      await _store.deleteRecord(
        transaction,
        ownerKey: ownerKey,
        recordId: recordId,
      );
    });
    await reloadOwner(ownerKey);
  }

  Future<void> clear() async {
    final ownerKey = _ownerKey;
    await AppDatabase.instance.transaction((transaction) async {
      await _store.deleteAllRecords(transaction, ownerKey: ownerKey);
    });
    await reloadOwner(ownerKey);
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

    final ownerKey = _ownerKey;
    final existingIds = _records.map((record) => record.id).toSet();
    final importedRecords = legacyRecords
        .where((record) => existingIds.add(record.id))
        .toList();

    await AppDatabase.instance.transaction((transaction) async {
      for (final record in importedRecords) {
        await _store.insertRecord(
          transaction,
          ownerKey: ownerKey,
          record: record,
        );
      }
    });
    await reloadOwner(ownerKey);

    final preferences = await SharedPreferences.getInstance();
    final removed = await preferences.remove(_legacyStorageKey);
    if (!removed) {
      throw StateError('Failed to finish the legacy record import.');
    }

    _hasQuarantinedLegacyData = false;
    _quarantinedLegacyRecords = <FishingRecord>[];
    notifyListeners();
    return importedRecords.length;
  }

  @visibleForTesting
  void clearCacheOnlyForTesting() {
    _recordsByOwner.clear();
    _quarantinedLegacyRecords = null;
    _hasQuarantinedLegacyData = false;
    notifyListeners();
  }
}
