import 'package:fishing_build/data/history/historical_conditions.dart';
import 'package:fishing_build/data/history/historical_conditions_service.dart';
import 'package:fishing_build/data/maps/map_location.dart';
import 'package:fishing_build/data/maps/water_area.dart';
import 'package:fishing_build/data/maps/water_area_service.dart';
import 'package:fishing_build/data/models/external_data.dart';
import 'package:fishing_build/data/services/external_data_service.dart';
import 'package:fishing_build/data/services/record_location_conditions_service.dart';
import 'package:fishing_build/data/water_temperature/water_temperature_models.dart';
import 'package:fishing_build/data/water_temperature/water_temperature_service.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime.utc(2026, 11, 21, 7, 45);
final _coast = MapLocation(name: '테스트 방파제', latitude: 35.1, longitude: 129.0);
const _waterStation = WaterTemperatureStation(
  code: 'station',
  name: '수온 관측소',
  latitude: 35.1,
  longitude: 129.0,
);

void main() {
  late _CurrentWeather currentWeather;
  late _HistoricalWeather historicalWeather;
  late _WaterAreaClassifier classifier;
  late _CurrentWater currentWater;
  late _HistoricalWater historicalWater;
  late RecordLocationConditionsService service;

  setUp(() {
    currentWeather = _CurrentWeather();
    historicalWeather = _HistoricalWeather();
    classifier = _WaterAreaClassifier();
    currentWater = _CurrentWater();
    historicalWater = _HistoricalWater();
    service = RecordLocationConditionsService(
      weatherService: currentWeather,
      historicalWeatherService: historicalWeather,
      waterAreaService: classifier,
      waterTemperatureService: currentWater,
      historicalWaterTemperatureService: historicalWater,
      clock: () => _now,
    );
  });

  test(
    'uses current forecast and observation within the current hour',
    () async {
      final startAt = DateTime.utc(2026, 11, 21, 7, 35);
      expect(await service.fetchWeather(_coast, startAt), (
        weather: '맑음',
        airTemperature: 16.0,
      ));
      expect(await service.fetchMarineWaterTemperature(_coast, startAt), 18.0);
      expect(currentWeather.locations.single, same(_coast));
      expect(currentWater.locations.single, same(_coast));
      expect(historicalWeather.requests, isEmpty);
      expect(historicalWater.requests, isEmpty);
    },
  );

  test('past records look up conditions for the exact start time', () async {
    final startAt = DateTime.utc(2026, 11, 20, 15, 22);
    expect(await service.fetchWeather(_coast, startAt), (
      weather: '흐림',
      airTemperature: 13.0,
    ));
    expect(await service.fetchMarineWaterTemperature(_coast, startAt), 17.5);
    expect(historicalWeather.requests.single, (_coast, startAt));
    expect(historicalWater.requests.single, (_coast, startAt));
    expect(currentWeather.locations, isEmpty);
    expect(currentWater.locations, isEmpty);
  });

  test(
    'filters mismatched readings and returns valid partial weather',
    () async {
      currentWeather.validAt = DateTime.utc(2026, 11, 21, 6);
      expect(await service.fetchWeather(_coast, _now), isNull);
      currentWeather.validAt = historicalHour(_now);
      currentWeather.temperature = double.nan;
      expect(await service.fetchWeather(_coast, _now), (
        weather: '맑음',
        airTemperature: null,
      ));
      expect(
        await service.fetchMarineWaterTemperature(
          _coast,
          DateTime.utc(2026, 11, 21, 7, 5),
        ),
        isNull,
        reason: 'The measurement at 07:20 cannot describe a record at 07:05.',
      );
      historicalWater.selectedLocation = MapLocation(
        name: _coast.name,
        latitude: 35.4,
        longitude: 129.5,
      );
      expect(
        await service.fetchMarineWaterTemperature(
          _coast,
          DateTime.utc(2026, 11, 20, 15, 22),
        ),
        isNull,
      );
    },
  );

  test('skips future hours and locations without coordinates', () async {
    final future = DateTime.utc(2026, 11, 21, 8);
    final manual = MapLocation(name: '직접 입력');
    expect(await service.fetchWeather(_coast, future), isNull);
    expect(await service.fetchMarineWaterTemperature(_coast, future), isNull);
    expect(await service.fetchWeather(manual, _now), isNull);
    expect(await service.fetchMarineWaterTemperature(manual, _now), isNull);
    expect(await service.isMarine(manual), isFalse);
    expect(currentWeather.locations, isEmpty);
    expect(currentWater.locations, isEmpty);
    expect(historicalWeather.requests, isEmpty);
    expect(historicalWater.requests, isEmpty);
    expect(classifier.locations, isEmpty);
  });

  test('only a confirmed marine location permits marine data', () async {
    for (final area in WaterArea.values) {
      classifier.area = area;
      expect(await service.isMarine(_coast), area == WaterArea.marine);
    }
    expect(classifier.locations, hasLength(WaterArea.values.length));
  });
}

