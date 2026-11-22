import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/personal_best_record.dart';
import '../../data/repositories/auth_session_repository.dart';
import '../../data/repositories/fishing_record_repository.dart';
import '../../data/repositories/personal_best_repository.dart';
import '../auth/auth_access_guard.dart';
import '../record/record_history_scope.dart';
import '../share/share_record_page.dart';
import 'personal_best_photo.dart';

class PersonalBestDetailPage extends StatefulWidget {
  const PersonalBestDetailPage({
    super.key,
    required this.record,
    this.repository,
    this.recordChanges,
  });

  final PersonalBestRecord record;
  final PersonalBestRepository? repository;
  final Listenable? recordChanges;

  @override
  State<PersonalBestDetailPage> createState() => _PersonalBestDetailPageState();
}

class _PersonalBestDetailPageState extends State<PersonalBestDetailPage> {
  final _auth = AuthSessionRepository.instance;
  late final String _ownerKey;
  late final int _sessionGeneration;
  late PersonalBestSortType _sortType;
  PersonalBestRecord? _record;

  PersonalBestRepository get _repository =>
      widget.repository ?? PersonalBestRepository.instance;
  Listenable get _recordChanges =>
      widget.recordChanges ?? FishingRecordRepository.instance;
  bool get _isOriginalSession =>
      _auth.dataOwnerKey == _ownerKey &&
      _auth.sessionGeneration == _sessionGeneration;
  bool get _isCurrentSession =>
      _isOriginalSession && _auth.isMember && !_auth.hasPendingAccountDeletion;

  @override
  void initState() {
    super.initState();
    _ownerKey = _auth.dataOwnerKey;
    _sessionGeneration = _auth.sessionGeneration;
    _sortType = widget.record.sortType;
    _readRecord();
    _recordChanges.addListener(_refreshRecord);
    _auth.addListener(_refreshRecord);
  }

