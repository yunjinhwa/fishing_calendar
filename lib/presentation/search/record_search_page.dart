import 'package:flutter/material.dart';

import '../../data/models/fishing_record.dart';
import '../../data/repositories/fishing_record_memory_repository.dart';
import '../record/record_detail_page.dart';
import '../record/record_form_page.dart';

enum RecordSortType {
  newest,
  oldest,
}

class RecordSearchPage extends StatefulWidget {
  final bool showAppBar;
  final String appBarTitle;

  const RecordSearchPage({
    super.key,
    this.showAppBar = true,
    this.appBarTitle = '기록 검색',
  });

  @override
  State<RecordSearchPage> createState() => _RecordSearchPageState();
}

class _RecordSearchPageState extends State<RecordSearchPage> {
  final searchController = TextEditingController();

  String? selectedGenre;
  DateTime? startDate;
  DateTime? endDate;
  RecordSortType sortType = RecordSortType.newest;

  final genres = const [
    '전체',
    '루어',
    '찌낚시',
    '선상',
    '원투',
    '기타',
  ];

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  List<FishingRecord> get filteredRecords {
    final keyword = searchController.text.trim();
    final records = FishingRecordMemoryRepository.instance.getAllRecords();

    final filtered = records.where((record) {
      final matchesKeyword =
          keyword.isEmpty ||
          record.location.contains(keyword) ||
          record.genreName.contains(keyword) ||
          (record.memo?.contains(keyword) ?? false) ||
          record.catches.any(
            (catchRecord) => catchRecord.speciesName.contains(keyword),
          );

      final matchesGenre =
          selectedGenre == null ||
          selectedGenre == '전체' ||
          record.genreName == selectedGenre;

      final matchesStartDate =
          startDate == null ||
          !record.startAt.isBefore(
            DateTime(startDate!.year, startDate!.month, startDate!.day),
          );

      final matchesEndDate =
          endDate == null ||
          record.startAt.isBefore(
            DateTime(endDate!.year, endDate!.month, endDate!.day)
                .add(const Duration(days: 1)),
          );

      return matchesKeyword &&
          matchesGenre &&
          matchesStartDate &&
          matchesEndDate;
    }).toList();

    filtered.sort((a, b) {
      switch (sortType) {
        case RecordSortType.newest:
          return b.startAt.compareTo(a.startAt);
        case RecordSortType.oldest:
          return a.startAt.compareTo(b.startAt);
      }
    });

    return filtered;
  }

  Future<void> pickStartDate() async {
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: startDate ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
    );

    if (pickedDate == null) {
      return;
    }

