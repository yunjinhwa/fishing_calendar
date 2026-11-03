import '../maps/map_location.dart';
import 'khoa_tide_stations.dart';
import 'tide_models.dart';

class TideStationCatalog {
  TideStationCatalog({List<TideStation>? stations})
    : stations = List.unmodifiable(stations ?? khoaTideStations);

  final List<TideStation> stations;

  List<TideStation> nearby(
    MapLocation location, {
    double maxDistanceKm = 50,
    int limit = 5,
  }) {
    if (!location.hasCoordinates ||
        !maxDistanceKm.isFinite ||
        maxDistanceKm <= 0 ||
        limit <= 0) {
      return const [];
    }
    final candidates = <({TideStation station, double distance})>[
      for (final station in stations)
        (
          station: station,
          distance: station.distanceKmTo(
            location.latitude!,
            location.longitude!,
          ),
        ),
    ]..removeWhere((entry) => entry.distance > maxDistanceKm);
    candidates.sort((a, b) {
      final distanceOrder = a.distance.compareTo(b.distance);
      return distanceOrder != 0
          ? distanceOrder
          : a.station.code.compareTo(b.station.code);
    });
    return List.unmodifiable(
      candidates.take(limit).map((entry) => entry.station),
    );
  }
}
