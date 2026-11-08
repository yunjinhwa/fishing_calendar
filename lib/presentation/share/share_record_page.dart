import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../data/models/personal_best_record.dart';
import '../../data/models/share_record_data.dart';
import '../../data/models/user_plan_policy.dart';
import '../../data/photos/record_photo_file_store.dart';
import '../../data/repositories/auth_session_repository.dart';
import '../../data/repositories/fishing_record_repository.dart';
import '../../data/repositories/personal_best_repository.dart';
import '../../data/sharing/share_image_exporter.dart';
import '../record/record_history_scope.dart';
import 'share_image_capture.dart';
import 'share_record_card.dart';

class ShareRecordPage extends StatefulWidget {
  const ShareRecordPage({
    super.key,
    required this.record,
    this.repository,
    this.recordChanges,
    this.exporter,
    this.photoReader,
    this.capture = captureShareImage,
  });

  final PersonalBestRecord record;
  final PersonalBestRepository? repository;
  final Listenable? recordChanges;
  final ShareImageExporter? exporter;
  final Future<Uint8List> Function(String path)? photoReader;
  final ShareImageCapture capture;

  @override
  State<ShareRecordPage> createState() => _ShareRecordPageState();
}

class _ShareRecordPageState extends State<ShareRecordPage> {
  final _auth = AuthSessionRepository.instance;
  final _boundaryKey = GlobalKey();
  final _shareButtonKey = GlobalKey();
  late final String _owner;
  late final int _generation;
  late final PersonalBestSortType _criterion;
  late final ShareImageExporter _exporter;
  PersonalBestRecord? _record;
  ShareRecordData? _data;
  String? _fingerprint;
  ShareRecordOptions _options = const ShareRecordOptions();
  int _photoIndex = 0;
  int _revision = 0;
  bool _loadingPhoto = false;
  bool _photoFailed = false;
  bool _busy = false;
  bool _stale = false;
  Uint8List? _png;

  PersonalBestRepository get _repository =>
      widget.repository ?? PersonalBestRepository.instance;
  Listenable get _changes =>
      widget.recordChanges ?? FishingRecordRepository.instance;
  bool get _sameSession =>
      _auth.dataOwnerKey == _owner &&
      _auth.sessionGeneration == _generation &&
      _auth.allows(UserCapability.manageRecords) &&
      !_auth.hasPendingAccountDeletion;
  bool get _isCurrent =>
      mounted &&
      ModalRoute.of(context)?.isCurrent != false &&
      _sameSession &&
      !_stale &&
      _record != null &&
      _fingerprint == _signature(_latest());

  PersonalBestRecord? _latest() => _sameSession
      ? _repository.getPersonalBest(
          widget.record.speciesName,
          sortType: _criterion,
        )
      : null;

  String _nickname() => _auth.nickname?.trim().isNotEmpty == true
      ? _auth.nickname!.trim()
      : '낚시인';

  // Only fields that can appear on this card. Unrelated edits do not rebuild it.
  String? _signature(PersonalBestRecord? record) => record == null
      ? null
      : jsonEncode([
          record.sourceRecord.id,
          record.selectedEvidence.catchIndex,
          record.speciesName,
          record.selectedType.name,
          record.selectedEvidence.lengthCm,
          record.selectedEvidence.weightG,
          record.caughtAt.toIso8601String(),
          record.sourceRecord.location,
          record.sourceRecord.photos.map((photo) => photo.toJson()).toList(),
          _nickname(),
        ]);

  @override
  void initState() {
    super.initState();
    _owner = _auth.dataOwnerKey;
    _generation = _auth.sessionGeneration;
    _criterion = widget.record.selectedType;
    _exporter = widget.exporter ?? createShareImageExporter();
    _auth.addListener(_sourceChanged);
    _changes.addListener(_sourceChanged);
    _resetSnapshot();
  }

  @override
  void dispose() {
    _auth.removeListener(_sourceChanged);
    _changes.removeListener(_sourceChanged);
    _revision++;
    super.dispose();
  }

  void _sourceChanged() {
    if (!mounted) return;
    if (!_sameSession || _signature(_latest()) != _fingerprint) {
      setState(() {
        _stale = true;
        _png = null;
        _data = null;
        _revision++;
      });
    }
  }

  void _resetSnapshot() {
    _record = _latest();
    _fingerprint = _signature(_record);
    _stale = false;
    _png = null;
    _photoIndex = 0;
    _photoFailed = false;
    _data = _record == null
        ? null
        : ShareRecordData.fromPersonalBest(_record!, nickname: _nickname());
    unawaited(_loadPhoto());
  }

