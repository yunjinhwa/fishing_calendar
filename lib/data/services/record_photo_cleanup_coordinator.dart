import '../repositories/auth_session_repository.dart';
import '../repositories/conflict_repository.dart';
import '../repositories/fishing_record_repository.dart';
import 'record_photo_cleanup_service.dart';
import 'record_sync_service.dart';

/// Schedules local-only garbage collection after durable data can change.
class RecordPhotoCleanupCoordinator {
  RecordPhotoCleanupCoordinator({RecordPhotoCleanupService? cleanup})
    : _cleanup = cleanup ?? RecordPhotoCleanupService.instance;

  static final instance = RecordPhotoCleanupCoordinator();

  final RecordPhotoCleanupService _cleanup;
  final _auth = AuthSessionRepository.instance;
  final _records = FishingRecordRepository.instance;
  final _conflicts = ConflictRepository.instance;
  final _sync = RecordSyncService.instance;
  bool _initialized = false;
  RecordSyncState? _lastSyncState;

  void initialize() {
    if (_initialized) return;
    _initialized = true;
    _cleanup.enableAutomaticCleanup();
    _lastSyncState = _sync.state;
    _auth.addListener(_onDataChanged);
    _records.addListener(_onDataChanged);
    _conflicts.addListener(_onDataChanged);
    _sync.addListener(_onSyncChanged);
    _onDataChanged();
  }

  void _onDataChanged() {
    if (_auth.isMember) _cleanup.requestCleanup(_auth.dataOwnerKey);
  }

  void _onSyncChanged() {
    final state = _sync.state;
    if (state == _lastSyncState) return;
    _lastSyncState = state;
    // A completed request can release the last photo reference even when
    // the corresponding record has already been deleted locally.
    if (state == RecordSyncState.succeeded || state == RecordSyncState.failed) {
      _onDataChanged();
    }
  }

  void dispose() {
    if (!_initialized) return;
    _initialized = false;
    _auth.removeListener(_onDataChanged);
    _records.removeListener(_onDataChanged);
    _conflicts.removeListener(_onDataChanged);
    _sync.removeListener(_onSyncChanged);
  }
}
