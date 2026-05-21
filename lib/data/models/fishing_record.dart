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
  final List<String> photoPaths;
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
    this.photoPaths = const [],
    this.memo,
  });

  factory FishingRecord.fromJson(Map<String, dynamic> json) {
    return FishingRecord(
      id: json['id'] as String,
      location: json['location'] as String,
      startAt: DateTime.parse(json['startAt'] as String),
      endAt: DateTime.parse(json['endAt'] as String),
      genreName: json['genreName'] as String,
      tide: json['tide'] as String?,
      weather: json['weather'] as String?,
      airTemperature: (json['airTemperature'] as num?)?.toDouble(),
      waterTemperature: (json['waterTemperature'] as num?)?.toDouble(),
      catches: ((json['catches'] as List?) ?? [])
          .map(
            (item) => CatchRecord.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList(),
      photoPaths: ((json['photoPaths'] as List?) ?? [])
        .map((item) => item as String)
        .toList(),
      memo: json['memo'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'location': location,
      'startAt': startAt.toIso8601String(),
      'endAt': endAt.toIso8601String(),
      'genreName': genreName,
      'tide': tide,
      'weather': weather,
      'airTemperature': airTemperature,
      'waterTemperature': waterTemperature,
      'catches': catches.map((catchRecord) => catchRecord.toJson()).toList(),
      'photoPaths': photoPaths,
      'memo': memo,
    };
  }

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

  const CatchRecord({
    required this.speciesName,
    this.lengthCm,
    this.weightG,
  });

  factory CatchRecord.fromJson(Map<String, dynamic> json) {
    return CatchRecord(
      speciesName: json['speciesName'] as String,
      lengthCm: (json['lengthCm'] as num?)?.toDouble(),
      weightG: json['weightG'] as int?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'speciesName': speciesName,
      'lengthCm': lengthCm,
      'weightG': weightG,
    };
  }
}