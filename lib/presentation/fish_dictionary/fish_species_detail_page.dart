import 'package:flutter/material.dart';

import '../../data/models/fish_species.dart';
import '../auth/auth_access_guard.dart';
import '../record/record_form_page.dart';

class FishSpeciesDetailPage extends StatelessWidget {
  final FishSpecies fish;

  const FishSpeciesDetailPage({super.key, required this.fish});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(fish.name)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              height: 180,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.set_meal_outlined,
                      size: 64,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      fish.imageDescription,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),

            Text(
              fish.name,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),

            Row(
              children: [
                Chip(label: Text(fish.categoryLabel)),
                const SizedBox(width: 8),
                if (fish.hasClosedSeason) const Chip(label: Text('금어기 정보 있음')),
              ],
            ),
            const SizedBox(height: 24),

            _SectionTitle(title: '기본 정보'),
            const SizedBox(height: 8),
            _InfoCard(
              children: [
                _InfoRow(label: '분류', value: fish.family),
                _InfoRow(label: '서식지', value: fish.habitat),
                _InfoRow(label: '크기', value: fish.maxSize),
                _InfoRow(label: '특징', value: fish.feature),
              ],
            ),
            const SizedBox(height: 24),

            _SectionTitle(title: '금어기'),
            const SizedBox(height: 8),
            _InfoCard(
              children: [
                Text(
                  fish.closedSeasonText,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
            const SizedBox(height: 24),

            FilledButton.icon(
              onPressed: () async {
                final allowed = await requireMemberAccess(
                  context,
                  message: '도감의 어종을 출조 기록으로 저장하려면 로그인이 필요합니다.',
                );

                if (!allowed || !context.mounted) {
                  return;
                }

                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => RecordFormPage(initialFishName: fish.name),
                  ),
                );
              },
              icon: const Icon(Icons.edit_note),
              label: const Text('이 어종으로 기록 작성하기'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;

  const _SectionTitle({required this.title});

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final List<Widget> children;

  const _InfoCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(label, style: TextStyle(color: Colors.grey.shade600)),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
