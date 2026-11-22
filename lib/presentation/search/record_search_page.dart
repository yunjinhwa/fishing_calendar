import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/fishing_record.dart';
import '../../data/repositories/fishing_record_repository.dart';
import '../auth/auth_access_guard.dart';
import '../common/record_action_footer.dart';
import '../record/record_detail_page.dart';
import '../record/record_form_page.dart';
import '../record/record_history_scope.dart';
import '../record/record_photo_thumbnail.dart';

enum RecordSortType { newest, oldest }

typedef _RecordFilters = ({
  String? genre,
  DateTime? start,
  DateTime? end,
  RecordSortType sort,
});

const _defaultRecordFilters = (
  genre: null,
  start: null,
  end: null,
  sort: RecordSortType.newest,
);
const _recordGenres = ['전체', '루어', '찌낚시', '선상', '원투', '기타'];

class RecordSearchPage extends StatefulWidget {
  final bool showAppBar;
  final String appBarTitle;
  final bool isActive;

  const RecordSearchPage({
    super.key,
    this.showAppBar = true,
    this.isActive = true,
    this.appBarTitle = '기록 검색',
  });

  @override
  State<RecordSearchPage> createState() => _RecordSearchPageState();
}

class _RecordSearchPageState extends State<RecordSearchPage> {
  final searchController = TextEditingController();
  final _recordRepository = FishingRecordRepository.instance;

  _RecordFilters _filters = _defaultRecordFilters;

  @override
  void initState() {
    super.initState();
    _recordRepository.addListener(_refreshRecords);
  }

  @override
  void dispose() {
    _recordRepository.removeListener(_refreshRecords);
    searchController.dispose();
    super.dispose();
  }

  void _refreshRecords() {
    if (!mounted) {
      return;
    }

    setState(() {});
  }

