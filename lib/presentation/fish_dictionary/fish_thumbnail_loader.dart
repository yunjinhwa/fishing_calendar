import 'dart:collection';
import 'dart:convert';

import '../../data/models/fish_species.dart';
import '../../data/fish/fish_photo_validation.dart';

typedef FishThumbnailRequest =
    Future<FishSpecies> Function(FishSpecies fish, {bool forceRefresh});

String fishThumbnailKey(FishSpecies fish) =>
    jsonEncode([fish.id, fish.name, fish.scientificName]);

bool hasFishThumbnail(FishSpecies fish) => hasUsableFishPhoto(fish);

/// Retain current taxonomy/description while adding a verified photo.
FishSpecies mergeFishThumbnail(FishSpecies base, FishSpecies photo) {
  if (!hasFishThumbnail(photo)) return base;
  return FishSpecies.fromJson({
    ...base.toJson(),
    'imageUrl': photo.imageUrl,
    'photoAttribution': photo.photoAttribution,
    'photoSourceUrl': photo.photoSourceUrl,
    'photoLicenseUrl': photo.photoLicenseUrl,
  });
}

/// Page-owned queue. Removing an owner cancels its queued work and callbacks;
/// requests already in progress may still populate the repository cache.
class FishThumbnailLoader {
  FishThumbnailLoader({
    required FishThumbnailRequest request,
    this.maxConcurrent = 2,
  }) : _request = request {
    if (maxConcurrent < 1 || maxConcurrent > 2) {
      throw ArgumentError.value(maxConcurrent, 'maxConcurrent');
    }
  }

  final FishThumbnailRequest _request;
  final int maxConcurrent;
  final _jobs = <String, _ThumbnailJob>{};
  final _owners = <Object, _ThumbnailJob>{};
  final _queue = Queue<_ThumbnailJob>();
  Set<String>? _allowedKeys;
  bool _enabled = false;
  bool _disposed = false;
  int _running = 0;

  void setEnabled(bool enabled) {
    if (_disposed || _enabled == enabled) return;
    _enabled = enabled;
    if (!enabled) {
      for (final job in _queue) {
        job.queued = false;
      }
      _queue.clear();
    } else {
      recheckVisible();
    }
  }

  void setAllowedKeys(Set<String> keys) {
    if (_disposed) return;
    _allowedKeys = keys;
    _queue.removeWhere((job) {
      if (keys.contains(job.key)) return false;
      job.queued = false;
      return true;
    });
    recheckVisible();
  }

  void attach({
    required Object owner,
    required FishSpecies fish,
    required bool Function() isVisible,
    required void Function(FishSpecies) onResult,
  }) {
    if (_disposed) return;
    final key = fishThumbnailKey(fish);
    if (_owners[owner]?.key != key) detach(owner);
    final job = _jobs.putIfAbsent(key, () => _ThumbnailJob(key, fish));
    job.fish = mergeFishThumbnail(fish, job.fish);
    job.owners[owner] = _ThumbnailOwner(isVisible, onResult);
    _owners[owner] = job;
    if (hasFishThumbnail(job.fish)) {
      job.finished = true;
      onResult(job.fish);
    } else {
      _enqueue(job);
      _drain();
    }
  }

  void detach(Object owner) {
    final job = _owners.remove(owner);
    if (job == null) return;
    job.owners.remove(owner);
    if (!_visible(job) && job.queued) {
      _queue.remove(job);
      job.queued = false;
    }
    if (job.owners.isEmpty && !job.running) _jobs.remove(job.key);
  }

  void recheckVisible() {
    if (_disposed || !_enabled) return;
    for (final job in _jobs.values) {
      _enqueue(job);
    }
    _drain();
  }

  void retryVisible({bool forceRefresh = false}) {
    if (_disposed) return;
    for (final job in _jobs.values) {
      if (job.running || hasFishThumbnail(job.fish) || !_visible(job)) continue;
      if (!forceRefresh && (!job.finished || job.recoveryRetries >= 1)) {
        continue;
      }
      if (forceRefresh) {
        job.recoveryRetries = 0;
      } else {
        job.recoveryRetries++;
      }
      job.finished = false;
      job.forceRefresh = forceRefresh;
      _enqueue(job);
    }
    _drain();
  }

  bool _visible(_ThumbnailJob job) =>
      (_allowedKeys?.contains(job.key) ?? true) &&
      job.owners.values.any((owner) => owner.isVisible());

  void _enqueue(_ThumbnailJob job) {
    if (!_enabled ||
        job.queued ||
        job.running ||
        job.finished ||
        !_visible(job)) {
      return;
    }
    job.queued = true;
    _queue.add(job);
  }

  void _drain() {
    if (_disposed || !_enabled) return;
    while (_running < maxConcurrent && _queue.isNotEmpty) {
      final job = _queue.removeFirst()..queued = false;
      if (job.finished || job.running || !_visible(job)) continue;
      job.running = true;
      _running++;
      _fetch(job);
    }
  }

  Future<void> _fetch(_ThumbnailJob job) async {
    final force = job.forceRefresh;
    job.forceRefresh = false;
    try {
      final fish = await _request(job.fish, forceRefresh: force);
      if (_disposed) return;
      if (fishThumbnailKey(fish) == job.key && fish.name == job.fish.name) {
        job.fish = mergeFishThumbnail(job.fish, fish);
        if (hasFishThumbnail(job.fish)) {
          for (final owner in List<_ThumbnailOwner>.of(job.owners.values)) {
            if (_visible(job) && owner.isVisible()) owner.onResult(job.fish);
          }
        }
      }
    } on Object {
      // The list stays usable; the repository applies negative caching/backoff.
    } finally {
      job.running = false;
      job.finished = true;
      _running--;
      if (job.owners.isEmpty) _jobs.remove(job.key);
      if (!_disposed) _drain();
    }
  }

  void dispose() {
    _disposed = true;
    _enabled = false;
    _queue.clear();
    _owners.clear();
    for (final job in _jobs.values) {
      job.owners.clear();
    }
    _jobs.clear();
  }
}

class _ThumbnailJob {
  _ThumbnailJob(this.key, this.fish);
  final String key;
  FishSpecies fish;
  final owners = <Object, _ThumbnailOwner>{};
  bool queued = false;
  bool running = false;
  bool finished = false;
  bool forceRefresh = false;
  int recoveryRetries = 0;
}

class _ThumbnailOwner {
  const _ThumbnailOwner(this.isVisible, this.onResult);
  final bool Function() isVisible;
  final void Function(FishSpecies) onResult;
}
