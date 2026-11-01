import 'dart:convert';

import 'package:fishing_build/core/validation/fishing_record_validator.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/outbox_item.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('legacy JSON remains text-only without adding payload keys', () {
    final original = _record().toJson();
    expect(original.containsKey('latitude'), isFalse);
    expect(original.containsKey('longitude'), isFalse);
    final restored = FishingRecord.fromJson(jsonDecode(jsonEncode(original)));
    expect(restored.latitude, isNull);
    expect(restored.longitude, isNull);
    expect(restored.toJson(), original);
    expect(FishingRecordValidator.validate(restored), isNull);
  });

  test('JSON and durable Outbox retain coordinate precision', () {
    final original = _record(latitude: 35.179612345, longitude: 129.075612345);
    final item = OutboxItem(
      id: 'coordinates',
      recordId: original.id,
      operationType: OutboxOperationType.create,
      status: OutboxStatus.pending,
      createdAt: DateTime(2026, 11, 1),
      payload: original.toJson(),
    );
    final restored = OutboxItem.fromJson(jsonDecode(jsonEncode(item.toJson())));
    final record = FishingRecord.fromJson(restored.payload!);
    expect(record.latitude, original.latitude);
    expect(record.longitude, original.longitude);
    expect(record.toJson(), original.toJson());
  });

  test('integer JSON coordinates normalize to doubles and accept zero', () {
    final record = FishingRecord.fromJson({
      ..._record().toJson(),
      'latitude': 0,
      'longitude': 0,
    });
    expect(record.latitude, 0.0);
    expect(record.longitude, 0.0);
    expect(FishingRecordValidator.validate(record), isNull);
  });

  test('WGS84 extreme bounds and negative coordinates are accepted', () {
    for (final pair in [
      (90.0, 180.0),
      (-90.0, -180.0),
      (-33.8688, 151.2093),
      (0.0, -0.0),
    ]) {
      expect(
        FishingRecordValidator.validate(
          _record(latitude: pair.$1, longitude: pair.$2),
        ),
        isNull,
      );
    }
  });

  test('partial, non-finite and out-of-range pairs are rejected', () {
    for (final pair in <(double?, double?)>[
      (35.0, null),
      (null, 129.0),
      (90.000001, 0),
      (-90.000001, 0),
      (0, 180.000001),
      (0, -180.000001),
      (double.nan, 0),
      (0, double.nan),
      (double.infinity, 0),
      (0, double.negativeInfinity),
    ]) {
      expect(
        FishingRecordValidator.validate(
          _record(latitude: pair.$1, longitude: pair.$2),
        ),
        isNotNull,
        reason: '$pair must not be saved',
      );
    }
  });

  test(
    'JSON missing one coordinate cannot silently discard the invalid value',
    () {
      final record = FishingRecord.fromJson({
        ..._record().toJson(),
        'latitude': 35.0,
      });
      expect(record.latitude, 35.0);
      expect(record.longitude, isNull);
      expect(FishingRecordValidator.validate(record), isNotNull);
      expect(record.toJson()['latitude'], 35.0);
    },
  );
}

FishingRecord _record({double? latitude, double? longitude}) => FishingRecord(
  id: 'coordinate-model',
  location: 'Test harbor',
  latitude: latitude,
  longitude: longitude,
  startAt: DateTime(2026, 11, 1, 8),
  endAt: DateTime(2026, 11, 1, 12),
  genreName: '루어',
);
