import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/models/personal_best_record.dart';
import 'package:fishing_build/data/repositories/personal_best_repository.dart';
import 'package:flutter_test/flutter_test.dart';

FishingRecord trip(String id, List<CatchRecord> catches, {int day = 1}) =>
    FishingRecord(
      id: id,
      location: 'location-$id',
      startAt: DateTime(2026, 11, day, 8),
      endAt: DateTime(2026, 11, day, 10),
      genreName: 'genre-$id',
      catches: catches,
      photos: [RecordPhoto(id: 'photo-$id', localPath: '/trip-$id.jpg')],
    );

void main() {
  test(
    'independent maxima retain their real catch, trip, and photo for either sort',
    () {
      final longest = trip('long', [
        const CatchRecord(speciesName: '갈치', lengthCm: 50, weightG: 1000),
      ]);
      final heaviest = trip('heavy', [
        const CatchRecord(speciesName: '갈치', lengthCm: 40, weightG: 2000),
      ], day: 2);
      final repository = PersonalBestRepository(
        recordsGetter: () => [longest, heaviest],
      );
      for (final sort in PersonalBestSortType.values) {
        final best = repository.getPersonalBests(sortType: sort).single;
        expect(best.bestLengthCm, 50);
        expect(best.bestWeightG, 2000);
        expect(best.lengthBest!.record, same(longest));
        expect(best.lengthBest!.weightG, 1000);
        expect(best.weightBest!.record, same(heaviest));
        expect(best.weightBest!.lengthCm, 40);
        final source = sort == PersonalBestSortType.weight ? heaviest : longest;
        expect(best.sourceRecord, same(source));
        expect(best.locationText, source.location);
        expect(best.caughtAt, source.startAt);
        expect(
          best.selectedEvidence.record.photos.single.localPath,
          source.photos.single.localPath,
        );
      }
    },
  );

  test(
    'two catches in one trip retain separate indices rather than synthesizing one fish',
    () {
      final source = trip('same', [
        const CatchRecord(speciesName: '갈치', lengthCm: 90, weightG: 500),
        const CatchRecord(speciesName: '갈치', lengthCm: 60, weightG: 900),
      ]);
      final best = PersonalBestRepository(
        recordsGetter: () => [source],
      ).getPersonalBest('갈치')!;
      expect(best.lengthBest!.catchIndex, 0);
      expect(best.weightBest!.catchIndex, 1);
      expect(best.lengthBest!.catchRecord, same(source.catches[0]));
      expect(best.weightBest!.catchRecord, same(source.catches[1]));
    },
  );

  test(
    'no measurements, blank species, NaN, infinity, and nonpositive values are excluded',
    () {
      final source = trip('invalid', [
        const CatchRecord(speciesName: '', lengthCm: 30),
        const CatchRecord(speciesName: '  ', weightG: 20),
        const CatchRecord(speciesName: 'unknown'),
        const CatchRecord(speciesName: 'zero', lengthCm: 0, weightG: 0),
        const CatchRecord(speciesName: 'negative', lengthCm: -2, weightG: -20),
        const CatchRecord(speciesName: 'nan', lengthCm: double.nan),
        const CatchRecord(speciesName: 'infinite', lengthCm: double.infinity),
        const CatchRecord(
          speciesName: 'negativeInfinity',
          lengthCm: double.negativeInfinity,
        ),
      ]);
      final repository = PersonalBestRepository(recordsGetter: () => [source]);
      expect(repository.getPersonalBests(), isEmpty);
      expect(repository.getPersonalBest('unknown'), isNull);
    },
  );

  test(
    'one valid measurement remains usable with an explicit alternate source criterion',
    () {
      final source = trip('one', [
        const CatchRecord(
          speciesName: '갈치',
          lengthCm: double.nan,
          weightG: 120,
        ),
        const CatchRecord(speciesName: '넙치', lengthCm: 30, weightG: -2),
      ]);
      final repository = PersonalBestRepository(recordsGetter: () => [source]);
      final weightOnly = repository.getPersonalBest('갈치')!;
      expect(weightOnly.bestLengthCm, isNull);
      expect(weightOnly.lengthText, '-');
      expect(weightOnly.weightText, '120 g');
      expect(weightOnly.selectedType, PersonalBestSortType.weight);
      final lengthOnly = repository.getPersonalBest(
        '넙치',
        sortType: PersonalBestSortType.weight,
      )!;
      expect(lengthOnly.bestWeightG, isNull);
      expect(lengthOnly.selectedType, PersonalBestSortType.length);
      expect(lengthOnly.lengthText, '30.0 cm');
    },
  );

  test(
    'groups trimmed names and sorts each metric with unavailable values last',
    () {
      final source = trip('sort', [
        const CatchRecord(speciesName: '갈치 ', lengthCm: 80, weightG: 100),
        const CatchRecord(speciesName: ' 갈치', lengthCm: 60, weightG: 200),
        const CatchRecord(speciesName: '넙치', lengthCm: 50, weightG: 300),
        const CatchRecord(speciesName: '무게만', weightG: 400),
        const CatchRecord(speciesName: '크기만', lengthCm: 90),
      ]);
      final repository = PersonalBestRepository(recordsGetter: () => [source]);
      expect(repository.getPersonalBests().map((r) => r.speciesName), [
        '크기만',
        '갈치',
        '넙치',
        '무게만',
      ]);
      expect(
        repository
            .getPersonalBests(sortType: PersonalBestSortType.weight)
            .map((r) => r.speciesName),
        ['무게만', '넙치', '갈치', '크기만'],
      );
      expect(repository.getPersonalBest(' 갈치 ')!.bestWeightG, 200);
      expect(
        repository
            .getPersonalBests(sortType: PersonalBestSortType.name)
            .map((r) => r.speciesName),
        ['갈치', '넙치', '무게만', '크기만'],
      );
    },
  );

  test('ties consistently select the latest trip, then ID and catch index', () {
    const catchRecord = CatchRecord(
      speciesName: '갈치',
      lengthCm: 80,
      weightG: 200,
    );
    final old = trip('0-old', [catchRecord], day: 1);
    final laterB = trip('b', [catchRecord], day: 2);
    final laterA = trip('a', [catchRecord, catchRecord], day: 2);
    for (final records in [
      [old, laterB, laterA],
      [laterA, laterB, old],
    ]) {
      final repository = PersonalBestRepository(recordsGetter: () => records);
      for (final sort in PersonalBestSortType.values) {
        final best = repository.getPersonalBest('갈치', sortType: sort)!;
        expect(best.lengthBest!.record.id, 'a');
        expect(best.weightBest!.record.id, 'a');
        expect(best.lengthBest!.catchIndex, 0);
        expect(best.weightBest!.catchIndex, 0);
      }
    }
  });

  test('equal species maxima have a stable alphabetical list order', () {
    final a = trip('a', [const CatchRecord(speciesName: '갈치', lengthCm: 80)]);
    final b = trip('b', [const CatchRecord(speciesName: '넙치', lengthCm: 80)]);
    for (final records in [
      [a, b],
      [b, a],
    ]) {
      expect(
        PersonalBestRepository(
          recordsGetter: () => records,
        ).getPersonalBests().map((r) => r.speciesName),
        ['갈치', '넙치'],
      );
    }
  });

  test(
    'recomputes from current records after edit, delete, and owner replacement',
    () {
      final first = trip('first', [
        const CatchRecord(speciesName: '갈치', lengthCm: 90),
      ]);
      final second = trip('second', [
        const CatchRecord(speciesName: '갈치', lengthCm: 60),
      ]);
      var records = [first, second];
      final repository = PersonalBestRepository(recordsGetter: () => records);
      expect(repository.getPersonalBest('갈치')!.bestLengthCm, 90);
      records = [
        trip('first', [const CatchRecord(speciesName: '갈치', lengthCm: 50)]),
        second,
      ];
      expect(repository.getPersonalBest('갈치')!.sourceRecord.id, 'second');
      records = [records.first];
      expect(repository.getPersonalBest('갈치')!.bestLengthCm, 50);
      records = [
        trip('anotherOwner', [
          const CatchRecord(speciesName: '참돔', weightG: 800),
        ]),
      ];
      expect(repository.getPersonalBest('갈치'), isNull);
      expect(repository.getPersonalBests().single.speciesName, '참돔');
      records = [];
      expect(repository.getPersonalBests(), isEmpty);
    },
  );
}
