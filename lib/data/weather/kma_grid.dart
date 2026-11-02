import 'dart:math' as math;

import '../services/external_data_service.dart';

/// The KMA 5 km Lambert conformal conic forecast grid.
class KmaGrid {
  const KmaGrid._(this.x, this.y);

  final int x;
  final int y;

  factory KmaGrid.fromWgs84(double latitude, double longitude) {
    if (!latitude.isFinite ||
        !longitude.isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      throw const ExternalDataException(
        ExternalDataFailure.unsupportedLocation,
      );
    }

    const radians = math.pi / 180;
    const radius = 6371.00877 / 5;
    const firstLatitude = 30 * radians;
    const secondLatitude = 60 * radians;
    const originLatitude = 38 * radians;
    const originLongitude = 126 * radians;
    final exponent =
        math.log(math.cos(firstLatitude) / math.cos(secondLatitude)) /
        math.log(
          math.tan(math.pi / 4 + secondLatitude / 2) /
              math.tan(math.pi / 4 + firstLatitude / 2),
        );
    final factor =
        math.pow(math.tan(math.pi / 4 + firstLatitude / 2), exponent) *
        math.cos(firstLatitude) /
        exponent;
    final originRadius =
        radius *
        factor /
        math.pow(math.tan(math.pi / 4 + originLatitude / 2), exponent);
    final projectedRadius =
        radius *
        factor /
        math.pow(math.tan(math.pi / 4 + latitude * radians / 2), exponent);
    var theta = longitude * radians - originLongitude;
    if (theta > math.pi) theta -= 2 * math.pi;
    if (theta < -math.pi) theta += 2 * math.pi;
    theta *= exponent;
    final projectedX = projectedRadius * math.sin(theta) + 43;
    final projectedY = originRadius - projectedRadius * math.cos(theta) + 136;
    if (!projectedX.isFinite || !projectedY.isFinite) {
      throw const ExternalDataException(
        ExternalDataFailure.unsupportedLocation,
      );
    }
    final x = (projectedX + 0.5).floor();
    final y = (projectedY + 0.5).floor();
    if (x < 1 || x > 149 || y < 1 || y > 253) {
      throw const ExternalDataException(
        ExternalDataFailure.unsupportedLocation,
      );
    }
    return KmaGrid._(x, y);
  }

  @override
  bool operator ==(Object other) =>
      other is KmaGrid && x == other.x && y == other.y;

  @override
  int get hashCode => Object.hash(x, y);
}
