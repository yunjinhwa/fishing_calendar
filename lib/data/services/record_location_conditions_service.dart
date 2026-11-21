import '../../core/validation/fishing_record_validator.dart';
import '../history/historical_conditions.dart';
import '../history/historical_conditions_service.dart';
import '../history/khoa_historical_water_temperature_service.dart';
import '../history/kma_historical_weather_service.dart';
import '../maps/map_location.dart';
import '../maps/open_map_water_service.dart';
import '../maps/water_area_service.dart';
import '../water_temperature/khoa_water_temperature_service.dart';
import '../water_temperature/water_temperature_service.dart';
import 'external_data_service.dart';
import 'kma_weather_service.dart';

typedef RecordLocationWeather = ({String? weather, double? airTemperature});

/// Selects external readings that match the record's place and start time.
class RecordLocationConditionsService {
  const RecordLocationConditionsService({
    ExternalDataService? weatherService,
    HistoricalWeatherService? historicalWeatherService,
    WaterAreaService? waterAreaService,
    WaterTemperatureService? waterTemperatureService,
    HistoricalWaterTemperatureService? historicalWaterTemperatureService,
    DateTime Function()? clock,
  }) : _weatherService = weatherService,
       _historicalWeatherService = historicalWeatherService,
       _waterAreaService = waterAreaService,
       _waterTemperatureService = waterTemperatureService,
       _historicalWaterTemperatureService = historicalWaterTemperatureService,
       _clock = clock;

  static const instance = RecordLocationConditionsService();

  final ExternalDataService? _weatherService;
  final HistoricalWeatherService? _historicalWeatherService;
  final WaterAreaService? _waterAreaService;
  final WaterTemperatureService? _waterTemperatureService;
  final HistoricalWaterTemperatureService? _historicalWaterTemperatureService;
  final DateTime Function()? _clock;

  DateTime get _now => (_clock ?? DateTime.now)();

  Future<RecordLocationWeather?> fetchWeather(
    MapLocation location,
    DateTime startAt,
  ) async {
    final hour = historicalHour(startAt);
    final currentHour = historicalHour(_now);
    if (!location.hasCoordinates || hour.isAfter(currentHour)) return null;

    if (hour.isBefore(currentHour)) {
      final observation =
          await (_historicalWeatherService ??
                  KmaHistoricalWeatherService.instance)
              .fetchAt(location: location, requestedAt: startAt);
      if (!observation.matchesSelection(location, startAt)) return null;
      return _validWeather(observation.weather, observation.airTemperature);
    }
    final forecast = await (_weatherService ?? KmaWeatherService.instance)
        .fetchCurrentData(location: location);
    if (!forecast.appliesToRecord(
      startAt: startAt,
      locationName: location.name,
      latitude: location.latitude,
      longitude: location.longitude,
    )) {
      return null;
    }
    return _validWeather(forecast.weather, forecast.airTemperature);
  }

  Future<bool> isMarine(MapLocation location) async {
    if (!location.hasCoordinates) return false;
    final area = await (_waterAreaService ?? OpenMapWaterService.instance)
        .classify(location);
    return area.providesMarineData;
  }

  /// Call after marine classification has confirmed the selected location.
  Future<double?> fetchMarineWaterTemperature(
    MapLocation location,
    DateTime startAt,
  ) async {
    final hour = historicalHour(startAt);
    final currentHour = historicalHour(_now);
    if (!location.hasCoordinates || hour.isAfter(currentHour)) return null;

    if (hour.isBefore(currentHour)) {
      final observation =
          await (_historicalWaterTemperatureService ??
                  KhoaHistoricalWaterTemperatureService.instance)
              .fetchAt(location: location, requestedAt: startAt);
      return observation.matchesSelection(location, startAt)
          ? observation.temperatureCelsius
          : null;
    }
    final observation =
        await (_waterTemperatureService ?? KhoaWaterTemperatureService.instance)
            .fetchCurrentData(location: location);
    return observation.appliesToRecord(
          startAt: startAt,
          locationName: location.name,
          latitude: location.latitude,
          longitude: location.longitude,
          now: _now,
        )
        ? observation.temperatureCelsius
        : null;
  }

  RecordLocationWeather? _validWeather(String? weather, double? temperature) {
    final text = weather?.trim();
    final validWeather =
        text != null &&
            text.isNotEmpty &&
            text.length <= FishingRecordValidator.maxWeatherLength
        ? text
        : null;
    final validTemperature =
        temperature != null && temperature.isFinite && temperature.abs() < 100
        ? temperature
        : null;
    if (validWeather == null && validTemperature == null) return null;
    return (weather: validWeather, airTemperature: validTemperature);
  }
}