  @override
  void didUpdateWidget(PersonalBestDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.recordChanges != widget.recordChanges) {
      (oldWidget.recordChanges ?? FishingRecordRepository.instance)
          .removeListener(_refreshRecord);
      _recordChanges.addListener(_refreshRecord);
    }
    if (oldWidget.repository != widget.repository ||
        oldWidget.recordChanges != widget.recordChanges ||
        oldWidget.record.speciesName != widget.record.speciesName) {
      _readRecord();
    }
  }

  @override
  void dispose() {
    _recordChanges.removeListener(_refreshRecord);
    _auth.removeListener(_refreshRecord);
    super.dispose();
  }

  void _readRecord() {
    _record = _isCurrentSession
        ? _repository.getPersonalBest(
            widget.record.speciesName,
            sortType: _sortType,
          )
        : null;
  }

  void _refreshRecord() {
    if (mounted) setState(_readRecord);
  }

  void _selectCriterion(PersonalBestSortType sortType) {
    if (_sortType == sortType) return;
    setState(() {
      _sortType = sortType;
      _readRecord();
    });
  }

  @override
  Widget build(BuildContext context) {
    final record = _record;
    return Scaffold(
      appBar: AppBar(title: Text(record?.speciesName ?? '기록어 상세')),
      bottomNavigationBar: record == null
          ? null
          : SafeArea(
              top: false,
              minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: FilledButton.icon(
                onPressed: _openShare,
                icon: const Icon(Icons.ios_share_outlined),
                label: const Text('공유 이미지 미리보기'),
              ),
            ),
      body: SafeArea(
        bottom: false,
        child: RecordHistoryScope(
          isActive: _isCurrentSession,
          child: record == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      !_auth.isMember && _isOriginalSession
                          ? '기록어는 로그인 후 확인할 수 있습니다.'
                          : _isCurrentSession
                          ? '이 어종의 크기·무게 기록이 없거나 삭제되었습니다.'
                          : '계정이 변경되어 이 기록을 표시할 수 없습니다.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : _buildRecord(record),
        ),
      ),
    );
  }

  Future<void> _openShare() async {
    final allowed = await requireMemberAccess(
      context,
      message: '기록어 공유는 로그인 후 사용할 수 있습니다.',
    );
    if (!allowed || !mounted || !_isCurrentSession) return;
    final latest = _repository.getPersonalBest(
      widget.record.speciesName,
      sortType: _sortType,
    );
    if (latest == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ShareRecordPage(
          record: latest,
          repository: _repository,
          recordChanges: _recordChanges,
        ),
      ),
    );
  }

  Widget _buildRecord(PersonalBestRecord record) {
    final source = record.sourceRecord;
    final criterion = record.selectedType == PersonalBestSortType.length
        ? '크기 기록'
        : '무게 기록';
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          spacing: 8,
          children: [
            ChoiceChip(
              label: const Text('크기 기록'),
              selected: record.selectedType == PersonalBestSortType.length,
              onSelected: record.lengthBest == null
                  ? null
                  : (_) => _selectCriterion(PersonalBestSortType.length),
            ),
            ChoiceChip(
              label: const Text('무게 기록'),
              selected: record.selectedType == PersonalBestSortType.weight,
              onSelected: record.weightBest == null
                  ? null
                  : (_) => _selectCriterion(PersonalBestSortType.weight),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (source.photos.length <= 1)
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: PersonalBestPhoto(
              photo: source.photos.firstOrNull,
              width: double.infinity,
              height: 196,
            ),
          )
        else
          LayoutBuilder(
            builder: (context, constraints) => SizedBox(
              height: 196,
              child: ListView.separated(
                key: ValueKey('${source.id}-${record.selectedType}'),
                scrollDirection: Axis.horizontal,
                itemCount: source.photos.length,
                separatorBuilder: (context, index) => const SizedBox(width: 8),
                itemBuilder: (context, index) => ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: PersonalBestPhoto(
                    photo: source.photos[index],
                    width: math.min(constraints.maxWidth * 0.84, 360.0),
                    height: 196,
                  ),
                ),
              ),
            ),
          ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            const gap = 8.0;
            final stack =
                constraints.maxWidth < 280 ||
                MediaQuery.textScalerOf(context).scale(16) > 20;
            final cardWidth = stack
                ? constraints.maxWidth
                : (constraints.maxWidth - gap) / 2;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                SizedBox(
                  width: cardWidth,
                  child: _BestEvidenceCard(
                    title: '최고 크기',
                    value: record.lengthText,
                    evidence: record.lengthBest,
                  ),
                ),
                SizedBox(
                  width: cardWidth,
                  child: _BestEvidenceCard(
                    title: '최고 무게',
                    value: record.weightText,
                    evidence: record.weightBest,
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 24),
        _SectionTitle(title: '$criterion의 출조 정보'),
        const SizedBox(height: 8),
        _InfoCard(
          children: [
            _InfoRow(label: '출조 위치', value: source.location),
            _InfoRow(label: '낚시 장르', value: source.genreName),
            _InfoRow(
              label: '출조 시간',
              value: _formatDateTimeRange(source.startAt, source.endAt),
            ),
            _InfoRow(
              label: '조과',
              value: '${record.selectedEvidence.catchIndex + 1}번째 조과',
            ),
            _InfoRow(label: '물때', value: source.tide ?? '-'),
            _InfoRow(label: '날씨', value: source.weather ?? '-'),
            _InfoRow(
              label: '메모',
              value: source.memo?.isNotEmpty == true
                  ? source.memo!
                  : '메모가 없습니다.',
            ),
          ],
        ),
      ],
    );
  }
}

class _BestEvidenceCard extends StatelessWidget {
  const _BestEvidenceCard({
    required this.title,
    required this.value,
    required this.evidence,
  });

  final String title;
  final String value;
  final PersonalBestEvidence? evidence;

  @override
  Widget build(BuildContext context) {
    final source = evidence?.record;
    final theme = Theme.of(context);
    return _InfoCard(
      children: [
        Text(
          title,
          style: theme.textTheme.labelLarge?.copyWith(color: AppTheme.muted),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          source == null
              ? '측정 기록이 없습니다.'
              : '${_formatDate(source.startAt)} · ${source.location} · '
                    '${evidence!.catchIndex + 1}번째 조과',
          style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.muted),
        ),
      ],
    );
  }
}

String _formatDate(DateTime date) {
  String twoDigits(int value) => value.toString().padLeft(2, '0');
  return '${date.year}.${twoDigits(date.month)}.${twoDigits(date.day)}';
}

String _formatDateTimeRange(DateTime startAt, DateTime endAt) {
  String time(DateTime date) =>
      '${_formatDate(date)} ${date.hour.toString().padLeft(2, '0')}:'
      '${date.minute.toString().padLeft(2, '0')}';
  return '${time(startAt)} - ${time(endAt)}';
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title});
  final String title;

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
  const _InfoCard({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
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
  const _InfoRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
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
