import 'package:fishing_build/data/maps/map_location.dart';
import 'package:fishing_build/data/tides/tide_models.dart';
import 'package:fishing_build/data/tides/tide_station_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('official catalog has valid unique station coordinates and codes', () {
    final stations = TideStationCatalog().stations;
    expect(stations, hasLength(84));
    expect(stations.map((s) => s.code).toSet(), hasLength(stations.length));
    for (final station in stations) {
      expect(RegExp(r'^[A-Z]{2}_[0-9]{4}$').hasMatch(station.code), isTrue);
      expect(station.name.trim(), isNotEmpty);
      expect(station.latitude, inInclusiveRange(30, 40));
      expect(station.longitude, inInclusiveRange(120, 135));
    }
    expect(() => stations.clear(), throwsUnsupportedError);
  });

  test(
    'renumbered stations remain the nearest forecast at former coordinates',
    () {
      final catalog = TideStationCatalog();
      const cases = [
        (
          name: '가덕도',
          code: 'DT_0063',
          retiredCode: 'DT_0019',
          latitude: 35.0242,
          longitude: 128.8109,
        ),
        (
          name: '독도',
          code: 'DT_0903',
          retiredCode: 'DT_0040',
          latitude: 37.2389,
          longitude: 131.8672,
        ),
        (
          name: '마산',
          code: 'DT_0062',
          retiredCode: 'DT_0015',
          latitude: 35.21,
          longitude: 128.5889,
        ),
        (
          name: '안흥',
          code: 'DT_0067',
          retiredCode: 'DT_0034',
          latitude: 36.6737,
          longitude: 126.1322,
        ),
        (
          name: '위도',
          code: 'DT_0068',
          retiredCode: 'DT_0030',
          latitude: 35.6181,
          longitude: 126.3017,
        ),
        (
          name: '덕적도',
          code: 'DT_0065',
          retiredCode: 'SO_0536',
          latitude: 37.25,
          longitude: 126.1333,
        ),
        (
          name: '포항',
          code: 'DT_0091',
          retiredCode: 'DT_0901',
          latitude: 36.0471,
          longitude: 129.3838,
        ),
      ];
      for (final entry in cases) {
        final nearest = catalog
            .nearby(
              MapLocation(
                name: entry.name,
                latitude: entry.latitude,
                longitude: entry.longitude,
              ),
            )
            .first;
        expect(nearest.code, entry.code, reason: entry.name);
        expect(nearest.name, entry.name);
        expect(
          catalog.stations.map((station) => station.code),
          isNot(contains(entry.retiredCode)),
        );
      }
    },
  );

  test(
    'nearby candidates use straight distance, radius, limit and stable ties',
    () {
      const a = TideStation(
        code: 'DT_0001',
        name: '첫 지점',
        latitude: 35,
        longitude: 129,
      );
      const b = TideStation(
        code: 'DT_0002',
        name: '둘째 지점',
        latitude: 35,
        longitude: 129,
      );
      const far = TideStation(
        code: 'DT_0003',
        name: '먼 지점',
        latitude: 37,
        longitude: 126,
      );
      final catalog = TideStationCatalog(stations: [far, b, a]);
      final location = MapLocation(name: '선택 위치', latitude: 35, longitude: 129);
      expect(catalog.nearby(location).map((s) => s.code), [
        'DT_0001',
        'DT_0002',
      ]);
      expect(catalog.nearby(location, limit: 1).single.code, 'DT_0001');
      expect(catalog.nearby(MapLocation(name: '좌표 없음')), isEmpty);
      expect(catalog.nearby(location, maxDistanceKm: double.nan), isEmpty);
      expect(catalog.nearby(location, limit: 0), isEmpty);
      expect(a.distanceKmTo(35, 129), closeTo(0, 0.000001));
    },
  );

  test('KST date keys follow midnight independent of the device time zone', () {
    expect(
      TideDay.fromInstant(DateTime.utc(2026, 11, 1, 14, 59)).apiDate,
      '20261101',
    );
    expect(
      TideDay.fromInstant(DateTime.utc(2026, 11, 1, 15)).apiDate,
      '20261102',
    );
    expect(TideDay.fromCalendar(DateTime(2026, 11, 2)).apiDate, '20261102');
    expect(TideDay(2026, 11, 2), TideDay(2026, 11, 2));
    expect(() => TideDay(2026, 2, 30), throwsArgumentError);
  });

  test('record reference requires the selected KST day and exact location', () {
    final location = MapLocation(name: '출조 항구', latitude: 35, longitude: 129);
    final reference = TideRecordReference(
      location: location,
      forecast: TideForecast(
        station: const TideStation(
          code: 'DT_0005',
          name: '부산',
          latitude: 35.1,
          longitude: 129.03,
        ),
        day: TideDay(2026, 11, 2),
        events: const [],
        fetchedAt: DateTime.utc(2026, 11, 2),
      ),
    );
    bool matches(DateTime at, {String name = '출조 항구', double? latitude = 35}) =>
        reference.appliesToRecord(
          startAt: at,
          locationName: name,
          latitude: latitude,
          longitude: 129,
        );
    expect(matches(DateTime.utc(2026, 11, 1, 15)), isTrue);
    expect(matches(DateTime.utc(2026, 11, 2, 14, 59)), isTrue);
    expect(matches(DateTime.utc(2026, 11, 2, 15)), isFalse);
    expect(matches(DateTime.utc(2026, 11, 2), name: '다른 곳'), isFalse);
    expect(matches(DateTime.utc(2026, 11, 2), latitude: null), isFalse);
  });
}
