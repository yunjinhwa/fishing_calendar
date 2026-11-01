import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/repositories/auth_session_repository.dart';
import '../../data/services/network_status_service.dart';
import '../../data/services/paid_record_cache_service.dart';

/// Retains the complete record history while a search or records page is open.
class RecordHistoryScope extends StatefulWidget {
  const RecordHistoryScope({
    super.key,
    required this.child,
    this.isActive = true,
  });

  final Widget child;
  final bool isActive;

  @override
  State<RecordHistoryScope> createState() => _RecordHistoryScopeState();
}

class _RecordHistoryScopeState extends State<RecordHistoryScope> {
  final _auth = AuthSessionRepository.instance;
  final _cache = PaidRecordCacheService.instance;
  final _network = NetworkStatusService.instance;
  VoidCallback? _releaseHistory;
  int? _heldGeneration;
  bool _wasDisconnected = false;
  bool _loadScheduled = false;
  bool _forceLoad = false;

  @override
  void initState() {
    super.initState();
    _wasDisconnected = _network.isDisconnected;
    _auth.addListener(_onSessionChanged);
    _cache.addListener(_onCacheChanged);
    _network.addListener(_onNetworkChanged);
    _updateHistoryLease();
  }

  @override
  void didUpdateWidget(RecordHistoryScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive != widget.isActive) _updateHistoryLease();
  }

  @override
  void dispose() {
    _auth.removeListener(_onSessionChanged);
    _cache.removeListener(_onCacheChanged);
    _network.removeListener(_onNetworkChanged);
    _releaseHistory?.call();
    super.dispose();
  }

  void _onSessionChanged() {
    if (_heldGeneration != _auth.sessionGeneration) _updateHistoryLease();
    _scheduleHistoryLoad();
    _onCacheChanged();
  }

  void _onCacheChanged() {
    if (mounted && widget.isActive) setState(() {});
  }

  void _onNetworkChanged() {
    final disconnected = _network.isDisconnected;
    final recovered = _wasDisconnected && !disconnected;
    _wasDisconnected = disconnected;
    if (recovered) _scheduleHistoryLoad();
  }

  void _updateHistoryLease() {
    _releaseHistory?.call();
    _releaseHistory = null;
    _heldGeneration = _auth.sessionGeneration;
    if (!widget.isActive) return;
    _releaseHistory = _cache.holdHistory();
    _scheduleHistoryLoad();
  }

  void _scheduleHistoryLoad({bool force = false}) {
    if (!widget.isActive) return;
    _forceLoad = _forceLoad || force;
    if (_loadScheduled) return;
    _loadScheduled = true;
    // Loading notifies its listeners synchronously. Defer it until every page
    // has finished building and its history retention has been registered.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadScheduled = false;
      final force = _forceLoad;
      _forceLoad = false;
      if (!mounted || !widget.isActive) return;
      unawaited(_cache.loadHistory(force: force));
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = _cache.historyState;
    final showStatus =
        widget.isActive &&
        (state == CachedMonthState.loading ||
            state == CachedMonthState.offline ||
            state == CachedMonthState.failed);

    return Column(
      children: [
        if (showStatus)
          _HistoryStatus(
            state: state,
            onRetry: () => _scheduleHistoryLoad(force: true),
          ),
        Expanded(child: widget.child),
      ],
    );
  }
}

class _HistoryStatus extends StatelessWidget {
  const _HistoryStatus({required this.state, required this.onRetry});

  final CachedMonthState state;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final loading = state == CachedMonthState.loading;
    final message = switch (state) {
      CachedMonthState.loading => '전체 기록을 불러오는 중입니다.',
      CachedMonthState.offline => '오프라인에서는 이 기기에 저장된 기록만 표시됩니다.',
      _ => '전체 기록을 불러오지 못했습니다. 저장된 기록을 표시합니다.',
    };
    return Semantics(
      liveRegion: true,
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              if (loading)
                const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  state == CachedMonthState.offline
                      ? Icons.cloud_off_outlined
                      : Icons.error_outline,
                  size: 20,
                ),
              const SizedBox(width: 12),
              Expanded(child: Text(message)),
              if (!loading)
                TextButton(onPressed: onRetry, child: const Text('다시 시도')),
            ],
          ),
        ),
      ),
    );
  }
}
