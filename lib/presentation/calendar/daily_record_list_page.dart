import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/models/fishing_record.dart';
import '../../data/models/outbox_item.dart';
import '../../data/repositories/auth_session_repository.dart';
import '../../data/repositories/fishing_record_repository.dart';
import '../../data/repositories/outbox_repository.dart';
import '../../data/services/record_sync_service.dart';
import '../record/record_detail_page.dart';
import '../record/record_form_page.dart';

class DailyRecordListPage extends StatefulWidget {
  final DateTime selectedDate;
  final bool isTodaySummary;
  final DateTime Function()? now;

  const DailyRecordListPage({
    super.key,
    required this.selectedDate,
    this.isTodaySummary = false,
    this.now,
  });

  @override
  State<DailyRecordListPage> createState() => _DailyRecordListPageState();
}

class _DailyRecordListPageState extends State<DailyRecordListPage>
    with WidgetsBindingObserver {
  bool hasChanged = false;
  final _authSession = AuthSessionRepository.instance;
  final _recordRepository = FishingRecordRepository.instance;
  final _outboxRepository = OutboxRepository.instance;
  final _syncService = RecordSyncService.instance;
  Timer? _dayChangeTimer;
  late DateTime _today;
  bool _isOpeningCreate = false;

  DateTime get _now => (widget.now ?? DateTime.now)().toLocal();
  DateTime get _selectedDate =>
      widget.isTodaySummary ? _today : widget.selectedDate;

  @override
  void initState() {
    super.initState();
    _recordRepository.addListener(_refreshRecords);
    _syncService.addListener(_refreshRecords);
    if (widget.isTodaySummary) {
      _authSession.addListener(_onSummarySessionChanged);
      WidgetsBinding.instance.addObserver(this);
    }
    _refreshDay(rebuild: false);
  }

  @override
  void dispose() {
    _recordRepository.removeListener(_refreshRecords);
    _syncService.removeListener(_refreshRecords);
    _authSession.removeListener(_onSummarySessionChanged);
    WidgetsBinding.instance.removeObserver(this);
    _dayChangeTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshDay();
    } else {
      _dayChangeTimer?.cancel();
    }
  }

  void _onSummarySessionChanged() => _refreshDay();

  void _refreshDay({bool rebuild = true}) {
    final now = _now;
    _today = DateTime(now.year, now.month, now.day);
    _dayChangeTimer?.cancel();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (widget.isTodaySummary &&
        _authSession.canManageRecords &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed)) {
      _dayChangeTimer = Timer(
        DateTime(now.year, now.month, now.day + 1).difference(now),
        _refreshDay,
      );
    }
    if (rebuild && mounted) setState(() {});
  }

  Future<void> _createRecord() async {
    if (!_authSession.canManageRecords ||
        _isOpeningCreate ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    final owner = _authSession.dataOwnerKey;
    final generation = _authSession.sessionGeneration;
    final now = _now;
    _isOpeningCreate = true;
    try {
      final saved = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => RecordFormPage(initialStartAt: now)),
      );
      if (!mounted ||
          owner != _authSession.dataOwnerKey ||
          generation != _authSession.sessionGeneration) {
        return;
      }
      _refreshDay();
      if (saved == true) {
        setState(() => hasChanged = true);
        unawaited(_syncService.syncNow(scheduleFollowUpIfBusy: true));
      }
    } finally {
      _isOpeningCreate = false;
    }
  }

  void _refreshRecords() {
    if (!mounted) {
      return;
    }

    setState(() {
      hasChanged = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final allowed = !widget.isTodaySummary || _authSession.canManageRecords;
    final records = allowed
        ? _recordRepository.getRecordsByDate(_selectedDate)
        : <FishingRecord>[];
    if (widget.isTodaySummary) {
      records.sort((left, right) {
        final time = left.startAt.compareTo(right.startAt);
        return time != 0 ? time : left.id.compareTo(right.id);
      });
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          return;
        }

        Navigator.of(context).pop(hasChanged);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            widget.isTodaySummary ? '오늘의 요약' : _formatDate(_selectedDate),
          ),
        ),
        body: !allowed
            ? const SizedBox.shrink()
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.isTodaySummary || records.isNotEmpty)
                    Padding(
                      key: widget.isTodaySummary
                          ? const ValueKey('today-summary-count')
                          : null,
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Text(
                        widget.isTodaySummary
                            ? '${_selectedDate.month}월 ${_selectedDate.day}일 · 출조 ${records.length}건'
                            : '출조 기록 ${records.length}건',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                  Expanded(
                    child: records.isEmpty
                        ? _EmptyRecordView(
                            selectedDate: _selectedDate,
                            onCreateRecord: widget.isTodaySummary
                                ? _createRecord
                                : null,
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.all(16),
                            itemCount: records.length,
                            separatorBuilder: (context, index) =>
                                const SizedBox(height: 12),
                            itemBuilder: (context, index) {
                              final record = records[index];
                              final theme = Theme.of(context);

                              return Card(
                                margin: EdgeInsets.zero,
                                child: ListTile(
                                  contentPadding: const EdgeInsets.all(16),
                                  title: Text(
                                    _formatTimeRange(
                                      record.startAt,
                                      record.endAt,
                                    ),
                                    style: theme.textTheme.titleMedium
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                  subtitle: Padding(
                                    padding: const EdgeInsets.only(top: 6),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(record.summaryTitle),
                                        const SizedBox(height: 4),
                                        Text(record.locationDisplayName),
                                        const SizedBox(height: 8),
                                        Text(
                                          _syncStatusFor(record.id),
                                          style: theme.textTheme.labelMedium,
                                        ),
                                      ],
                                    ),
                                  ),
                                  isThreeLine: true,
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: () async {
                                    if (widget.isTodaySummary &&
                                        (!_authSession.canManageRecords ||
                                            ModalRoute.of(context)?.isCurrent ==
                                                false)) {
                                      return;
                                    }
                                    final owner = _authSession.dataOwnerKey;
                                    final generation =
                                        _authSession.sessionGeneration;
                                    final changed = await Navigator.of(context)
                                        .push<bool>(
                                          MaterialPageRoute(
                                            builder: (_) => RecordDetailPage(
                                              record: record,
                                            ),
                                          ),
                                        );

                                    if (!mounted) return;
                                    if (widget.isTodaySummary &&
                                        (owner != _authSession.dataOwnerKey ||
                                            generation !=
                                                _authSession
                                                    .sessionGeneration)) {
                                      return;
                                    }
                                    unawaited(
                                      _syncService.syncNow(
                                        scheduleFollowUpIfBusy: true,
                                      ),
                                    );

                                    if (changed == true && mounted) {
                                      setState(() {
                                        hasChanged = true;
                                      });
                                    }
                                  },
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.year}년 ${date.month}월 ${date.day}일 기록';
  }

  String _syncStatusFor(String recordId) {
    if (!_authSession.isPaid) {
      return '로컬 저장';
    }

    final recordItems = _outboxRepository
        .getAllItems()
        .where(
          (item) =>
              item.recordId == recordId &&
              item.operationType != OutboxOperationType.delete,
        )
        .toList(growable: false);

    if (recordItems.any((item) => item.status == OutboxStatus.conflicted)) {
      return '기록 동기화 충돌 · 해결 필요';
    }
    if (recordItems.any((item) => item.status == OutboxStatus.failed)) {
      return '기록 동기화 실패';
    }
    if (recordItems.any((item) => item.status == OutboxStatus.sending)) {
      return '기록 동기화 중';
    }
    if (recordItems.any((item) => item.status == OutboxStatus.pending)) {
      return '기록 동기화 대기';
    }
    if (recordItems.any((item) => item.status == OutboxStatus.succeeded) ||
        _syncService.state == RecordSyncState.succeeded) {
      return '기록 동기화 완료';
    }
    if (_syncService.lastResult?.skipReason ==
        RecordSyncSkipReason.gatewayUnavailable) {
      return '로컬 저장 · 기록 동기화 사용 불가';
    }
    return '기록 동기화 상태 확인 전';
  }

  String _formatTimeRange(DateTime startAt, DateTime endAt) {
    if (widget.isTodaySummary) {
      startAt = startAt.toLocal();
      endAt = endAt.toLocal();
    }
    String twoDigits(int value) => value.toString().padLeft(2, '0');

    if (widget.isTodaySummary &&
        startAt.year == endAt.year &&
        startAt.month == endAt.month &&
        startAt.day == endAt.day) {
      return '${twoDigits(startAt.hour)}:${twoDigits(startAt.minute)} ~ '
          '${twoDigits(endAt.hour)}:${twoDigits(endAt.minute)}';
    }
    final includeYear = widget.isTodaySummary && startAt.year != endAt.year;
    final start =
        '${includeYear ? '${startAt.year}.' : ''}'
        '${twoDigits(startAt.month)}.${twoDigits(startAt.day)} '
        '${twoDigits(startAt.hour)}:${twoDigits(startAt.minute)}';

    final end =
        '${includeYear ? '${endAt.year}.' : ''}'
        '${twoDigits(endAt.month)}.${twoDigits(endAt.day)} '
        '${twoDigits(endAt.hour)}:${twoDigits(endAt.minute)}';

    return widget.isTodaySummary ? '$start ~ $end' : '$start - $end';
  }
}

class _EmptyRecordView extends StatelessWidget {
  final DateTime selectedDate;
  final VoidCallback? onCreateRecord;

  const _EmptyRecordView({required this.selectedDate, this.onCreateRecord});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.event_note_outlined,
                size: 56,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                '저장된 출조 기록이 없습니다.',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                '${selectedDate.month}월 ${selectedDate.day}일에는 아직 기록이 없습니다.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              if (onCreateRecord != null) ...[
                const SizedBox(height: 16),
                FilledButton.icon(
                  key: const ValueKey('calendar-today-create'),
                  onPressed: onCreateRecord,
                  icon: const Icon(Icons.edit_note),
                  label: const Text('기록 작성'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
