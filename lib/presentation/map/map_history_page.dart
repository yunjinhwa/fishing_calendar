import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/history/historical_conditions.dart';
import '../../data/history/historical_conditions_service.dart';
import '../../data/history/khoa_historical_water_temperature_service.dart';
import '../../data/history/kma_historical_weather_service.dart';
import '../../data/maps/map_location.dart';
import '../../data/maps/water_area.dart';
import '../../data/services/network_status_service.dart';
import '../../data/tides/tide_models.dart';
import '../../data/tides/tide_name.dart';
import '../../data/tides/tide_station_catalog.dart';
import '../auth/auth_access_guard.dart';
import '../record/record_form_page.dart';
import 'weather_data_card.dart';

class MapHistoryPage extends StatefulWidget {
  const MapHistoryPage({
    super.key,
    required this.selectedLocation,
    this.latitude,
    this.longitude,
    this.waterArea = WaterArea.unknown,
    this.weatherService,
    this.waterTemperatureService,
    this.initialRequestedAt,
    this.clock,
  });

  final String selectedLocation;
  final double? latitude;
  final double? longitude;
  final WaterArea waterArea;
  final HistoricalWeatherService? weatherService;
  final HistoricalWaterTemperatureService? waterTemperatureService;
  final DateTime? initialRequestedAt;
  final DateTime Function()? clock;

  @override
  State<MapHistoryPage> createState() => _MapHistoryPageState();
}

class _MapHistoryPageState extends State<MapHistoryPage> {
  final _network = NetworkStatusService.instance;
  late MapLocation _location;
  late DateTime _selectedDate;
  late int _selectedHour;
  HistoricalWeatherObservation? _weather;
  HistoricalWaterTemperatureObservation? _water;
  HistoricalDataFailure? _weatherFailure;
  HistoricalDataFailure? _waterFailure;
  bool _weatherLoading = false;
  bool _waterLoading = false;
  int _weatherRevision = 0;
  int _waterRevision = 0;
  bool _wasDisconnected = false;

  DateTime get _now => (widget.clock ?? DateTime.now)().toUtc();
  DateTime get _nowKst => _now.add(const Duration(hours: 9));
  DateTime get _requestedAt => DateTime.utc(
    _selectedDate.year,
    _selectedDate.month,
    _selectedDate.day,
    _selectedHour,
  ).subtract(const Duration(hours: 9));
  HistoricalWeatherService get _weatherService =>
      widget.weatherService ?? KmaHistoricalWeatherService.instance;
  HistoricalWaterTemperatureService get _waterService =>
      widget.waterTemperatureService ??
      KhoaHistoricalWaterTemperatureService.instance;

