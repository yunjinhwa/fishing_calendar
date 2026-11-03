import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/maps/map_location.dart';
import '../../data/maps/water_area.dart';
import '../../data/models/external_data.dart';
import '../../data/services/network_status_service.dart';
import '../../data/tides/khoa_tide_service.dart';
import '../../data/tides/tide_models.dart';
import '../../data/tides/tide_name.dart';
import '../../data/tides/tide_service.dart';
import '../../data/tides/tide_station_catalog.dart';
import 'location_conditions_card.dart';

class TidePanel extends StatefulWidget {
  const TidePanel({
    super.key,
    required this.location,
    this.isActive = true,
    this.service,
    this.catalog,
    this.onReferenceChanged,
    this.onTideNameChanged,
    this.waterArea = WaterArea.unknown,
    this.waterAreaSelector,
    this.weatherData,
    this.weatherLoading = false,
    this.weatherError,
    this.onRetryWeather,
    this.clock,
  });

  final MapLocation location;
  final bool isActive;
  final TideService? service;
  final TideStationCatalog? catalog;
  final ValueChanged<TideRecordReference?>? onReferenceChanged;
  final ValueChanged<TideName?>? onTideNameChanged;
  final WaterArea waterArea;
  final Widget? waterAreaSelector;
  final ExternalData? weatherData;
  final bool weatherLoading;
  final String? weatherError;
  final VoidCallback? onRetryWeather;
  final DateTime Function()? clock;

  @override
  State<TidePanel> createState() => _TidePanelState();
}

