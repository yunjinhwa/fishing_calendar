class FishingRecord {
  final String id;
  final String location;
  final DateTime startAt;
  final DateTime endAt;
  final String genreName;

  final String? tide;
  final String? weather;
  final double? airTemperature;
  final double? waterTemperature;

  final List<CatchRecord> catches;
  final String? memo;

  const FishingRecord({
    required this.id,
    required this.location,
    required this.startAt,
    required this.endAt,
    required this.genreName,
    this.tide,
    this.weather,
    this.airTemperature,
    this.waterTemperature,
    this.catches = const [],
    this.memo,
  });

  String get summaryTitle {
    final firstSpecies = catches
        .map((catchRecord) => catchRecord.speciesName)
        .where((speciesName) => speciesName.trim().isNotEmpty)
        .firstOrNull;

    if (firstSpecies == null) {
      return genreName;
    }

    return '$genreName · $firstSpecies';
  }

  bool overlapsDate(DateTime date) {
    final dayStart = DateTime(date.year, date.month, date.day);
    final dayEnd = dayStart.add(const Duration(days: 1));

    return startAt.isBefore(dayEnd) && endAt.isAfter(dayStart);
  }
}

class CatchRecord {
  final String speciesName;
  final double? lengthCm;
  final int? weightG;

  const CatchRecord({required this.speciesName, this.lengthCm, this.weightG});
}
