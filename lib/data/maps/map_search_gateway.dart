import 'map_location.dart';

abstract interface class MapSearchGateway {
  Future<List<MapLocation>> search(String keyword);
  Future<String?> addressForCoordinates(double latitude, double longitude);
}
