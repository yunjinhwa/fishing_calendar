import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../data/models/fishing_record.dart';
import '../../data/models/record_edit_snapshot.dart';
import '../../data/photos/record_photo_file_store.dart';
import '../../data/repositories/fishing_record_repository.dart';
import '../../data/repositories/auth_session_repository.dart';
import '../../data/services/record_mutation_service.dart';
import '../../data/services/record_sync_service.dart';
import '../auth/auth_access_guard.dart';
import 'record_form_page.dart';

class RecordDetailPage extends StatefulWidget {
  final FishingRecord record;

  const RecordDetailPage({super.key, required this.record});

  @override
  State<RecordDetailPage> createState() => _RecordDetailPageState();
}

class _RecordDetailPageState extends State<RecordDetailPage> {
  final _recordRepository = FishingRecordRepository.instance;

  late FishingRecord record;
  late final String _ownerKey;
  late final int _sessionGeneration;
  RecordEditConflictReason? _unavailableReason;
  bool _isPreparingDelete = false;
  bool _isDeleting = false;
  VoidCallback? _stopRecordWatch;

  @override
  void initState() {
    super.initState();
    _ownerKey = AuthSessionRepository.instance.dataOwnerKey;
    _sessionGeneration = AuthSessionRepository.instance.sessionGeneration;
    final current = _recordRepository.getRecordById(widget.record.id);
    record = current ?? widget.record;
    if (current == null) _unavailableReason = RecordEditConflictReason.deleted;
    _recordRepository.addListener(_handleRecordChange);
    AuthSessionRepository.instance.addListener(_handleRecordChange);
    _stopRecordWatch = RecordSyncService.instance.observeRecord(record.id);
  }

  @override
  void dispose() {
    _stopRecordWatch?.call();
    _recordRepository.removeListener(_handleRecordChange);
    AuthSessionRepository.instance.removeListener(_handleRecordChange);
    super.dispose();
  }

  bool get _isCurrentSession =>
      AuthSessionRepository.instance.dataOwnerKey == _ownerKey &&
      AuthSessionRepository.instance.sessionGeneration == _sessionGeneration;

  void _handleRecordChange() {
    if (!mounted) return;
    if (!_isCurrentSession) {
      if (_unavailableReason != RecordEditConflictReason.sessionChanged) {
        setState(
          () => _unavailableReason = RecordEditConflictReason.sessionChanged,
        );
      }
      return;
    }
    final current = _recordRepository.getRecordById(widget.record.id);
    setState(() {
      _unavailableReason = current == null
          ? RecordEditConflictReason.deleted
          : null;
      if (current != null) record = current;
    });
  }

