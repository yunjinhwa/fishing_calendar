import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Availability of a network transport reported by the operating system.
///
/// A connected transport does not guarantee Internet or backend reachability.
enum NetworkStatus { unknown, connected, disconnected }

abstract interface class ConnectivityGateway {
  Future<List<ConnectivityResult>> checkConnectivity();

  Stream<List<ConnectivityResult>> get onConnectivityChanged;
}

class ConnectivityPlusGateway implements ConnectivityGateway {
  ConnectivityPlusGateway({Connectivity? connectivity})
    : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  @override
  Future<List<ConnectivityResult>> checkConnectivity() {
    return _connectivity.checkConnectivity();
  }

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged {
    return _connectivity.onConnectivityChanged;
  }
}

class NetworkStatusService extends ChangeNotifier {
  NetworkStatusService({ConnectivityGateway? gateway, DateTime Function()? now})
    : _gateway = gateway ?? ConnectivityPlusGateway(),
      _now = now ?? DateTime.now;

  static final NetworkStatusService instance = NetworkStatusService();

  ConnectivityGateway _gateway;
  final DateTime Function() _now;

  StreamSubscription<List<ConnectivityResult>>? _subscription;
  Future<void>? _initializeFuture;
  Future<NetworkStatus>? _refreshFuture;

  NetworkStatus _status = NetworkStatus.unknown;
  List<ConnectivityResult> _connectivityResults = const <ConnectivityResult>[];
  Object? _lastError;
  StackTrace? _lastErrorStackTrace;
  DateTime? _lastCheckedAt;
  bool _isChecking = false;
  bool _isInitialized = false;
  bool _isDisposed = false;
  int _generation = 0;
  int _streamEventVersion = 0;

  NetworkStatus get status => _status;
  List<ConnectivityResult> get connectivityResults => _connectivityResults;
  Object? get lastError => _lastError;
  StackTrace? get lastErrorStackTrace => _lastErrorStackTrace;
  DateTime? get lastCheckedAt => _lastCheckedAt;
  bool get isChecking => _isChecking;
  bool get isInitialized => _isInitialized;
  bool get isConnected => _status == NetworkStatus.connected;
  bool get isDisconnected => _status == NetworkStatus.disconnected;

  Future<void> initialize() {
    _ensureNotDisposed();

    if (_isInitialized && _subscription != null) {
      return Future<void>.value();
    }

    final pendingInitialize = _initializeFuture;
    if (pendingInitialize != null) {
      return pendingInitialize;
    }

    final generation = _generation;
    late final Future<void> initializeFuture;
    initializeFuture = _performInitialize(generation).whenComplete(() {
      if (identical(_initializeFuture, initializeFuture)) {
        _initializeFuture = null;
      }
    });
    _initializeFuture = initializeFuture;
    return initializeFuture;
  }

  Future<void> _performInitialize(int generation) async {
    if (!_isCurrentGeneration(generation)) {
      return;
    }

    _subscribeToConnectivityChanges(generation);
    await refresh();

    _setInitialized(_subscription != null, generation);
  }

  void _subscribeToConnectivityChanges(int generation) {
    if (_subscription != null || !_isCurrentGeneration(generation)) {
      return;
    }

    try {
      _subscription = _gateway.onConnectivityChanged.listen(
        (results) => _handleConnectivityResults(results, generation),
        onError: (Object error, StackTrace stackTrace) {
          _handleConnectivityError(error, stackTrace, generation);
        },
        onDone: () => _handleConnectivityStreamDone(generation),
      );
    } on Object catch (error, stackTrace) {
      _applyError(error, stackTrace, generation);
    }
  }

  Future<NetworkStatus> refresh() {
    _ensureNotDisposed();

    final pendingRefresh = _refreshFuture;
    if (pendingRefresh != null) {
      return pendingRefresh;
    }

    final generation = _generation;
    late final Future<NetworkStatus> refreshFuture;
    refreshFuture = _performRefresh(generation).whenComplete(() {
      if (identical(_refreshFuture, refreshFuture)) {
        _refreshFuture = null;
      }
    });
    _refreshFuture = refreshFuture;
    return refreshFuture;
  }

