import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/validation/fishing_record_validator.dart';
import '../../data/maps/current_location_gateway.dart';
import '../../data/maps/geolocator_current_location_gateway.dart';
import '../../data/maps/kakao_map_configuration.dart';
import '../../data/maps/map_location.dart';
import '../../data/maps/map_search_gateway.dart';
import '../map/kakao_map_canvas.dart';
import '../map/map_selection_controller.dart';

class RecordLocationSearchPage extends StatefulWidget {
  const RecordLocationSearchPage({
    super.key,
    this.initialLocation,
    this.controller,
    this.configuration = const KakaoMapConfiguration(),
    this.mapBuilder,
  });

  final MapLocation? initialLocation;
  final MapSelectionController? controller;
  final KakaoMapConfiguration configuration;
  final MapCanvasBuilder? mapBuilder;

  @override
  State<RecordLocationSearchPage> createState() =>
      _RecordLocationSearchPageState();
}

class _RecordLocationSearchPageState extends State<RecordLocationSearchPage> {
  late final MapSelectionController _controller;
  late final TextEditingController _queryController;
  late final bool _ownsController;
  bool _mayUseSelection = false;
  int _request = 0;
  int _recenterRequest = 0;

  bool get _isBusy =>
      _controller.isSearching ||
      _controller.isLocating ||
      _controller.isResolving;

  bool get _canConfirm =>
      _mayUseSelection && !_isBusy && _controller.selection.hasCoordinates;

