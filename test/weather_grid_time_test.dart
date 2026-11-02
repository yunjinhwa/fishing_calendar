import 'package:fishing_build/data/services/external_data_service.dart';
import 'package:fishing_build/data/weather/kma_forecast_time.dart';
import 'package:fishing_build/data/weather/kma_grid.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'official Seoul, Busan and Jeju coordinate references match KMA grids',
    () {
      for (final reference in [
        (37.5635694444444, 126.980008333333, 60, 127),
        (35.0881166666666, 129.070186111111, 98, 74),
        (33.4856944444444, 126.500333333333, 52, 38),
      ]) {
        final grid = KmaGrid.fromWgs84(reference.$1, reference.$2);
        expect(grid.x, reference.$3);
        expect(grid.y, reference.$4);
        expect(grid, KmaGrid.fromWgs84(reference.$1, reference.$2));
        expect(
          grid.hashCode,
          KmaGrid.fromWgs84(reference.$1, reference.$2).hashCode,
        );
      }
    },
  );

  test(
    'invalid and out-of-coverage coordinates fail as unsupported locations',
    () {
      for (final pair in [
        (double.nan, 126.0),
        (35.0, double.infinity),
        (91.0, 126.0),
        (35.0, -181.0),
        (90.0, 126.0),
        (-90.0, 126.0),
        (0.0, 0.0),
        (-33.8688, 151.2093),
        (51.5072, -0.1276),
      ]) {
        expect(
          () => KmaGrid.fromWgs84(pair.$1, pair.$2),
          throwsA(
            isA<ExternalDataException>().having(
              (error) => error.reason,
              'reason',
              ExternalDataFailure.unsupportedLocation,
            ),
          ),
        );
      }
    },
  );

  test('the previous-hour issue covers this hour before and after :45', () {
    final before = KmaForecastTime.forCurrentHour(
      DateTime.parse('2026-11-02T10:44:59+09:00'),
    );
    final available = KmaForecastTime.forCurrentHour(
      DateTime.parse('2026-11-02T10:45:00+09:00'),
    );
    expect(before.issuedAt, DateTime.parse('2026-11-02T09:30:00+09:00'));
    expect(available.issuedAt, DateTime.parse('2026-11-02T09:30:00+09:00'));
    expect(before.validAt, DateTime.parse('2026-11-02T10:00:00+09:00'));
    expect(available.validAt, before.validAt);
    expect(available.issuedAt.isUtc, isTrue);
    expect(available.validAt.isUtc, isTrue);
    final hourStart = KmaForecastTime.forCurrentHour(
      DateTime.parse('2026-11-02T11:00:00+09:00'),
    );
    expect(hourStart.issuedAt, DateTime.parse('2026-11-02T10:30:00+09:00'));
    expect(hourStart.validAt, DateTime.parse('2026-11-02T11:00:00+09:00'));
  });

  test('KST midnight and New Year use the previous issue date safely', () {
    final before = KmaForecastTime.forCurrentHour(
      DateTime.parse('2026-01-01T00:44:59+09:00'),
    );
    final after = KmaForecastTime.forCurrentHour(
      DateTime.parse('2026-01-01T00:45:00+09:00'),
    );
    expect(KmaForecastTime.date(before.issuedAt), '20251231');
    expect(KmaForecastTime.time(before.issuedAt), '2330');
    expect(KmaForecastTime.date(after.issuedAt), '20251231');
    expect(KmaForecastTime.time(after.issuedAt), '2330');
    expect(KmaForecastTime.date(after.validAt), '20260101');
    expect(KmaForecastTime.time(after.validAt), '0000');
  });

  test('timestamp formatting and issue selection ignore source timezone', () {
    final korea = DateTime.parse('2026-11-02T00:10:00+09:00');
    final utc = DateTime.parse('2026-11-01T15:10:00Z');
    final west = DateTime.parse('2026-11-01T07:10:00-08:00');
    for (final instant in [korea, utc, west]) {
      final selected = KmaForecastTime.forCurrentHour(instant);
      expect(selected.issuedAt, DateTime.parse('2026-11-01T14:30:00Z'));
      expect(selected.validAt, DateTime.parse('2026-11-01T15:00:00Z'));
      expect(KmaForecastTime.date(instant), '20261102');
      expect(KmaForecastTime.time(instant), '0010');
    }
  });
}
