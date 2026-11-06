/// Selects explicit body-length statements from already verified Korean prose.
///
/// This is an extract, not a maximum-size calculator: wording, units, ranges,
/// sex and growth conditions stay in the source. Ambiguous statements are left
/// out rather than assigning a measurement to a different subject.
String extractFishSizeSummary(String description) {
  if (description.isEmpty) return '';
  final wasTruncated = description.length > _maxInputLength;
  final bounded = wasTruncated
      ? description.substring(0, _maxInputLength)
      : description;
  final selected = <String>[];
  var outputLength = 0;
  var previous = '';
  for (final raw in _sentences(bounded, keepTail: !wasTruncated)) {
    final sentence = raw.replaceAll(_whitespace, ' ').trim();
    if (sentence.isEmpty || sentence.length > _maxCandidateLength) {
      previous = '';
      continue;
    }
    final clauses = _sizeClauses(sentence);
    for (var clause in clauses) {
      // A short preceding sex/age heading must not silently disappear. For
      // example, "수컷이다. 몸길이는 20cm이다." stays qualified as male.
      if (_contextHeading.hasMatch(previous) &&
          !_explicitContext.hasMatch(clause)) {
        clause = '$previous $clause';
      }
      if (clause.length > _maxOutputLength || selected.contains(clause)) {
        continue;
      }
      final separatorLength = selected.isEmpty ? 0 : 1;
      if (selected.length >= _maxOutputLines ||
          outputLength + separatorLength + clause.length > _maxOutputLength) {
        continue;
      }
      selected.add(clause);
      outputLength += separatorLength + clause.length;
    }
    previous = sentence.length <= _maxContextLength ? sentence : '';
  }
  return selected.join('\n');
}

const _maxInputLength = 64 * 1024;
const _maxCandidateLength = 1500;
const _maxContextLength = 120;
const _maxOutputLength = 450;
const _maxOutputLines = 3;

const _lengthType = r'(?:몸\s*길이|몸의\s*길이|가랑이\s*체장|표준\s*체장|체장|전장)';
const _number = r'\d{1,8}(?:\.\d{1,6})?';
const _unit =
    r'(?:밀리미터|센티미터|미터|mm|cm|m|㎜|㎝|ｍ)'
    r'(?![a-zA-Z0-9²³⁰¹⁴⁵⁶⁷⁸⁹^/／·×⁻⁺])';
const _rangeSeparator = r'(?:[~～〜–—-]|에서|부터|내지)';
const _measure =
    '(?:$_number\\s*(?:$_unit\\s*)?$_rangeSeparator\\s*'
    '$_number\\s*$_unit|$_number\\s*$_unit)';
const _qualifier = r'(?:최대(?:로)?|평균|보통|대개|통상|약|대략|일반적으로)';

final _whitespace = RegExp(r'\s+');
final _lengthLabels = RegExp(_lengthType);
final _bodyMeasurements = RegExp(
  '$_lengthType\\s*(?:는|은|이|가|의)?\\s*'
  '(?:$_qualifier\\s*){0,4}$_measure',
  caseSensitive: false,
);
final _measurements = RegExp(_measure, caseSensitive: false);
final _numbers = RegExp(_number);
final _signedMeasurements = RegExp('[-−+]\\s*$_measure', caseSensitive: false);
final _rangeStart = RegExp('(?:[0-9]|$_unit)\\s*\$', caseSensitive: false);
final _qualifiedNumbers = RegExp(
  '(?:최대|평균|약|대략|(?:수컷|암컷)(?:은|는))\\s*($_number)',
);
final _badMeasureTail = RegExp(
  r'^\s*(?:[~～〜–—+±^/／²³]|[-−]\s*\d|에서\s*$|부터\s*$|내지\s*$|'
  r'또는\s*$|혹은\s*$|제곱|세제곱)',
);
final _unsafeContext = RegExp(
  r'수심|서식심도|깊이|해발|수온|무게|중량|체중|질량|'
  r'지느러미|주둥이|꼬리길이|머리길이|두장|난경|알의|알은|알을|포란|'
  r'먹이|먹는|먹는다|먹으며|먹고|섭식|잡아\s*먹|포식|잡식|육식|초식|식성|'
  r'그물|어망|수조|낚싯|'
  r'아니|않|(?<![가-힣])못|없|미상|불명|미확인|%|퍼센트|'
  r'\bkg\b|그램|킬로그램|\d\s*g\b|'
  r'<|>|\^|[²³]|\d\s*[eE]\s*[+−-]?\d|\d\s*[×*]\s*\d',
  caseSensitive: false,
);
// Splitting is only a fallback for sentences that mix body size with a
// different measurement. Never split a clear sex/age/range statement merely
// to pick its first number.
final _clauseBoundary = RegExp(
  r'[,，]|(?:이고|이며|이지만|지만|는데)\s*|'
  r'\s+(?=(?:수심|서식심도|깊이|무게|중량|체중|질량|지느러미|먹이))',
);
final _contextHeading = RegExp(
  r'^(?:수컷|암컷|성어|성체|치어|유어|어린\s*개체|\d{1,3}년생)'
  r'(?:은|는|의\s*경우)?(?:이다|다음과\s*같다)?[.:：]?$|'
  r'^(?:수컷|암컷)(?:은|는)\s*[^0-9]{1,60}[.]$',
);
final _explicitContext = RegExp(r'수컷|암컷|성어|성체|치어|유어|어린\s*개체|\d{1,3}년생');
final _subjectScope = RegExp(
  r'먹이|먹는|섭식|잡아\s*먹|포식|난경|알의|알은|알을|포란|'
  r'아니|않|(?<![가-힣])못|없|미상|불명|미확인|%|퍼센트',
);
final _negation = RegExp(r'아니|않|(?<![가-힣])못|없|미상|불명|미확인');

