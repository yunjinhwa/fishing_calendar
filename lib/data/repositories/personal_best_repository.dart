import '../models/fishing_record.dart';
import '../models/personal_best_record.dart';
import 'fishing_record_memory_repository.dart';

class PersonalBestRepository {
  PersonalBestRepository._();

  static final PersonalBestRepository instance = PersonalBestRepository._();

  List<PersonalBestRecord> getPersonalBests({
    PersonalBestSortType sortType = PersonalBestSortType.length,
  }) {
    final records = FishingRecordMemoryRepository.instance.getAllRecords();
    final bestBySpecies = <String, PersonalBestRecord>{};

    for (final record in records) {
      for (final catchRecord in record.catches) {
        final speciesName = catchRecord.speciesName.trim();

        if (speciesName.isEmpty) {
          continue;
        }

        final current = bestBySpecies[speciesName];

        if (current == null) {
          bestBySpecies[speciesName] = PersonalBestRecord(
            speciesName: speciesName,
            bestLengthCm: catchRecord.lengthCm,
            bestWeightG: catchRecord.weightG,
            sourceRecord: record,
          );
          continue;
        }

        final shouldReplace = _shouldReplaceBest(
          current: current,
          candidate: catchRecord,
          sourceRecord: record,
          sortType: sortType,
        );

        if (shouldReplace) {
          bestBySpecies[speciesName] = PersonalBestRecord(
            speciesName: speciesName,
            bestLengthCm: catchRecord.lengthCm,
            bestWeightG: catchRecord.weightG,
            sourceRecord: record,
          );
        }
      }
    }

    final items = bestBySpecies.values.toList();

    items.sort((a, b) {
      switch (sortType) {
        case PersonalBestSortType.length:
          return (b.bestLengthCm ?? -1).compareTo(a.bestLengthCm ?? -1);
        case PersonalBestSortType.weight:
          return (b.bestWeightG ?? -1).compareTo(a.bestWeightG ?? -1);
      }
    });

    return items;
  }

  bool _shouldReplaceBest({
    required PersonalBestRecord current,
    required CatchRecord candidate,
    required FishingRecord sourceRecord,
    required PersonalBestSortType sortType,
  }) {
    switch (sortType) {
      case PersonalBestSortType.length:
        return (candidate.lengthCm ?? -1) > (current.bestLengthCm ?? -1);
      case PersonalBestSortType.weight:
        return (candidate.weightG ?? -1) > (current.bestWeightG ?? -1);
    }
  }
}