class _CurrentWeather implements ExternalDataService {
  final locations = <MapLocation>[];
  DateTime validAt = historicalHour(_now);
  double temperature = 16;

  @override
  Future<ExternalData> fetchCurrentData({
    required MapLocation location,
    bool forceRefresh = false,
  }) async {
    locations.add(location);
    return ExternalData(
      locationName: location.name,
      latitude: location.latitude!,
      longitude: location.longitude!,
      gridX: 98,
      gridY: 74,
      issuedAt: validAt,
      validAt: validAt,
      fetchedAt: _now,
      weather: ' 맑음 ',
      airTemperature: temperature,
    );
  }
}

class _HistoricalWeather implements HistoricalWeatherService {
  final requests = <(MapLocation, DateTime)>[];

  @override
  Future<HistoricalWeatherObservation> fetchAt({
    required MapLocation location,
    required DateTime requestedAt,
    bool forceRefresh = false,
  }) async {
    requests.add((location, requestedAt));
    return HistoricalWeatherObservation(
      location: location,
      station: const HistoricalWeatherStation(
        code: 'weather',
        name: '기상 관측소',
        latitude: 35.1,
        longitude: 129.0,
      ),
      requestedAt: requestedAt,
      observedAt: historicalHour(requestedAt),
      fetchedAt: _now,
      weather: '흐림',
      airTemperature: 13,
    );
  }
}

class _WaterAreaClassifier implements WaterAreaService {
  final locations = <MapLocation>[];
  WaterArea area = WaterArea.unknown;

  @override
  Future<WaterArea> classify(
    MapLocation location, {
    bool forceRefresh = false,
  }) async {
    locations.add(location);
    return area;
  }
}

class _CurrentWater implements WaterTemperatureService {
  final locations = <MapLocation>[];

  @override
  Future<WaterTemperatureObservation> fetchCurrentData({
    required MapLocation location,
    bool forceRefresh = false,
  }) async {
    locations.add(location);
    return WaterTemperatureObservation(
      location: location,
      station: _waterStation,
      observedAt: DateTime.utc(2026, 11, 21, 7, 20),
      fetchedAt: _now,
      temperatureCelsius: 18,
    );
  }
}

class _HistoricalWater implements HistoricalWaterTemperatureService {
  final requests = <(MapLocation, DateTime)>[];
  MapLocation? selectedLocation;

  @override
  Future<HistoricalWaterTemperatureObservation> fetchAt({
    required MapLocation location,
    required DateTime requestedAt,
    bool forceRefresh = false,
  }) async {
    requests.add((location, requestedAt));
    return HistoricalWaterTemperatureObservation(
      location: selectedLocation ?? location,
      station: _waterStation,
      requestedAt: requestedAt,
      observedAt: requestedAt.subtract(const Duration(minutes: 5)),
      fetchedAt: _now,
      temperatureCelsius: 17.5,
    );
  }
}