Iterable<String> _sentences(String text, {required bool keepTail}) sync* {
  var start = 0;
  for (var i = 0; i < text.length; i++) {
    final code = text.codeUnitAt(i);
    if (code == 46 &&
        i > 0 &&
        i + 1 < text.length &&
        _isDigit(text.codeUnitAt(i - 1)) &&
        _isDigit(text.codeUnitAt(i + 1))) {
      continue;
    }
    if (code == 46 ||
        code == 33 ||
        code == 63 ||
        code == 0x3002 ||
        code == 59 ||
        code == 0xff1b ||
        code == 10 ||
        code == 13) {
      yield text.substring(start, i + 1);
      start = i + 1;
    }
  }
  if (keepTail && start < text.length) yield text.substring(start);
}

bool _isDigit(int code) => code >= 48 && code <= 57;

List<String> _sizeClauses(String sentence) {
  if (!_lengthLabels.hasMatch(sentence)) return const [];
  if (_isClearSize(sentence)) return [sentence];
  if (!_unsafeContext.hasMatch(sentence)) return const [];
  if (_negation.hasMatch(sentence)) return const [];

  // A prey/egg/negated/proportional subject before the length label is not a
  // statement about this fish. Removing that prefix would change its meaning.
  final firstLength = _lengthLabels.firstMatch(sentence)!;
  if (_subjectScope.hasMatch(sentence.substring(0, firstLength.start))) {
    return const [];
  }
  final parts = sentence.split(_clauseBoundary);
  if (parts.length < 2) return const [];
  final selected = <String>[];
  for (final part in parts) {
    final clause = part.trim();
    if (clause.isEmpty) continue;
    if (_isClearSize(clause)) {
      selected.add(clause);
    } else if (_measurements.hasMatch(clause) &&
        !_unsafeContext.hasMatch(clause)) {
      // An omitted subject can inherit body length from an earlier clause
      // ("수컷은 전장 30cm이고 암컷은 50cm..."). Do not keep only the male.
      return const [];
    }
  }
  return selected;
}

bool _isClearSize(String sentence) {
  if (sentence.isEmpty || _unsafeContext.hasMatch(sentence)) return false;
  final labels = _lengthLabels.allMatches(sentence).toList();
  final evidence = _bodyMeasurements.allMatches(sentence).toList();
  if (evidence.isEmpty || evidence.length != labels.length) return false;
  for (final signed in _signedMeasurements.allMatches(sentence)) {
    // A hyphen after a number/unit is a source range. A signed second size is
    // still invalid even if the sentence began with a valid ordinary size.
    if (signed.group(0)!.startsWith('+') ||
        !_rangeStart.hasMatch(sentence.substring(0, signed.start))) {
      return false;
    }
  }
  for (final qualified in _qualifiedNumbers.allMatches(sentence)) {
    final numberStart = qualified.end - qualified.group(1)!.length;
    if (_measurements.matchAsPrefix(sentence, numberStart) == null) {
      return false;
    }
  }
  for (var i = 0; i < labels.length; i++) {
    if (labels[i].start != evidence[i].start) return false;
    for (final value in _numbers.allMatches(evidence[i].group(0)!)) {
      if (double.parse(value.group(0)!) <= 0) return false;
    }
    if (_badMeasureTail.hasMatch(sentence.substring(evidence[i].end))) {
      return false;
    }
  }
  // No invalid secondary values may hide behind an otherwise valid first
  // measurement, including growth sequences and ordinary/maximum pairs.
  for (final value in _measurements.allMatches(sentence)) {
    for (final number in _numbers.allMatches(value.group(0)!)) {
      if (double.parse(number.group(0)!) <= 0) return false;
    }
    if (_badMeasureTail.hasMatch(sentence.substring(value.end))) return false;
  }
  return true;
}
