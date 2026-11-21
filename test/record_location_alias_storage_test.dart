import 'dart:io';

import 'package:fishing_build/core/validation/fishing_record_validator.dart';
import 'package:fishing_build/data/local/app_database.dart';
import 'package:fishing_build/data/local/local_data_store.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/outbox_item.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _owner = 'member:location-alias';

FishingRecord _record({String? alias}) => FishingRecord(
  id: 'alias-record',
  location: '부산 영도구 동삼동',
  locationAlias: alias,
  latitude: 35.08,
  longitude: 129.07,
  startAt: DateTime.utc(2026, 11, 21, 10),
  endAt: DateTime.utc(2026, 11, 21, 13),
  genreName: '루어',
  catches: const [CatchRecord(speciesName: '우럭', lengthCm: 32)],
  photos: const [RecordPhoto(id: 'photo1', localPath: 'C:/photos/photo1.jpg')],
  memo: '예전 메모',
);

void main() {
  test('the optional alias round trips without replacing the actual place', () {
    final legacy = _record();
    expect(legacy.toJson().containsKey('locationAlias'), isFalse);
    expect(FishingRecord.fromJson(legacy.toJson()).locationAlias, isNull);

    final original = _record(alias: '단골 포인트');
    final restored = FishingRecord.fromJson(original.toJson());
    expect(restored.locationAlias, '단골 포인트');
    expect(restored.location, legacy.location);
    expect(restored.latitude, legacy.latitude);
    expect(restored.longitude, legacy.longitude);
    expect(restored.locationDisplayName, '단골 포인트 (부산 영도구 동삼동)');
    expect(
      _record(alias: legacy.location).locationDisplayName,
      legacy.location,
    );
  });

  test('alias validation allows omission and enforces the length limit', () {
    const limit = FishingRecordValidator.maxLocationAliasLength;
    expect(FishingRecordValidator.validate(_record()), isNull);
    expect(
      FishingRecordValidator.validate(_record(alias: '\t  \n')),
      '위치 별칭은 공백만 입력할 수 없습니다.',
    );
    expect(
      FishingRecordValidator.validate(_record(alias: '🎣' * (limit ~/ 2))),
      isNull,
    );
    expect(
      FishingRecordValidator.validate(_record(alias: '가' * (limit + 1))),
      '위치 별칭은 $limit자 이하로 입력하세요.',
    );
  });

  test(
    'v6 migration keeps existing data and persists later alias edits',
    () async {
      sqfliteFfiInit();
      final directory = await Directory.systemTemp.createTemp('alias-storage-');
      final databasePath = path.join(directory.path, 'legacy-v6.db');
      final appDatabase = AppDatabase.instance;
      final store = LocalDataStore.instance;
      addTearDown(() async {
        await appDatabase.close();
        await databaseFactoryFfiNoIsolate.deleteDatabase(databasePath);
        await directory.delete();
      });
      await appDatabase.configureForTesting(
        databaseFactory: databaseFactoryFfiNoIsolate,
        databasePath: databasePath,
      );
      final original = _record();
      await appDatabase.transaction((transaction) async {
        await store.insertRecord(
          transaction,
          ownerKey: _owner,
          record: original,
        );
        await store.insertOutboxItem(
          transaction,
          ownerKey: _owner,
          item: OutboxItem(
            id: 'pending-before-aliases',
            userId: 'location-alias',
            recordId: original.id,
            operationType: OutboxOperationType.update,
            status: OutboxStatus.failed,
            createdAt: original.endAt,
            payload: original.toJson(),
          ),
        );
      });
      final legacy = await appDatabase.database;
      await legacy.execute(
        'ALTER TABLE ${AppDatabase.fishingRecordsTable} DROP COLUMN location_alias',
      );
      await legacy.setVersion(6);
      await appDatabase.close();

      final upgraded = await appDatabase.database;
      expect(await upgraded.getVersion(), 7);
      expect(
        (await store.readRecordForOwner(_owner, original.id))!.toJson(),
        original.toJson(),
      );
      expect(
        (await store.readOutboxItemsForOwner(_owner)).single.payload,
        original.toJson(),
      );
      expect(await upgraded.rawQuery('PRAGMA foreign_key_check'), isEmpty);

      Future<void> replace(FishingRecord record) => appDatabase.transaction(
        (transaction) => store.insertRecord(
          transaction,
          ownerKey: _owner,
          record: record,
          replace: true,
        ),
      );

      final aliased = _record(alias: '단골 포인트');
      await replace(aliased);
      await appDatabase.close();
      expect(
        (await store.readRecordsForOwner(_owner)).single.toJson(),
        aliased.toJson(),
      );
      await replace(original);
      expect(
        (await store.readRecordForOwner(_owner, original.id))!.toJson(),
        original.toJson(),
      );
    },
  );
}
