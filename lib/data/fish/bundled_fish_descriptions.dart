import '../models/fish_species.dart';

/// Short Korean translations reviewed against pinned English article revisions.
/// These only fill gaps; verified live Korean descriptions keep priority.
class BundledFishDescriptions {
  static const _credit =
      '영어 위키백과 기여자 · 한국어 번역·요약 · CC BY-SA 4.0 · '
      'https://creativecommons.org/licenses/by-sa/4.0/';

  static const _entries =
      <
        String,
        ({String name, String description, String article, int revision})
      >{
        'strophidon sathete': (
          name: '가는곰치',
          description:
              '몸이 매우 길게 뻗은 곰치류로, 등 쪽은 회갈색이고 배 쪽으로 갈수록 옅어진다. '
              '홍해와 동아프리카에서 서태평양에 이르는 인도·서태평양에 분포한다. '
              '바다와 하구의 진흙 바닥에서 생활하며, 내만이나 강에서도 발견된다.',
          article: 'Slender giant moray',
          revision: 1370178422,
        ),
        'scomberoides tol': (
          name: '가시전갱이',
          description:
              '몸이 옆으로 납작하고 길쭉하며, 등 쪽은 청록색에서 청회색이고 배 쪽은 은백색이다. '
              '옆구리에는 세로로 긴 타원형 검은 반점이 5~8개 있으나 어린 개체에서는 희미하거나 없을 수 있다. '
              '인도·서태평양의 연안과 하구에 분포하며, 성어는 수면 가까이에서 작은 무리를 이루기도 한다.',
          article: 'Scomberoides tol',
          revision: 1363314457,
        ),
        'hypsagonus corniger': (
          name: '가시줄고기',
          description:
              '북서태평양의 차가운 바다에 사는 어류로, 오호츠크해 남부와 동해 북부에 분포한다. '
              '알려진 서식 수심은 18~105m이다. 수컷의 최대 전장은 약 10cm로 보고되어 있다.',
          article: 'Hypsagonus corniger',
          revision: 1271719228,
        ),
        'limanda aspera': (
          name: '각시가자미',
          description:
              '부드러운 모래 바닥에서 생활하는 저서성 가자미류이다. '
              '한국과 동해에서 오호츠크해·베링해를 거쳐 캐나다 서해안에 이르는 북태평양 온대 해역에 분포한다. '
              '눈이 있는 쪽은 올리브색에서 갈색이며 어두운 무늬가 있고, 등지느러미와 뒷지느러미는 누런빛을 띤다.',
          article: 'Yellowfin sole',
          revision: 1351305262,
        ),
      };

  static FishSpecies apply(FishSpecies fish) {
    if (fish.feature.trim().isNotEmpty) return fish;
    final key = fish.scientificName.trim().toLowerCase().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );
    final entry = _entries[key];
    if (entry == null || fish.name.trim() != entry.name) return fish;
    final source = Uri.https('en.wikipedia.org', '/w/index.php', {
      'title': entry.article,
      'oldid': '${entry.revision}',
    }).toString();
    return FishSpecies.fromJson({
      ...fish.toJson(),
      'feature': entry.description,
      'descriptionSourceUrl': source,
      'descriptionAttribution': _credit,
      'sourceName': {
        ...fish.sourceName.split(' · ').where((name) => name.isNotEmpty),
        '영어 위키백과 한국어 번역·요약',
      }.join(' · '),
    });
  }
}
