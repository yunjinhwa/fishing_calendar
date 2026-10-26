import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../local/app_database.dart';
import '../photos/record_photo_file_store.dart';

/// Collects only managed copies which have no durable or open-editor reference.
///
/// File writes and sweeps share a queue. The database transaction remains open
/// during a sweep so a record save cannot race the reference snapshot.
class RecordPhotoCleanupService {
  RecordPhotoCleanupService({
    RecordPhotoFileStore? fileStore,
    AppDatabase? database,
    bool automaticCleanup = true,
  }) : _fileStore = fileStore ?? RecordPhotoFileStore(),
       _database = database ?? AppDatabase.instance,
       _automaticCleanup = automaticCleanup;

  static final instance = RecordPhotoCleanupService(automaticCleanup: false);

  RecordPhotoFileStore _fileStore;
  final AppDatabase _database;
  bool _automaticCleanup;
  final Map<Object, _DraftReferences> _drafts = {};
  final Set<String> _requestedOwners = {};
  Future<void> _queue = Future<void>.value();
  int _pendingOperations = 0;
  Future<void>? _requestDrain;

  /// Background failures never turn an already committed save into a failure.
  Object? lastError;

  void enableAutomaticCleanup() {
    _automaticCleanup = true;
  }

  RecordPhotoDraftLease createDraft({
    required String ownerKey,
    Iterable<String> paths = const [],
  }) {
    _validateOwner(ownerKey);
    final token = Object();
    _drafts[token] = _DraftReferences(ownerKey, _normalizePaths(paths));
    return RecordPhotoDraftLease._(this, token);
  }

  /// Explicit collection fails closed if any reference cannot be read safely.
  Future<int> collectOwner(String ownerKey) {
    _validateOwner(ownerKey);
    return _serialize(() => _collectOwner(ownerKey));
  }

  /// Coalesces repeated notifications and retries on the next request on error.
  void requestCleanup(String ownerKey) {
    _validateOwner(ownerKey);
    _requestedOwners.add(ownerKey);
    _requestDrain ??= Future<void>.microtask(() async {
      try {
        while (_requestedOwners.isNotEmpty) {
          final owner = _requestedOwners.first;
          _requestedOwners.remove(owner);
          try {
            await collectOwner(owner);
            lastError = null;
          } on Object catch (error) {
            lastError = error;
          }
        }
      } finally {
        _requestDrain = null;
      }
    });
  }

  Future<void> flushPending() async {
    while (true) {
      final drain = _requestDrain;
      if (drain != null) await drain;
      // An idle tail may belong to a disposed FakeAsync zone in widget tests.
      if (_pendingOperations > 0) await _queue;
      if (_requestDrain == null && _pendingOperations == 0) return;
    }
  }

  Future<int> _collectOwner(String ownerKey) {
    return _database.transaction((transaction) async {
      final retained = await _readReferences(transaction);
      return _fileStore.deleteUnreferencedFiles(
        ownerId: ownerKey,
        retainedPaths: retained,
        // Drafts can change while the backend awaits directory/file I/O.
        isProtected: (path) {
          final normalized = _normalizePath(path);
          return _drafts.values.any(
            (draft) => draft.paths.contains(normalized),
          );
        },
      );
    });
  }

  Future<Set<String>> _readReferences(DatabaseExecutor executor) async {
    final retained = <String>{};
    // Unscoped pre-account records remain quarantined until the user imports
    // them. They are not in SQLite yet and must retain their managed copies.
    final preferences = await SharedPreferences.getInstance();
    final legacyJson = preferences.getString('fishing_records');
    if (legacyJson != null && legacyJson.trim().isNotEmpty) {
      final legacyRecords = jsonDecode(legacyJson);
      if (legacyRecords is! List) {
        throw const FormatException(
          'Quarantined legacy records are not a list.',
        );
      }
      for (final record in legacyRecords) {
        _addDecodedPayloadPaths(retained, record);
      }
    }
    // Read every owner: imported legacy data may share a local file path.
    final photos = await executor.query(
      AppDatabase.recordPhotosTable,
      columns: const ['local_path'],
    );
    for (final photo in photos) {
      _addPath(retained, photo['local_path']);
    }

    final outbox = await executor.query(
      AppDatabase.outboxItemsTable,
      columns: const ['payload_json'],
      where: 'status != ?',
      whereArgs: const ['succeeded'],
    );
    for (final row in outbox) {
      _addPayloadPaths(retained, row['payload_json']);
    }

    final conflicts = await executor.query(
      AppDatabase.recordConflictsTable,
      columns: const ['local_payload_json', 'remote_payload_json'],
      where: 'status != ?',
      whereArgs: const ['resolved'],
    );
    for (final row in conflicts) {
      _addPayloadPaths(retained, row['local_payload_json']);
      _addPayloadPaths(retained, row['remote_payload_json']);
    }

    final localChanges = await executor.query(
      AppDatabase.localRecordChangesTable,
      columns: const ['payload_json'],
      where: 'operation_type != ?',
      whereArgs: const ['delete'],
    );
    for (final row in localChanges) {
      _addPayloadPaths(retained, row['payload_json']);
    }
    return retained;
  }

  void _addPayloadPaths(Set<String> retained, Object? encoded) {
    if (encoded == null) return;
    if (encoded is! String) {
      throw const FormatException('Photo reference payload is not JSON text.');
    }
    _addDecodedPayloadPaths(retained, jsonDecode(encoded));
  }

