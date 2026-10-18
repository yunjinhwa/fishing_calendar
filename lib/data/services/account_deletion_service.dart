import 'dart:convert';
import 'dart:developer' as developer;

import 'package:shared_preferences/shared_preferences.dart';

import '../local/app_database.dart';
import '../local/data_owner_key.dart';
import '../local/local_data_migration_service.dart';
import '../local/local_data_store.dart';
import '../local/local_identity_migration_service.dart';
import '../photos/record_photo_file_store.dart';
import '../repositories/auth_session_repository.dart';
import '../repositories/conflict_repository.dart';
import '../repositories/fishing_record_repository.dart';
import '../repositories/outbox_repository.dart';

class AccountDeletionService {
  AccountDeletionService({
    AuthSessionRepository? authSession,
    LocalDataStore? localDataStore,
    RecordPhotoFileStoreBackend? photoFileStore,
    FishingRecordRepository? recordRepository,
    OutboxRepository? outboxRepository,
    ConflictRepository? conflictRepository,
  }) : _authSession = authSession ?? AuthSessionRepository.instance,
       _localDataStore = localDataStore ?? LocalDataStore.instance,
       _photoFileStore = photoFileStore ?? RecordPhotoFileStore(),
       _recordRepository = recordRepository ?? FishingRecordRepository.instance,
       _outboxRepository = outboxRepository ?? OutboxRepository.instance,
       _conflictRepository = conflictRepository ?? ConflictRepository.instance;

  static final AccountDeletionService instance = AccountDeletionService();

  static const String _pendingLocalCleanupKey =
      'account_deletion_local_cleanup_v1';
  static const String _syncMarkerPrefix = 'firestore_record_sync_v2';

  final AuthSessionRepository _authSession;
  final LocalDataStore _localDataStore;
  final RecordPhotoFileStoreBackend _photoFileStore;
  final FishingRecordRepository _recordRepository;
  final OutboxRepository _outboxRepository;
  final ConflictRepository _conflictRepository;
  final Map<String, Future<void>> _remoteCleanupTasks =
      <String, Future<void>>{};

  Future<void> deleteCurrentAccount(String password) async {
    final currentUid = _authSession.memberId;
    final remoteCleanup = currentUid == null
        ? null
        : _remoteCleanupTasks[currentUid];
    if (remoteCleanup != null) {
      await remoteCleanup;
    }
    await _authSession.deleteCurrentAccount(
      password: password,
      prepareLocalDataDeletion: (ownerKey, email, firebaseUid) async {
        final pending = _PendingLocalCleanup(
          ownerKey: ownerKey,
          email: email,
          firebaseUid: firebaseUid,
        );
        await _writePendingCleanup(pending);
      },
      purgeLocalData: (ownerKey, email, firebaseUid) async {
        final pending = _PendingLocalCleanup(
          ownerKey: ownerKey,
          email: email,
          firebaseUid: firebaseUid,
        );
        await _purgeLocalData(pending);
      },
    );
    await _clearPendingCleanup();
  }

  Future<void> handleRemoteAccountDeletion({
    required String ownerKey,
    required String email,
    required String firebaseUid,
  }) {
    final existing = _remoteCleanupTasks[firebaseUid];
    if (existing != null) {
      return existing;
    }
    final task = _performRemoteAccountDeletionCleanup(
      ownerKey: ownerKey,
      email: email,
      firebaseUid: firebaseUid,
    );
    _remoteCleanupTasks[firebaseUid] = task;
    return task;
  }