  Future<void> _loadPhoto() async {
    final revision = ++_revision;
    final record = _record;
    final photos = record?.sourceRecord.photos;
    final path = photos == null || photos.isEmpty
        ? null
        : photos[_photoIndex].localPath;
    _loadingPhoto = path != null && path.isNotEmpty && _options.showPhoto;
    _photoFailed = false;
    _png = null;
    if (record == null) return;
    _data = ShareRecordData.fromPersonalBest(record, nickname: _nickname());
    if (!_loadingPhoto) return;
    try {
      final bytes =
          await (widget.photoReader ?? RecordPhotoFileStore().readBytes)(path!);
      if (!mounted || !_isCurrent || revision != _revision) return;
      if (bytes.isEmpty || bytes.length > 10 * 1024 * 1024) {
        throw StateError('Photo is unavailable.');
      }
      final candidate = ShareRecordData.fromPersonalBest(
        record,
        nickname: _nickname(),
        photoBytes: bytes,
      );
      var decoded = true;
      await precacheImage(
        ShareRecordCard.photoProvider(candidate.photoBytes!),
        context,
        onError: (error, stack) => decoded = false,
      );
      if (!mounted || !_isCurrent || revision != _revision) return;
      setState(() {
        _photoFailed = !decoded;
        _data = decoded
            ? candidate
            : ShareRecordData.fromPersonalBest(record, nickname: _nickname());
      });
    } catch (_) {
      if (_isCurrent && revision == _revision) {
        setState(() => _photoFailed = true);
      }
    } finally {
      if (mounted && revision == _revision) {
        setState(() => _loadingPhoto = false);
      }
    }
  }

  void _setOptions(ShareRecordOptions options) {
    if (_busy) return;
    final photoChanged = _options.showPhoto != options.showPhoto;
    setState(() {
      _options = options;
      _png = null;
      if (photoChanged) unawaited(_loadPhoto());
    });
  }