    setState(() {
      startDate = pickedDate;
    });
  }

  Future<void> pickEndDate() async {
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: endDate ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
    );

    if (pickedDate == null) {
      return;
    }

    setState(() {
      endDate = pickedDate;
    });
  }

  void resetFilters() {
    setState(() {
      searchController.clear();
      selectedGenre = null;
      startDate = null;
      endDate = null;
      sortType = RecordSortType.newest;
    });
  }

  @override
  Widget build(BuildContext context) {
    final records = filteredRecords;

    return Scaffold(
      appBar: widget.showAppBar
    ? AppBar(
        title: Text(widget.appBarTitle),
        actions: [
          TextButton.icon(
            onPressed: () async {
              final saved = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => const RecordFormPage(),
                ),
              );

              if (saved == true && context.mounted) {
                setState(() {});
              }
            },
            icon: const Icon(Icons.edit_note),
            label: const Text('기록 작성'),
          ),
          IconButton(
            onPressed: resetFilters,
            icon: const Icon(Icons.refresh),
            tooltip: '필터 초기화',
          ),
        ],
      )
    : null,
      body: SafeArea(
        child: Column(
          children: [
            _SearchFilterArea(
              searchController: searchController,
              genres: genres,
              selectedGenre: selectedGenre,
              startDate: startDate,
              endDate: endDate,
              sortType: sortType,
              onSearchChanged: () {
                setState(() {});
              },
              onGenreChanged: (genre) {
                setState(() {
                  selectedGenre = genre;
                });
              },
              onStartDateTap: pickStartDate,
              onEndDateTap: pickEndDate,
              onSortChanged: (value) {
                setState(() {
                  sortType = value;
                });
              },
              onStartDateClear: () {
                setState(() {
                  startDate = null;
                });
              },
              onEndDateClear: () {
                setState(() {
                  endDate = null;
                });
              },
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(
                children: [
                  Text(
                    '검색 결과 ${records.length}건',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const Spacer(),
                  if (records.isNotEmpty)
                    Text(
                      sortType == RecordSortType.newest ? '최신순' : '오래된순',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ),
            Expanded(
              child: records.isEmpty
                  ? const _EmptySearchResultView()
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: records.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final record = records[index];

                        return _RecordSearchResultCard(
                          record: record,
                          onTap: () async {
                            final changed = await Navigator.of(context).push<bool>(
                              MaterialPageRoute(
                                builder: (_) => RecordDetailPage(
                                  record: record,
                                ),
                              ),
                            );

                            if (changed == true && context.mounted) {
                              setState(() {});
                            }
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

class _SearchFilterArea extends StatelessWidget {
  final TextEditingController searchController;
  final List<String> genres;
  final String? selectedGenre;
  final DateTime? startDate;
  final DateTime? endDate;
  final RecordSortType sortType;
  final VoidCallback onSearchChanged;
  final ValueChanged<String?> onGenreChanged;
  final VoidCallback onStartDateTap;
  final VoidCallback onEndDateTap;
  final VoidCallback onStartDateClear;
  final VoidCallback onEndDateClear;
  final ValueChanged<RecordSortType> onSortChanged;

  const _SearchFilterArea({
    required this.searchController,
    required this.genres,
    required this.selectedGenre,
    required this.startDate,
    required this.endDate,
    required this.sortType,
    required this.onSearchChanged,
    required this.onGenreChanged,
    required this.onStartDateTap,
    required this.onEndDateTap,
    required this.onStartDateClear,
    required this.onEndDateClear,
    required this.onSortChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 1,
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          children: [
            TextField(
              controller: searchController,
              decoration: const InputDecoration(
                labelText: '검색어',
                hintText: '장소, 어종, 메모 검색',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (_) => onSearchChanged(),
            ),
            const SizedBox(height: 12),

            DropdownButtonFormField<String>(
              initialValue: selectedGenre,
              decoration: const InputDecoration(
                labelText: '낚시 장르',
                border: OutlineInputBorder(),
              ),
              items: genres
                  .map(
                    (genre) => DropdownMenuItem(
                      value: genre,
                      child: Text(genre),
                    ),
                  )
                  .toList(),
              onChanged: onGenreChanged,
            ),
            const SizedBox(height: 12),

            Row(
              children: [
                Expanded(
                  child: _DateFilterButton(
                    label: '시작일',
                    date: startDate,
                    onTap: onStartDateTap,
                    onClear: onStartDateClear,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _DateFilterButton(
                    label: '종료일',
                    date: endDate,
                    onTap: onEndDateTap,
                    onClear: onEndDateClear,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            Row(
              children: [
                ChoiceChip(
                  label: const Text('최신순'),
                  selected: sortType == RecordSortType.newest,
                  onSelected: (_) => onSortChanged(RecordSortType.newest),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('오래된순'),
                  selected: sortType == RecordSortType.oldest,
                  onSelected: (_) => onSortChanged(RecordSortType.oldest),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DateFilterButton extends StatelessWidget {
  final String label;
  final DateTime? date;
  final VoidCallback onTap;
  final VoidCallback onClear;

  const _DateFilterButton({
    required this.label,
    required this.date,
    required this.onTap,
    required this.onClear,
  });

    @override
  Widget build(BuildContext context) {
    if (date == null) {
      return OutlinedButton.icon(
        onPressed: onTap,
        icon: const Icon(Icons.calendar_month_outlined),
        label: Text(label),
      );
    }

    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: onTap,
            icon: const Icon(Icons.calendar_month_outlined),
            label: Text(_formatDate(date!)),
          ),
        ),
        IconButton(
          onPressed: onClear,
          icon: const Icon(Icons.close),
          tooltip: '$label 초기화',
        ),
      ],
    );
  }

  String _formatDate(DateTime date) {
    String twoDigits(int value) => value.toString().padLeft(2, '0');

    return '${date.year}.${twoDigits(date.month)}.${twoDigits(date.day)}';
  }
}

class _RecordSearchResultCard extends StatelessWidget {
  final FishingRecord record;
  final VoidCallback onTap;

  const _RecordSearchResultCard({
    required this.record,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        title: Text(
          record.summaryTitle,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: Text(
          '${_formatDateTime(record.startAt)}\n'
          '${record.location} · ${record.genreName}',
        ),
        isThreeLine: true,
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }

  String _formatDateTime(DateTime dateTime) {
    String twoDigits(int value) => value.toString().padLeft(2, '0');

    return '${dateTime.year}.${twoDigits(dateTime.month)}.${twoDigits(dateTime.day)} '
        '${twoDigits(dateTime.hour)}:${twoDigits(dateTime.minute)}';
  }
}

class _EmptySearchResultView extends StatelessWidget {
  const _EmptySearchResultView();

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