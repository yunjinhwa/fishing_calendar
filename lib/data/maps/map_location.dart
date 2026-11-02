import '../../core/validation/fishing_record_validator.dart';

class MapLocation {
  MapLocation({
    required String name,
    this.address,
    this.latitude,
    this.longitude,
  }) : name = name.trim() {
    if (this.name.isEmpty ||
        this.name.length > FishingRecordValidator.maxLocationLength) {
      throw ArgumentError.value(name, 'name', '위치 이름은 1~200자여야 합니다.');
    }
    final error = FishingRecordValidator.validateCoordinates(
      latitude,
      longitude,
    );
    if (error != null) throw ArgumentError(error);
  }

  final String name;
  final String? address;
  final double? latitude;
  final double? longitude;

  bool get hasCoordinates => latitude != null && longitude != null;
}
