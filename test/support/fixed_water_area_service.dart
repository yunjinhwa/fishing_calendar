import 'package:fishing_build/data/maps/map_location.dart';
import 'package:fishing_build/data/maps/water_area.dart';
import 'package:fishing_build/data/maps/water_area_service.dart';

class FixedWaterAreaService implements WaterAreaService {
  const FixedWaterAreaService([this.area = WaterArea.marine]);

  final WaterArea area;

  @override
  Future<WaterArea> classify(
    MapLocation location, {
    bool forceRefresh = false,
  }) async => area;
}