  Future<NetworkStatus> _performRefresh(int generation) async {
    final streamEventVersion = _streamEventVersion;
    _setChecking(true, generation);

    try {
      final results = await _gateway.checkConnectivity();
      if (streamEventVersion == _streamEventVersion) {
        _applyResults(results, generation);
      }
    } on Object catch (error, stackTrace) {
      if (streamEventVersion == _streamEventVersion) {
        _applyError(error, stackTrace, generation);
      }
    } finally {
      _setChecking(false, generation);
    }

    return _status;
  }

  void _handleConnectivityResults(
    List<ConnectivityResult> results,
    int generation,
  ) {
    if (!_isCurrentGeneration(generation)) {
      return;
    }

    _streamEventVersion += 1;
    _applyResults(results, generation);
  }

  void _handleConnectivityError(
    Object error,
    StackTrace stackTrace,
    int generation,
  ) {
    if (!_isCurrentGeneration(generation)) {
      return;
    }

    _streamEventVersion += 1;
    _applyError(error, stackTrace, generation);
  }

  void _handleConnectivityStreamDone(int generation) {
    if (!_isCurrentGeneration(generation)) {
      return;
    }

    _subscription = null;
    _setInitialized(false, generation);
  }

  void _applyResults(List<ConnectivityResult> results, int generation) {
    if (!_isCurrentGeneration(generation)) {
      return;
    }

    final snapshot = List<ConnectivityResult>.unmodifiable(results);
    final nextStatus =
        snapshot.any((result) => result != ConnectivityResult.none)
        ? NetworkStatus.connected
        : NetworkStatus.disconnected;

    final shouldNotify =
        _status != nextStatus ||
        !listEquals(_connectivityResults, snapshot) ||
        _lastError != null ||
        _lastErrorStackTrace != null;

    _connectivityResults = snapshot;
    _status = nextStatus;
    _lastError = null;
    _lastErrorStackTrace = null;
    _lastCheckedAt = _now();
    if (shouldNotify) {
      notifyListeners();
    }
  }

  void _applyError(Object error, StackTrace stackTrace, int generation) {
    if (!_isCurrentGeneration(generation)) {
      return;
    }

    _connectivityResults = const <ConnectivityResult>[];
    _status = NetworkStatus.unknown;
    _lastError = error;
    _lastErrorStackTrace = stackTrace;
    _lastCheckedAt = _now();
    notifyListeners();
  }

  void _setChecking(bool value, int generation) {
    if (!_isCurrentGeneration(generation) || _isChecking == value) {
      return;
    }

    _isChecking = value;
    notifyListeners();
  }

  void _setInitialized(bool value, int generation) {
    if (!_isCurrentGeneration(generation) || _isInitialized == value) {
      return;
    }

    _isInitialized = value;
    notifyListeners();
  }

  bool _isCurrentGeneration(int generation) {
    return !_isDisposed && generation == _generation;
  }

  void _ensureNotDisposed() {
    if (_isDisposed) {
      throw StateError('NetworkStatusService has been disposed.');
    }
  }

  @visibleForTesting
  Future<void> close() async {
    if (_isDisposed) {
      return;
    }

    _generation += 1;
    _isInitialized = false;
    _initializeFuture = null;
    _refreshFuture = null;

    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();

    if (_isChecking) {
      _isChecking = false;
      notifyListeners();
    }
  }

  @visibleForTesting
  Future<void> resetForTesting({ConnectivityGateway? gateway}) async {
    await close();

    if (gateway != null) {
      _gateway = gateway;
    }

    final hasChanges =
        _status != NetworkStatus.unknown ||
        _connectivityResults.isNotEmpty ||
        _lastError != null ||
        _lastErrorStackTrace != null ||
        _lastCheckedAt != null;

    _status = NetworkStatus.unknown;
    _connectivityResults = const <ConnectivityResult>[];
    _lastError = null;
    _lastErrorStackTrace = null;
    _lastCheckedAt = null;
    _isChecking = false;

    if (hasChanges) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    if (_isDisposed) {
      return;
    }

    _isDisposed = true;
    _generation += 1;
    _isInitialized = false;
    _initializeFuture = null;
    _refreshFuture = null;

    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) {
      unawaited(subscription.cancel());
    }

    super.dispose();
  }
}