  Future<void> _export({required bool share}) async {
    if (_busy || _loadingPhoto || !_isCurrent) return;
    final revision = _revision;
    bool current() => _isCurrent && revision == _revision;
    setState(() => _busy = true);
    try {
      if (_png == null) {
        final cardContext = _boundaryKey.currentContext;
        if (cardContext == null) return;
        await Scrollable.ensureVisible(cardContext, alignment: 0);
        if (!mounted || !current()) return;
        await precacheImage(
          ShareRecordCard.backgroundProvider,
          context,
          onError: (error, stack) {},
        );
        if (!mounted || !current()) return;
        // Keep exactly the provider decoded by the card ready for its paint.
        final photo = _data?.photoBytes;
        if (_options.showPhoto && photo != null) {
          await precacheImage(
            ShareRecordCard.photoProvider(photo),
            context,
            onError: (error, stack) {},
          );
          if (!mounted || !current()) return;
        }
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || !current()) return;
        final png = await widget.capture(_boundaryKey);
        if (!mounted || !current()) return;
        _png = png;
      }
      if (!mounted || !current()) return;
      final renderBox = _shareButtonKey.currentContext?.findRenderObject();
      final origin = renderBox is RenderBox
          ? renderBox.localToGlobal(Offset.zero) & renderBox.size
          : null;
      // A neutral filename carries no nickname, place or internal record ID.
      final fileName =
          'FishingBuild_${DateTime.now().millisecondsSinceEpoch}.png';
      final result = share
          ? await _exporter.share(
              _png!,
              fileName: fileName,
              isCurrent: current,
              origin: origin,
            )
          : await _exporter.save(_png!, fileName: fileName, isCurrent: current);
      if (!mounted || !current()) return;
      _message(switch (result) {
        ShareImageExportResult.saved => '이미지를 저장했습니다.',
        ShareImageExportResult.shared => '공유 앱을 선택했습니다.',
        ShareImageExportResult.shareSheetOpened => '공유 화면을 열었습니다.',
        ShareImageExportResult.cancelled =>
          share ? '공유를 취소했습니다.' : '저장을 취소했습니다.',
      });
    } catch (error) {
      if (!mounted || !current()) return;
      final reason = error is ShareImageExportException ? error.reason : null;
      _message(switch (reason) {
        ShareImageExportFailure.permissionDenied =>
          '사진 저장 권한이 필요합니다. 설정에서 권한을 허용한 후 다시 시도해 주세요.',
        ShareImageExportFailure.storageFull => '저장 공간이 부족합니다.',
        ShareImageExportFailure.unavailable =>
          share ? '이 기기에서는 이미지 공유를 지원하지 않습니다.' : '이 기기에서는 이미지 저장을 지원하지 않습니다.',
        _ => '이미지를 ${share ? '공유' : '저장'}하지 못했습니다. 다시 시도해 주세요.',
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final valid = _sameSession && !_stale && _data != null;
    return Scaffold(
      appBar: AppBar(title: const Text('공유 이미지 미리보기')),
      bottomNavigationBar: valid
          ? SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    if (_busy) ...[
                      const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy || _loadingPhoto
                            ? null
                            : () => _export(share: false),
                        icon: const Icon(Icons.download_outlined),
                        label: const Text('이미지 저장'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        key: _shareButtonKey,
                        onPressed: _busy || _loadingPhoto
                            ? null
                            : () => _export(share: true),
                        icon: const Icon(Icons.ios_share_outlined),
                        label: const Text('공유하기'),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : null,
      body: SafeArea(
        child: RecordHistoryScope(
          isActive: _sameSession,
          child: !valid
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          !_sameSession
                              ? '계정 상태가 변경되어 공유를 중단했습니다.'
                              : '기록이 변경되었거나 삭제되었습니다. 최신 기록을 확인해 주세요.',
                          textAlign: TextAlign.center,
                        ),
                        if (_sameSession && !_busy)
                          TextButton(
                            onPressed: () => setState(_resetSnapshot),
                            child: const Text('최신 기록으로 새로고침'),
                          ),
                      ],
                    ),
                  ),
                )
              : Column(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Center(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: RepaintBoundary(
                                  key: _boundaryKey,
                                  child: ShareRecordCard(
                                    data: _data!,
                                    options: _options,
                                  ),
                                ),
                              ),
                            ),
                            if (_loadingPhoto)
                              const Padding(
                                padding: EdgeInsets.all(12),
                                child: LinearProgressIndicator(),
                              ),
                            if (_photoFailed && _options.showPhoto)
                              const Padding(
                                padding: EdgeInsets.only(top: 12),
                                child: Text('사진을 불러올 수 없어 기본 표시로 대체했습니다.'),
                              ),
                            if (_options.showPhoto &&
                                _record!.sourceRecord.photos.length > 1) ...[
                              const SizedBox(height: 16),
                              DropdownButtonFormField<int>(
                                key: ValueKey('share-photo-$_photoIndex'),
                                initialValue: _photoIndex,
                                decoration: const InputDecoration(
                                  labelText: '출조 사진 선택',
                                ),
                                items: [
                                  for (
                                    var i = 0;
                                    i < _record!.sourceRecord.photos.length;
                                    i++
                                  )
                                    DropdownMenuItem(
                                      value: i,
                                      child: Text('사진 ${i + 1}'),
                                    ),
                                ],
                                onChanged: _busy
                                    ? null
                                    : (index) {
                                        if (index == null ||
                                            index == _photoIndex) {
                                          return;
                                        }
                                        setState(() {
                                          _photoIndex = index;
                                          unawaited(_loadPhoto());
                                        });
                                      },
                              ),
                            ],
                            const SizedBox(height: 20),
                            Text(
                              '이미지에 포함할 항목',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: [
                                _option(
                                  '닉네임',
                                  _options.showNickname,
                                  (v) => _options.copyWith(showNickname: v),
                                ),
                                _option(
                                  '사진',
                                  _options.showPhoto,
                                  (v) => _options.copyWith(showPhoto: v),
                                ),
                                _option(
                                  '크기',
                                  _options.showLength,
                                  (v) => _options.copyWith(showLength: v),
                                ),
                                _option(
                                  '무게',
                                  _options.showWeight,
                                  (v) => _options.copyWith(showWeight: v),
                                ),
                                _option(
                                  '날짜',
                                  _options.showDate,
                                  (v) => _options.copyWith(showDate: v),
                                ),
                                _option(
                                  '장소',
                                  _options.showLocation,
                                  (v) => _options.copyWith(showLocation: v),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              '선택한 조과의 크기·무게를 표시합니다. 사진은 해당 출조의 사진입니다.',
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _option(
    String label,
    bool selected,
    ShareRecordOptions Function(bool) update,
  ) => FilterChip(
    label: Text(label),
    selected: selected,
    onSelected: _busy ? null : (value) => _setOptions(update(value)),
  );
}
