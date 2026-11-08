import 'dart:typed_data';

import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/personal_best_record.dart';
import 'package:fishing_build/data/models/share_record_data.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('snapshot keeps both measurements and trip details from one catch', () {
    for (final criterion in [
      PersonalBestSortType.length,
      PersonalBestSortType.weight,
    ]) {
      final record = _best(criterion);
      final source = record.selectedEvidence;
      final data = ShareRecordData.fromPersonalBest(record, nickname: '바다낚시인');

      expect(data.recordId, source.record.id);
      expect(data.catchIndex, source.catchIndex);
      expect(data.speciesName, record.speciesName);
      expect(data.criterion, record.selectedType);
      expect(data.caughtAt, source.record.startAt);
      expect(data.location, source.record.location);
      expect(data.lengthCm, source.catchRecord.lengthCm);
      expect(data.weightG, source.catchRecord.weightG);
      if (criterion == PersonalBestSortType.length) {
        expect(data.lengthCm, 90);
        expect(data.weightG, 500);
        expect(data.weightG, isNot(record.bestWeightG));
      } else {
        expect(data.lengthCm, 60);
        expect(data.weightG, 900);
        expect(data.lengthCm, isNot(record.bestLengthCm));
      }
    }
  });

  test('an unmeasured companion value is not filled from another catch', () {
    final record = _best(PersonalBestSortType.length, lengthCatchWeight: null);
    final data = ShareRecordData.fromPersonalBest(record, nickname: '낚시인');

    expect(record.bestWeightG, 900);
    expect(data.lengthCm, 90);
    expect(data.weightG, isNull);
  });

  test(
    'missing nickname uses a neutral name without private source content',
    () {
      final record = _best(PersonalBestSortType.length);
      expect(record.sourceRecord.memo, contains('private@example.com'));
      for (final nickname in ['', '  \n\t ']) {
        final data = ShareRecordData.fromPersonalBest(
          record,
          nickname: nickname,
        );
        expect(data.nickname, '낚시인');
        expect(data.nickname, isNot(contains('@')));
        expect(data.nickname, isNot(record.sourceRecord.id));
        expect(data.nickname, isNot(record.sourceRecord.memo));
      }
      expect(
        ShareRecordData.fromPersonalBest(
          record,
          nickname: '  바다낚시인  ',
        ).nickname,
        '바다낚시인',
      );
    },
  );

  test(
    'default fields are included and date and location require opting in',
    () {
      const options = ShareRecordOptions();
      expect(options.showNickname, isTrue);
      expect(options.showPhoto, isTrue);
      expect(options.showLength, isTrue);
      expect(options.showWeight, isTrue);
      expect(options.showDate, isFalse);
      expect(options.showLocation, isFalse);

      final withDate = options.copyWith(showDate: true);
      expect(withDate.showDate, isTrue);
      expect(withDate.showLocation, isFalse);
      final withLocation = options.copyWith(showLocation: true);
      expect(withLocation.showDate, isFalse);
      expect(withLocation.showLocation, isTrue);
      expect(options.showDate, isFalse);
      expect(options.showLocation, isFalse);
    },
  );

  test('photo bytes are defensively copied and stay immutable', () {
    final original = Uint8List.fromList([1, 2, 3]);
    final record = _best(PersonalBestSortType.length);
    final data = ShareRecordData.fromPersonalBest(
      record,
      nickname: '바다낚시인',
      photoBytes: original,
    );

    expect(data.photoBytes, isNot(same(original)));
    original[0] = 99;
    expect(data.photoBytes, orderedEquals([1, 2, 3]));
    expect(() => data.photoBytes![0] = 42, throwsUnsupportedError);
    expect(
      () => data.photoBytes!.buffer.asUint8List()[0] = 42,
      throwsUnsupportedError,
    );
    expect(
      ShareRecordData.fromPersonalBest(record, nickname: '낚시인').photoBytes,
      isNull,
    );
  });
}

PersonalBestRecord _best(
  PersonalBestSortType criterion, {
  int? lengthCatchWeight = 500,
}) {
  final lengthTrip = FishingRecord(
    id: 'private-length-record-id',
    location: '제주항',
    startAt: DateTime(2026, 11, 1, 8),
    endAt: DateTime(2026, 11, 1, 10),
    genreName: '바다낚시',
    memo: 'Private account email: private@example.com',
    catches: [
      const CatchRecord(speciesName: '갈치', lengthCm: 20, weightG: 100),
      CatchRecord(speciesName: '갈치', lengthCm: 90, weightG: lengthCatchWeight),
    ],
  );
  final weightTrip = FishingRecord(
    id: 'private-weight-record-id',
    location: '부산항',
    startAt: DateTime(2026, 11, 2, 6),
    endAt: DateTime(2026, 11, 2, 9),
    genreName: '바다낚시',
    catches: const [CatchRecord(speciesName: '갈치', lengthCm: 60, weightG: 900)],
  );
  return PersonalBestRecord(
    speciesName: '갈치',
    lengthBest: PersonalBestEvidence(
      record: lengthTrip,
      catchRecord: lengthTrip.catches[1],
      catchIndex: 1,
    ),
    weightBest: PersonalBestEvidence(
      record: weightTrip,
      catchRecord: weightTrip.catches[0],
      catchIndex: 0,
    ),
    sortType: criterion,
  );
}
