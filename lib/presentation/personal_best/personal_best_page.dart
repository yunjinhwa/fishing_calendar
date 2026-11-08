import 'package:flutter/material.dart';

import '../../data/models/personal_best_record.dart';
import '../../data/repositories/auth_session_repository.dart';
import '../../data/repositories/fishing_record_repository.dart';
import '../../data/repositories/personal_best_repository.dart';
import '../record/record_history_scope.dart';
import 'personal_best_detail_page.dart';
import 'personal_best_photo.dart';

class PersonalBestPage extends StatefulWidget {
  const PersonalBestPage({super.key, this.repository, this.recordChanges});

  final PersonalBestRepository? repository;
  final Listenable? recordChanges;

  @override
  State<PersonalBestPage> createState() => _PersonalBestPageState();
}

class _PersonalBestPageState extends State<PersonalBestPage> {
  PersonalBestSortType _sortType = PersonalBestSortType.length;
  final _auth = AuthSessionRepository.instance;
  final _searchController = TextEditingController();
  String? _searchOwnerKey;
  late List<PersonalBestRecord> _records;
  late List<PersonalBestRecord> _filteredRecords;

  PersonalBestRepository get _repository =>
      widget.repository ?? PersonalBestRepository.instance;
  Listenable get _recordChanges =>
      widget.recordChanges ?? FishingRecordRepository.instance;

  @override
  void initState() {
    super.initState();
    _readRecords();
    _recordChanges.addListener(_refreshRecords);
    _auth.addListener(_refreshRecords);
  }

  @override
  void didUpdateWidget(PersonalBestPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.recordChanges != widget.recordChanges) {
      (oldWidget.recordChanges ?? FishingRecordRepository.instance)
          .removeListener(_refreshRecords);
      _recordChanges.addListener(_refreshRecords);
    }
    if (oldWidget.repository != widget.repository ||
        oldWidget.recordChanges != widget.recordChanges) {
      _readRecords();
    }
  }

  @override
  void dispose() {
    _recordChanges.removeListener(_refreshRecords);
    _auth.removeListener(_refreshRecords);
    _searchController.dispose();
    super.dispose();
  }

  void _readRecords() {
    if (_searchOwnerKey != _auth.dataOwnerKey) {
      _searchOwnerKey = _auth.dataOwnerKey;
      _searchController.clear();
    }
    _records = !_auth.isMember || _auth.hasPendingAccountDeletion
        ? const []
        : _repository.getPersonalBests(sortType: _sortType);
    _filterRecords();
  }

  void _filterRecords() {
    final keyword = _searchController.text.trim().toLowerCase();
    _filteredRecords = keyword.isEmpty
        ? _records
        : _records
              .where(
                (record) => record.speciesName.toLowerCase().contains(keyword),
              )
              .toList(growable: false);
  }

  void _refreshRecords() {
    if (mounted) setState(_readRecords);
  }

  void _selectSort(PersonalBestSortType sortType) {
    if (_sortType == sortType) return;
    setState(() {
      _sortType = sortType;
      _readRecords();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('내 기록어')),
      body: SafeArea(
        child: RecordHistoryScope(
          isActive: _auth.isMember && !_auth.hasPendingAccountDeletion,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: TextField(
                  controller: _searchController,
                  enabled: _auth.isMember && !_auth.hasPendingAccountDeletion,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    labelText: '어종명 검색',
                    hintText: '어종명을 입력해 주세요',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchController.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '검색어 지우기',
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                              setState(_filterRecords);
                            },
                          ),
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(_filterRecords),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('크기순'),
                      selected: _sortType == PersonalBestSortType.length,
                      onSelected: (_) =>
                          _selectSort(PersonalBestSortType.length),
                    ),
                    ChoiceChip(
                      label: const Text('무게순'),
                      selected: _sortType == PersonalBestSortType.weight,
                      onSelected: (_) =>
                          _selectSort(PersonalBestSortType.weight),
                    ),
                    ChoiceChip(
                      label: const Text('이름순'),
                      selected: _sortType == PersonalBestSortType.name,
                      onSelected: (_) => _selectSort(PersonalBestSortType.name),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _records.isEmpty
                    ? _EmptyPersonalBestView(isMember: _auth.isMember)
                    : _filteredRecords.isEmpty
                    ? const Center(child: Text('검색 결과가 없습니다.'))
                    : ListView.separated(
                        padding: const EdgeInsets.all(16),
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        itemCount: _filteredRecords.length,
                        separatorBuilder: (context, index) =>
                            const SizedBox(height: 12),
                        itemBuilder: (context, index) {
                          final record = _filteredRecords[index];
                          return _PersonalBestCard(
                            record: record,
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => PersonalBestDetailPage(
                                  record: record,
                                  repository: _repository,
                                  recordChanges: _recordChanges,
                                ),
                              ),
                            ),
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

class _PersonalBestCard extends StatelessWidget {
  const _PersonalBestCard({required this.record, required this.onTap});

  final PersonalBestRecord record;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final source = record.sourceRecord;
    final criterion = record.selectedType == PersonalBestSortType.length
        ? '크기 기록'
        : '무게 기록';
    return Card(
      child: ListTile(
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: PersonalBestPhoto(
            photo: source.photos.firstOrNull,
            width: 56,
            height: 56,
          ),
        ),
        title: Text(
          record.speciesName,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          '최고 크기 ${record.lengthText} · 최고 무게 ${record.weightText}\n'
          '$criterion · ${_formatDate(record.caughtAt)} | ${record.locationText}',
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
  const _EmptyPersonalBestView({required this.isMember});

  final bool isMember;

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
              isMember ? '아직 기록어가 없습니다.' : '기록어는 로그인 후 확인할 수 있습니다.',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            if (isMember) ...[
              const SizedBox(height: 8),
              const Text(
                '출조 기록에 어종과 크기 또는 무게를 입력하면 기록어가 표시됩니다.',
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
