import 'map_location.dart';
import 'water_area.dart';

abstract interface class WaterAreaService {
  Future<WaterArea> classify(MapLocation location, {bool forceRefresh = false});
}