  Future<void> _performRemoteAccountDeletionCleanup({
    required String ownerKey,
    required String email,
    required String firebaseUid,
  }) async {
    final pending = _PendingLocalCleanup(
      ownerKey: ownerKey,
      email: email,
      firebaseUid: firebaseUid,
    );
    try {
      await _writePendingCleanup(pending);
      await _authSession.clearDeletedAccountLocalState(
        email: email,
        firebaseUid: firebaseUid,
      );
      await _purgeLocalData(pending);
      await _clearPendingCleanup();
    } on Object catch (error, stackTrace) {
      // Once written, the durable marker lets startup retry every idempotent
      // cleanup step. The server tombstone independently keeps access locked.
      developer.log(
        'Deferred remote account-deletion cleanup until the next launch.',
        name: 'AccountDeletionService',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _remoteCleanupTasks.remove(firebaseUid);
    }
  }

  Future<void> resumePendingLocalCleanup() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_pendingLocalCleanupKey);
    if (raw == null) {
      return;
    }
    final pending = _PendingLocalCleanup.tryParse(raw);
    if (pending == null) {
      await prefs.remove(_pendingLocalCleanupKey);
      developer.log(
        'Discarded a malformed pending account-deletion cleanup marker.',
        name: 'AccountDeletionService',
      );
      return;
    }
    try {
      await _authSession.clearDeletedAccountLocalState(
        email: pending.email,
        firebaseUid: pending.firebaseUid,
      );
      await _purgeLocalData(pending);
      await _clearPendingCleanup();
    } on Object catch (error, stackTrace) {
      // Startup must remain available. The durable marker is intentionally kept
      // so the idempotent cleanup can be attempted again on the next launch.
      developer.log(
        'Deferred pending account-deletion cleanup until the next launch.',
        name: 'AccountDeletionService',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _writePendingCleanup(_PendingLocalCleanup pending) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setString(
      _pendingLocalCleanupKey,
      jsonEncode(pending.toJson()),
    );
    if (!saved) {
      throw StateError('Failed to persist pending account cleanup.');
    }
  }

  Future<void> _clearPendingCleanup() async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.remove(_pendingLocalCleanupKey)) {
      throw StateError('Failed to clear pending account cleanup.');
    }
  }

  Future<void> _purgeLocalData(_PendingLocalCleanup pending) async {
    final legacyOwnerKey = DataOwnerKey.legacyEmail(pending.email);
    final ownerKeys = <String>{pending.ownerKey, legacyOwnerKey};

    for (final ownerKey in ownerKeys) {
      await _photoFileStore.deleteOwnerFiles(ownerKey);
    }

    await AppDatabase.instance.transaction((transaction) async {
      for (final ownerKey in ownerKeys) {
        await _localDataStore.deleteOwnerData(transaction, ownerKey: ownerKey);
      }
      final firebaseUid = pending.firebaseUid;
      if (firebaseUid != null) {
        await _localDataStore.deleteMetadata(
          transaction,
          key: '$_syncMarkerPrefix:$firebaseUid',
        );
        await LocalIdentityMigrationService.instance.deleteAccountClaim(
          transaction,
          authenticatedEmail: pending.email,
        );
      }
    });

    await _removeOwnerFromLegacyPreferences(ownerKeys);
    for (final ownerKey in ownerKeys) {
      await _recordRepository.reloadOwner(ownerKey);
      await _outboxRepository.reloadOwner(ownerKey);
      await _conflictRepository.reloadOwner(ownerKey);
    }
  }

  Future<void> _removeOwnerFromLegacyPreferences(Set<String> ownerKeys) async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in <String>[
      LocalDataMigrationService.scopedRecordsPreferencesKey,
      LocalDataMigrationService.scopedOutboxPreferencesKey,
      LocalDataMigrationService.recordsMigrationBackupKey,
      LocalDataMigrationService.outboxMigrationBackupKey,
    ]) {
      final raw = prefs.getString(key);
      if (raw == null) {
        continue;
      }
      dynamic decoded;
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        continue;
      }
      if (decoded is! Map) {
        continue;
      }
      final values = Map<String, dynamic>.from(decoded);
      var changed = false;
      for (final ownerKey in ownerKeys) {
        if (values.containsKey(ownerKey)) {
          values.remove(ownerKey);
          changed = true;
        }
      }
      if (!changed) {
        continue;
      }
      final success = values.isEmpty
          ? await prefs.remove(key)
          : await prefs.setString(key, jsonEncode(values));
      if (!success) {
        throw StateError('Failed to clear deleted account migration data.');
      }
    }
  }
}

class _PendingLocalCleanup {
  final String ownerKey;
  final String email;
  final String? firebaseUid;

  const _PendingLocalCleanup({
    required this.ownerKey,
    required this.email,
    required this.firebaseUid,
  });

  Map<String, Object> toJson() => <String, Object>{
    'version': 1,
    'ownerKey': ownerKey,
    'email': email,
    'firebaseUid': ?firebaseUid,
  };

  static _PendingLocalCleanup? tryParse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return null;
      }
      final map = Map<String, dynamic>.from(decoded);
      final ownerKey = map['ownerKey'];
      final email = map['email'];
      final firebaseUid = map['firebaseUid'];
      if (map['version'] != 1 ||
          ownerKey is! String ||
          ownerKey.isEmpty ||
          email is! String ||
          email.isEmpty ||
          (firebaseUid != null &&
              (firebaseUid is! String || firebaseUid.isEmpty))) {
        return null;
      }
      return _PendingLocalCleanup(
        ownerKey: ownerKey,
        email: email,
        firebaseUid: firebaseUid as String?,
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }
}
