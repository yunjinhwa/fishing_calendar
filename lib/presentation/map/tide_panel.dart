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
import '../../data/water_temperature/water_temperature_models.dart';
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
    this.waterTemperatureObservation,
    this.waterTemperatureLoading = false,
    this.waterTemperatureError,
    this.onRetryWaterTemperature,
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
  final WaterTemperatureObservation? waterTemperatureObservation;
  final bool waterTemperatureLoading;
  final String? waterTemperatureError;
  final VoidCallback? onRetryWaterTemperature;

  @override
  State<TidePanel> createState() => _TidePanelState();
}

class _TidePanelState extends State<TidePanel>
    with AutomaticKeepAliveClientMixin<TidePanel>, WidgetsBindingObserver {
  static const _retryDelay = Duration(minutes: 5);
  final _network = NetworkStatusService.instance;
  final _inFlight = <(TideService, String, TideDay), Future<TideForecast>>{};
  late TideDay _day;
  late bool _appResumed;
  Timer? _freshnessTimer;
  List<TideStation> _stations = const [];
  TideStation? _station;
  TideRecordReference? _reference;
  TideForecast? _forecast;
  TideFailure? _failure;
  DateTime? _retryAfter;
  bool _automaticRetryBlocked = false;
  String? _message;
  bool _loading = false;
  bool _followsToday = true;
  bool _wasDisconnected = false;
  int _generation = 0;
  int _notification = 0;

  TideService get _service => widget.service ?? KhoaTideService.instance;
  DateTime get _now => (widget.clock ?? DateTime.now)().toUtc();
  Duration get _forecastLifetime => switch (_service) {
    KhoaTideService service => service.cacheTtl,
    _ => const Duration(minutes: 10),
  };
  bool get _canRefresh =>
      mounted &&
      widget.isActive &&
      _appResumed &&
      widget.waterArea.providesMarineData &&
      _station != null;

  @override
  bool get wantKeepAlive => widget.isActive;

  @override
  void initState() {
    super.initState();
    _day = TideDay.fromInstant(_now);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _appResumed = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
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
    final changedClock = oldWidget.clock != widget.clock;
    if (changedActive) updateKeepAlive();
    if (!moved && !changedSource && !changedActive && !changedArea) {
      if (changedClock) _scheduleLoad();
      return;
    }
    final changedContext = moved || changedSource || changedArea;
    if (changedContext) _selectNearby();
    _invalidate(clearForecast: changedContext, resetRetry: changedContext);
    if (widget.isActive) _scheduleLoad();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    if (_appResumed == resumed) return;
    _appResumed = resumed;
    _freshnessTimer?.cancel();
    if (resumed) {
      // Retained background results must repaint even when a retry cooldown
      // prevents starting another request.
      setState(() {});
      _refreshIfNeeded();
    } else {
      // A still-running request can be reused on resume, but cannot publish
      // into a hidden screen in the meantime.
      _generation++;
      _loading = false;
    }
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
        _refreshIfNeeded();
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

  void _invalidate({bool clearForecast = true, bool resetRetry = true}) {
    _freshnessTimer?.cancel();
    _generation++;
    _loading = false;
    if (clearForecast) _forecast = null;
    if (resetRetry) {
      _failure = null;
      _retryAfter = null;
      _automaticRetryBlocked = false;
    }
    _publish(null);
  }

  bool _isFresh(TideForecast? forecast, DateTime now) {
    if (forecast == null) return false;
    final age = now.difference(forecast.fetchedAt.toUtc());
    return !age.isNegative && age < _forecastLifetime;
  }

  void _refreshIfNeeded({bool forceRefresh = false}) {
    if (!_canRefresh) return;
    final now = _now;
    final today = TideDay.fromInstant(now);
    if (_followsToday && _day != today) {
      setState(() {
        _day = today;
        _invalidate(resetRetry: !_automaticRetryBlocked);
      });
    }
    if (_loading) return;
    if (!forceRefresh && _isFresh(_forecast, now)) {
      if (_reference == null && !_network.isDisconnected) {
        setState(() {
          _publish(
            TideRecordReference(
              location: widget.location,
              forecast: _forecast!,
            ),
          );
        });
      }
      _scheduleFreshnessCheck();
      return;
    }
    if (_automaticRetryBlocked ||
        (_retryAfter != null && now.isBefore(_retryAfter!))) {
      _scheduleFreshnessCheck();
      return;
    }
    unawaited(_load(forceRefresh: forceRefresh));
  }

  void _scheduleFreshnessCheck() {
    _freshnessTimer?.cancel();
    if (!_canRefresh) return;
    final now = _now;
    DateTime? nextCheck;
    if (_followsToday) {
      final kst = now.add(const Duration(hours: 9));
      nextCheck = DateTime.utc(
        kst.year,
        kst.month,
        kst.day + 1,
      ).subtract(const Duration(hours: 9));
    }
    if (!_network.isDisconnected && !_loading && !_automaticRetryBlocked) {
      var expiresAt =
          _forecast?.fetchedAt.toUtc().add(_forecastLifetime) ?? now;
      final retryAfter = _retryAfter;
      if (retryAfter != null && retryAfter.isAfter(expiresAt)) {
        expiresAt = retryAfter;
      }
      if (nextCheck == null || expiresAt.isBefore(nextCheck)) {
        nextCheck = expiresAt;
      }
    }
    if (nextCheck == null) return;
    final delay = nextCheck.difference(now);
    _freshnessTimer = Timer(
      delay <= Duration.zero ? const Duration(milliseconds: 1) : delay,
      _refreshIfNeeded,
    );
  }

  void _onNetworkChanged() {
    final disconnected = _network.isDisconnected;
    final recovered = _wasDisconnected && _network.isConnected;
    if (disconnected) _wasDisconnected = true;
    if (recovered) _wasDisconnected = false;
    if (!mounted) return;
    if (disconnected) {
      setState(() {
        _invalidate(resetRetry: false);
        if (_station != null) {
          _message = '인터넷에 연결하면 만조·간조 예보를 조회할 수 있습니다.';
        }
      });
      _scheduleFreshnessCheck();
    } else if (recovered) {
      _refreshIfNeeded(forceRefresh: true);
    }
  }

  Future<void> _load({bool forceRefresh = false}) async {
    if (!_canRefresh || _loading) return;
    _freshnessTimer?.cancel();
    final service = _service;
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
    _scheduleFreshnessCheck();
    if (_network.isDisconnected) {
      return;
    }
    try {
      final key = (service, station.code, day);
      final operation = _inFlight.putIfAbsent(key, () {
        return Future.sync(
          () => service.fetchForecast(
            station: station,
            day: day,
            forceRefresh: forceRefresh,
          ),
        ).whenComplete(() {
          _inFlight.remove(key);
        });
      });
      final forecast = await operation;
      if (forecast.station.code != station.code || forecast.day != day) {
        throw const TideException(TideFailure.invalidResponse);
      }
      if (forecast.events.isEmpty) {
        throw const TideException(TideFailure.noData);
      }
      if (!_isCurrent(generation)) {
        if (_matchesSelection(service, station, day, location) &&
            !_network.isDisconnected) {
          _forecast = forecast;
          _retryAfter = _isFresh(forecast, _now) ? null : _now.add(_retryDelay);
          _automaticRetryBlocked = false;
        }
        return;
      }
      setState(() {
        _loading = false;
        _forecast = forecast;
        _retryAfter = _isFresh(forecast, _now) ? null : _now.add(_retryDelay);
        _automaticRetryBlocked = false;
        _publish(TideRecordReference(location: location, forecast: forecast));
      });
    } on TideException catch (error) {
      if (!_isCurrent(generation)) {
        if (_matchesSelection(service, station, day, location)) {
          _recordFailure(error.reason);
        }
        return;
      }
      setState(() {
        _loading = false;
        _recordFailure(error.reason);
        _publish(null);
      });
    } on Object {
      if (!_isCurrent(generation)) {
        if (_matchesSelection(service, station, day, location)) {
          _recordFailure(TideFailure.network);
        }
        return;
      }
      setState(() {
        _loading = false;
        _recordFailure(TideFailure.network);
        _message = '만조·간조 예보를 가져오지 못했습니다. 잠시 후 다시 조회해 주세요.';
        _publish(null);
      });
    } finally {
      if (_isCurrent(generation)) _scheduleFreshnessCheck();
    }
  }

  void _recordFailure(TideFailure failure) {
    _failure = failure;
    _message = TideException(failure).message;
    _retryAfter = _now.add(_retryDelay);
    _automaticRetryBlocked =
        failure == TideFailure.configuration ||
        failure == TideFailure.unauthorized;
  }

  bool _matchesSelection(
    TideService service,
    TideStation station,
    TideDay day,
    MapLocation location,
  ) =>
      mounted &&
      service == _service &&
      station.code == _station?.code &&
      day == _day &&
      _sameLocation(location, widget.location);

  bool _isCurrent(int generation) =>
      mounted &&
      widget.isActive &&
      _appResumed &&
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
    if (day == _day) {
      _followsToday = false;
      _scheduleFreshnessCheck();
      return;
    }
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
    _freshnessTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
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
      clock: widget.clock,
      waterArea: widget.waterArea,
      waterAreaSelector: widget.waterAreaSelector,
      weatherData: widget.weatherData,
      weatherLoading: widget.weatherLoading,
      weatherError: widget.weatherError,
      onRetryWeather: widget.onRetryWeather,
      waterTemperatureObservation: marine
          ? widget.waterTemperatureObservation
          : null,
      waterTemperatureLoading: marine && widget.waterTemperatureLoading,
      waterTemperatureError: marine ? widget.waterTemperatureError : null,
      onRetryWaterTemperature: marine ? widget.onRetryWaterTemperature : null,
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
