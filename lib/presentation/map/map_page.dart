import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/maps/current_location_gateway.dart';
import '../../data/maps/geolocator_current_location_gateway.dart';
import '../../data/maps/kakao_map_configuration.dart';
import '../../data/maps/map_location.dart';
import '../../data/maps/map_search_gateway.dart';
import '../../data/models/external_data.dart';
import '../../data/services/external_data_service.dart';
import '../../data/services/kma_weather_service.dart';
import '../../data/services/network_status_service.dart';
import '../auth/auth_access_guard.dart';
import '../record/record_form_page.dart';
import 'kakao_map_canvas.dart';
import 'map_detail_page.dart';
import 'map_fallback_page.dart';
import 'map_selection_controller.dart';
import 'weather_data_card.dart';

typedef MapCanvasBuilder =
    Widget Function(
      MapLocation selection,
      ValueChanged<MapSearchGateway?> onGatewayChanged,
      void Function(double latitude, double longitude) onPointSelected,
    );

class MapPage extends StatefulWidget {
  const MapPage({
    super.key,
    this.isActive = true,
    this.controller,
    this.configuration = const KakaoMapConfiguration(),
    this.mapBuilder,
    this.externalDataService,
  });

  final bool isActive;
  final MapSelectionController? controller;
  final KakaoMapConfiguration configuration;
  final MapCanvasBuilder? mapBuilder;
  final ExternalDataService? externalDataService;

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  final _searchController = TextEditingController();
  final _network = NetworkStatusService.instance;
  late final MapSelectionController _controller;
  late final ExternalDataService _externalService;
  MapLocation? _observedSelection;
  MapLocation? _externalRequestedFor;
  ExternalData? _externalData;
  String? _externalError;
  bool _loadingExternal = false;
  int _externalRevision = 0;
  int _mapAttempt = 0;
  int _locationEntryRevision = 0;
  bool _wasDisconnected = false;

  @override
  void initState() {
    super.initState();
    _controller =
        widget.controller ??
        MapSelectionController(
          locationGateway: GeolocatorCurrentLocationGateway(),
        );
    _externalService = widget.externalDataService ?? KmaWeatherService.instance;
    _observedSelection = _controller.selection;
    _wasDisconnected = _network.isDisconnected;
    _controller.addListener(_onSelectionChanged);
    _network.addListener(_onNetworkChanged);
    if (widget.isActive) _locateOnEntry();
  }

