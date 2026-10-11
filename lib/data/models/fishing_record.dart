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
  final List<RecordPhoto> photos;
  final String? memo;

  FishingRecord({
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
    List<RecordPhoto> photos = const [],
    List<String> photoPaths = const [],
    this.memo,
  }) : photos = List<RecordPhoto>.unmodifiable(
         photos.isNotEmpty ? photos : _legacyPhotos(photoPaths),
       );

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
            (item) =>
                CatchRecord.fromJson(Map<String, dynamic>.from(item as Map)),
          )
          .toList(),
      photos: _photosFromJson(json),
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
      'photos': photos.map((photo) => photo.toJson()).toList(),
      'memo': memo,
    };
  }

  /// Device-local paths kept for compatibility with the existing UI.
  ///
  /// Cloud-only photos intentionally do not appear in this view.
  List<String> get photoPaths => List<String>.unmodifiable(
    photos.map((photo) => photo.localPath).whereType<String>(),
  );

  static List<RecordPhoto> _photosFromJson(Map<String, dynamic> json) {
    if (json.containsKey('photos')) {
      return ((json['photos'] as List?) ?? const <Object?>[])
          .map(
            (item) =>
                RecordPhoto.fromJson(Map<String, dynamic>.from(item as Map)),
          )
          .toList(growable: false);
    }

    final legacyPaths = ((json['photoPaths'] as List?) ?? const <Object?>[])
        .map((item) => item as String)
        .toList(growable: false);
    return _legacyPhotos(legacyPaths);
  }

  static List<RecordPhoto> _legacyPhotos(List<String> paths) {
    return <RecordPhoto>[
      for (var index = 0; index < paths.length; index++)
        RecordPhoto(id: 'legacy-$index', localPath: paths[index]),
    ];
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

class RecordPhoto {
  final String id;
  final String? localPath;
  final String? contentType;
  final int? sizeBytes;
  final String? checksum;

  const RecordPhoto({
    required this.id,
    this.localPath,
    this.contentType,
    this.sizeBytes,
    this.checksum,
  });

  factory RecordPhoto.fromJson(Map<String, dynamic> json) {
    return RecordPhoto(
      id: json['id'] as String,
      localPath: json['localPath'] as String?,
      contentType: json['contentType'] as String?,
      sizeBytes: (json['sizeBytes'] as num?)?.toInt(),
      checksum: json['checksum'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'localPath': localPath,
      'contentType': contentType,
      'sizeBytes': sizeBytes,
      'checksum': checksum,
    };
  }
}

class CatchRecord {
  final String speciesName;
  final double? lengthCm;
  final int? weightG;

  const CatchRecord({required this.speciesName, this.lengthCm, this.weightG});

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
