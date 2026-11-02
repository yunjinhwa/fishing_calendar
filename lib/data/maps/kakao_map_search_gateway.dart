import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:kakao_map_plugin/kakao_map_plugin.dart';

import '../../core/validation/fishing_record_validator.dart';
import 'map_location.dart';
import 'map_search_gateway.dart';

/// Uses the JavaScript services library with the map's public JavaScript key.
/// Search strings are passed through the plugin's JSON-encoded request APIs.
class KakaoMapSearchGateway implements MapSearchGateway {
  KakaoMapSearchGateway(KakaoMapController controller)
    : this.withRequests(
        keywordSearch: controller.keywordSearch,
        addressSearch: controller.addressSearch,
        reverseGeocode: controller.coord2Address,
      );

  @visibleForTesting
  KakaoMapSearchGateway.withRequests({
    required Future<KeywordSearchResponse> Function(KeywordSearchRequest)
    keywordSearch,
    required Future<AddressSearchResponse> Function(AddressSearchRequest)
    addressSearch,
    required Future<Coord2AddressResponse> Function(Coord2AddressRequest)
    reverseGeocode,
    this.requestTimeout = const Duration(seconds: 12),
  }) : _keywordSearch = keywordSearch,
       _addressSearch = addressSearch,
       _reverseGeocode = reverseGeocode;

  final Future<KeywordSearchResponse> Function(KeywordSearchRequest)
  _keywordSearch;
  final Future<AddressSearchResponse> Function(AddressSearchRequest)
  _addressSearch;
  final Future<Coord2AddressResponse> Function(Coord2AddressRequest)
  _reverseGeocode;
  final Duration requestTimeout;
  bool _disposed = false;

  void dispose() => _disposed = true;

  void _ensureActive() {
    if (_disposed) throw StateError('지도 연결이 종료되었습니다. 다시 지도를 열어 주세요.');
  }

  Future<T> _request<T>(Future<T> Function() operation) async {
    _ensureActive();
    final response = await Future<T>.sync(operation).timeout(requestTimeout);
    _ensureActive();
    return response;
  }

  Future<List<MapLocation>?> _attempt(
    Future<List<MapLocation>> Function() operation,
  ) async {
    try {
      return await operation();
    } on Object {
      return null;
    }
  }

  @override
  Future<List<MapLocation>> search(String keyword) async {
    _ensureActive();
    final query = keyword.trim();
    if (query.isEmpty) return const [];
    if (query.length > FishingRecordValidator.maxLocationLength) {
      throw ArgumentError('검색어는 200자 이하로 입력하세요.');
    }
    final responses = await Future.wait([
      _attempt(() async {
        final result = await _request(
          () => _keywordSearch(KeywordSearchRequest(keyword: query, size: 15)),
        );
        return result.list
            .map(
              (place) => _location(
                name:
                    _text(place.placeName) ??
                    _text(place.roadAddressName) ??
                    place.addressName,
                address: _text(place.roadAddressName) ?? place.addressName,
                x: place.x,
                y: place.y,
              ),
            )
            .whereType<MapLocation>()
            .toList();
      }),
      _attempt(() async {
        final result = await _request(
          () => _addressSearch(AddressSearchRequest(addr: query, size: 15)),
        );
        return result.list
            .map(
              (address) => _location(
                name: address.addressName,
                address:
                    address.roadAddress?.addressName ??
                    address.address?.addressName ??
                    address.addressName,
                x: address.x,
                y: address.y,
              ),
            )
            .whereType<MapLocation>()
            .toList();
      }),
    ]);
    _ensureActive();
    final seen = <(String, double?, double?)>{};
    final locations = <MapLocation>[
      for (final response in responses)
        if (response != null)
          for (final location in response)
            if (seen.add((
              location.name,
              location.latitude,
              location.longitude,
            )))
              location,
    ];
    if (locations.isEmpty && responses.any((response) => response == null)) {
      throw StateError('장소를 검색하지 못했습니다. 잠시 후 다시 시도해 주세요.');
    }
    return List.unmodifiable(locations);
  }

  static String? _text(String? value) {
    final text = value?.trim();
    return text == null || text.isEmpty ? null : text;
  }

  static MapLocation? _location({
    required String? name,
    required String? address,
    required String? x,
    required String? y,
  }) {
    final latitude = double.tryParse(y?.trim() ?? '');
    final longitude = double.tryParse(x?.trim() ?? '');
    final label = _text(name);
    if (label == null ||
        label.length > FishingRecordValidator.maxLocationLength ||
        latitude == null ||
        longitude == null ||
        FishingRecordValidator.validateCoordinates(latitude, longitude) !=
            null) {
      return null;
    }
    return MapLocation(
      name: label,
      address: _text(address),
      latitude: latitude,
      longitude: longitude,
    );
  }

  @override
  Future<String?> addressForCoordinates(
    double latitude,
    double longitude,
  ) async {
    _ensureActive();
    final error = FishingRecordValidator.validateCoordinates(
      latitude,
      longitude,
    );
    if (error != null) throw ArgumentError(error);
    final result = await _request(
      () => _reverseGeocode(Coord2AddressRequest(x: longitude, y: latitude)),
    );
    for (final item in result.list) {
      for (final value in [
        item.roadAddress?.addressName,
        item.address?.addressName,
      ]) {
        final text = _text(value);
        if (text != null &&
            text.length <= FishingRecordValidator.maxLocationLength) {
          return text;
        }
      }
    }
    return null;
  }
}
