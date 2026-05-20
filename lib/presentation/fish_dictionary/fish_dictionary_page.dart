import 'package:flutter/material.dart';

import '../../data/models/fish_species.dart';
import '../../data/repositories/fish_species_mock_repository.dart';
import 'fish_species_detail_page.dart';

class FishDictionaryPage extends StatefulWidget {
  const FishDictionaryPage({super.key});

  @override
  State<FishDictionaryPage> createState() => _FishDictionaryPageState();
}

class _FishDictionaryPageState extends State<FishDictionaryPage> {
  final searchController = TextEditingController();

  FishCategory? selectedCategory;
  bool closedSeasonOnly = false;

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  List<FishSpecies> get filteredItems {
    return FishSpeciesMockRepository.instance.search(
      keyword: searchController.text,
      category: selectedCategory,
      closedSeasonOnly: closedSeasonOnly,
    );
  }

  void selectCategory(FishCategory? category) {
    setState(() {
      selectedCategory = category;
      closedSeasonOnly = false;
    });
  }

  void toggleClosedSeasonOnly() {
    setState(() {
      closedSeasonOnly = !closedSeasonOnly;
      selectedCategory = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final items = filteredItems;

    return Scaffold(
      appBar: AppBar(
        title: const Text('어류도감'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: searchController,
                decoration: const InputDecoration(
                  labelText: '어종 검색',
                  hintText: '예: 감성돔, 광어, 배스',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (_) {
                  setState(() {});
                },
              ),
            ),

            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  ChoiceChip(
                    label: const Text('전체'),
                    selected:
                        selectedCategory == null && closedSeasonOnly == false,
                    onSelected: (_) => selectCategory(null),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('바다'),
                    selected: selectedCategory == FishCategory.sea,
                    onSelected: (_) => selectCategory(FishCategory.sea),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('민물'),
                    selected: selectedCategory == FishCategory.freshwater,
                    onSelected: (_) => selectCategory(FishCategory.freshwater),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('금어기'),
                    selected: closedSeasonOnly,
                    onSelected: (_) => toggleClosedSeasonOnly(),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 8),

            Expanded(
              child: items.isEmpty
                  ? const _EmptyFishView()
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: items.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final fish = items[index];

                        return _FishSpeciesCard(
                          fish: fish,
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => FishSpeciesDetailPage(
                                  fish: fish,
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FishSpeciesCard extends StatelessWidget {
  final FishSpecies fish;
  final VoidCallback onTap;

  const _FishSpeciesCard({
    required this.fish,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: const Icon(Icons.set_meal_outlined),
        ),
        title: Text(
          fish.name,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: Text(
          '${fish.categoryLabel} · ${fish.family}\n${fish.feature}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        isThreeLine: true,
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

class _EmptyFishView extends StatelessWidget {
  const _EmptyFishView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search_off_outlined,
              size: 56,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              '검색 결과가 없습니다.',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              '검색어 또는 필터 조건을 변경해보세요.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}