import 'package:fishing_build/data/local/app_database.dart';
import 'package:fishing_build/data/local/local_data_store.dart';
import 'package:fishing_build/data/models/record_sync_checkpoint.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_database.dart';

void main() {
  test(
    'durable checkpoint preserves nanoseconds and timestamp tie ordering',
    () {
      final checkpoint = RecordSyncCheckpoint(
        cursor: const RecordSyncCursor(
          seconds: 1792972800,
          nanoseconds: 123456789,
          recordId: 'record-z',
        ),
        lastFullSyncAt: DateTime.utc(2026, 10, 26),
      );
      final decoded = RecordSyncCheckpoint.decode(checkpoint.encode());
      expect(decoded.cursor.seconds, checkpoint.cursor.seconds);
      expect(decoded.cursor.nanoseconds, 123456789);
      expect(decoded.cursor.recordId, 'record-z');
      expect(decoded.lastFullSyncAt, checkpoint.lastFullSyncAt);
      expect(
        decoded.cursor.compareTo(
          const RecordSyncCursor(
            seconds: 1792972800,
            nanoseconds: 123456788,
            recordId: 'record-z',
          ),
        ),
        greaterThan(0),
      );
      expect(
        decoded.cursor.compareTo(
          const RecordSyncCursor(
            seconds: 1792972800,
            nanoseconds: 123456789,
            recordId: 'record-a',
          ),
        ),
        greaterThan(0),
      );
    },
  );

  test('account data purge clears only that owner pull checkpoint', () async {
    await resetTestDatabase();
    final store = LocalDataStore.instance;
    const ownerA = 'member:checkpoint-a';
    const ownerB = 'member:checkpoint-b';
    final encoded = RecordSyncCheckpoint(
      cursor: RecordSyncCursor.origin,
      lastFullSyncAt: DateTime.utc(2026, 10, 26),
    ).encode();
    await AppDatabase.instance.transaction((transaction) async {
      for (final owner in [ownerA, ownerB]) {
        await store.writeMetadata(
          transaction,
          key: RecordSyncCheckpoint.metadataKey(owner),
          value: encoded,
        );
      }
    });
    await AppDatabase.instance.transaction(
      (transaction) => store.deleteOwnerData(transaction, ownerKey: ownerA),
    );
    final database = await AppDatabase.instance.database;
    expect(
      await store.readMetadata(
        database,
        RecordSyncCheckpoint.metadataKey(ownerA),
      ),
      isNull,
    );
    expect(
      await store.readMetadata(
        database,
        RecordSyncCheckpoint.metadataKey(ownerB),
      ),
      encoded,
    );
  });
}