  void _addDecodedPayloadPaths(Set<String> retained, Object? payload) {
    if (payload is! Map<String, dynamic>) {
      throw const FormatException('Photo reference payload is not an object.');
    }
    final photos = payload['photos'];
    if (photos != null) {
      if (photos is! List) {
        throw const FormatException('Photo references are not a list.');
      }
      for (final photo in photos) {
        if (photo is! Map<String, dynamic>) {
          throw const FormatException('Photo reference is not an object.');
        }
        _addPath(retained, photo['localPath']);
      }
    }
    // Preserve both representations even when a legacy payload has both keys.
    final legacyPaths = payload['photoPaths'];
    if (legacyPaths != null) {
      if (legacyPaths is! List) {
        throw const FormatException('Legacy photo references are not a list.');
      }
      for (final path in legacyPaths) {
        if (path is! String) {
          throw const FormatException('Legacy photo path is not a string.');
        }
        _addPath(retained, path);
      }
    }
  }

  void _addPath(Set<String> retained, Object? path) {
    if (path == null) return;
    if (path is! String) {
      throw const FormatException('Local photo path is not a string.');
    }
    if (path.trim().isNotEmpty) retained.add(path);
  }

  Future<StoredRecordPhotoFile> _persistSelection(
    Object token, {
    required String recordId,
    required String photoId,
    Uint8List? bytes,
    String? sourcePath,
    String? contentType,
  }) {
    final draft = _drafts[token];
    if (draft == null) throw StateError('Photo draft is no longer open.');
    return _serialize(() async {
      final stored = await _fileStore.persistSelection(
        ownerId: draft.ownerKey,
        recordId: recordId,
        photoId: photoId,
        bytes: bytes,
        sourcePath: sourcePath,
        contentType: contentType,
      );
      // Pin before returning the file to the editor or releasing this queue.
      draft.paths.add(_normalizePath(stored.path));
      return stored;
    });
  }

  void _updatePaths(Object token, Iterable<String> paths) {
    final draft = _drafts[token];
    if (draft == null) throw StateError('Photo draft is no longer open.');
    draft.paths
      ..clear()
      ..addAll(_normalizePaths(paths));
    if (_automaticCleanup) requestCleanup(draft.ownerKey);
  }

  Future<void> _release(Object token) async {
    final owner = await _serialize(() async => _drafts.remove(token)?.ownerKey);
    if (owner != null && _automaticCleanup) {
      requestCleanup(owner);
      await flushPending();
    }
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    // Start each idle batch in the caller's zone. Only pending work needs the
    // existing tail; retaining its scheduler would couple separate widget tests.
    final operation = _pendingOperations == 0
        ? Future<T>.microtask(action)
        : _queue.then((_) => action());
    _pendingOperations++;
    // Failure is returned to the caller without poisoning subsequent cleanup.
    _queue = operation.then<void>(
      (_) {
        _pendingOperations--;
      },
      onError: (Object _, StackTrace _) {
        _pendingOperations--;
      },
    );
    return operation;
  }

  static Set<String> _normalizePaths(Iterable<String> paths) => {
    for (final path in paths)
      if (path.trim().isNotEmpty) _normalizePath(path),
  };

  static String _normalizePath(String path) {
    final trimmed = path.trim();
    if (trimmed.startsWith('memory-record-photo:')) {
      return Uri.parse(trimmed).normalizePath().toString();
    }
    final normalized = p.normalize(p.absolute(trimmed));
    return p.style == p.Style.windows ? normalized.toLowerCase() : normalized;
  }

  static void _validateOwner(String ownerKey) {
    if (ownerKey.trim().isEmpty) {
      throw ArgumentError.value(ownerKey, 'ownerKey', 'Must not be empty.');
    }
  }

  @visibleForTesting
  Future<void> configureForTesting({
    required RecordPhotoFileStore fileStore,
  }) async {
    await flushPending();
    _queue = Future<void>.value();
    _drafts.clear();
    _fileStore = fileStore;
    _automaticCleanup = false;
    lastError = null;
  }

  @visibleForTesting
  Future<void> resetForTesting() async {
    await configureForTesting(fileStore: RecordPhotoFileStore());
  }
}

final class RecordPhotoDraftLease {
  RecordPhotoDraftLease._(this._service, this._token);

  final RecordPhotoCleanupService _service;
  final Object _token;
  bool _released = false;
  Future<void>? _releaseFuture;

  Future<StoredRecordPhotoFile> persistSelection({
    required String recordId,
    required String photoId,
    Uint8List? bytes,
    String? sourcePath,
    String? contentType,
  }) {
    _ensureOpen();
    return _service._persistSelection(
      _token,
      recordId: recordId,
      photoId: photoId,
      bytes: bytes,
      sourcePath: sourcePath,
      contentType: contentType,
    );
  }

  void updatePaths(Iterable<String> paths) {
    _ensureOpen();
    _service._updatePaths(_token, paths);
  }

  Future<void> release() {
    _released = true;
    return _releaseFuture ??= _service._release(_token);
  }

  void _ensureOpen() {
    if (_released) throw StateError('Photo draft is no longer open.');
  }
}

final class _DraftReferences {
  _DraftReferences(this.ownerKey, this.paths);

  final String ownerKey;
  final Set<String> paths;
}
