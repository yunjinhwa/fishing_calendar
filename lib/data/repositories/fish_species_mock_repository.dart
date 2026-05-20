import '../models/fish_species.dart';

class FishSpeciesMockRepository {
  FishSpeciesMockRepository._();

  static final FishSpeciesMockRepository instance =
      FishSpeciesMockRepository._();

  final List<FishSpecies> _items = const [
    FishSpecies(
      id: 'fish-001',
      name: '감성돔',
      category: FishCategory.sea,
      family: '농어목 도미과',
      habitat: '연안, 갯바위, 방파제',
      maxSize: '최대 60cm',
      feature: '검은 줄무늬와 강한 입질이 특징입니다.',
      hasClosedSeason: true,
      closedSeasonText: '지역 및 시기에 따라 금어기 제한이 있을 수 있습니다.',
      imageDescription: '감성돔 대표 이미지 자리',
    ),
    FishSpecies(
      id: 'fish-002',
      name: '참돔',
      category: FishCategory.sea,
      family: '농어목 도미과',
      habitat: '연안 암초, 깊은 바다',
      maxSize: '최대 100cm',
      feature: '붉은빛 몸색과 강한 힘이 특징입니다.',
      hasClosedSeason: false,
      closedSeasonText: '등록된 금어기 정보가 없습니다.',
      imageDescription: '참돔 대표 이미지 자리',
    ),
    FishSpecies(
      id: 'fish-003',
      name: '광어',
      category: FishCategory.sea,
      family: '가자미목 넙치과',
      habitat: '모래 바닥, 연안, 방파제 인근',
      maxSize: '최대 80cm 이상',
      feature: '납작한 몸과 바닥에 붙어 사는 습성이 특징입니다.',
      hasClosedSeason: false,
      closedSeasonText: '등록된 금어기 정보가 없습니다.',
      imageDescription: '광어 대표 이미지 자리',
    ),
    FishSpecies(
      id: 'fish-004',
      name: '우럭',
      category: FishCategory.sea,
      family: '쏨뱅이목 양볼락과',
      habitat: '암초, 방파제, 선상 포인트',
      maxSize: '최대 50cm',
      feature: '바닥층에서 잘 낚이며 입질이 묵직합니다.',
      hasClosedSeason: false,
      closedSeasonText: '등록된 금어기 정보가 없습니다.',
      imageDescription: '우럭 대표 이미지 자리',
    ),
    FishSpecies(
      id: 'fish-005',
      name: '벵에돔',
      category: FishCategory.sea,
      family: '농어목 황줄깜정이과',
      habitat: '갯바위, 여밭, 조류가 빠른 연안',
      maxSize: '최대 50cm',
      feature: '예민한 입질과 강한 파이팅이 특징입니다.',
      hasClosedSeason: false,
      closedSeasonText: '등록된 금어기 정보가 없습니다.',
      imageDescription: '벵에돔 대표 이미지 자리',
    ),
    FishSpecies(
      id: 'fish-006',
      name: '배스',
      category: FishCategory.freshwater,
      family: '검정우럭과',
      habitat: '호수, 저수지, 강',
      maxSize: '최대 70cm',
      feature: '루어낚시 대상어로 공격적인 입질이 특징입니다.',
      hasClosedSeason: false,
      closedSeasonText: '등록된 금어기 정보가 없습니다.',
      imageDescription: '배스 대표 이미지 자리',
    ),
  ];

  List<FishSpecies> getAllItems() {
    return List.unmodifiable(_items);
  }

  List<FishSpecies> search({
    String keyword = '',
    FishCategory? category,
    bool closedSeasonOnly = false,
  }) {
    final normalizedKeyword = keyword.trim();

    return _items.where((item) {
      final matchesKeyword =
          normalizedKeyword.isEmpty || item.name.contains(normalizedKeyword);

      final matchesCategory = category == null || item.category == category;

      final matchesClosedSeason =
          !closedSeasonOnly || item.hasClosedSeason;

      return matchesKeyword && matchesCategory && matchesClosedSeason;
    }).toList();
  }

  FishSpecies? findById(String id) {
    for (final item in _items) {
      if (item.id == id) {
        return item;
      }
    }

    return null;
  }
}