class _TidePanelState extends State<TidePanel>
    with AutomaticKeepAliveClientMixin<TidePanel> {
  final _network = NetworkStatusService.instance;
  late TideDay _day;
  List<TideStation> _stations = const [];
  TideStation? _station;
  TideRecordReference? _reference;
  TideFailure? _failure;
  String? _message;
  bool _loading = false;
  bool _followsToday = true;
  bool _wasDisconnected = false;
  int _generation = 0;
  int _notification = 0;

  TideService get _service => widget.service ?? KhoaTideService.instance;

  @override
  bool get wantKeepAlive => widget.isActive;

  @override
  void initState() {
    super.initState();
    _day = TideDay.fromInstant((widget.clock ?? DateTime.now)());
    _wasDisconnected = _network.isDisconnected;
    _network.addListener(_onNetworkChanged);
    _selectNearby();
    _scheduleLoad();
  }

  @override
  void didUpdateWidget(TidePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final moved = !_sameLocation(oldWidget.location, widget.location);
    final changedSource =
        oldWidget.service != widget.service ||
        oldWidget.catalog != widget.catalog;
    final changedActive = oldWidget.isActive != widget.isActive;
    final changedArea = oldWidget.waterArea != widget.waterArea;
    if (changedActive) updateKeepAlive();
    if (!moved && !changedSource && !changedActive && !changedArea) return;
    if (changedActive && widget.isActive && _followsToday) {
      _day = TideDay.fromInstant((widget.clock ?? DateTime.now)());
    }
    if (moved || changedSource || changedArea) _selectNearby();
    _invalidate();
    if (widget.isActive) _scheduleLoad();
  }

  void _selectNearby() {
    _stations = widget.waterArea.providesMarineData
        ? (widget.catalog ?? TideStationCatalog()).nearby(widget.location)
        : const [];
    _station = _stations.isEmpty ? null : _stations.first;
    _message = widget.waterArea.providesMarineData && _station == null
        ? '제공되지 않음'
        : null;
  }

  void _scheduleLoad() {
    final generation = _generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && generation == _generation && widget.isActive) {
        unawaited(_load());
      }
    });
  }

  void _publish(TideRecordReference? reference) {
    _reference = reference;
    final location = widget.location;
    final station = _station;
    final tideName =
        widget.isActive &&
            widget.waterArea.providesMarineData &&
            station != null
        ? TideName.calculate(day: _day, station: station)
        : null;
    final notification = ++_notification;
    final generation = _generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          notification != _notification ||
          generation != _generation ||
          !_sameLocation(location, widget.location)) {
        return;
      }
      widget.onReferenceChanged?.call(reference);
      widget.onTideNameChanged?.call(tideName);
    });
  }

  void _invalidate() {
    _generation++;
    _loading = false;
    _failure = null;
    _publish(null);
  }

  void _onNetworkChanged() {
    final disconnected = _network.isDisconnected;
    final recovered = _wasDisconnected && _network.isConnected;
    _wasDisconnected = disconnected;
    if (!mounted) return;
    if (disconnected) {
      setState(() {
        _invalidate();
        if (_station != null) {
          _message = '인터넷에 연결하면 만조·간조 예보를 조회할 수 있습니다.';
        }
      });
    } else if (recovered && widget.isActive) {
      unawaited(_load(forceRefresh: true));
    }
  }

  Future<void> _load({bool forceRefresh = false}) async {
    if (!widget.isActive ||
        !widget.waterArea.providesMarineData ||
        _station == null) {
      return;
    }
    final station = _station!;
    final location = widget.location;
    final day = _day;
    final generation = ++_generation;
    setState(() {
      _publish(null);
      _failure = null;
      _loading = !_network.isDisconnected;
      _message = _network.isDisconnected
          ? '인터넷에 연결하면 만조·간조 예보를 조회할 수 있습니다.'
          : null;
    });
    if (_network.isDisconnected) return;
    try {
      final forecast = await _service.fetchForecast(
        station: station,
        day: day,
        forceRefresh: forceRefresh,
      );
      if (!_isCurrent(generation)) return;
      if (forecast.station.code != station.code || forecast.day != day) {
        throw const TideException(TideFailure.invalidResponse);
      }
      if (forecast.events.isEmpty) {
        throw const TideException(TideFailure.noData);
      }
      setState(() {
        _loading = false;
        _publish(TideRecordReference(location: location, forecast: forecast));
      });
    } on TideException catch (error) {
      if (!_isCurrent(generation)) return;
      setState(() {
        _loading = false;
        _failure = error.reason;
        _message = error.message;
        _publish(null);
      });
    } on Object {
      if (!_isCurrent(generation)) return;
      setState(() {
        _loading = false;
        _failure = TideFailure.network;
        _message = '만조·간조 예보를 가져오지 못했습니다. 잠시 후 다시 조회해 주세요.';
        _publish(null);
      });
    }
  }

  bool _isCurrent(int generation) =>
      mounted &&
      widget.isActive &&
      widget.waterArea.providesMarineData &&
      !_network.isDisconnected &&
      generation == _generation;

  Future<void> _chooseDay() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _day.calendarDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035, 12, 31),
      helpText: '조석 예보 날짜 선택',
    );
    if (!mounted || !widget.isActive || date == null) return;
    final day = TideDay.fromCalendar(date);
    if (day == _day) return;
    setState(() {
      _day = day;
      _followsToday = false;
      _invalidate();
    });
    await _load();
  }

  @override
  void dispose() {
    _generation++;
    _notification++;
    _network.removeListener(_onNetworkChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final reference = _reference;
    final station = _station;
    final marine = widget.waterArea.providesMarineData;
    final tideName = !marine || station == null
        ? null
        : TideName.calculate(day: _day, station: station);
    return LocationConditionsCard(
      waterArea: widget.waterArea,
      waterAreaSelector: widget.waterAreaSelector,
      weatherData: widget.weatherData,
      weatherLoading: widget.weatherLoading,
      weatherError: widget.weatherError,
      onRetryWeather: widget.onRetryWeather,
      tideName: tideName,
      tideForecast: marine ? reference?.forecast : null,
      tideLoading: marine && _loading,
      tideError: marine ? _message : null,
      onRetryTide:
          marine &&
              _failure != null &&
              _failure != TideFailure.configuration &&
              !_network.isDisconnected
          ? () => unawaited(_load(forceRefresh: true))
          : null,
      tideControls: !marine || _stations.isEmpty
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<String>(
                  key: ValueKey('tide-station-${_station?.code}'),
                  initialValue: _station?.code,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '예보 지점'),
                  items: [
                    for (final station in _stations)
                      DropdownMenuItem(
                        value: station.code,
                        child: Text(
                          station.name,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (code) {
                    if (code == null || code == _station?.code) return;
                    setState(() {
                      _station = _stations.firstWhere(
                        (item) => item.code == code,
                      );
                      _invalidate();
                    });
                    unawaited(_load());
                  },
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const ValueKey('tide-date'),
                    onPressed: _chooseDay,
                    icon: const Icon(Icons.calendar_today_outlined, size: 18),
                    label: Text(_day.label),
                  ),
                ),
              ],
            ),
    );
  }
}

bool _sameLocation(MapLocation left, MapLocation right) =>
    left.name == right.name &&
    left.latitude == right.latitude &&
    left.longitude == right.longitude;
