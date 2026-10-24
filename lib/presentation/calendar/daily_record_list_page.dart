import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/models/outbox_item.dart';
import '../../data/repositories/auth_session_repository.dart';
import '../../data/repositories/fishing_record_repository.dart';
import '../../data/repositories/outbox_repository.dart';
import '../../data/services/record_sync_service.dart';
import '../record/record_detail_page.dart';

class DailyRecordListPage extends StatefulWidget {
  final DateTime selectedDate;

  const DailyRecordListPage({super.key, required this.selectedDate});

  @override
  State<DailyRecordListPage> createState() => _DailyRecordListPageState();
}

class _DailyRecordListPageState extends State<DailyRecordListPage> {
  bool hasChanged = false;
  final _authSession = AuthSessionRepository.instance;
  final _recordRepository = FishingRecordRepository.instance;
  final _outboxRepository = OutboxRepository.instance;
  final _syncService = RecordSyncService.instance;

  @override
  void initState() {
    super.initState();
    _recordRepository.addListener(_refreshRecords);
    _syncService.addListener(_refreshRecords);
  }

  @override
  void dispose() {
    _recordRepository.removeListener(_refreshRecords);
    _syncService.removeListener(_refreshRecords);
    super.dispose();
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
    final records = _recordRepository.getRecordsByDate(widget.selectedDate);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          return;
        }

        Navigator.of(context).pop(hasChanged);
      },
      child: Scaffold(
        appBar: AppBar(title: Text(_formatDate(widget.selectedDate))),
        body: records.isEmpty
            ? _EmptyRecordView(selectedDate: widget.selectedDate)
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: records.length,
                separatorBuilder: (context, index) =>
                    const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final record = records[index];

                  return Card(
                    child: ListTile(
                      contentPadding: const EdgeInsets.all(16),
                      title: Text(
                        record.summaryTitle,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          '${_formatTimeRange(record.startAt, record.endAt)}\n'
                          '${record.location}\n${_syncStatusFor(record.id)}',
                        ),
                      ),
                      isThreeLine: true,
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () async {
                        final changed = await Navigator.of(context).push<bool>(
                          MaterialPageRoute(
                            builder: (_) => RecordDetailPage(record: record),
                          ),
                        );

                        if (!mounted) return;
                        unawaited(
                          _syncService.syncNow(scheduleFollowUpIfBusy: true),
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
    String twoDigits(int value) => value.toString().padLeft(2, '0');

    final start =
        '${twoDigits(startAt.month)}.${twoDigits(startAt.day)} '
        '${twoDigits(startAt.hour)}:${twoDigits(startAt.minute)}';

    final end =
        '${twoDigits(endAt.month)}.${twoDigits(endAt.day)} '
        '${twoDigits(endAt.hour)}:${twoDigits(endAt.minute)}';

    return '$start - $end';
  }
}

class _EmptyRecordView extends StatelessWidget {
  final DateTime selectedDate;

  const _EmptyRecordView({required this.selectedDate});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
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
          ],
        ),
      ),
    );
  }
}
