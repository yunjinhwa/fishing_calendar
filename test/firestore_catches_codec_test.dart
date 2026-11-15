import 'dart:math';

import 'package:fishing_build/data/models/fishing_record.dart';
import 'package:fishing_build/data/remote/firestore_catches_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('empty catches use an empty JSON array', () {
    expect(FirestoreCatchesCodec.encode([]), '[]');
    expect(FirestoreCatchesCodec.decode('[]'), isEmpty);
  });

  test('canonical writing fixes field order, escapes and number notation', () {
    const catches = [
      CatchRecord(speciesName: '우럭', lengthCm: 31.25, weightG: 820),
    ];
    expect(
      FirestoreCatchesCodec.encode(catches),
      r'[{"speciesName":"\uc6b0\ub7ed","lengthCm":3.1250000000000000e+1,"weightG":820}]',
    );
  });

  test('100 catches and UTF16 names round-trip', () {
    final catches = List.generate(
      100,
      (index) => CatchRecord(
        speciesName: '물고기 $index 🐟 " \\ \t\n',
        lengthCm: index / 8,
        weightG: index,
      ),
    );
    final encoded = FirestoreCatchesCodec.encode(catches);
    final decoded = FirestoreCatchesCodec.decode(encoded);
    expect(
      decoded.map((item) => item.toJson()),
      catches.map((item) => item.toJson()),
    );
    expect(FirestoreCatchesCodec.encode(decoded), encoded);
  });

  for (final length in [
    null,
    0.0,
    -0.0,
    0.1,
    31.2,
    double.minPositive,
    double.maxFinite,
  ]) {
    test('finite length $length survives the shared grammar', () {
      final original = CatchRecord(speciesName: '갈치', lengthCm: length);
      final encoded = FirestoreCatchesCodec.encode([original]);
      final decoded = FirestoreCatchesCodec.decode(encoded).single;
      expect(decoded.lengthCm, length);
      if (length != null) {
        expect(decoded.lengthCm!.isNegative, length.isNegative);
      }
      expect(FirestoreCatchesCodec.encode([decoded]), encoded);
    });
  }

  test('maximum signed 64-bit weight round-trips exactly', () {
    final weight = int.parse(FirestoreCatchesCodec.maxWeightDigits);
    final encoded = FirestoreCatchesCodec.encode([
      CatchRecord(speciesName: '우럭', weightG: weight),
    ]);
    expect(FirestoreCatchesCodec.decode(encoded).single.weightG, weight);
  });

  test(
    'safe decimal rounding is readable even if writing would normalize it',
    () {
      const encoded =
          r'[{"speciesName":"\uc6b0","lengthCm":1.0000000000000001e+0,"weightG":null}]';
      final decoded = FirestoreCatchesCodec.decode(encoded);
      expect(decoded.single.lengthCm, 1.0);
      expect(FirestoreCatchesCodec.encode(decoded), isNot(encoded));
    },
  );

  test('finite values across all exponent ranges preserve their values', () {
    final random = Random(307);
    for (var exponent = -324; exponent <= 308; exponent++) {
      final length = double.parse(
        '${1 + random.nextInt(8)}.1234567890123456e$exponent',
      );
      if (!length.isFinite) continue;
      final decoded = FirestoreCatchesCodec.decode(
        FirestoreCatchesCodec.encode([
          CatchRecord(speciesName: '어종 🐟', lengthCm: length),
        ]),
      ).single;
      expect(decoded.lengthCm, length, reason: 'exponent $exponent');
    }
  });

  test('escaped UTF16 including lone surrogates remains readable', () {
    for (final name in ['어종\ud800', '어종\udc00', '어종\u0000']) {
      final decoded = FirestoreCatchesCodec.decode(
        FirestoreCatchesCodec.encode([CatchRecord(speciesName: name)]),
      ).single;
      expect(decoded.speciesName.codeUnits, name.codeUnits);
    }
    expect(
      FirestoreCatchesCodec.wholeArrayPattern.length,
      lessThanOrEqualTo(4096),
    );
  });

  test('names are bounded by UTF16 code units including surrogate pairs', () {
    final validName = '🐟' * 50;
    expect(
      FirestoreCatchesCodec.decode(
        FirestoreCatchesCodec.encode([CatchRecord(speciesName: validName)]),
      ).single.speciesName,
      validName,
    );
    expect(
      () => FirestoreCatchesCodec.encode([CatchRecord(speciesName: '🐟' * 51)]),
      throwsFormatException,
    );
  });

  for (final name in ['', ' ', '\t\r\n', '\u0085', '\u2003\ufeff']) {
    test('blank species name ${name.codeUnits} is rejected', () {
      expect(
        () => FirestoreCatchesCodec.encode([CatchRecord(speciesName: name)]),
        throwsFormatException,
      );
    });
  }

  test('invalid local lengths, weights and oversized catches are rejected', () {
    for (final length in [
      -1.0,
      double.nan,
      double.infinity,
      double.negativeInfinity,
    ]) {
      expect(
        () => FirestoreCatchesCodec.encode([
          CatchRecord(speciesName: '우럭', lengthCm: length),
        ]),
        throwsFormatException,
      );
    }
    expect(
      () => FirestoreCatchesCodec.encode([
        const CatchRecord(speciesName: '우럭', weightG: -1),
      ]),
      throwsFormatException,
    );
    expect(
      () => FirestoreCatchesCodec.encode(
        List.filled(101, const CatchRecord(speciesName: '우럭')),
      ),
      throwsFormatException,
    );
  });

  test('unsafe grammar, overflow and malformed fields are rejected', () {
    const valid = r'[{"speciesName":"\uc6b0","lengthCm":null,"weightG":null}]';
    for (final encoded in [
      '[42]',
      '[{}]',
      valid.replaceFirst(r'\uc6b0', '우'),
      valid.replaceFirst(r'\uc6b0', r'\uC6B0'),
      valid.replaceFirst(r'\uc6b0', r'\u0020'),
      valid.replaceFirst('"weightG":null', '"weightG":9223372036854775808'),
      valid.replaceFirst('"weightG":null', '"weightG":1.0'),
      valid.replaceFirst(
        '"lengthCm":null',
        '"lengthCm":1.8000000000000000e+308',
      ),
      valid.replaceFirst(
        '"lengthCm":null',
        '"lengthCm":1.0000000000000000e+309',
      ),
      valid.replaceFirst(
        '"lengthCm":null',
        '"lengthCm":-1.0000000000000000e+0',
      ),
      valid.replaceFirst('"lengthCm":null', '"lengthCm":"1"'),
      valid.replaceFirst('"lengthCm":null,', ''),
      valid.replaceFirst('"weightG":null', '"weightG":null,"quantity":1'),
      '$valid\n',
      ' $valid',
      '[${List.filled(101, valid.substring(1, valid.length - 1)).join(',')}]',
    ]) {
      expect(
        () => FirestoreCatchesCodec.decode(encoded),
        throwsFormatException,
        reason: encoded,
      );
    }
  });
}
