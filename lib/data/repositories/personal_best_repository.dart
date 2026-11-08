import '../models/fishing_record.dart';
import '../models/personal_best_record.dart';
import 'fishing_record_repository.dart';

/// Derived from the active owner's retained records, without a second store.
class PersonalBestRepository {
  PersonalBestRepository({List<FishingRecord> Function()? recordsGetter})
    : _recordsGetter =
          recordsGetter ?? FishingRecordRepository.instance.getAllRecords;

  static final PersonalBestRepository instance = PersonalBestRepository();
  final List<FishingRecord> Function() _recordsGetter;

  List<PersonalBestRecord> getPersonalBests({
    PersonalBestSortType sortType = PersonalBestSortType.length,
  }) {
    final items = _aggregate(sortType).values.toList();
    items.sort((a, b) {
      if (sortType == PersonalBestSortType.name) {
        return a.speciesName.compareTo(b.speciesName);
      }
      final num? aValue = sortType == PersonalBestSortType.length
          ? a.bestLengthCm
          : a.bestWeightG;
      final num? bValue = sortType == PersonalBestSortType.length
          ? b.bestLengthCm
          : b.bestWeightG;
      if (aValue == null && bValue != null) return 1;
      if (aValue != null && bValue == null) return -1;
      final byMeasurement = aValue == null ? 0 : bValue!.compareTo(aValue);
      return byMeasurement != 0
          ? byMeasurement
          : a.speciesName.compareTo(b.speciesName);
    });
    return List.unmodifiable(items);
  }

  PersonalBestRecord? getPersonalBest(
    String speciesName, {
    PersonalBestSortType sortType = PersonalBestSortType.length,
  }) => _aggregate(sortType)[speciesName.trim()];

  Map<String, PersonalBestRecord> _aggregate(PersonalBestSortType sortType) {
    final bySpecies = <String, _BestPair>{};
    for (final record in _recordsGetter()) {
      for (var index = 0; index < record.catches.length; index++) {
        final catchRecord = record.catches[index];
        final speciesName = catchRecord.speciesName.trim();
        if (speciesName.isEmpty) continue;
        final candidate = PersonalBestEvidence(
          record: record,
          catchRecord: catchRecord,
          catchIndex: index,
        );
        final length = candidate.lengthCm;
        final weight = candidate.weightG;
        if (length == null && weight == null) continue;
        final pair = bySpecies.putIfAbsent(speciesName, _BestPair.new);
        if (length != null && _wins(candidate, pair.length, byLength: true)) {
          pair.length = candidate;
        }
        if (weight != null && _wins(candidate, pair.weight, byLength: false)) {
          pair.weight = candidate;
        }
      }
    }
    return {
      for (final entry in bySpecies.entries)
        entry.key: PersonalBestRecord(
          speciesName: entry.key,
          lengthBest: entry.value.length,
          weightBest: entry.value.weight,
          sortType: sortType,
        ),
    };
  }

  bool _wins(
    PersonalBestEvidence candidate,
    PersonalBestEvidence? current, {
    required bool byLength,
  }) {
    if (current == null) return true;
    final num candidateValue = byLength
        ? candidate.lengthCm!
        : candidate.weightG!;
    final num currentValue = byLength ? current.lengthCm! : current.weightG!;
    final byValue = candidateValue.compareTo(currentValue);
    if (byValue != 0) return byValue > 0;
    final byDate = candidate.record.startAt.compareTo(current.record.startAt);
    if (byDate != 0) return byDate > 0;
    final byId = candidate.record.id.compareTo(current.record.id);
    if (byId != 0) return byId < 0;
    return candidate.catchIndex < current.catchIndex;
  }
}

class _BestPair {
  PersonalBestEvidence? length;
  PersonalBestEvidence? weight;
}