  List<FishingRecord> get filteredRecords {
    final keyword = searchController.text.trim();
    final records = _recordRepository.getAllRecords();
    final (
      genre: selectedGenre,
      start: startDate,
      end: endDate,
      sort: sortType,
    ) = _filters;

    final filtered = records.where((record) {
      final matchesKeyword =
          keyword.isEmpty ||
          record.location.contains(keyword) ||
          (record.locationAlias?.contains(keyword) ?? false) ||
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
            DateTime(startDate.year, startDate.month, startDate.day),
          );

      final matchesEndDate =
          endDate == null ||
          record.startAt.isBefore(
            DateTime(
              endDate.year,
              endDate.month,
              endDate.day,
            ).add(const Duration(days: 1)),
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

  Future<void> _showFilters() async {
    FocusScope.of(context).unfocus();
    final filters = await showModalBottomSheet<_RecordFilters>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _RecordFilterSheet(initial: _filters),
    );
    if (!mounted || filters == null) return;
    setState(() => _filters = filters);
  }

  void resetFilters() {
    setState(() {
      searchController.clear();
      _filters = _defaultRecordFilters;
    });
  }

  @override
  Widget build(BuildContext context) {
    final records = filteredRecords;
    final (
      genre: selectedGenre,
      start: startDate,
      end: endDate,
      sort: sortType,
    ) = _filters;
    final hasFilters = _filters != _defaultRecordFilters;
    final showWriteAction =
        widget.showAppBar && MediaQuery.viewInsetsOf(context).bottom == 0;

    return Scaffold(
      appBar: widget.showAppBar
          ? AppBar(title: Text(widget.appBarTitle))
          : null,
      bottomNavigationBar: showWriteAction
          ? RecordActionFooter(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: FilledButton.icon(
                onPressed: () async {
                  final allowed = await requireMemberAccess(
                    context,
                    message: '출조 기록 작성은 로그인 후 사용할 수 있습니다.',
                  );
                  if (!allowed || !context.mounted) return;
                  final saved = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(builder: (_) => const RecordFormPage()),
                  );
                  if (saved == true && context.mounted) setState(() {});
                },
                icon: const Icon(Icons.add_rounded),
                label: const Text('기록 작성'),
              ),
            )
          : null,
      body: SafeArea(
        child: RecordHistoryScope(
          isActive: widget.isActive,
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: searchController,
                              textInputAction: TextInputAction.search,
                              decoration: InputDecoration(
                                labelText: '검색어',
                                hintText: '장소, 위치 별칭, 어종, 메모 검색',
                                prefixIcon: const Icon(Icons.search),
                                suffixIcon: searchController.text.isEmpty
                                    ? null
                                    : IconButton(
                                        tooltip: '검색어 지우기',
                                        onPressed: () {
                                          setState(searchController.clear);
                                        },
                                        icon: const Icon(Icons.close),
                                      ),
                              ),
                              onChanged: (_) => setState(() {}),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton.outlined(
                            tooltip: '필터',
                            isSelected: hasFilters,
                            onPressed: _showFilters,
                            icon: const Icon(Icons.tune),
                            style: hasFilters
                                ? IconButton.styleFrom(
                                    backgroundColor: AppTheme.primaryContainer,
                                    foregroundColor: AppTheme.primary,
                                  )
                                : null,
                          ),
                        ],
                      ),
                      if (hasFilters) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            if (selectedGenre != null)
                              Chip(label: Text(selectedGenre)),
                            if (startDate != null)
                              Chip(
                                label: Text(
                                  '${_formatFilterDate(startDate)}부터',
                                ),
                              ),
                            if (endDate != null)
                              Chip(
                                label: Text('${_formatFilterDate(endDate)}까지'),
                              ),
                            TextButton(
                              onPressed: () {
                                setState(
                                  () => _filters = _defaultRecordFilters,
                                );
                              },
                              child: const Text('필터 초기화'),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
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
              ),
              if (records.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _EmptySearchResultView(
                    onReset: hasFilters || searchController.text.isNotEmpty
                        ? resetFilters
                        : null,
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.all(16),
                  sliver: SliverList.separated(
                    itemCount: records.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final record = records[index];

                      return _RecordSearchResultCard(
                        record: record,
                        onTap: () async {
                          final changed = await Navigator.of(context)
                              .push<bool>(
                                MaterialPageRoute(
                                  builder: (_) =>
                                      RecordDetailPage(record: record),
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
      ),
    );
  }
}

class _RecordFilterSheet extends StatefulWidget {
  const _RecordFilterSheet({required this.initial});

  final _RecordFilters initial;

  @override
  State<_RecordFilterSheet> createState() => _RecordFilterSheetState();
}

class _RecordFilterSheetState extends State<_RecordFilterSheet> {
  late _RecordFilters _draft = widget.initial;

  Future<void> _pickDate({required bool isStart}) async {
    final current = isStart ? _draft.start : _draft.end;
    final date = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
    );
    if (!mounted || date == null) return;
    _changeDate(isStart: isStart, date: date);
  }

  void _changeDate({required bool isStart, required DateTime? date}) {
    setState(() {
      _draft = (
        genre: _draft.genre,
        start: isStart ? date : _draft.start,
        end: isStart ? _draft.end : date,
        sort: _draft.sort,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final (genre: selectedGenre, :start, :end, :sort) = _draft;
    final textTheme = Theme.of(context).textTheme;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(child: Text('필터', style: textTheme.titleLarge)),
                const CloseButton(),
              ],
            ),
            Text('낚시 장르', style: textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final genre in _recordGenres)
                  ChoiceChip(
                    label: Text(genre),
                    selected: (selectedGenre ?? '전체') == genre,
                    onSelected: (_) => setState(() {
                      _draft = (
                        genre: genre == '전체' ? null : genre,
                        start: start,
                        end: end,
                        sort: sort,
                      );
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            Text('기간', style: textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _DateFilterButton(
                  label: '시작일',
                  date: start,
                  onTap: () => _pickDate(isStart: true),
                  onClear: () => _changeDate(isStart: true, date: null),
                ),
                _DateFilterButton(
                  label: '종료일',
                  date: end,
                  onTap: () => _pickDate(isStart: false),
                  onClear: () => _changeDate(isStart: false, date: null),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text('정렬 기준', style: textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final value in RecordSortType.values)
                  ChoiceChip(
                    label: Text(
                      value == RecordSortType.newest ? '최신순' : '오래된순',
                    ),
                    selected: sort == value,
                    onSelected: (_) => setState(() {
                      _draft = (
                        genre: selectedGenre,
                        start: start,
                        end: end,
                        sort: value,
                      );
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            OverflowBar(
              alignment: MainAxisAlignment.end,
              spacing: 8,
              overflowSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: () =>
                      setState(() => _draft = _defaultRecordFilters),
                  child: const Text('초기화'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(_draft),
                  child: const Text('적용하기'),
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
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: OutlinedButton.icon(
            onPressed: onTap,
            icon: const Icon(Icons.calendar_month_outlined),
            label: Text('$label ${_formatFilterDate(date!)}'),
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
}

String _formatFilterDate(DateTime date) {
  String twoDigits(int value) => value.toString().padLeft(2, '0');
  return '${date.year}.${twoDigits(date.month)}.${twoDigits(date.day)}';
}

class _RecordSearchResultCard extends StatelessWidget {
  final FishingRecord record;
  final VoidCallback onTap;

  const _RecordSearchResultCard({required this.record, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final photo = record.photos.firstOrNull;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: photo == null
                    ? const ColoredBox(
                        color: AppTheme.coolGray,
                        child: SizedBox.square(
                          dimension: 64,
                          child: Icon(
                            Icons.set_meal_outlined,
                            color: AppTheme.muted,
                          ),
                        ),
                      )
                    : RecordPhotoThumbnail(
                        photo: photo,
                        size: 64,
                        compact: true,
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      record.summaryTitle,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${_formatDateTime(record.startAt)}\n'
                      '${record.locationDisplayName}',
                      style: const TextStyle(color: AppTheme.muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right, color: AppTheme.muted),
            ],
          ),
        ),
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
  const _EmptySearchResultView({required this.onReset});

  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const DecoratedBox(
              decoration: BoxDecoration(
                color: AppTheme.coolGray,
                shape: BoxShape.circle,
              ),
              child: SizedBox.square(
                dimension: 72,
                child: Icon(
                  Icons.search_outlined,
                  size: 36,
                  color: AppTheme.muted,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '검색 결과가 없습니다.',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              '검색어 또는 필터 조건을 변경해보세요.',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: AppTheme.muted),
            ),
            if (onReset != null) ...[
              const SizedBox(height: 16),
              OutlinedButton(onPressed: onReset, child: const Text('전체 기록 보기')),
            ],
          ],
        ),
      ),
    );
  }
}
