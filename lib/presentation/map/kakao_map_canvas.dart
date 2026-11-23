import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:kakao_map_plugin/kakao_map_plugin.dart';

import '../../data/maps/kakao_map_configuration.dart';
import '../../data/maps/kakao_map_search_gateway.dart';
import '../../data/maps/map_location.dart';
import '../../data/maps/map_search_gateway.dart';

typedef MapCanvasBuilder =
    Widget Function(
      MapLocation selection,
      ValueChanged<MapSearchGateway?> onGatewayChanged,
      void Function(double latitude, double longitude) onPointSelected,
    );

// Keep the WebView and its in-flight requests when a list moves the map
// outside the viewport. A stable host key also preserves it as siblings change.
class MapCanvasHost extends StatefulWidget {
  const MapCanvasHost({super.key, required this.isActive, required this.child});

  final bool isActive;
  final Widget child;

  @override
  State<MapCanvasHost> createState() => _MapCanvasHostState();
}

class _MapCanvasHostState extends State<MapCanvasHost>
    with AutomaticKeepAliveClientMixin<MapCanvasHost> {
  @override
  bool get wantKeepAlive => widget.isActive;

  @override
  void didUpdateWidget(MapCanvasHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive != widget.isActive) updateKeepAlive();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

class KakaoMapCanvas extends StatefulWidget {
  const KakaoMapCanvas({
    super.key,
    required this.configuration,
    required this.selection,
    required ValueChanged<MapSearchGateway?> this.onGatewayChanged,
    required void Function(double latitude, double longitude)
    this.onPointSelected,
    this.recenterRequest = 0,
  });

  const KakaoMapCanvas.preview({
    super.key,
    required this.configuration,
    required this.selection,
  }) : onGatewayChanged = null,
       onPointSelected = null,
       recenterRequest = 0;

  final KakaoMapConfiguration configuration;
  final MapLocation selection;
  final ValueChanged<MapSearchGateway?>? onGatewayChanged;
  final void Function(double latitude, double longitude)? onPointSelected;
  final int recenterRequest;

  bool get _isPreview => onGatewayChanged == null;

  @override
  State<KakaoMapCanvas> createState() => _KakaoMapCanvasState();
}

class _KakaoMapCanvasState extends State<KakaoMapCanvas> {
  Timer? _readinessTimer;
  KakaoMapSearchGateway? _gateway;
  KakaoMapController? _mapController;
  int _attempt = 0;
  bool _ready = false;
  bool _failed = false;

  bool get _canCreateMap =>
      widget.configuration.isConfigured &&
      widget.configuration.supportsPlatform;

  @override
  void initState() {
    super.initState();
    _prepareAttempt();
  }

  @override
  void didUpdateWidget(KakaoMapCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.configuration.javascriptKey !=
            widget.configuration.javascriptKey ||
        oldWidget.configuration.baseUrl != widget.configuration.baseUrl ||
        oldWidget._isPreview != widget._isPreview) {
      _prepareAttempt();
      _notifyGateway(null);
    } else if (oldWidget.recenterRequest != widget.recenterRequest) {
      final controller = _mapController;
      final selection = widget.selection;
      if (controller != null && selection.hasCoordinates) {
        unawaited(_recenter(controller, selection));
      }
    }
  }

  Future<void> _recenter(
    KakaoMapController controller,
    MapLocation location,
  ) async {
    try {
      // Dragging the map does not change the plugin's last applied center.
      await controller.setCenter(
        LatLng(location.latitude!, location.longitude!),
      );
    } on Object {
      // A closed or reloading WebView does not affect the selected coordinates.
    }
  }

  void _notifyGateway(MapSearchGateway? gateway) {
    if (widget._isPreview) return;
    final attempt = _attempt;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || attempt != _attempt) return;
      widget.onGatewayChanged?.call(gateway);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _prepareAttempt() {
    _attempt++;
    _readinessTimer?.cancel();
    _gateway?.dispose();
    _gateway = null;
    _mapController = null;
    _ready = false;
    _failed = false;
    if (!_canCreateMap) return;
    AuthRepository.initialize(
      appKey: widget.configuration.javascriptKey.trim(),
      baseUrl: widget.configuration.baseUrl,
      libraries: {KakaoMapLibrary.services},
    );
    final attempt = _attempt;
    _readinessTimer = Timer(const Duration(seconds: 15), () {
      if (!mounted || _ready || attempt != _attempt) return;
      _gateway?.dispose();
      _gateway = null;
      setState(() => _failed = true);
      _notifyGateway(null);
    });
  }

  void _onMapCreated(KakaoMapController controller, int attempt) {
    if (!mounted || _failed || attempt != _attempt) return;
    _readinessTimer?.cancel();
    if (!widget._isPreview) {
      _gateway?.dispose();
      _gateway = KakaoMapSearchGateway(controller);
      _mapController = controller;
    }
    setState(() => _ready = true);
    _notifyGateway(_gateway);
  }

  void _retry() {
    setState(_prepareAttempt);
    _notifyGateway(null);
  }

  @override
  void dispose() {
    _attempt++;
    _readinessTimer?.cancel();
    _gateway?.dispose();
    // The child map owns its WebView controller and disposes its own resources.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selection = widget.selection;
    final isPreview = widget._isPreview;
    final center = selection.hasCoordinates
        ? LatLng(selection.latitude!, selection.longitude!)
        : LatLng(35.1796, 129.0756);
    final attempt = _attempt;
    return SizedBox(
      height: isPreview ? 200 : 280,
      width: double.infinity,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: !_canCreateMap
            ? const _MapNotice(message: '지도를 표시할 수 없습니다.')
            : _failed
            ? _MapNotice(
                message: '지도를 불러오지 못했습니다. 인터넷 연결을 확인해 주세요.',
                onRetry: _retry,
              )
            : Stack(
                children: [
                  Positioned.fill(
                    child: IgnorePointer(
                      ignoring: isPreview,
                      child: KakaoMap(
                        key: ValueKey(attempt),
                        center: center,
                        currentLevel: 4,
                        minLevel: 1,
                        maxLevel: 14,
                        zoomControl: !isPreview,
                        libraries: {if (!isPreview) KakaoMapLibrary.services},
                        // Let a preview's surrounding page handle scrolling.
                        gestureRecognizers: {
                          if (!isPreview)
                            const Factory<OneSequenceGestureRecognizer>(
                              EagerGestureRecognizer.new,
                            ),
                        },
                        onMapCreated: (controller) =>
                            _onMapCreated(controller, attempt),
                        onMapTap: isPreview
                            ? null
                            : (point) {
                                if (!_ready || attempt != _attempt) return;
                                widget.onPointSelected?.call(
                                  point.latitude,
                                  point.longitude,
                                );
                              },
                        markers: [
                          if (selection.hasCoordinates)
                            Marker(
                              markerId: 'selected-location',
                              latLng: center,
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (!_ready)
                    const Positioned.fill(
                      child: _MapNotice(
                        message: '지도를 불러오는 중입니다.',
                        loading: true,
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

class _MapNotice extends StatelessWidget {
  const _MapNotice({required this.message, this.loading = false, this.onRetry});

  final String message;
  final bool loading;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (loading)
                const CircularProgressIndicator()
              else
                const Icon(Icons.map_outlined, size: 40),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
              if (onRetry != null)
                TextButton(onPressed: onRetry, child: const Text('지도 다시 불러오기')),
            ],
          ),
        ),
      ),
    ),
  );
}
