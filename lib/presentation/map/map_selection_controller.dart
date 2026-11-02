import 'package:flutter/foundation.dart';

import '../../data/maps/current_location_gateway.dart';
import '../../data/maps/map_location.dart';
import '../../data/maps/map_search_gateway.dart';

/// Coordinates map searches and explicit selections without allowing an older
/// network or permission response to replace the user's newer choice.
class MapSelectionController extends ChangeNotifier {
  MapSelectionController({
    required CurrentLocationGateway locationGateway,
    MapLocation? initialSelection,
  }) : _locationGateway = locationGateway,
       _selection = initialSelection ?? MapLocation(name: '부산 영도구 동삼동');

  final CurrentLocationGateway _locationGateway;
  MapSearchGateway? _gateway;
  MapLocation _selection;
  List<MapLocation> _results = const [];
  bool _isSearching = false;
  bool _isLocating = false;
  bool _isResolving = false;
  String? _errorMessage;
  CurrentLocationFailure? _locationFailure;
  int _searchRevision = 0;
  int _selectionRevision = 0;
  int _gatewayRevision = 0;
  bool _disposed = false;

  MapLocation get selection => _selection;
  List<MapLocation> get results => _results;
  bool get isSearching => _isSearching;
  bool get isLocating => _isLocating;
  bool get isResolving => _isResolving;
  String? get errorMessage => _errorMessage;
  CurrentLocationFailure? get locationFailure => _locationFailure;
  bool get isMapReady => _gateway != null;

  void setGateway(MapSearchGateway? gateway) {
    if (_disposed || identical(gateway, _gateway)) return;
    _gateway = gateway;
    _gatewayRevision++;
    _searchRevision++;
    _isSearching = false;
    _isResolving = false;
    _results = const [];
    if (_locationFailure == null) _errorMessage = null;
    notifyListeners();
  }

  Future<void> search(String keyword) async {
    if (_disposed) return;
    final revision = ++_searchRevision;
    final gatewayRevision = _gatewayRevision;
    final gateway = _gateway;
    _cancelPointWork();
    _resetErrors();
    _results = const [];
    final query = keyword.trim();
    if (query.isEmpty) {
      _errorMessage = '검색할 장소나 주소를 입력하세요.';
      _isSearching = false;
      notifyListeners();
      return;
    }
    if (gateway == null) {
      _errorMessage = '지도가 준비된 뒤 다시 검색해 주세요.';
      _isSearching = false;
      notifyListeners();
      return;
    }
    bool current() =>
        !_disposed &&
        revision == _searchRevision &&
        gatewayRevision == _gatewayRevision &&
        identical(gateway, _gateway);
    _isSearching = true;
    notifyListeners();
    try {
      if (!current()) return;
      final found = await gateway.search(query);
      if (!current()) return;
      _results = List.unmodifiable(
        found.where((place) => place.hasCoordinates),
      );
      if (_results.isEmpty) {
        _errorMessage = '검색 결과가 없습니다. 다른 장소나 주소로 검색해 주세요.';
      } else {
        _selection = _results.first;
      }
    } on Object {
      if (!current()) return;
      _errorMessage = '장소를 검색하지 못했습니다. 연결 상태를 확인하고 다시 시도해 주세요.';
    } finally {
      if (current()) {
        _isSearching = false;
        notifyListeners();
      }
    }
  }

  void selectLocation(MapLocation location) {
    if (_disposed) return;
    _beginPointSelection();
    _selection = location;
    notifyListeners();
  }

  Future<void> selectCoordinates(double latitude, double longitude) async {
    if (_disposed) return;
    final revision = _beginPointSelection();
    try {
      _selection = MapLocation(
        name: '지도에서 선택한 위치',
        latitude: latitude,
        longitude: longitude,
      );
    } on ArgumentError {
      _errorMessage = '올바른 지도 위치를 선택해 주세요.';
      notifyListeners();
      return;
    }
    await _resolveSelection(_selection, revision);
  }