  @override
  void initState() {
    super.initState();
    _setLocation();
    final initial = historicalHour(
      widget.initialRequestedAt ?? _now.subtract(const Duration(days: 1)),
    );
    final latest = historicalHour(_now).subtract(const Duration(hours: 1));
    final earliest = DateTime.utc(2019, 12, 31, 15);
    final selected = initial.isAfter(latest)
        ? latest
        : initial.isBefore(earliest)
        ? earliest
        : initial;
    final kst = selected.add(const Duration(hours: 9));
    _selectedDate = DateTime(kst.year, kst.month, kst.day);
    _selectedHour = kst.hour;
    _wasDisconnected = _network.isDisconnected;
    _network.addListener(_onNetworkChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reload();
    });
  }

  void _setLocation() {
    _location = MapLocation(
      name: widget.selectedLocation,
      latitude: widget.latitude,
      longitude: widget.longitude,
    );
  }

  @override
  void didUpdateWidget(MapHistoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedLocation != widget.selectedLocation ||
        oldWidget.latitude != widget.latitude ||
        oldWidget.longitude != widget.longitude ||
        oldWidget.waterArea != widget.waterArea ||
        oldWidget.weatherService != widget.weatherService ||
        oldWidget.waterTemperatureService != widget.waterTemperatureService) {
      _setLocation();
      _reload();
    }
  }

  void _onNetworkChanged() {
    final disconnected = _network.isDisconnected;
    final recovered = _wasDisconnected && _network.isConnected;
    _wasDisconnected = disconnected;
    if (!mounted) return;
    if (disconnected) {
      setState(() {
        _weatherRevision++;
        _waterRevision++;
        _weatherLoading = false;
        _waterLoading = false;
        if (_weather == null) _weatherFailure = HistoricalDataFailure.network;
        if (_water == null && widget.waterArea.providesMarineData) {
          _waterFailure = HistoricalDataFailure.network;
        }
      });
    } else if (recovered) {
      _reload(force: true);
    } else {
      setState(() {});
    }
  }

  void _reload({bool force = false}) {
    setState(() {
      _weather = null;
      _water = null;
      _weatherFailure = null;
      _waterFailure = null;
      _weatherRevision++;
      _waterRevision++;
      _weatherLoading = false;
      _waterLoading = false;
    });
    unawaited(_loadWeather(force: force));
    unawaited(_loadWater(force: force));
  }

  HistoricalDataFailure? get _requestFailure {
    if (!_location.hasCoordinates) {
      return HistoricalDataFailure.coordinatesRequired;
    }
    if (!_requestedAt.isBefore(historicalHour(_now))) {
      return HistoricalDataFailure.unsupportedDate;
    }
    if (_network.isDisconnected) return HistoricalDataFailure.network;
    return null;
  }

  Future<void> _loadWeather({bool force = false}) async {
    final revision = ++_weatherRevision;
    final location = _location;
    final target = _requestedAt;
    final unavailable = _requestFailure;
    setState(() {
      _weather = null;
      _weatherFailure = unavailable;
      _weatherLoading = unavailable == null;
    });
    if (unavailable != null) return;
    try {
      final result = await _weatherService.fetchAt(
        location: location,
        requestedAt: target,
        forceRefresh: force,
      );
      if (!mounted || revision != _weatherRevision) return;
      if (!result.matchesSelection(location, target)) {
        throw const HistoricalDataException(
          HistoricalDataFailure.invalidResponse,
        );
      }
      setState(() {
        _weather = result;
        _weatherLoading = false;
      });
    } on Object catch (error) {
      if (!mounted || revision != _weatherRevision) return;
      setState(() {
        _weatherFailure = error is HistoricalDataException
            ? error.reason
            : HistoricalDataFailure.invalidResponse;
        _weatherLoading = false;
      });
    }
  }

  Future<void> _loadWater({bool force = false}) async {
    if (!widget.waterArea.providesMarineData) return;
    final revision = ++_waterRevision;
    final location = _location;
    final target = _requestedAt;
    final unavailable = _requestFailure;
    setState(() {
      _water = null;
      _waterFailure = unavailable;
      _waterLoading = unavailable == null;
    });
    if (unavailable != null) return;
    try {
      final result = await _waterService.fetchAt(
        location: location,
        requestedAt: target,
        forceRefresh: force,
      );
      if (!mounted || revision != _waterRevision) return;
      if (!result.matchesSelection(location, target)) {
        throw const HistoricalDataException(
          HistoricalDataFailure.invalidResponse,
        );
      }
      setState(() {
        _water = result;
        _waterLoading = false;
      });
    } on Object catch (error) {
      if (!mounted || revision != _waterRevision) return;
      setState(() {
        _waterFailure = error is HistoricalDataException
            ? error.reason
            : HistoricalDataFailure.invalidResponse;
        _waterLoading = false;
      });
    }
  }

  int _maxHour(DateTime day) =>
      day.year == _nowKst.year &&
          day.month == _nowKst.month &&
          day.day == _nowKst.day
      ? _nowKst.hour - 1
      : 23;

  Future<void> _pickDate() async {
    final latestKst = historicalHour(
      _now,
    ).subtract(const Duration(hours: 1)).add(const Duration(hours: 9));
    final date = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(latestKst.year, latestKst.month, latestKst.day),
    );
    if (!mounted || date == null || date == _selectedDate) return;
    setState(() {
      _selectedDate = date;
      _selectedHour = _selectedHour.clamp(0, _maxHour(date));
    });
    _reload();
  }

  Future<void> _openRecord() async {
    final allowed = await requireMemberAccess(
      context,
      message: '조회한 과거 정보를 출조 기록으로 저장하려면 로그인이 필요합니다.',
    );
    if (!allowed || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RecordFormPage(
          initialLocation: _location.name,
          initialLatitude: _location.latitude,
          initialLongitude: _location.longitude,
          initialStartAt: _requestedAt,
          initialHistoricalWeather: _weather,
          initialHistoricalWaterTemperature: widget.waterArea.providesMarineData
              ? _water
              : null,
          allowAutomaticTide: widget.waterArea.providesMarineData,
          allowAutomaticWaterTemperature: widget.waterArea.providesMarineData,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _weatherRevision++;
    _waterRevision++;
    _network.removeListener(_onNetworkChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nearby = widget.waterArea.providesMarineData
        ? TideStationCatalog().nearby(_location, limit: 1)
        : const <TideStation>[];
    final tideName = nearby.isEmpty
        ? null
        : TideName.calculate(
            day: TideDay.fromInstant(_requestedAt),
            station: nearby.first,
          );
    return Scaffold(
      appBar: AppBar(title: const Text('과거 정보 조회')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              widget.selectedLocation,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              key: const ValueKey('history-date'),
              onPressed: _pickDate,
              icon: const Icon(Icons.calendar_month_outlined),
              label: Text(
                '${_selectedDate.year}.'
                '${_selectedDate.month.toString().padLeft(2, '0')}.'
                '${_selectedDate.day.toString().padLeft(2, '0')}',
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              key: ValueKey('history-hour-$_selectedDate-$_selectedHour'),
              initialValue: _selectedHour,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: '조회 시간 (KST)',
                border: OutlineInputBorder(),
              ),
              items: [
                for (var hour = 0; hour <= _maxHour(_selectedDate); hour++)
                  DropdownMenuItem(
                    value: hour,
                    child: Text('${hour.toString().padLeft(2, '0')}:00'),
                  ),
              ],
              onChanged: (hour) {
                if (hour == null || hour == _selectedHour) return;
                setState(() => _selectedHour = hour);
                _reload();
              },
            ),
            const SizedBox(height: 16),
            if (!_location.hasCoordinates)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text('지도에서 좌표가 있는 위치를 선택해 주세요.'),
              ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '과거 날씨·낚시 정보',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 16),
                    if (_weatherLoading || _waterLoading) ...[
                      const LinearProgressIndicator(),
                      const SizedBox(height: 12),
                    ],
                    WeatherDataCard(
                      embedded: true,
                      waterArea: widget.waterArea,
                      historicalWeather: _weather,
                      historicalWaterTemperature:
                          widget.waterArea.providesMarineData ? _water : null,
                      tideName: tideName,
                    ),
                    if (_weatherFailure != null && _location.hasCoordinates)
                      _HistoryRetry(
                        label: '날씨 다시 조회',
                        onRetry: _network.isDisconnected
                            ? null
                            : () => unawaited(_loadWeather(force: true)),
                      ),
                    if (_waterFailure != null &&
                        widget.waterArea.providesMarineData &&
                        _location.hasCoordinates)
                      _HistoryRetry(
                        label: '수온 다시 조회',
                        onRetry: _network.isDisconnected
                            ? null
                            : () => unawaited(_loadWater(force: true)),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _openRecord,
              icon: const Icon(Icons.edit_note),
              label: const Text('이 정보로 기록 작성'),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryRetry extends StatelessWidget {
  const _HistoryRetry({required this.label, this.onRetry});
  final String label;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton.icon(
      onPressed: onRetry,
      icon: const Icon(Icons.refresh),
      label: Text(label),
    ),
  );
}