  @override
  void didUpdateWidget(MapPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive == widget.isActive) return;
    if (!widget.isActive) {
      _locationEntryRevision++;
      _externalRevision++;
      _loadingExternal = false;
      _externalRequestedFor = null;
      _controller.cancelPendingLocation();
      _controller.setGateway(null);
    } else {
      _locateOnEntry();
    }
  }

  void _locateOnEntry() {
    final revision = ++_locationEntryRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !widget.isActive || revision != _locationEntryRevision) {
        return;
      }
      await _controller.useCurrentLocation(requestPermission: false);
      if (!mounted || !widget.isActive || revision != _locationEntryRevision) {
        return;
      }
      await _fetchExternalData();
    });
  }

  void _onSelectionChanged() {
    if (!mounted) return;
    final selection = _controller.selection;
    if (!identical(selection, _observedSelection)) {
      _observedSelection = selection;
      _externalRevision++;
      _externalData = null;
      _externalError = null;
      _loadingExternal = false;
    }
    setState(() {});
    if (widget.isActive &&
        !_controller.isLocating &&
        !_controller.isResolving &&
        !identical(selection, _externalRequestedFor)) {
      unawaited(_fetchExternalData());
    }
  }

  void _onNetworkChanged() {
    final disconnected = _network.isDisconnected;
    final recovered = _wasDisconnected && _network.isConnected;
    _wasDisconnected = disconnected;
    if (!mounted) return;
    if (disconnected || recovered) _controller.setGateway(null);
    setState(() {
      if (recovered) _mapAttempt++;
    });
    if (recovered && widget.isActive) {
      unawaited(_fetchExternalData(force: true));
    }
  }

  Future<void> _fetchExternalData({bool force = false}) async {
    if (!widget.isActive || _controller.isLocating || _controller.isResolving) {
      return;
    }
    final selection = _controller.selection;
    if (!force && identical(selection, _externalRequestedFor)) return;
    _externalRequestedFor = selection;
    final revision = ++_externalRevision;
    if (_network.isDisconnected) {
      setState(() {
        _externalError = '인터넷에 연결한 뒤 다시 조회해 주세요.';
        _loadingExternal = false;
      });
      return;
    }
    setState(() {
      _loadingExternal = true;
      _externalError = null;
    });
    try {
      final data = await _externalService.fetchCurrentData(
        location: selection,
        forceRefresh: force,
      );
      if (!mounted || !widget.isActive || revision != _externalRevision) return;
      setState(() {
        _externalData = data;
        _loadingExternal = false;
      });
    } on ExternalDataException catch (error) {
      if (!mounted || !widget.isActive || revision != _externalRevision) return;
      setState(() {
        _externalData = null;
        _loadingExternal = false;
        _externalError = error.message;
      });
    } on Object {
      if (!mounted || !widget.isActive || revision != _externalRevision) return;
      setState(() {
        _externalData = null;
        _loadingExternal = false;
        _externalError = '외부 데이터를 가져오지 못했습니다.';
      });
    }
  }

  Future<void> _openFallback() async {
    final name = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const MapFallbackPage()));
    if (!mounted || name == null || name.trim().isEmpty) return;
    _controller.selectLocation(MapLocation(name: name));
    _searchController.clear();
  }

  void _search(String query) {
    FocusScope.of(context).unfocus();
    unawaited(_controller.search(query));
  }

  Future<void> _openRecordForm() async {
    final allowed = await requireMemberAccess(
      context,
      message: '지도 정보를 출조 기록으로 저장하려면 로그인이 필요합니다.',
    );
    if (!allowed || !mounted) return;
    final location = _controller.selection;
    final data = _externalData;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RecordFormPage(
          initialLocation: location.name,
          initialLatitude: location.latitude,
          initialLongitude: location.longitude,
          initialExternalData: data,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _locationEntryRevision++;
    _externalRevision++;
    _network.removeListener(_onNetworkChanged);
    _controller.removeListener(_onSelectionChanged);
    _controller.cancelPendingLocation();
    _controller.setGateway(null);
    if (widget.controller == null) _controller.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selected = _controller.selection;
    final choosing = _controller.isLocating || _controller.isResolving;
    return Scaffold(
      appBar: AppBar(
        title: const Text('지도'),
        actions: [
          IconButton(
            onPressed: _openFallback,
            icon: const Icon(Icons.edit_location_alt_outlined),
            tooltip: '위치 대체 입력',
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: _searchController,
              maxLength: 200,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                labelText: '위치 검색',
                hintText: '장소 이름 또는 주소',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  onPressed: () => _search(_searchController.text),
                  icon: const Icon(Icons.search),
                  tooltip: '검색',
                ),
              ),
              onSubmitted: _search,
            ),
            if (_controller.isSearching) const LinearProgressIndicator(),
            if (_controller.errorMessage != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  _controller.errorMessage!,
                  key: const ValueKey('map-error'),
                ),
              ),
            if (_controller.locationFailure ==
                CurrentLocationFailure.deniedForever)
              TextButton(
                onPressed: () async {
                  await _controller.openAppSettings();
                },
                child: const Text('앱 권한 설정 열기'),
              ),
            if (_controller.locationFailure ==
                CurrentLocationFailure.serviceDisabled)
              TextButton(
                onPressed: () async {
                  await _controller.openLocationSettings();
                },
                child: const Text('위치 서비스 설정 열기'),
              ),
            const SizedBox(height: 12),
            _MapCanvasHost(
              key: const ValueKey('map-canvas'),
              isActive: widget.isActive,
              child: SizedBox(
                height: 280,
                child: !widget.isActive
                    ? const SizedBox.shrink()
                    : _network.isDisconnected
                    ? const Card(
                        child: Center(child: Text('오프라인에서는 장소를 직접 입력해 주세요.')),
                      )
                    : widget.mapBuilder?.call(
                            selected,
                            _controller.setGateway,
                            (lat, lon) => unawaited(
                              _controller.selectCoordinates(lat, lon),
                            ),
                          ) ??
                          KakaoMapCanvas(
                            key: ValueKey(_mapAttempt),
                            configuration: widget.configuration,
                            selection: selected,
                            onGatewayChanged: _controller.setGateway,
                            onPointSelected: (lat, lon) => unawaited(
                              _controller.selectCoordinates(lat, lon),
                            ),
                          ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _controller.isLocating
                        ? null
                        : () => unawaited(_controller.useCurrentLocation()),
                    icon: const Icon(Icons.my_location),
                    label: const Text('현재 위치'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _openFallback,
                    icon: const Icon(Icons.edit_location_alt_outlined),
                    label: const Text('장소 직접 입력'),
                  ),
                ),
              ],
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      selected.name,
                      key: const ValueKey('map-selected-location'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (selected.address != null &&
                        selected.address != selected.name)
                      Text(selected.address!),
                    Text(
                      choosing
                          ? '위치를 확인하고 있습니다.'
                          : selected.hasCoordinates
                          ? '선택한 위치를 기록에 저장합니다.'
                          : '장소 이름을 기록에 저장합니다.',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            ..._controller.results.map(
              (result) => Card(
                child: ListTile(
                  leading: const Icon(Icons.place_outlined),
                  title: Text(result.name),
                  subtitle: result.address == null
                      ? null
                      : Text(result.address!),
                  onTap: () {
                    _controller.selectLocation(result);
                    FocusScope.of(context).unfocus();
                  },
                ),
              ),
            ),
            _ExternalDataCard(
              externalData: _externalData,
              isLoading: _loadingExternal,
              errorMessage: _externalError,
              onRetry: () => unawaited(_fetchExternalData(force: true)),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: choosing
                        ? null
                        : () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => MapDetailPage(
                                  selectedLocation: selected.name,
                                  latitude: selected.latitude,
                                  longitude: selected.longitude,
                                  externalData: _externalData,
                                ),
                              ),
                            );
                          },
                    icon: const Icon(Icons.info_outline),
                    label: const Text('자세히 보기'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: choosing ? null : _openRecordForm,
                    icon: const Icon(Icons.edit_note),
                    label: const Text('기록 작성'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// Search results can move the map outside the viewport. Keep its WebView and
// in-flight requests alive until the map tab is deactivated.
class _MapCanvasHost extends StatefulWidget {
  const _MapCanvasHost({
    super.key,
    required this.isActive,
    required this.child,
  });

  final bool isActive;
  final Widget child;

  @override
  State<_MapCanvasHost> createState() => _MapCanvasHostState();
}

class _MapCanvasHostState extends State<_MapCanvasHost>
    with AutomaticKeepAliveClientMixin<_MapCanvasHost> {
  @override
  bool get wantKeepAlive => widget.isActive;

  @override
  void didUpdateWidget(_MapCanvasHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive != widget.isActive) updateKeepAlive();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

class _ExternalDataCard extends StatelessWidget {
  final ExternalData? externalData;
  final bool isLoading;
  final String? errorMessage;
  final VoidCallback onRetry;

  const _ExternalDataCard({
    required this.externalData,
    required this.isLoading,
    required this.errorMessage,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    if (errorMessage != null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '외부 데이터 조회 실패',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(errorMessage!),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('다시 조회'),
              ),
            ],
          ),
        ),
      );
    }

    final data = externalData;

    if (data == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('조회된 외부 데이터가 없습니다.'),
        ),
      );
    }

    return WeatherDataCard(data: data);
  }
}