  Future<void> useCurrentLocation({bool requestPermission = true}) async {
    if (_disposed) return;
    final revision = _beginPointSelection();
    bool current() => !_disposed && revision == _selectionRevision;
    _isLocating = true;
    notifyListeners();
    try {
      if (!current()) return;
      final point = await _locationGateway.currentLocation(
        requestPermission: requestPermission,
      );
      if (!current()) return;
      if (!point.hasCoordinates) {
        throw const CurrentLocationException(
          CurrentLocationFailure.unavailable,
        );
      }
      _isLocating = false;
      _selection = point;
      await _resolveSelection(point, revision);
    } on CurrentLocationException catch (error) {
      if (!current()) return;
      if (!requestPermission &&
          error.reason != CurrentLocationFailure.timedOut) {
        return;
      }
      _locationFailure = error.reason;
      _errorMessage = _locationErrorMessage(error.reason);
    } on Object {
      if (!current()) return;
      if (!requestPermission) return;
      _locationFailure = CurrentLocationFailure.unavailable;
      _errorMessage = _locationErrorMessage(CurrentLocationFailure.unavailable);
    } finally {
      if (current()) {
        _isLocating = false;
        notifyListeners();
      }
    }
  }

  void cancelPendingLocation() {
    if (_disposed || (!_isLocating && !_isResolving)) return;
    _cancelPointWork();
    notifyListeners();
  }

  Future<void> _resolveSelection(MapLocation point, int revision) async {
    final gateway = _gateway;
    final gatewayRevision = _gatewayRevision;
    bool current() =>
        !_disposed &&
        revision == _selectionRevision &&
        gatewayRevision == _gatewayRevision &&
        identical(gateway, _gateway);
    if (gateway == null) {
      notifyListeners();
      return;
    }
    _isResolving = true;
    notifyListeners();
    try {
      if (!current()) return;
      final address = (await gateway.addressForCoordinates(
        point.latitude!,
        point.longitude!,
      ))?.trim();
      if (!current()) return;
      if (address != null && address.isNotEmpty) {
        _selection = MapLocation(
          name: address.length > 200 ? address.substring(0, 200) : address,
          address: address,
          latitude: point.latitude,
          longitude: point.longitude,
        );
      }
    } on Object {
      if (!current()) return;
      _errorMessage = '주소를 가져오지 못했습니다. 선택한 위치의 좌표는 유지됩니다.';
    } finally {
      if (current()) {
        _isResolving = false;
        notifyListeners();
      }
    }
  }

  int _beginPointSelection() {
    _searchRevision++;
    _isSearching = false;
    _results = const [];
    _resetErrors();
    _cancelPointWork();
    return _selectionRevision;
  }

  void _cancelPointWork() {
    _selectionRevision++;
    _isLocating = false;
    _isResolving = false;
  }

  void _resetErrors() {
    _errorMessage = null;
    _locationFailure = null;
  }

  void clearError() {
    if (_disposed || (_errorMessage == null && _locationFailure == null)) {
      return;
    }
    _resetErrors();
    notifyListeners();
  }

  Future<bool> openAppSettings() =>
      _openSettings(_locationGateway.openAppSettings);

  Future<bool> openLocationSettings() =>
      _openSettings(_locationGateway.openLocationSettings);

  Future<bool> _openSettings(Future<bool> Function() open) async {
    if (_disposed) return false;
    try {
      final opened = await open();
      return !_disposed && opened;
    } on Object {
      return false;
    }
  }

  static String _locationErrorMessage(
    CurrentLocationFailure reason,
  ) => switch (reason) {
    CurrentLocationFailure.denied => '현재 위치를 사용하려면 위치 권한을 허용해 주세요.',
    CurrentLocationFailure.deniedForever => '위치 권한이 차단되어 있습니다. 앱 설정에서 허용해 주세요.',
    CurrentLocationFailure.serviceDisabled => '기기의 위치 서비스를 켠 뒤 다시 시도해 주세요.',
    CurrentLocationFailure.timedOut => '현재 위치를 확인하는 데 시간이 걸립니다. 다시 시도해 주세요.',
    CurrentLocationFailure.unavailable =>
      '현재 위치를 가져오지 못했습니다. 지도에서 위치를 선택하거나 직접 입력해 주세요.',
  };

  @override
  void dispose() {
    _disposed = true;
    _gateway = null;
    _searchRevision++;
    _selectionRevision++;
    _gatewayRevision++;
    super.dispose();
  }
}
