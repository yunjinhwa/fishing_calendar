import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../data/maps/current_location_gateway.dart';
import '../../data/maps/geolocator_current_location_gateway.dart';
import '../../data/maps/kakao_map_configuration.dart';
import '../../data/maps/map_location.dart';
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
import '../../data/water_temperature/khoa_water_temperature_service.dart';
import '../../data/water_temperature/water_temperature_models.dart';
import '../../data/water_temperature/water_temperature_service.dart';
import '../auth/auth_access_guard.dart';
import '../common/record_action_footer.dart';
import '../record/record_form_page.dart';
import 'kakao_map_canvas.dart';
import 'map_detail_page.dart';
import 'map_selection_controller.dart';
import 'tide_panel.dart';

export 'kakao_map_canvas.dart' show MapCanvasBuilder;

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
    this.waterTemperatureService,
    this.clock,
  });

  final bool isActive;
  final MapSelectionController? controller;
  final KakaoMapConfiguration configuration;
  final MapCanvasBuilder? mapBuilder;
  final ExternalDataService? externalDataService;
  final TideService? tideService;
  final TideStationCatalog? tideStations;
  final WaterAreaService? waterAreaService;
  final WaterTemperatureService? waterTemperatureService;
  final DateTime Function()? clock;

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> with WidgetsBindingObserver {
  static const _refreshInterval = Duration(minutes: 10);
  static const _retryDelay = Duration(minutes: 5);
  final _searchController = TextEditingController();
  final _resultsScrollController = ScrollController(keepScrollOffset: false);
  final _network = NetworkStatusService.instance;
  late final MapSelectionController _controller;
  late final ExternalDataService _externalService;
  late final WaterAreaService _waterAreaService;
  MapLocation? _observedSelection;
  List<MapLocation>? _observedResults;
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
  WaterTemperatureObservation? _waterTemperatureObservation;
  WaterTemperatureFailure? _waterTemperatureFailure;
  MapLocation? _waterTemperatureRequestedFor;
  bool _loadingWaterTemperature = false;
  int _waterTemperatureRevision = 0;
  Timer? _freshnessTimer;
  bool _isForeground = true;
  DateTime? _weatherRefreshAt;
  DateTime? _waterRefreshAt;

  DateTime _now() => (widget.clock ?? DateTime.now)().toUtc();
  bool get _canRefresh =>
      mounted &&
      widget.isActive &&
      _isForeground &&
      !_controller.isLocating &&
      !_controller.isResolving;
  ExternalData? get _currentExternalData =>
      _externalData?.isUsableAt(_now()) == true ? _externalData : null;

  WaterArea get _waterArea => _waterAreaOverride ?? _detectedWaterArea;
  WaterTemperatureService get _temperatureService =>
      widget.waterTemperatureService ?? KhoaWaterTemperatureService.instance;
  WaterTemperatureObservation? get _currentWaterTemperature {
    final observation = _waterTemperatureObservation;
    return _waterArea.providesMarineData &&
            observation != null &&
            observation.matchesLocation(_controller.selection) &&
            observation.isUsableAt(_now())
        ? observation
        : null;
  }

  void _resetWaterTemperature() {
    _waterTemperatureRevision++;
    _waterTemperatureObservation = null;
    _waterTemperatureFailure = null;
    _waterTemperatureRequestedFor = null;
    _loadingWaterTemperature = false;
    _waterRefreshAt = null;
  }

  @override
  void initState() {
    super.initState();
    _isForeground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _controller =
        widget.controller ??
        MapSelectionController(
          locationGateway: GeolocatorCurrentLocationGateway(),
        );
    _externalService = widget.externalDataService ?? KmaWeatherService.instance;
    _waterAreaService = widget.waterAreaService ?? OpenMapWaterService.instance;
    _observedSelection = _controller.selection;
    _observedResults = _controller.results;
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
      _freshnessTimer?.cancel();
      _resetWaterTemperature();
      _tideReference = null;
      _tideName = null;
      _waterAreaRevision++;
      _classifyingWaterArea = false;
      _waterAreaRequestedFor = null;
      _locationEntryRevision++;
      _externalRevision++;
      _loadingExternal = false;
      _externalRequestedFor = null;
      _weatherRefreshAt = null;
      _controller.cancelPendingLocation();
      _controller.setGateway(null);
    } else {
      _tideName = _defaultTideName(_controller.selection);
      _locateOnEntry();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isForeground = state == AppLifecycleState.resumed;
    _freshnessTimer?.cancel();
    if (_isForeground && widget.isActive) _refreshCurrentData();
  }

  // A single deadline timer replaces polling; hidden tabs and background apps
  // neither schedule refreshes nor start API calls.
  void _scheduleFreshnessCheck() {
    _freshnessTimer?.cancel();
    if (!_canRefresh) return;
    final now = _now();
    final deadlines = <DateTime>[];
    final weather = _currentExternalData;
    if (weather != null) {
      deadlines.add(weather.validAt.toUtc().add(const Duration(hours: 1)));
    }
    final water = _currentWaterTemperature;
    if (water != null) {
      deadlines.add(_waterExpiresAt(water));
    }
    if (!_network.isDisconnected) {
      if (!_loadingExternal && _weatherRefreshAt != null) {
        deadlines.add(_weatherRefreshAt!);
      }
      if (_waterArea.providesMarineData &&
          !_loadingWaterTemperature &&
          _waterRefreshAt != null) {
        deadlines.add(_waterRefreshAt!);
      }
    }
    if (deadlines.isEmpty) return;
    final next = deadlines.reduce((a, b) => a.isBefore(b) ? a : b);
    final delay = next.difference(now);
    _freshnessTimer = Timer(
      delay.isNegative ? Duration.zero : delay,
      _refreshCurrentData,
    );
  }

  void _refreshCurrentData() {
    if (!_canRefresh) return;
    // Rebuild even offline so expired values stop looking like current data.
    setState(() {});
    if (!_network.isDisconnected) {
      unawaited(_fetchExternalData(ifStale: true));
      unawaited(_fetchWaterTemperature(ifStale: true));
      if (_waterAreaRequestedFor == null) unawaited(_classifyWaterArea());
    }
    _scheduleFreshnessCheck();
  }

  DateTime _nextRefresh(DateTime fetchedAt, DateTime expiresAt) {
    final cachedUntil = fetchedAt.toUtc().add(_refreshInterval);
    final deadline = cachedUntil.isBefore(expiresAt) ? cachedUntil : expiresAt;
    final now = _now();
    // An injected/cached response with an old fetch time must not spin a timer.
    return deadline.isAfter(now) ? deadline : now.add(_retryDelay);
  }

  DateTime _waterExpiresAt(WaterTemperatureObservation observation) =>
      observation.observedAt
          .toUtc()
          .add(WaterTemperatureObservation.maxObservationAge)
          .add(const Duration(milliseconds: 1));

  bool _isRefreshDue(DateTime? deadline) =>
      deadline != null && !deadline.isAfter(_now());

  void _locateOnEntry() {
    final revision = ++_locationEntryRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted ||
          !widget.isActive ||
          !_isForeground ||
          revision != _locationEntryRevision) {
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
    final results = _controller.results;
    if (!identical(results, _observedResults)) {
      _observedResults = results;
      if (results.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted ||
              !identical(results, _controller.results) ||
              !_resultsScrollController.hasClients) {
            return;
          }
          if (_resultsScrollController.offset != 0) {
            _resultsScrollController.jumpTo(0);
          }
        });
      }
    }
    final selection = _controller.selection;
    if (!identical(selection, _observedSelection)) {
      _observedSelection = selection;
      _externalRevision++;
      _externalData = null;
      _weatherRefreshAt = null;
      _resetWaterTemperature();
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
        !_controller.isResolving) {
      if (!identical(selection, _externalRequestedFor)) {
        unawaited(_fetchExternalData());
      }
      unawaited(_classifyWaterArea());
      unawaited(_fetchWaterTemperature());
    }
    _scheduleFreshnessCheck();
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
      day: day ?? TideDay.fromInstant(_now()),
      station: stations.first,
    );
  }

  void _onNetworkChanged() {
    final disconnected = _network.isDisconnected;
    final recovered = _wasDisconnected && _network.isConnected;
    if (disconnected || _network.isConnected) _wasDisconnected = disconnected;
    if (!mounted) return;
    if (disconnected || recovered) _controller.setGateway(null);
    setState(() {
      if (recovered) _mapAttempt++;
      if (disconnected) {
        if (_loadingExternal) {
          _externalRevision++;
          _loadingExternal = false;
          _externalRequestedFor = null;
        }
        if (_loadingWaterTemperature) {
          _waterTemperatureRevision++;
          _loadingWaterTemperature = false;
          _waterTemperatureRequestedFor = null;
        }
      }
    });
    if (recovered && widget.isActive) {
      if (_detectedWaterArea == WaterArea.unknown) {
        _waterAreaRequestedFor = null;
      }
      _refreshCurrentData();
    }
    _scheduleFreshnessCheck();
  }

  Future<void> _classifyWaterArea({bool force = false}) async {
    if (!widget.isActive ||
        !_isForeground ||
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
        _resetWaterTemperature();
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
      if (!area.providesMarineData) {
        _tideReference = null;
        _resetWaterTemperature();
      }
    });
    unawaited(_fetchWaterTemperature());
  }

  void _chooseWaterArea(WaterArea? area) {
    setState(() {
      _waterAreaRevision++;
      _waterAreaOverride = area;
      _classifyingWaterArea = false;
      _tideReference = null;
      _resetWaterTemperature();
      _tideName = _defaultTideName(_controller.selection, day: _tideName?.day);
    });
    if (area == null) {
      _waterAreaRequestedFor = null;
      unawaited(_classifyWaterArea());
    }
    unawaited(_fetchWaterTemperature());
  }

  Future<void> _fetchWaterTemperature({
    bool force = false,
    bool ifStale = false,
  }) async {
    if (!_canRefresh ||
        !_waterArea.providesMarineData ||
        _network.isDisconnected) {
      return;
    }
    final location = _controller.selection;
    final sameRequest = identical(location, _waterTemperatureRequestedFor);
    if (!location.hasCoordinates ||
        (sameRequest && _loadingWaterTemperature) ||
        (!force &&
            sameRequest &&
            (!ifStale || !_isRefreshDue(_waterRefreshAt)))) {
      return;
    }
    _waterTemperatureRequestedFor = location;
    _waterRefreshAt = null;
    final revision = ++_waterTemperatureRevision;
    setState(() {
      _waterTemperatureFailure = null;
      _loadingWaterTemperature = true;
    });
    bool current() =>
        mounted &&
        widget.isActive &&
        _waterArea.providesMarineData &&
        revision == _waterTemperatureRevision &&
        identical(location, _controller.selection);
    try {
      final observation = await _temperatureService.fetchCurrentData(
        location: location,
        forceRefresh: force,
      );
      if (!current()) return;
      if (!observation.matchesLocation(location)) {
        throw const WaterTemperatureException(
          WaterTemperatureFailure.invalidResponse,
        );
      }
      if (!observation.isUsableAt(_now())) {
        throw const WaterTemperatureException(WaterTemperatureFailure.noData);
      }
      setState(() {
        _waterTemperatureObservation = observation;
        _loadingWaterTemperature = false;
        _waterRefreshAt = _nextRefresh(
          observation.fetchedAt,
          _waterExpiresAt(observation),
        );
      });
    } on Object catch (error) {
      if (!current()) return;
      setState(() {
        _waterTemperatureObservation = null;
        _loadingWaterTemperature = false;
        _waterTemperatureFailure = error is WaterTemperatureException
            ? error.reason
            : WaterTemperatureFailure.invalidResponse;
        _waterRefreshAt = switch (_waterTemperatureFailure) {
          WaterTemperatureFailure.configuration ||
          WaterTemperatureFailure.unauthorized ||
          WaterTemperatureFailure.coordinatesRequired ||
          WaterTemperatureFailure.unsupportedLocation => null,
          _ => _now().add(_retryDelay),
        };
      });
    } finally {
      if (current()) _scheduleFreshnessCheck();
    }
  }

  Future<void> _fetchExternalData({
    bool force = false,
    bool ifStale = false,
  }) async {
    if (!_canRefresh) {
      return;
    }
    final selection = _controller.selection;
    final sameRequest = identical(selection, _externalRequestedFor);
    if ((sameRequest && _loadingExternal) ||
        (!force &&
            sameRequest &&
            (!ifStale || !_isRefreshDue(_weatherRefreshAt)))) {
      return;
    }
    _externalRequestedFor = selection;
    _weatherRefreshAt = null;
    final revision = ++_externalRevision;
    if (_network.isDisconnected) {
      _externalRequestedFor = null;
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
      if (!data.isUsableAt(_now())) {
        throw const ExternalDataException(ExternalDataFailure.noData);
      }
      setState(() {
        _externalData = data;
        _loadingExternal = false;
        _weatherRefreshAt = _nextRefresh(
          data.fetchedAt,
          data.validAt.toUtc().add(const Duration(hours: 1)),
        );
      });
    } on ExternalDataException catch (error) {
      if (!mounted || !widget.isActive || revision != _externalRevision) return;
      setState(() {
        _externalData = null;
        _loadingExternal = false;
        _externalError = error.message;
        _weatherRefreshAt = switch (error.reason) {
          ExternalDataFailure.configuration ||
          ExternalDataFailure.unauthorized ||
          ExternalDataFailure.coordinatesRequired ||
          ExternalDataFailure.unsupportedLocation => null,
          _ => _now().add(_retryDelay),
        };
      });
    } on Object {
      if (!mounted || !widget.isActive || revision != _externalRevision) return;
      setState(() {
        _externalData = null;
        _loadingExternal = false;
        _externalError = '외부 데이터를 가져오지 못했습니다.';
        _weatherRefreshAt = _now().add(_retryDelay);
      });
    } finally {
      if (mounted && revision == _externalRevision) _scheduleFreshnessCheck();
    }
  }

  void _search(String query) {
    FocusScope.of(context).unfocus();
    unawaited(_controller.search(query));
  }

  void _openMapDetail() {
    final location = _controller.selection;
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => MapDetailPage(
            selectedLocation: location.name,
            configuration: widget.configuration,
            latitude: location.latitude,
            longitude: location.longitude,
            externalData: _currentExternalData,
            tideReference: _tideReference,
            tideName: _tideName,
            waterArea: _waterArea,
            waterTemperatureObservation: _currentWaterTemperature,
          ),
        ),
      ),
    );
  }

  Future<void> _openRecordForm() async {
    final allowed = await requireMemberAccess(
      context,
      message: '지도 정보를 출조 기록으로 저장하려면 로그인이 필요합니다.',
    );
    if (!allowed || !mounted) return;
    final location = _controller.selection;
    final data = _currentExternalData;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RecordFormPage(
          initialLocation: location.name,
          initialLatitude: location.latitude,
          initialLongitude: location.longitude,
          initialExternalData: data,
          initialTideReference: _tideReference,
          allowAutomaticTide: _waterArea.providesMarineData,
          initialWaterTemperatureObservation: _currentWaterTemperature,
          allowAutomaticWaterTemperature: _waterArea.providesMarineData,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _freshnessTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _waterAreaRevision++;
    _waterTemperatureRevision++;
    _locationEntryRevision++;
    _externalRevision++;
    _network.removeListener(_onNetworkChanged);
    _controller.removeListener(_onSelectionChanged);
    _controller.cancelPendingLocation();
    _controller.setGateway(null);
    if (widget.controller == null) _controller.dispose();
    _searchController.dispose();
    _resultsScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selected = _controller.selection;
    final results = _controller.results;
    final selectedResultIndex = results.indexOf(selected);
    final colors = Theme.of(context).colorScheme;
    final choosing = _controller.isLocating || _controller.isResolving;
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    const actionPadding = EdgeInsets.symmetric(horizontal: 12, vertical: 8);
    return Scaffold(
      appBar: AppBar(title: const Text('지도')),
      bottomNavigationBar: keyboardVisible
          ? null
          : RecordActionFooter(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: choosing ? null : _openMapDetail,
                      style: OutlinedButton.styleFrom(padding: actionPadding),
                      icon: const Icon(Icons.info_outline),
                      label: const Text('자세히 보기', textAlign: TextAlign.center),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: choosing ? null : _openRecordForm,
                      style: FilledButton.styleFrom(padding: actionPadding),
                      icon: const Icon(Icons.edit_note),
                      label: const Text('기록 작성', textAlign: TextAlign.center),
                    ),
                  ),
                ],
              ),
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
            MapCanvasHost(
              key: const ValueKey('map-canvas'),
              isActive: widget.isActive,
              child: SizedBox(
                height: 280,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: ColoredBox(
                    color: AppTheme.coolGray,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (widget.isActive)
                          if (_network.isDisconnected)
                            const Center(
                              child: Text(
                                '오프라인에서는 지도를 불러올 수 없습니다.\n기록 작성 화면에서 위치를 입력할 수 있습니다.',
                                textAlign: TextAlign.center,
                              ),
                            )
                          else
                            widget.mapBuilder?.call(
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
                        Positioned(
                          right: 12,
                          bottom: 12,
                          child: IconButton.filled(
                            tooltip: '현재 위치',
                            style: IconButton.styleFrom(
                              backgroundColor: AppTheme.primary,
                              foregroundColor: Colors.white,
                            ),
                            onPressed: _controller.isLocating
                                ? null
                                : () => unawaited(
                                    _controller.useCurrentLocation(),
                                  ),
                            icon: const Icon(Icons.my_location),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            if (results.isEmpty)
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        selected.name,
                        key: const ValueKey('map-selected-location'),
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      if (selected.address != null &&
                          selected.address != selected.name)
                        Text(selected.address!),
                      if (choosing) const Text('위치를 확인하고 있습니다.'),
                    ],
                  ),
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: Scrollbar(
                  controller: _resultsScrollController,
                  child: ListView.builder(
                    key: const ValueKey('map-search-results'),
                    controller: _resultsScrollController,
                    primary: false,
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    itemCount: results.length,
                    itemBuilder: (context, index) {
                      final result = results[index];
                      final isSelected = index == selectedResultIndex;
                      return Card(
                        key: ValueKey('map-search-result-outline-$index'),
                        elevation: 0,
                        color: isSelected
                            ? AppTheme.primaryContainer
                            : colors.surface,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                            color: isSelected
                                ? colors.primary
                                : colors.outlineVariant,
                            width: isSelected ? 2 : 1,
                          ),
                        ),
                        child: ListTile(
                          minTileHeight: 72,
                          selected: isSelected,
                          leading: const Icon(Icons.place_outlined),
                          title: Text(result.name),
                          subtitle: result.address == null
                              ? null
                              : Text(result.address!),
                          onTap: () {
                            _controller.selectLocation(
                              result,
                              preserveSearchResults: true,
                            );
                            FocusScope.of(context).unfocus();
                          },
                        ),
                      );
                    },
                  ),
                ),
              ),
            const SizedBox(height: 12),
            TidePanel(
              clock: widget.clock,
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
              weatherData: choosing ? null : _currentExternalData,
              weatherLoading: widget.isActive && _loadingExternal,
              weatherError: _externalError,
              onRetryWeather: () => unawaited(_fetchExternalData(force: true)),
              waterTemperatureObservation: choosing
                  ? null
                  : _currentWaterTemperature,
              waterTemperatureLoading:
                  widget.isActive && !choosing && _loadingWaterTemperature,
              waterTemperatureError: _waterTemperatureFailure == null
                  ? null
                  : '제공되지 않음',
              onRetryWaterTemperature:
                  _waterTemperatureFailure != null &&
                      _waterTemperatureFailure !=
                          WaterTemperatureFailure.configuration &&
                      !_network.isDisconnected
                  ? () => unawaited(_fetchWaterTemperature(force: true))
                  : null,
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
          ],
        ),
      ),
    );
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
      if (isLoading) ...[
        const SizedBox(height: 8),
        const LinearProgressIndicator(key: ValueKey('water-area-loading')),
      ] else if (areaOverride == null && detected == WaterArea.unknown)
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(onPressed: onRetry, child: const Text('다시 판별')),
        ),
    ],
  );
}
