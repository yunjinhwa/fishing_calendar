import 'package:fishing_build/data/fish/fish_size_summary.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('preserves body-length evidence and its meaning', () {
    for (final sentence in [
      '몸길이는 50cm이다.',
      '최대 전장 50cm이다.',
      '몸길이는 최대 50cm이다.',
      '암컷의 몸길이는 최대 50.5cm이다.',
      '수컷은 최대 체장 300밀리미터이다.',
      '몸길이는 최대 1.2 m이다.',
      '최대 전장은 35센티미터에 이른다.',
      '몸의 길이 약 30cm이다.',
      '전장 최대 1m',
      '몸길이 1m가량',
      '몸 길이는 보통 약 20cm 정도이다.',
      '몸길이는 20㎝이고 체장은 150㎜이다.',
      '몸길이는 1ｍ이다.',
      '표준체장은 12.5cm이고 전장은 15.2cm이다.',
      '체장 5~7cm이다.',
      '몸길이는 5.5–7.2 cm로 자란다.',
      '몸길이는 5 - 7cm로 자란다.',
      '연못에 살며 몸길이는 20cm이다.',
      '몸길이가 50cm에서 1m에 이른다.',
      '몸길이는 50에서 100cm이다.',
      '몸길이는 50cm부터 1m까지이다.',
      '체장은 20mm 내지 30mm이다.',
      '몸길이는 평균 50cm이고 최대 70cm이다.',
      '몸길이는 최대 50cm일 것으로 추정된다.',
      '수컷은 전장 30cm이고 암컷은 최대 전장 50cm이다.',
      '치어는 전장 5mm이고 성어는 전장 30cm로 자란다.',
    ]) {
      test(sentence, () {
        expect(extractFishSizeSummary('  $sentence  '), sentence);
      });
    }

    test(
      'preserves every age and adult qualifier rather than the first size',
      () {
        const growth =
            '부화 후 만 1년이면 가랑이체장 16cm, 2년이면 34cm, '
            '3년이면 43cm, 4년이면 54cm 전후로 자라며, '
            '다 자라면 전장 100cm 가량 자란다.';
        expect(extractFishSizeSummary(growth), growth);
      },
    );

    test(
      'keeps ordinary total length separate from maximum standard length',
      () {
        expect(
          extractFishSizeSummary('최대 체장 15cm까지 성장한다. 전장 약 16 cm이다.'),
          '최대 체장 15cm까지 성장한다.\n전장 약 16 cm이다.',
        );
      },
    );

    test('retains a preceding sex heading', () {
      expect(
        extractFishSizeSummary('수컷이다. 몸길이는 최대 50cm이다.'),
        '수컷이다. 몸길이는 최대 50cm이다.',
      );
    });

    test(
      'does not attach a previous male heading to an explicit female size',
      () {
        expect(
          extractFishSizeSummary('수컷이다. 암컷의 몸길이는 50cm이다.'),
          '암컷의 몸길이는 50cm이다.',
        );
      },
    );

    test(
      'keeps decimal dots and extracts size from long multi-sentence prose',
      () {
        final prose =
            '${'몸은 은빛이고 길쭉하다. ' * 200}'
            '수컷의 최대 전장은 약 10.5cm로 보고되어 있다. '
            '서식 수심은 18~105m이며 작은 갑각류를 먹는다.';
        expect(extractFishSizeSummary(prose), '수컷의 최대 전장은 약 10.5cm로 보고되어 있다.');
      },
    );

    test('normalizes layout whitespace without changing source wording', () {
      expect(
        extractFishSizeSummary('  몸길이는\t약   20cm이다.\n몸은 은빛이다. '),
        '몸길이는 약 20cm이다.',
      );
    });
  });

  group('isolates unrelated measurements only at clear clause boundaries', () {
    test('depth prefix does not become a body size', () {
      expect(
        extractFishSizeSummary('수심 최대 50m이고 몸길이는 20cm이다.'),
        '몸길이는 20cm이다.',
      );
    });

    test('body size before a separate depth clause', () {
      expect(
        extractFishSizeSummary('몸길이는 최대 50cm이고 서식 수심은 30m이다.'),
        '몸길이는 최대 50cm',
      );
    });

    test('mixed-unit body range survives a separate weight clause', () {
      expect(
        extractFishSizeSummary('몸길이가 50cm에서 1m에 이르며 무게가 5~8kg에 이르는 대형 어종이다.'),
        '몸길이가 50cm에서 1m에 이르며',
      );
    });

    test('does not select the first sex from an elliptical mixed sentence', () {
      expect(
        extractFishSizeSummary('수컷은 전장 30cm이고 암컷은 50cm이며 무게는 2kg이다.'),
        isEmpty,
      );
    });

    test('separate depth sentence cannot contaminate sex qualifier', () {
      expect(
        extractFishSizeSummary('서식 수심 18~105m. 수컷의 최대 전장은 약 10cm로 보고되어 있다.'),
        '수컷의 최대 전장은 약 10cm로 보고되어 있다.',
      );
    });
  });

  group('rejects unrelated, incomplete, negated and malformed evidence', () {
    for (final sentence in [
      '',
      '최대 수심은 300~600m이다.',
      '수심 25~1140m에서 산다.',
      '기대 수명은 최대 8년이다.',
      '최대 5만 마리까지 무리 지어 다닌다.',
      '몸무게는 최대 50kg이다.',
      '등지느러미 길이는 5cm이다.',
      '지느러미는 몸길이의 20%이며 길이는 5cm이다.',
      '몸길이의 20%인 지느러미는 5cm이다.',
      '알의 몸길이는 2mm이다.',
      '알은 지름이 2mm이다.',
      '먹이의 몸길이는 5cm이다.',
      '먹이로 몸길이 5cm인 작은 어류를 먹는다.',
      '몸길이 5cm인 작은 어류를 잡아먹는다.',
      '전장 10cm 이상이 되면 잡식성이 강해지며 15cm 이상에서는 성게를 먹는다.',
      '포란수는 체장 41~87cm이며 약 8만~200만 개의 알을 낳는다.',
      '몸길이는 최대 -50cm이다.',
      '몸길이는 최대 −50cm이다.',
      '몸길이는 최대 +50cm이다.',
      '몸길이는 최대 0cm이다.',
      '몸길이는 최대 0.0cm이다.',
      '몸길이는 최대 50이다.',
      '최대 전장 50cm가 아니다.',
      '몸길이는 50cm에 이르지 않는다.',
      '몸길이는 50cm 미만이 아니며 확인되지 않았다.',
      '몸길이는 미상이고 전장은 50cm이다.',
      '몸길이는 50cm이며 전장은 -20cm이다.',
      '몸길이는 평균 20cm이고 최대 -50cm이다.',
      '몸길이는 평균 20cm이고 최대 +50cm이다.',
      '몸길이는 평균 20cm이고 최대 50이다.',
      '수컷은 전장 30cm이고 암컷은 50이다.',
      '몸길이는 20cm~이다.',
      '몸길이는 20cm에서',
      '몸길이는 20cm 또는',
      '몸길이는 10^2cm이다.',
      '몸길이는 1e3cm이다.',
      '몸길이는 2×10cm이다.',
      '몸길이는 50cm²이다.',
      '몸길이는 50cm/s이다.',
      '몸길이는 50mmol이다.',
      '몸길이는 50ml이다.',
      '몸길이는 50m2이다.',
      '몸길이는 50m제곱이다.',
      '몸길이는 999999999cm이다.',
      '몸길이는 <b>20cm</b>이다.',
    ]) {
      test(sentence.isEmpty ? 'empty input' : sentence, () {
        expect(extractFishSizeSummary(sentence), isEmpty);
      });
    }
  });

  group('bounded output and work', () {
    test('keeps at most three whole source statements', () {
      expect(
        extractFishSizeSummary(
          '몸길이는 보통 20cm이다. 몸길이는 최대 30cm이다. '
          '수컷은 체장 15cm이다. 암컷은 체장 25cm이다.',
        ),
        '몸길이는 보통 20cm이다.\n몸길이는 최대 30cm이다.\n수컷은 체장 15cm이다.',
      );
    });

    test('does not truncate a long size context to an unqualified number', () {
      final sentence = '몸길이는 최대 50cm이며 ${'은빛 무늬가 있다 ' * 100}';
      expect(extractFishSizeSummary(sentence), isEmpty);
    });

    test('input beyond the bounded prefix is ignored', () {
      final description = '${'은빛이다. ' * 12000}몸길이는 최대 50cm이다.';
      expect(extractFishSizeSummary(description), isEmpty);
    });

    test(
      'truncated trailing statement is not treated as complete evidence',
      () {
        final description = '${' ' * (64 * 1024 - 8)}몸길이는20cm이다.';
        expect(extractFishSizeSummary(description), isEmpty);
      },
    );

    test('duplicate source statements are not repeated', () {
      expect(
        extractFishSizeSummary('몸길이는 20cm이다. 몸길이는 20cm이다.'),
        '몸길이는 20cm이다.',
      );
    });

    test('oversized candidates do not block later complete sentences', () {
      final description = '${'긴 설명 ' * 500}. 몸길이는 20cm이다.';
      expect(extractFishSizeSummary(description), '몸길이는 20cm이다.');
    });
  });
}
