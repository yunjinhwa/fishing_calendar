import 'package:flutter/material.dart';

import '../../data/models/personal_best_record.dart';
import '../../data/repositories/fishing_record_repository.dart';
import '../../data/repositories/personal_best_repository.dart';
import 'personal_best_detail_page.dart';

class PersonalBestPage extends StatefulWidget {
  const PersonalBestPage({super.key});

  @override
  State<PersonalBestPage> createState() => _PersonalBestPageState();
}

class _PersonalBestPageState extends State<PersonalBestPage> {
  PersonalBestSortType sortType = PersonalBestSortType.length;
  final _recordRepository = FishingRecordRepository.instance;

  @override
  void initState() {
    super.initState();
    _recordRepository.addListener(_refreshRecords);
  }

  @override
  void dispose() {
    _recordRepository.removeListener(_refreshRecords);
    super.dispose();
  }

  void _refreshRecords() {
    if (!mounted) {
      return;
    }

    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final records = PersonalBestRepository.instance.getPersonalBests(
      sortType: sortType,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('내 기록어')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: [
                  ChoiceChip(
                    label: const Text('크기순'),
                    selected: sortType == PersonalBestSortType.length,
                    onSelected: (_) {
                      setState(() {
                        sortType = PersonalBestSortType.length;
                      });
                    },
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('무게순'),
                    selected: sortType == PersonalBestSortType.weight,
                    onSelected: (_) {
                      setState(() {
                        sortType = PersonalBestSortType.weight;
                      });
                    },
                  ),
                ],
              ),
            ),

            Expanded(
              child: records.isEmpty
                  ? const _EmptyPersonalBestView()
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: records.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final record = records[index];

                        return _PersonalBestCard(
                          record: record,
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) =>
                                    PersonalBestDetailPage(record: record),
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

class _PersonalBestCard extends StatelessWidget {
  final PersonalBestRecord record;
  final VoidCallback onTap;

  const _PersonalBestCard({required this.record, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: const Icon(Icons.emoji_events_outlined),
        ),
        title: Text(
          record.speciesName,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          '${record.lengthText} · ${record.weightText}\n'
          '${_formatDate(record.caughtAt)} | ${record.locationText}',
        ),
        isThreeLine: true,
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }

  String _formatDate(DateTime date) {
    String twoDigits(int value) => value.toString().padLeft(2, '0');

    return '${date.year}.${twoDigits(date.month)}.${twoDigits(date.day)}';
  }
}

class _EmptyPersonalBestView extends StatelessWidget {
  const _EmptyPersonalBestView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.emoji_events_outlined,
              size: 56,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              '아직 기록어가 없습니다.',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              '출조 기록에 어종과 크기 또는 무게를 입력하면 기록어가 표시됩니다.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
