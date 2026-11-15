import 'dart:convert';

import '../../core/validation/fishing_record_validator.dart';
import '../models/fishing_record.dart';

/// A bounded JSON grammar that Firestore Rules can validate without iterating
/// over the catches. Writing is canonical; reading accepts safe float rounding.
class FirestoreCatchesCodec {
  FirestoreCatchesCodec._();

  static const String maxWeightDigits = '9223372036854775807';
  static const String maxSignificandDigits = '17976931348623157';
  static const int maxEncodedLength = 100000;
  static const String namePattern = r'"(?:\\u[0-9a-f]{4})+"';
  static const String oversizedNamePattern =
      r'.*"speciesName":"(?:\\u[0-9a-f]{4}){101,}".*';
  static const String whitespaceNamePattern =
      r'"(?:\\u(?:000[9a-d]|0020|0085|00a0|1680|200[0-a]|202[89f]|205f|3000|feff))+"';

  static final String unsignedWeightPattern =
      '(?:0|[1-9][0-9]{0,17}|${_boundedDigits(maxWeightDigits)})';

  /// Fixed 17 significant digits; all finite nonnegative doubles can be written
  /// this way. -0.0 retains its sign. The exponent-308 upper bound is exact.
  static final String finiteLengthPattern =
      r'(?:-?0\.0{16}e\+0|[1-9]\.[0-9]{16}e(?:\+(?:[0-9]|[1-9][0-9]|[12][0-9]{2}|30[0-7])|-(?:[1-9]|[1-9][0-9]|[12][0-9]{2}|3[01][0-9]|32[0-4]))|'
      '${_boundedDigits(maxSignificandDigits, decimalAfterFirst: true)}'
      r'e\+308)';

  static final String catchPattern =
      r'\{"speciesName":'
      '$namePattern'
      r',"lengthCm":(?:null|'
      '$finiteLengthPattern'
      r'),"weightG":(?:null|'
      '$unsignedWeightPattern'
      r')\}';

  static final String wholeArrayPattern =
      r'\[(?:'
      '$catchPattern'
      r'(?:,'
      '$catchPattern'
      r')*)?\]';

  /// Rules must reject this alongside matching [wholeArrayPattern].
  static final String whitespaceCatchPattern =
      '.*"speciesName":$whitespaceNamePattern.*';

  static final RegExp _arraySyntax = RegExp(wholeArrayPattern);
  static final RegExp _whitespaceCatch = RegExp(whitespaceCatchPattern);
  static final RegExp _oversizedName = RegExp(oversizedNamePattern);
  static final BigInt _maxWeight = BigInt.parse(maxWeightDigits);

  static String encode(List<CatchRecord> catches) {
    _validateCount(catches.length);
    return '[${catches.map((item) {
      _validateCatch(item);
      final escapedName = item.speciesName.codeUnits.map((unit) => '\\u${unit.toRadixString(16).padLeft(4, '0')}').join();
      final length = item.lengthCm?.toStringAsExponential(16) ?? 'null';
      final weight = item.weightG?.toString() ?? 'null';
      return '{"speciesName":"$escapedName","lengthCm":$length,"weightG":$weight}';
    }).join(',')}]';
  }

  static List<CatchRecord> decode(String encoded) {
    if (encoded.length > maxEncodedLength) {
      throw const FormatException('Encoded catches exceed the size limit.');
    }
    final syntaxMatch = _arraySyntax.matchAsPrefix(encoded);
    if (syntaxMatch == null ||
        syntaxMatch.end != encoded.length ||
        _whitespaceCatch.hasMatch(encoded) ||
        _oversizedName.hasMatch(encoded)) {
      throw const FormatException('Invalid encoded catches grammar.');
    }
    final decoded = jsonDecode(encoded);
    if (decoded is! List) {
      throw const FormatException('Catches must be a list.');
    }
    _validateCount(decoded.length);
    final catches = <CatchRecord>[];
    for (var index = 0; index < decoded.length; index++) {
      final value = decoded[index];
      if (value is! Map<String, dynamic> ||
          value.length != 3 ||
          !value.keys.toSet().containsAll(const [
            'speciesName',
            'lengthCm',
            'weightG',
          ]) ||
          value['speciesName'] is! String ||
          (value['lengthCm'] != null && value['lengthCm'] is! num) ||
          (value['weightG'] != null && value['weightG'] is! int)) {
        throw FormatException('Invalid catch at index $index.');
      }
      final item = CatchRecord(
        speciesName: value['speciesName'] as String,
        lengthCm: (value['lengthCm'] as num?)?.toDouble(),
        weightG: value['weightG'] as int?,
      );
      _validateCatch(item);
      catches.add(item);
    }
    // Safe grammar numbers may round to the same double, so re-encoding need
    // not reproduce their exact decimal text. Do not reject those documents.
    return List<CatchRecord>.unmodifiable(catches);
  }

  static void _validateCount(int count) {
    if (count > FishingRecordValidator.maxCatchCount) {
      throw const FormatException('Too many catches.');
    }
  }

  static void _validateCatch(CatchRecord item) {
    final name = item.speciesName;
    if (name.trim().isEmpty ||
        name.length > FishingRecordValidator.maxSpeciesNameLength ||
        _whitespaceCatch.hasMatch('{"speciesName":${_escapeName(name)}}')) {
      throw const FormatException('Invalid species name.');
    }
    final length = item.lengthCm;
    if (length != null && (!length.isFinite || length < 0)) {
      throw const FormatException('Invalid catch length.');
    }
    final weight = item.weightG;
    if (weight != null && (weight < 0 || BigInt.from(weight) > _maxWeight)) {
      throw const FormatException('Invalid catch weight.');
    }
  }

  static String _escapeName(String name) =>
      '"${name.codeUnits.map((unit) => '\\u${unit.toRadixString(16).padLeft(4, '0')}').join()}"';

  /// Exact-width digit ranges from the smallest positive number to [maximum].
  /// The optional decimal point follows the first digit of a significand.
  static String _boundedDigits(
    String maximum, {
    bool decimalAfterFirst = false,
  }) {
    final alternatives = <String>[];
    String withDecimal(List<String> tokens) => decimalAfterFirst
        ? '${tokens.first}\\.${tokens.skip(1).join()}'
        : tokens.join();
    for (var index = 0; index < maximum.length; index++) {
      final upperDigit = int.parse(maximum[index]);
      final lowerDigit = index == 0 ? 1 : 0;
      if (upperDigit <= lowerDigit) continue;
      final tokens = <String>[
        ...maximum.substring(0, index).split(''),
        upperDigit - 1 == lowerDigit
            ? '$lowerDigit'
            : '[$lowerDigit-${upperDigit - 1}]',
        if (index + 1 < maximum.length) '[0-9]{${maximum.length - index - 1}}',
      ];
      alternatives.add(withDecimal(tokens));
    }
    alternatives.add(withDecimal(maximum.split('')));
    return '(?:${alternatives.join('|')})';
  }
}
