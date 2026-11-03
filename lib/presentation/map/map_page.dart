import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/maps/current_location_gateway.dart';
import '../../data/maps/geolocator_current_location_gateway.dart';
import '../../data/maps/kakao_map_configuration.dart';
import '../../data/maps/map_location.dart';
import '../../data/maps/map_search_gateway.dart';
import '../../data/maps/open_map_water_service.dart';
import '../../data/maps/water_area.dart';
import '../../data/maps/water_area_service.dart';
import '../../data/models/external_data.dart';
import '../../data/services/external_data_service.dart';
import '../../data/services/kma_weather_service.dart';
import '../../data/services/network_status_service.dart';
import '../../data/tides/tide_models.dart';
import '../../data/tides/tide_name.dart';
import '../../data/tides/tide_service.dart';
import '../../data/tides/tide_station_catalog.dart';
import '../auth/auth_access_guard.dart';
import '../record/record_form_page.dart';
import 'kakao_map_canvas.dart';
import 'map_detail_page.dart';
import 'map_fallback_page.dart';
import 'map_selection_controller.dart';
import 'tide_panel.dart';

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
    this.tideService,
    this.tideStations,
    this.waterAreaService,
  });

  final bool isActive;
  final MapSelectionController? controller;
  final KakaoMapConfiguration configuration;
  final MapCanvasBuilder? mapBuilder;
  final ExternalDataService? externalDataService;
  final TideService? tideService;
  final TideStationCatalog? tideStations;
  final WaterAreaService? waterAreaService;

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  final _searchController = TextEditingController();
  final _network = NetworkStatusService.instance;
  late final MapSelectionController _controller;
  late final ExternalDataService _externalService;
  late final WaterAreaService _waterAreaService;
  MapLocation? _observedSelection;
  MapLocation? _externalRequestedFor;
  ExternalData? _externalData;
  TideRecordReference? _tideReference;
  TideName? _tideName;
  String? _externalError;
  bool _loadingExternal = false;
  int _externalRevision = 0;
  int _mapAttempt = 0;
  int _locationEntryRevision = 0;
  bool _wasDisconnected = false;
  WaterArea _detectedWaterArea = WaterArea.unknown;
  WaterArea? _waterAreaOverride;
  bool _classifyingWaterArea = false;
  int _waterAreaRevision = 0;
  MapLocation? _waterAreaRequestedFor;

  WaterArea get _waterArea => _waterAreaOverride ?? _detectedWaterArea;

  @override
  void initState() {
    super.initState();
    _controller =
        widget.controller ??
        MapSelectionController(
          locationGateway: GeolocatorCurrentLocationGateway(),
        );
    _externalService = widget.externalDataService ?? KmaWeatherService.instance;
    _waterAreaService = widget.waterAreaService ?? OpenMapWaterService.instance;
    _observedSelection = _controller.selection;
    _tideName = _defaultTideName(_controller.selection);
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
      _tideReference = null;
      _tideName = null;
      _waterAreaRevision++;
      _classifyingWaterArea = false;
      _waterAreaRequestedFor = null;
      _locationEntryRevision++;
      _externalRevision++;
      _loadingExternal = false;
      _externalRequestedFor = null;
      _controller.cancelPendingLocation();
      _controller.setGateway(null);
    } else {
      _tideName = _defaultTideName(_controller.selection);
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
      await _classifyWaterArea();
    });
  }

  void _onSelectionChanged() {
    if (!mounted) return;
    final selection = _controller.selection;
    if (!identical(selection, _observedSelection)) {
      _observedSelection = selection;
      _externalRevision++;
      _externalData = null;
      _tideReference = null;
      _waterAreaRevision++;
      _waterAreaRequestedFor = null;
      _detectedWaterArea = WaterArea.unknown;
      _waterAreaOverride = null;
      _classifyingWaterArea = false;
      _tideName = _defaultTideName(selection, day: _tideName?.day);
      _externalError = null;
      _loadingExternal = false;
    }
    setState(() {});
    if (widget.isActive &&
        !_controller.isLocating &&
        !_controller.isResolving &&
        !identical(selection, _externalRequestedFor)) {
      unawaited(_fetchExternalData());
      unawaited(_classifyWaterArea());
    }
  }

  // The weather card can enter the viewport before the lazy tide panel does.
  // Calculate the default locally so its tide value does not depend on scrolling.
  TideName? _defaultTideName(MapLocation location, {TideDay? day}) {
    if (!_waterArea.providesMarineData) return null;
    final stations = (widget.tideStations ?? TideStationCatalog()).nearby(
      location,
      limit: 1,
    );
    if (stations.isEmpty) return null;
    return TideName.calculate(
      day: day ?? TideDay.fromInstant(DateTime.now()),
      station: stations.first,
    );
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
      if (_detectedWaterArea == WaterArea.unknown) {
        _waterAreaRequestedFor = null;
      }
      unawaited(_classifyWaterArea());
    }
  }

  Future<void> _classifyWaterArea({bool force = false}) async {
    if (!widget.isActive ||
        _controller.isLocating ||
        _controller.isResolving ||
        _waterAreaOverride != null ||
        _network.isDisconnected) {
      return;
    }
    final location = _controller.selection;
    if (!force && identical(location, _waterAreaRequestedFor)) return;
    _waterAreaRequestedFor = location;
    final revision = ++_waterAreaRevision;
    if (!location.hasCoordinates) {
      setState(() {
        _detectedWaterArea = WaterArea.unknown;
        _classifyingWaterArea = false;
        _tideName = null;
        _tideReference = null;
      });
      return;
    }
    setState(() => _classifyingWaterArea = true);
    WaterArea area;
    try {
      area = await _waterAreaService.classify(location, forceRefresh: force);
    } on Object {
      area = WaterArea.unknown;
    }
    if (!mounted ||
        !widget.isActive ||
        revision != _waterAreaRevision ||
        !identical(location, _controller.selection)) {
      return;
    }
    setState(() {
      _detectedWaterArea = area;
      _classifyingWaterArea = false;
      _tideName = _defaultTideName(location, day: _tideName?.day);
      if (!area.providesMarineData) _tideReference = null;
    });
  }

  void _chooseWaterArea(WaterArea? area) {
    setState(() {
      _waterAreaRevision++;
      _waterAreaOverride = area;
      _classifyingWaterArea = false;
      _tideReference = null;
      _tideName = _defaultTideName(_controller.selection, day: _tideName?.day);
    });
    if (area == null) {
      _waterAreaRequestedFor = null;
      unawaited(_classifyWaterArea());
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
          initialTideReference: _tideReference,
          allowAutomaticTide: _waterArea.providesMarineData,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _waterAreaRevision++;
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
            TidePanel(
              key: const ValueKey('map-tide-panel'),
              location: selected,
              isActive: widget.isActive && !choosing,
              service: widget.tideService,
              catalog: widget.tideStations,
              waterArea: _waterArea,
              waterAreaSelector: _WaterAreaSelector(
                detected: _detectedWaterArea,
                areaOverride: _waterAreaOverride,
                isLoading: _classifyingWaterArea,
                onChanged: _chooseWaterArea,
                onRetry: () => unawaited(_classifyWaterArea(force: true)),
              ),
              weatherData: choosing ? null : _externalData,
              weatherLoading: widget.isActive && _loadingExternal,
              weatherError: _externalError,
              onRetryWeather: () => unawaited(_fetchExternalData(force: true)),
              onTideNameChanged: (name) {
                if (!mounted) return;
                final current = _controller.selection;
                if (name != null &&
                    (!_waterArea.providesMarineData ||
                        !widget.isActive ||
                        _controller.isLocating ||
                        _controller.isResolving ||
                        selected.name != current.name ||
                        selected.latitude != current.latitude ||
                        selected.longitude != current.longitude)) {
                  return;
                }
                if (_tideName?.day == name?.day &&
                    _tideName?.station.code == name?.station.code) {
                  return;
                }
                setState(() => _tideName = name);
              },
              onReferenceChanged: (reference) {
                if (!mounted) return;
                final current = _controller.selection;
                if (reference != null &&
                    (!_waterArea.providesMarineData ||
                        !widget.isActive ||
                        _controller.isLocating ||
                        _controller.isResolving ||
                        reference.location.name != current.name ||
                        reference.location.latitude != current.latitude ||
                        reference.location.longitude != current.longitude)) {
                  return;
                }
                if (identical(_tideReference, reference)) return;
                setState(() => _tideReference = reference);
              },
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
                                  tideReference: _tideReference,
                                  tideName: _tideName,
                                  waterArea: _waterArea,
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

class _WaterAreaSelector extends StatelessWidget {
  const _WaterAreaSelector({
    required this.detected,
    required this.areaOverride,
    required this.isLoading,
    required this.onChanged,
    required this.onRetry,
  });

  final WaterArea detected;
  final WaterArea? areaOverride;
  final bool isLoading;
  final ValueChanged<WaterArea?> onChanged;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SegmentedButton<WaterArea?>(
        key: const ValueKey('water-area-selector'),
        direction: MediaQuery.textScalerOf(context).scale(1) > 1.5
            ? Axis.vertical
            : Axis.horizontal,
        segments: const [
          ButtonSegment(value: null, label: Text('자동')),
          ButtonSegment(value: WaterArea.marine, label: Text('바다')),
          ButtonSegment(value: WaterArea.freshwater, label: Text('민물')),
        ],
        selected: {areaOverride},
        onSelectionChanged: (selected) => onChanged(selected.single),
      ),
      const SizedBox(height: 8),
      if (isLoading)
        const LinearProgressIndicator(key: ValueKey('water-area-loading'))
      else if (areaOverride == null)
        Row(
          children: [
            Expanded(child: Text('자동 판별 · ${detected.label}')),
            if (detected == WaterArea.unknown)
              TextButton(onPressed: onRetry, child: const Text('다시 판별')),
          ],
        ),
    ],
  );
}
