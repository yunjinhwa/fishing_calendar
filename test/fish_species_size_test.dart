import 'package:fishing_build/data/models/fish_species.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'old JSON without size derives body length and preserves source metadata',
    () {
      final fish = FishSpecies.fromJson({
        'id': 'cached-fish',
        'name': '저장된 어종',
        'scientificName': 'Genus species',
        'feature': '수심은 100m이다. 몸길이는 약 20cm이다.',
        'maxSize': '',
        'descriptionSourceUrl': 'https://ko.wikipedia.org/wiki/Source',
        'descriptionAttribution': '원문 기여자',
      });
      expect(fish.maxSize, contains('20cm'));
      expect(fish.maxSize, isNot(contains('100m')));
      expect(fish.descriptionAttribution, '원문 기여자');
      expect(fish.scientificName, 'Genus species');
      expect(FishSpecies.fromJson(fish.toJson()).maxSize, fish.maxSize);
    },
  );

  test(
    'a supplied size keeps priority over lengths mentioned in the description',
    () {
      const fish = FishSpecies(
        id: 'existing-size',
        name: '어종',
        maxSize: '최대 전장 80cm (암컷)',
        feature: '어린 개체의 몸길이는 10cm이다.',
      );
      expect(fish.sizeDescription, fish.maxSize);
      expect(fish.withDerivedSize(), same(fish));
      expect(FishSpecies.fromJson(fish.toJson()).maxSize, fish.maxSize);
    },
  );

  test(
    'const description data displays qualified length before any API load',
    () {
      const fish = FishSpecies(
        id: 'offline-size',
        name: '어종',
        feature: '등 쪽은 갈색이다. 수컷의 최대 전장은 약 10cm이다.',
      );
      expect(fish.sizeDescription, contains('수컷'));
      expect(fish.sizeDescription, contains('최대'));
      expect(fish.sizeDescription, contains('10cm'));
      final enriched = fish.withDerivedSize();
      expect(enriched.maxSize, fish.sizeDescription);
      expect(enriched.withDerivedSize(), same(enriched));
    },
  );

  test('depth, prey weight and fin size do not become the fish size', () {
    const fish = FishSpecies(
      id: 'no-body-size',
      name: '어종',
      feature: '수심은 100m이다. 먹이의 무게는 10g이다. 등지느러미 길이는 3cm이다.',
    );
    expect(fish.sizeDescription, isEmpty);
    expect(fish.withDerivedSize(), same(fish));
    expect(FishSpecies.fromJson(fish.toJson()).maxSize, isEmpty);
  });
}