  void _showMutationError(Object error) {
    if (!mounted) return;
    _handleRecordChange();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          error is RecordEditConflictException
              ? error.message
              : '기록을 처리하지 못했습니다. 다시 시도해 주세요.',
        ),
      ),
    );
  }

  Future<void> editRecord() async {
    if (_isPreparingDelete || _isDeleting) return;
    final allowed = await requireMemberAccess(
      context,
      message: '출조 기록 수정은 로그인 후 사용할 수 있습니다.',
    );

    if (!allowed || !mounted || _isPreparingDelete || _isDeleting) {
      return;
    }
    _handleRecordChange();
    if (_unavailableReason != null) return;

    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => RecordFormPage(editingRecord: record)),
    );

    if (!mounted) return;
    unawaited(RecordSyncService.instance.syncNow(scheduleFollowUpIfBusy: true));
    if (saved == true) _handleRecordChange();
  }

  Future<void> deleteRecord() async {
    if (_isPreparingDelete || _isDeleting) return;
    setState(() => _isPreparingDelete = true);
    try {
      final allowed = await requireMemberAccess(
        context,
        message: '출조 기록 삭제는 로그인 후 사용할 수 있습니다.',
      );
      if (!allowed || !mounted) return;
      _handleRecordChange();
      if (_unavailableReason != null) return;
      final snapshot = await RecordMutationService.instance.beginEditingRecord(
        record,
      );
      if (!mounted) return;

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('기록 삭제'),
            content: const Text('이 출조 기록을 삭제하시겠습니까?'),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop(false);
                },
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.of(context).pop(true);
                },
                child: const Text('삭제'),
              ),
            ],
          );
        },
      );

      if (confirmed != true || !mounted) return;
      setState(() {
        _isPreparingDelete = false;
        _isDeleting = true;
      });
      await RecordMutationService.instance.deleteRecord(
        record.id,
        expectedSnapshot: snapshot,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('출조 기록이 삭제되었습니다.')));
      Navigator.of(context).pop(true);
    } on Object catch (error) {
      _showMutationError(error);
    } finally {
      if (mounted) {
        setState(() {
          _isPreparingDelete = false;
          _isDeleting = false;
        });
      }
    }
  }

  void _requestExit() {
    if (_isPreparingDelete || _isDeleting) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _isDeleting
                ? '기록을 삭제하는 중입니다. 잠시만 기다려 주세요.'
                : '기록을 확인하는 중입니다. 잠시만 기다려 주세요.',
          ),
        ),
      );
      return;
    }
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<bool>(
      canPop: !_isPreparingDelete && !_isDeleting,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _requestExit();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: _requestExit),
          title: const Text('출조 기록'),
          bottom: _isDeleting
              ? const PreferredSize(
                  preferredSize: Size.fromHeight(2),
                  child: LinearProgressIndicator(),
                )
              : null,
          actions: [
            IconButton(
              onPressed:
                  _unavailableReason != null ||
                      _isPreparingDelete ||
                      _isDeleting
                  ? null
                  : editRecord,
              icon: const Icon(Icons.edit_outlined),
              tooltip: '수정',
            ),
            IconButton(
              onPressed:
                  _unavailableReason != null ||
                      _isPreparingDelete ||
                      _isDeleting
                  ? null
                  : deleteRecord,
              icon: const Icon(Icons.delete_outline),
              tooltip: '삭제',
            ),
          ],
        ),
        body: _unavailableReason != null
            ? SafeArea(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _unavailableReason ==
                                  RecordEditConflictReason.sessionChanged
                              ? '계정이 변경되어 이 기록을 표시할 수 없습니다.'
                              : '이 기록은 삭제되었습니다.',
                        ),
                        const SizedBox(height: 16),
                        TextButton(
                          onPressed: _requestExit,
                          child: const Text('목록으로 돌아가기'),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            : SafeArea(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(
                      record.summaryTitle,
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),

                    Text(
                      _formatDateTimeRange(record.startAt, record.endAt),
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 12),

                    Row(
                      children: [
                        const Icon(Icons.place_outlined, size: 18),
                        const SizedBox(width: 6),
                        Expanded(child: Text(record.location)),
                      ],
                    ),
                    const SizedBox(height: 24),

                    _SectionTitle(title: '외부 데이터'),
                    const SizedBox(height: 8),
                    _InfoCard(
                      children: [
                        _InfoRow(label: '물때', value: record.tide ?? '-'),
                        _InfoRow(label: '날씨', value: record.weather ?? '-'),
                        _InfoRow(
                          label: '기온',
                          value: record.airTemperature == null
                              ? '-'
                              : '${record.airTemperature}℃',
                        ),
                        _InfoRow(
                          label: '수온',
                          value: record.waterTemperature == null
                              ? '-'
                              : '${record.waterTemperature}℃',
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    _SectionTitle(title: '조과'),
                    const SizedBox(height: 8),

                    if (record.catches.isEmpty)
                      const _EmptyInfoCard(message: '입력된 조과가 없습니다.')
                    else
                      ...record.catches.map(
                        (catchRecord) => _InfoCard(
                          margin: const EdgeInsets.only(bottom: 8),
                          children: [
                            _InfoRow(
                              label: '어종',
                              value: catchRecord.speciesName,
                            ),
                            _InfoRow(
                              label: '크기',
                              value: catchRecord.lengthCm == null
                                  ? '-'
                                  : '${catchRecord.lengthCm}cm',
                            ),
                            _InfoRow(
                              label: '무게',
                              value: catchRecord.weightG == null
                                  ? '-'
                                  : '${catchRecord.weightG}g',
                            ),
                          ],
                        ),
                      ),

                    const SizedBox(height: 16),

                    _SectionTitle(title: '사진'),
                    const SizedBox(height: 8),

                    if (record.photos.isEmpty)
                      const _EmptyInfoCard(message: '첨부된 사진이 없습니다.')
                    else
                      SizedBox(
                        height: 120,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: record.photos.length,
                          separatorBuilder: (context, index) =>
                              const SizedBox(width: 8),
                          itemBuilder: (context, index) {
                            final photo = record.photos[index];

                            return ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: _RecordPhotoPreview(photo: photo),
                            );
                          },
                        ),
                      ),

                    const SizedBox(height: 24),

                    _SectionTitle(title: '메모'),
                    const SizedBox(height: 8),
                    _InfoCard(
                      children: [
                        Text(
                          record.memo?.isNotEmpty == true
                              ? record.memo!
                              : '메모가 없습니다.',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  String _formatDateTimeRange(DateTime startAt, DateTime endAt) {
    String twoDigits(int value) => value.toString().padLeft(2, '0');

    final start =
        '${startAt.year}.${twoDigits(startAt.month)}.${twoDigits(startAt.day)} '
        '${twoDigits(startAt.hour)}:${twoDigits(startAt.minute)}';

    final end =
        '${endAt.year}.${twoDigits(endAt.month)}.${twoDigits(endAt.day)} '
        '${twoDigits(endAt.hour)}:${twoDigits(endAt.minute)}';

    return '$start - $end';
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
  final EdgeInsetsGeometry? margin;

  const _InfoCard({required this.children, this.margin});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: margin,
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
            width: 56,
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.grey.shade600),
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

class _EmptyInfoCard extends StatelessWidget {
  final String message;

  const _EmptyInfoCard({required this.message});

  @override
  Widget build(BuildContext context) {
    return _InfoCard(
      children: [
        Text(
          message,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: Colors.grey.shade600),
        ),
      ],
    );
  }
}

class _RecordPhotoPreview extends StatelessWidget {
  final RecordPhoto photo;

  const _RecordPhotoPreview({required this.photo});

  @override
  Widget build(BuildContext context) {
    final localPath = photo.localPath?.trim();
    if (!kIsWeb && localPath != null && localPath.isNotEmpty) {
      return Image.file(
        File(localPath),
        width: 120,
        height: 120,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => _placeholder(
          context,
          icon: Icons.broken_image_outlined,
          label: '사진을 불러올 수 없음',
        ),
      );
    }
    if (kIsWeb && localPath != null && localPath.isNotEmpty) {
      return FutureBuilder<Uint8List>(
        future: RecordPhotoFileStore().readBytes(localPath),
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          if (bytes != null) {
            return Image.memory(
              bytes,
              width: 120,
              height: 120,
              fit: BoxFit.cover,
            );
          }
          return _placeholder(
            context,
            icon: snapshot.hasError
                ? Icons.broken_image_outlined
                : Icons.image_outlined,
            label: snapshot.hasError ? '사진을 불러올 수 없음' : null,
          );
        },
      );
    }

    return _placeholder(
      context,
      icon: Icons.broken_image_outlined,
      label: '사진을 불러올 수 없음',
    );
  }

  Widget _placeholder(
    BuildContext context, {
    required IconData icon,
    String? label,
  }) {
    return Container(
      width: 120,
      height: 120,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.all(8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon),
          if (label != null) ...[
            const SizedBox(height: 6),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ],
      ),
    );
  }
}
