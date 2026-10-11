import 'package:fishing_build/core/validation/fishing_record_validator.dart';
import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('accepts values at every Firestore boundary', () {
    final record = _record(
      id: 'r' * FishingRecordValidator.maxDocumentIdLength,
      location: '장' * FishingRecordValidator.maxLocationLength,
      genreName: '장' * FishingRecordValidator.maxGenreNameLength,
      catches: List<CatchRecord>.filled(
        FishingRecordValidator.maxCatchCount,
        CatchRecord(
          speciesName: '어' * FishingRecordValidator.maxSpeciesNameLength,
          lengthCm: 0,
          weightG: 0,
        ),
      ),
      memo: '메' * FishingRecordValidator.maxMemoLength,
    );

    expect(FishingRecordValidator.validate(record), isNull);
  });

  test('rejects text and list values beyond Firestore limits', () {
    expect(
      FishingRecordValidator.validate(
        _record(location: '장' * (FishingRecordValidator.maxLocationLength + 1)),
      ),
      contains('위치는'),
    );
    expect(
      FishingRecordValidator.validate(
        _record(
          genreName: '장' * (FishingRecordValidator.maxGenreNameLength + 1),
        ),
      ),
      contains('낚시 장르는'),
    );
    expect(
      FishingRecordValidator.validate(
        _record(
          catches: List<CatchRecord>.filled(
            FishingRecordValidator.maxCatchCount + 1,
            const CatchRecord(speciesName: '우럭'),
          ),
        ),
      ),
      contains('조과는 최대'),
    );
    expect(
      FishingRecordValidator.validate(
        _record(memo: '메' * (FishingRecordValidator.maxMemoLength + 1)),
      ),
      contains('메모는'),
    );
  });

  test('rejects non-finite and negative measurements', () {
    expect(
      FishingRecordValidator.validate(_record(airTemperature: double.nan)),
      contains('기온'),
    );
    expect(
      FishingRecordValidator.validate(
        _record(waterTemperature: double.infinity),
      ),
      contains('수온'),
    );
    expect(
      FishingRecordValidator.validate(
        _record(
          catches: const <CatchRecord>[
            CatchRecord(speciesName: '우럭', lengthCm: double.nan),
          ],
        ),
      ),
      contains('크기는'),
    );
    expect(
      FishingRecordValidator.validate(
        _record(
          catches: const <CatchRecord>[
            CatchRecord(speciesName: '우럭', weightG: -1),
          ],
        ),
      ),
      contains('무게는'),
    );
  });

  test('accepts local photo values at configured boundaries', () {
    final photos = <RecordPhoto>[
      for (var index = 0; index < FishingRecordValidator.maxPhotoCount; index++)
        RecordPhoto(
          id: 'photo_$index',
          localPath: 'photo-$index.jpg',
          contentType: 'image/jpeg',
          sizeBytes: FishingRecordValidator.maxPhotoBytes,
          checksum: 'a' * 64,
        ),
    ];

    expect(FishingRecordValidator.validate(_record(photos: photos)), isNull);
  });

  test('accepts legacy local photos without generated metadata', () {
    expect(
      FishingRecordValidator.validate(
        _record(
          photos: const <RecordPhoto>[
            RecordPhoto(id: 'legacy-0', localPath: 'legacy.jpg'),
          ],
        ),
      ),
      isNull,
    );
  });

  test('rejects too many photos and duplicate or unsafe photo IDs', () {
    expect(
      FishingRecordValidator.validate(
        _record(
          photos: List<RecordPhoto>.generate(
            FishingRecordValidator.maxPhotoCount + 1,
            (index) => RecordPhoto(id: 'photo_$index', localPath: '$index.jpg'),
          ),
        ),
      ),
      contains('최대 10장'),
    );
    expect(
      FishingRecordValidator.validate(
        _record(
          photos: const <RecordPhoto>[
            RecordPhoto(id: 'duplicate', localPath: 'one.jpg'),
            RecordPhoto(id: 'duplicate', localPath: 'two.jpg'),
          ],
        ),
      ),
      contains('중복'),
    );
    expect(
      FishingRecordValidator.validate(
        _record(
          photos: const <RecordPhoto>[
            RecordPhoto(id: 'unsafe/id', localPath: 'photo.jpg'),
          ],
        ),
      ),
      contains('ID 형식'),
    );
    expect(
      FishingRecordValidator.validate(
        _record(
          photos: <RecordPhoto>[
            RecordPhoto(
              id: 'p' * (FishingRecordValidator.maxPhotoIdLength + 1),
              localPath: 'photo.jpg',
            ),
          ],
        ),
      ),
      contains('ID 형식'),
    );
  });

  test('rejects invalid photo size, content type, and missing local path', () {
    expect(
      FishingRecordValidator.validate(
        _record(
          photos: <RecordPhoto>[
            RecordPhoto(
              id: 'empty',
              localPath: 'empty.jpg',
              contentType: 'image/jpeg',
              sizeBytes: 0,
              checksum: 'a' * 64,
            ),
          ],
        ),
      ),
      contains('10 MiB 이하'),
    );
    expect(
      FishingRecordValidator.validate(
        _record(
          photos: <RecordPhoto>[
            RecordPhoto(
              id: 'too_large',
              localPath: 'large.jpg',
              contentType: 'image/jpeg',
              sizeBytes: FishingRecordValidator.maxPhotoBytes + 1,
              checksum: 'a' * 64,
            ),
          ],
        ),
      ),
      contains('10 MiB 이하'),
    );
    expect(
      FishingRecordValidator.validate(
        _record(
          photos: <RecordPhoto>[
            RecordPhoto(
              id: 'gif',
              localPath: 'photo.gif',
              contentType: 'image/gif',
              sizeBytes: 1,
              checksum: 'a' * 64,
            ),
          ],
        ),
      ),
      contains('JPEG, PNG, WebP'),
    );
    expect(
      FishingRecordValidator.validate(
        _record(
          photos: const <RecordPhoto>[RecordPhoto(id: 'missing_local_path')],
        ),
      ),
      contains('파일 경로'),
    );
  });
}

FishingRecord _record({
  String id = 'record-id',
  String location = '테스트 방파제',
  String genreName = '바다낚시',
  double? airTemperature = 24,
  double? waterTemperature = 20,
  List<CatchRecord> catches = const <CatchRecord>[
    CatchRecord(speciesName: '우럭', lengthCm: 31, weightG: 820),
  ],
  List<RecordPhoto> photos = const <RecordPhoto>[],
  String? memo = '테스트 메모',
}) {
  return FishingRecord(
    id: id,
    location: location,
    startAt: DateTime(2026, 9, 28, 8),
    endAt: DateTime(2026, 9, 28, 10),
    genreName: genreName,
    tide: '3물',
    weather: '맑음',
    airTemperature: airTemperature,
    waterTemperature: waterTemperature,
    catches: catches,
    photos: photos,
    memo: memo,
  );
}