  bool get _canLocate =>
      _controller.isMapReady &&
      !_controller.isLocating &&
      !_controller.isResolving;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller =
        widget.controller ??
        MapSelectionController(
          locationGateway: GeolocatorCurrentLocationGateway(),
          initialSelection: widget.initialLocation,
        );
    _queryController = TextEditingController(
      text: widget.initialLocation?.name ?? '',
    );
    _mayUseSelection =
        widget.initialLocation?.hasCoordinates == true &&
        _controller.selection.name == widget.initialLocation?.name &&
        _controller.selection.latitude == widget.initialLocation?.latitude &&
        _controller.selection.longitude == widget.initialLocation?.longitude;
    _controller.addListener(_controllerChanged);
  }

  void _controllerChanged() {
    if (mounted) setState(() {});
  }

  void _gatewayChanged(MapSearchGateway? gateway) {
    if (!mounted) return;
    _request++;
    if (_controller.isMapReady || gateway == null) _mayUseSelection = false;
    _controller.cancelPendingLocation();
    _controller.setGateway(gateway);
    setState(() {});
  }

  void _queryChanged(String _) {
    _request++;
    _mayUseSelection = false;
    // Invalidate an older search before the user submits the next query.
    _controller.selectLocation(_controller.selection);
  }

  Future<void> _search() async {
    final request = ++_request;
    setState(() => _mayUseSelection = false);
    FocusScope.of(context).unfocus();
    await _controller.search(_queryController.text);
    if (!mounted || request != _request) return;
    setState(() {
      _mayUseSelection =
          _controller.results.isNotEmpty &&
          _controller.errorMessage == null &&
          _controller.selection.hasCoordinates;
    });
  }

  void _selectResult(MapLocation location) {
    _request++;
    _mayUseSelection = true;
    _controller.selectLocation(location, preserveSearchResults: true);
    FocusScope.of(context).unfocus();
  }

  Future<void> _selectCoordinates(double latitude, double longitude) async {
    final request = ++_request;
    setState(() => _mayUseSelection = false);
    FocusScope.of(context).unfocus();
    await _controller.selectCoordinates(latitude, longitude);
    if (!mounted || request != _request) return;
    setState(() {
      _mayUseSelection =
          _controller.selection.latitude == latitude &&
          _controller.selection.longitude == longitude &&
          _controller.selection.hasCoordinates;
    });
  }

  Future<void> _useCurrentLocation() async {
    if (!_canLocate) return;
    final request = ++_request;
    setState(() => _mayUseSelection = false);
    FocusScope.of(context).unfocus();
    await _controller.useCurrentLocation();
    if (!mounted || request != _request) return;
    setState(() {
      _mayUseSelection =
          _controller.locationFailure == null &&
          _controller.selection.hasCoordinates;
      if (_mayUseSelection) _recenterRequest = request;
    });
  }

  void _confirm() {
    if (!_canConfirm) return;
    Navigator.of(context).pop<MapLocation>(_controller.selection);
  }

  @override
  void dispose() {
    _request++;
    _controller.removeListener(_controllerChanged);
    if (_ownsController) {
      _controller.dispose();
    } else {
      _controller.cancelPendingLocation();
    }
    _queryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selection = _controller.selection;
    final error = _controller.errorMessage;
    final colors = Theme.of(context).colorScheme;
    final selectedResultIndex = _mayUseSelection
        ? _controller.results.indexOf(selection)
        : -1;
    return Scaffold(
      appBar: AppBar(title: const Text('위치 검색')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              key: const ValueKey('record-location-query'),
              controller: _queryController,
              maxLength: FishingRecordValidator.maxLocationLength,
              onChanged: _queryChanged,
              onSubmitted: (_) => unawaited(_search()),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                labelText: '장소 또는 주소',
                hintText: '예: 흰여울문화마을, 부산 영도구',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  key: const ValueKey('record-location-search'),
                  tooltip: '장소 검색',
                  onPressed: _controller.isMapReady
                      ? () => unawaited(_search())
                      : null,
                  icon: const Icon(Icons.search),
                ),
              ),
            ),
            if (_isBusy) const LinearProgressIndicator(),
            if (error != null) ...[
              const SizedBox(height: 8),
              Semantics(liveRegion: true, child: Text(error)),
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
            ],
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const ValueKey('record-location-current'),
                onPressed: _canLocate ? _useCurrentLocation : null,
                icon: const Icon(Icons.my_location),
                label: const Text('내 위치로 이동'),
              ),
            ),
            const SizedBox(height: 12),
            MapCanvasHost(
              key: const ValueKey('record-location-map'),
              isActive: true,
              child:
                  widget.mapBuilder?.call(
                    selection,
                    _gatewayChanged,
                    (latitude, longitude) =>
                        unawaited(_selectCoordinates(latitude, longitude)),
                  ) ??
                  KakaoMapCanvas(
                    configuration: widget.configuration,
                    selection: selection,
                    onGatewayChanged: _gatewayChanged,
                    onPointSelected: (latitude, longitude) =>
                        unawaited(_selectCoordinates(latitude, longitude)),
                    recenterRequest: _recenterRequest,
                  ),
            ),
            const SizedBox(height: 12),
            if (!_mayUseSelection)
              const Text('검색 결과나 지도에서 위치를 선택한 뒤 아래 버튼을 눌러 주세요.'),
            for (final (index, location) in _controller.results.indexed)
              Card(
                key: ValueKey('record-location-result-outline-$index'),
                margin: const EdgeInsets.only(bottom: 8),
                elevation: 0,
                color: colors.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: index == selectedResultIndex
                        ? colors.primary
                        : colors.outlineVariant,
                    width: index == selectedResultIndex ? 2 : 1,
                  ),
                ),
                child: ListTile(
                  key: ValueKey('record-location-result-$index'),
                  selected: index == selectedResultIndex,
                  leading: const Icon(Icons.location_on_outlined),
                  title: Text(location.name),
                  subtitle: location.address == null
                      ? null
                      : Text(location.address!),
                  onTap: () => _selectResult(location),
                ),
              ),
            const SizedBox(height: 12),
            TextButton(
              key: const ValueKey('record-location-cancel'),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('직접 입력으로 돌아가기'),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.all(16),
        child: FilledButton.icon(
          key: const ValueKey('record-location-confirm'),
          onPressed: _canConfirm ? _confirm : null,
          icon: const Icon(Icons.check),
          label: const Text('이 위치 사용'),
        ),
      ),
    );
  }
}
