import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/validation/fishing_record_validator.dart';
import '../../data/models/fishing_record.dart';
import '../../data/models/record_edit_snapshot.dart';
import '../../data/photos/record_photo_file_store.dart';
import '../../data/photos/record_photo_file_store_utils.dart';
import '../../data/repositories/auth_session_repository.dart';
import '../../data/repositories/fishing_record_repository.dart';
import '../../data/services/record_mutation_service.dart';
import '../../data/services/record_sync_service.dart';
import '../auth/auth_access_guard.dart';

class RecordFormPage extends StatefulWidget {
  final FishingRecord? editingRecord;

  final String? initialLocation;
  final String? initialTide;
  final String? initialWeather;
  final double? initialAirTemperature;
  final double? initialWaterTemperature;
  final String? initialFishName;

  const RecordFormPage({
    super.key,
    this.editingRecord,
    this.initialLocation,
    this.initialTide,
    this.initialWeather,
    this.initialAirTemperature,
    this.initialWaterTemperature,
    this.initialFishName,
  });

  @override
  State<RecordFormPage> createState() => _RecordFormPageState();
}

class _RecordFormPageState extends State<RecordFormPage> {
  bool get isEditMode => widget.editingRecord != null;

  final locationController = TextEditingController();
  final tideController = TextEditingController();
  final weatherController = TextEditingController();
  final airTemperatureController = TextEditingController();
  final waterTemperatureController = TextEditingController();
  final memoController = TextEditingController();
  final customGenreController = TextEditingController();

  final imagePicker = ImagePicker();
  final photoFileStore = RecordPhotoFileStore();
  final photos = <RecordPhoto>[];
  final catchItems = <_CatchItemInput>[_CatchItemInput()];

  late final String recordId;
  late final String _editingOwnerKey;
  late final int _editingSessionGeneration;
  RecordEditSnapshot? _editSnapshot;
  RecordEditConflictReason? _editConflictReason;
  String? _editLoadError;
  bool _isPreparingEdit = false;
  bool _isSaving = false;
  bool _isConfirmingDiscard = false;
  bool _isConfirmingReload = false;
  String? _draftBaseline;
  bool _hasUnsavedChanges = false;
  VoidCallback? _stopRecordWatch;
  bool isPickingPhoto = false;
  int nextPhotoSequence = 0;

  DateTime startAt = DateTime.now();
  DateTime endAt = DateTime.now().add(const Duration(hours: 2));

  String? selectedGenre;

  final genres = const ['루어', '찌낚시', '선상', '원투', '기타'];

  @override
  void initState() {
    super.initState();

    recordId =
        widget.editingRecord?.id ??
        DateTime.now().microsecondsSinceEpoch.toString();
    _editingOwnerKey = AuthSessionRepository.instance.dataOwnerKey;
    _editingSessionGeneration =
        AuthSessionRepository.instance.sessionGeneration;

    locationController.text = widget.initialLocation ?? '';
    tideController.text = widget.initialTide ?? '';
    weatherController.text = widget.initialWeather ?? '';
    airTemperatureController.text =
        widget.initialAirTemperature?.toString() ?? '';
    waterTemperatureController.text =
        widget.initialWaterTemperature?.toString() ?? '';

    if (widget.initialFishName != null && catchItems.isNotEmpty) {
      catchItems.first.speciesController.text = widget.initialFishName!;
    }

    final editingRecord = widget.editingRecord;

    if (editingRecord != null) {
      _initializeEditingRecord(editingRecord);
      AuthSessionRepository.instance.addListener(_handleEditSourceChange);
      FishingRecordRepository.instance.addListener(_handleEditSourceChange);
      _stopRecordWatch = RecordSyncService.instance.observeRecord(recordId);
      _isPreparingEdit = true;
      unawaited(_prepareEditingRecord(editingRecord));
    }
    _resetDraftBaseline();
    for (final controller in _textControllers) {
      controller.addListener(_handleDraftChange);
    }
    for (final item in catchItems) {
      item.addListener(_handleDraftChange);
    }
  }

  Iterable<TextEditingController> get _textControllers => [
    locationController,
    tideController,
    weatherController,
    airTemperatureController,
    waterTemperatureController,
    memoController,
    customGenreController,
  ];

  String _captureDraft() => jsonEncode([
    for (final controller in _textControllers) controller.text,
    startAt.toIso8601String(),
    endAt.toIso8601String(),
    selectedGenre,
    for (final item in catchItems)
      [
        item.speciesController.text,
        item.lengthController.text,
        item.weightController.text,
      ],
    photos.map((photo) => photo.toJson()).toList(),
  ]);

  void _resetDraftBaseline() {
    _draftBaseline = _captureDraft();
    _hasUnsavedChanges = false;
  }

  void _handleDraftChange() {
    if (!mounted || _draftBaseline == null) return;
    final changed = _captureDraft() != _draftBaseline;
    if (changed != _hasUnsavedChanges) {
      setState(() => _hasUnsavedChanges = changed);
    }
  }

  Future<void> _requestExit() async {
    if (_isSaving) {
      showMessage('기록을 저장하는 중입니다. 잠시만 기다려 주세요.');
      return;
    }
    if (_isPreparingEdit || isPickingPhoto) {
      showMessage('기록 정보를 처리하는 중입니다. 잠시만 기다려 주세요.');
      return;
    }
    if (_isConfirmingDiscard || _isConfirmingReload) return;
    if (!_hasUnsavedChanges) {
      Navigator.of(context).pop();
      return;
    }
    _isConfirmingDiscard = true;
    try {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('저장하지 않고 나가시겠습니까?'),
          content: const Text('작성한 내용이 저장되지 않습니다.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('계속 작성'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('나가기'),
            ),
          ],
        ),
      );
      if (discard == true && mounted) Navigator.of(context).pop();
    } finally {
      _isConfirmingDiscard = false;
    }
  }

  bool get _isEditingSessionCurrent =>
      AuthSessionRepository.instance.dataOwnerKey == _editingOwnerKey &&
      AuthSessionRepository.instance.sessionGeneration ==
          _editingSessionGeneration;

  String get _editNoticeMessage => _editConflictReason == null
      ? _editLoadError ?? '기록 정보를 확인한 뒤 다시 시도해 주세요.'
      : RecordEditConflictException(_editConflictReason!).message;

  Future<void> _prepareEditingRecord(FishingRecord displayedRecord) async {
    try {
      final snapshot = await RecordMutationService.instance.beginEditingRecord(
        displayedRecord,
      );
      if (!mounted) return;
      setState(() {
        _editSnapshot = snapshot;
        _isPreparingEdit = false;
      });
      _handleEditSourceChange();
    } on RecordEditConflictException catch (error) {
      if (!mounted) return;
      setState(() {
        _editConflictReason = error.reason;
        _isPreparingEdit = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _editLoadError = '기록 정보를 확인하지 못했습니다. 입력한 내용은 유지됩니다. 다시 시도해 주세요.';
        _isPreparingEdit = false;
      });
    }
  }

  void _handleEditSourceChange() {
    if (!mounted || _isSaving) return;
    RecordEditConflictReason? reason;
    if (!_isEditingSessionCurrent) {
      reason = RecordEditConflictReason.sessionChanged;
    } else if (_editSnapshot != null && !_isPreparingEdit) {
      final current = FishingRecordRepository.instance.getRecordById(recordId);
      if (current == null) {
        reason = RecordEditConflictReason.deleted;
      } else if (!_editSnapshot!.matchesRecord(current)) {
        reason = RecordEditConflictReason.changed;
      }
    }
    if (reason != null && reason != _editConflictReason) {
      setState(() => _editConflictReason = reason);
    }
  }

  Future<void> _reloadLatestRecord() async {
    if (_isPreparingEdit ||
        _isSaving ||
        isPickingPhoto ||
        _isConfirmingDiscard ||
        _isConfirmingReload) {
      return;
    }
    if (!_isEditingSessionCurrent) {
      setState(
        () => _editConflictReason = RecordEditConflictReason.sessionChanged,
      );
      return;
    }
    _isConfirmingReload = true;
    final bool? confirmed;
    try {
      confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('최신 기록 불러오기'),
          content: const Text('최신 기록을 불러오면 현재 입력한 내용이 대체됩니다. 불러오시겠습니까?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('입력 유지'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('불러오기'),
            ),
          ],
        ),
      );
    } finally {
      _isConfirmingReload = false;
    }
    if (confirmed != true || !mounted) return;
    if (!_isEditingSessionCurrent) {
      setState(
        () => _editConflictReason = RecordEditConflictReason.sessionChanged,
      );
      return;
    }
    setState(() => _isPreparingEdit = true);
    try {
      final snapshot = await RecordMutationService.instance
          .loadRecordForEditing(recordId);
      if (!mounted) return;
      if (!_isEditingSessionCurrent) {
        throw const RecordEditConflictException(
          RecordEditConflictReason.sessionChanged,
        );
      }
      setState(() {
        _initializeEditingRecord(snapshot.record);
        _editSnapshot = snapshot;
        _editConflictReason = null;
        _editLoadError = null;
        _resetDraftBaseline();
      });
    } on RecordEditConflictException catch (error) {
      if (!mounted) return;
      setState(() => _editConflictReason = error.reason);
      showMessage(error.message);
    } on Object {
      if (!mounted) return;
      showMessage('기록을 불러오지 못했습니다. 입력한 내용은 유지됩니다. 다시 시도해 주세요.');
    } finally {
      if (mounted) setState(() => _isPreparingEdit = false);
    }
  }

  void _initializeEditingRecord(FishingRecord record) {
    locationController.text = record.location;
    tideController.text = record.tide ?? '';
    weatherController.text = record.weather ?? '';
    airTemperatureController.text = record.airTemperature?.toString() ?? '';
    waterTemperatureController.text = record.waterTemperature?.toString() ?? '';
    memoController.text = record.memo ?? '';

    startAt = record.startAt;
    endAt = record.endAt;

    if (genres.contains(record.genreName)) {
      selectedGenre = record.genreName;
      customGenreController.clear();
    } else {
      selectedGenre = '기타';
      customGenreController.text = record.genreName;
    }

    for (final item in catchItems) {
      item.dispose();
    }

    catchItems
      ..clear()
      ..addAll(
        record.catches.map(
          (catchRecord) => _CatchItemInput(catchRecord: catchRecord),
        ),
      );

    if (catchItems.isEmpty) {
      catchItems.add(_CatchItemInput());
    }
    if (_draftBaseline != null) {
      for (final item in catchItems) {
        item.addListener(_handleDraftChange);
      }
    }

    photos
      ..clear()
      ..addAll(record.photos);
  }

  @override
  void dispose() {
    _stopRecordWatch?.call();
    if (isEditMode) {
      AuthSessionRepository.instance.removeListener(_handleEditSourceChange);
      FishingRecordRepository.instance.removeListener(_handleEditSourceChange);
    }
    locationController.dispose();
    tideController.dispose();
    weatherController.dispose();
    airTemperatureController.dispose();
    waterTemperatureController.dispose();
    memoController.dispose();
    for (final item in catchItems) {
      item.dispose();
    }
    customGenreController.dispose();
    super.dispose();
  }

  Future<void> saveRecord() async {
    if (_isSaving ||
        _isPreparingEdit ||
        isPickingPhoto ||
        _isConfirmingDiscard ||
        _isConfirmingReload) {
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _isSaving = true);
    try {
      if (isEditMode) {
        if (!_isEditingSessionCurrent) {
          throw const RecordEditConflictException(
            RecordEditConflictReason.sessionChanged,
          );
        }
        if (_editSnapshot == null) {
          showMessage(_editNoticeMessage);
          return;
        }
      }
      await _saveValidatedRecord();
    } on RecordEditConflictException catch (error) {
      if (!mounted) return;
      setState(() => _editConflictReason = error.reason);
      showMessage(error.message);
    } on Object {
      if (!mounted) return;
      showMessage('기록을 저장하지 못했습니다. 입력한 내용은 유지됩니다. 다시 시도해 주세요.');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _saveValidatedRecord() async {
    final allowed = await requireMemberAccess(
      context,
      message: '출조 기록 저장은 로그인 후 사용할 수 있습니다.',
    );

    if (!allowed || !mounted) {
      return;
    }

    final location = locationController.text.trim();
    final tide = tideController.text.trim();
    final weather = weatherController.text.trim();
    final airTemperature = airTemperatureController.text.trim();
    final waterTemperature = waterTemperatureController.text.trim();
    final genre = selectedGenre;
    final customGenre = customGenreController.text.trim();

    if (location.isEmpty) {
      showMessage('위치를 입력하세요.');
      return;
    }

    if (!startAt.isBefore(endAt)) {
      showMessage('종료 시간은 시작 시간보다 늦어야 합니다.');
      return;
    }

    if (genre == null || genre.trim().isEmpty) {
      showMessage('낚시 장르를 선택하세요.');
      return;
    }

    if (genre == '기타' && customGenre.isEmpty) {
      showMessage('기타 낚시 장르를 입력하세요.');
      return;
    }

    final genreName = genre == '기타' ? customGenre : genre;

    if (tide.isEmpty) {
      showMessage('물때를 입력하세요.');
      return;
    }

    if (weather.isEmpty) {
      showMessage('날씨를 입력하세요.');
      return;
    }

    if (airTemperature.isEmpty) {
      showMessage('기온을 입력하세요.');
      return;
    }

    final airTemperatureValue = double.tryParse(airTemperature);

    if (airTemperatureValue == null) {
      showMessage('기온은 숫자로 입력하세요.');
      return;
    }

    if (waterTemperature.isEmpty) {
      showMessage('수온을 입력하세요.');
      return;
    }

    final waterTemperatureValue = double.tryParse(waterTemperature);

    if (waterTemperatureValue == null) {
      showMessage('수온은 숫자로 입력하세요.');
      return;
    }

    for (var i = 0; i < catchItems.length; i++) {
      final item = catchItems[i];
      final species = item.speciesController.text.trim();
      final length = item.lengthController.text.trim();
      final weight = item.weightController.text.trim();

      final hasAnyValue =
          species.isNotEmpty || length.isNotEmpty || weight.isNotEmpty;

      if (!hasAnyValue) {
        continue;
      }

      if (species.isEmpty) {
        showMessage('조과 ${i + 1}의 어종을 입력하세요.');
        return;
      }

      if (length.isNotEmpty) {
        final lengthValue = double.tryParse(length);

        if (lengthValue == null || lengthValue < 0) {
          showMessage('조과 ${i + 1}의 크기는 0 이상의 숫자로 입력하세요.');
          return;
        }
      }

      if (weight.isNotEmpty) {
        final weightValue = int.tryParse(weight);

        if (weightValue == null || weightValue < 0) {
          showMessage('조과 ${i + 1}의 무게는 0 이상의 정수(g)로 입력하세요.');
          return;
        }
      }
    }

    final catches = catchItems
        .map((item) {
          final species = item.speciesController.text.trim();
          final length = item.lengthController.text.trim();
          final weight = item.weightController.text.trim();

          if (species.isEmpty) {
            return null;
          }

          return CatchRecord(
            speciesName: species,
            lengthCm: length.isEmpty ? null : double.parse(length),
            weightG: weight.isEmpty ? null : int.parse(weight),
          );
        })
        .whereType<CatchRecord>()
        .toList();

    final record = FishingRecord(
      id: recordId,
      location: location,
      startAt: startAt,
      endAt: endAt,
      genreName: genreName,
      tide: tide,
      weather: weather,
      airTemperature: airTemperatureValue,
      waterTemperature: waterTemperatureValue,
      catches: catches,
      photos: List<RecordPhoto>.unmodifiable(photos),
      memo: memoController.text.trim().isEmpty
          ? null
          : memoController.text.trim(),
    );

    final validationMessage = FishingRecordValidator.validate(record);
    if (validationMessage != null) {
      showMessage(validationMessage);
      return;
    }

    if (isEditMode) {
      await RecordMutationService.instance.updateRecord(
        record,
        expectedSnapshot: _editSnapshot!,
      );
    } else {
      await RecordMutationService.instance.addRecord(record);
    }

    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          AuthSessionRepository.instance.isPaid
              ? isEditMode
                    ? '기록을 기기에 수정했습니다. 사진은 이 기기에만 보관되며 기록 동기화 상태는 업로드 대기열에서 확인할 수 있습니다.'
                    : '기록을 기기에 저장했습니다. 사진은 이 기기에만 보관되며 기록 동기화 상태는 업로드 대기열에서 확인할 수 있습니다.'
              : isEditMode
              ? '출조 기록이 수정되었습니다.'
              : '출조 기록이 저장되었습니다.',
        ),
      ),
    );

    Navigator.of(context).pop(true);
  }

  void showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> pickPhoto() async {
    if (isPickingPhoto || _isSaving || _isPreparingEdit) {
      return;
    }
    if (photos.length >= FishingRecordValidator.maxPhotoCount) {
      showMessage(
        '사진은 최대 ${FishingRecordValidator.maxPhotoCount}장까지 첨부할 수 있습니다.',
      );
      return;
    }

    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('앨범에서 선택'),
              onTap: () => Navigator.of(context).pop(ImageSource.gallery),
            ),
            if (kIsWeb ||
                defaultTargetPlatform == TargetPlatform.android ||
                defaultTargetPlatform == TargetPlatform.iOS)
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('카메라로 촬영'),
                onTap: () => Navigator.of(context).pop(ImageSource.camera),
              ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) {
      return;
    }

    setState(() {
      isPickingPhoto = true;
    });

    try {
      final pickedImage = await imagePicker.pickImage(source: source);
      if (pickedImage == null) {
        return;
      }

      final byteLength = await pickedImage.length();
      if (byteLength < 1) {
        showMessage('비어 있는 사진 파일은 첨부할 수 없습니다.');
        return;
      }
      if (byteLength > FishingRecordValidator.maxPhotoBytes) {
        showMessage('사진은 10 MiB 이하 파일만 첨부할 수 있습니다.');
        return;
      }

      final bytes = await pickedImage.readAsBytes();
      final contentType = detectRecordPhotoContentType(bytes);
      if (contentType == null ||
          !FishingRecordValidator.allowedPhotoContentTypes.contains(
            contentType,
          )) {
        showMessage('JPEG, PNG, WebP 형식의 사진만 첨부할 수 있습니다.');
        return;
      }

      final photoId = _newPhotoId();
      final stored = await photoFileStore.persistSelection(
        ownerId: AuthSessionRepository.instance.dataOwnerKey,
        recordId: recordId,
        photoId: photoId,
        bytes: bytes,
        contentType: contentType,
      );
      if (!mounted) {
        return;
      }

      setState(() {
        photos.add(
          RecordPhoto(
            id: photoId,
            localPath: stored.path,
            contentType: stored.contentType,
            sizeBytes: stored.byteLength,
            checksum: stored.checksum,
          ),
        );
      });
      _handleDraftChange();
    } on RecordPhotoTooLargeException {
      if (mounted) {
        showMessage('사진은 10 MiB 이하 파일만 첨부할 수 있습니다.');
      }
    } on RecordPhotoFileStoreException {
      if (mounted) {
        showMessage('사진을 앱 저장소에 복사하지 못했습니다. 다시 시도해 주세요.');
      }
    } on Object {
      if (mounted) {
        showMessage('사진을 불러오지 못했습니다. 다시 선택해 주세요.');
      }
    } finally {
      if (mounted) {
        setState(() {
          isPickingPhoto = false;
        });
      }
    }
  }

  String _newPhotoId() {
    String candidate;
    do {
      candidate =
          'photo_${DateTime.now().microsecondsSinceEpoch}_${nextPhotoSequence++}';
    } while (photos.any((photo) => photo.id == candidate));
    return candidate;
  }

  void removePhoto(int index) {
    if (_isSaving || _isPreparingEdit) return;
    setState(() {
      photos.removeAt(index);
    });
    _handleDraftChange();
  }

  void addCatchItem() {
    if (_isSaving || _isPreparingEdit) return;
    if (catchItems.length >= FishingRecordValidator.maxCatchCount) {
      showMessage(
        '조과는 최대 ${FishingRecordValidator.maxCatchCount}개까지 입력할 수 있습니다.',
      );
      return;
    }
    setState(() {
      catchItems.add(_CatchItemInput()..addListener(_handleDraftChange));
    });
    _handleDraftChange();
  }

  void removeCatchItem(int index) {
    if (_isSaving || _isPreparingEdit) return;
    if (catchItems.length == 1) {
      showMessage('조과 입력칸은 최소 1개가 필요합니다.');
      return;
    }

    setState(() {
      catchItems[index].dispose();
      catchItems.removeAt(index);
    });
    _handleDraftChange();
  }

  String formatDateTime(DateTime dateTime) {
    String twoDigits(int value) => value.toString().padLeft(2, '0');

    return '${dateTime.year}.${twoDigits(dateTime.month)}.${twoDigits(dateTime.day)} '
        '${twoDigits(dateTime.hour)}:${twoDigits(dateTime.minute)}';
  }

  Future<void> pickStartDateTime() async {
    if (_isSaving || _isPreparingEdit) return;
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: startAt,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
    );

    if (pickedDate == null || !mounted) return;

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(startAt),
    );

    if (pickedTime == null || !mounted) return;

    setState(() {
      startAt = DateTime(
        pickedDate.year,
        pickedDate.month,
        pickedDate.day,
        pickedTime.hour,
        pickedTime.minute,
      );
    });
    _handleDraftChange();
  }

  Future<void> pickEndDateTime() async {
    if (_isSaving || _isPreparingEdit) return;
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: endAt,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
    );

    if (pickedDate == null || !mounted) return;

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(endAt),
    );

    if (pickedTime == null || !mounted) return;

    setState(() {
      endAt = DateTime(
        pickedDate.year,
        pickedDate.month,
        pickedDate.day,
        pickedTime.hour,
        pickedTime.minute,
      );
    });
    _handleDraftChange();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<bool>(
      canPop:
          !_hasUnsavedChanges &&
          !_isSaving &&
          !_isPreparingEdit &&
          !isPickingPhoto,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_requestExit());
      },
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: _requestExit),
          title: Text(isEditMode ? '출조 기록 수정' : '출조 기록 작성'),
        ),
        body: SafeArea(
          child: AbsorbPointer(
            absorbing: _isSaving || _isPreparingEdit,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_isPreparingEdit || _isSaving)
                  const LinearProgressIndicator(),
                if (isEditMode &&
                    (_editConflictReason != null || _editLoadError != null))
                  Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_editNoticeMessage),
                          if (_editConflictReason !=
                              RecordEditConflictReason.sessionChanged)
                            TextButton(
                              onPressed: _isPreparingEdit || _isSaving
                                  ? null
                                  : _reloadLatestRecord,
                              child: const Text('최신 기록 불러오기'),
                            ),
                        ],
                      ),
                    ),
                  ),
                if (widget.initialLocation != null ||
                    widget.initialFishName != null) ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Icon(
                            Icons.check_circle_outline,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              widget.initialFishName != null
                                  ? '도감에서 선택한 어종을 자동 입력했습니다.'
                                  : '지도에서 가져온 정보를 자동 입력했습니다.',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                _SectionTitle(title: '필수 정보'),
                const SizedBox(height: 12),

                TextField(
                  controller: locationController,
                  maxLength: FishingRecordValidator.maxLocationLength,
                  decoration: const InputDecoration(
                    labelText: '위치 *',
                    hintText: '예: 부산 영도구 동삼동',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),

                _DateTimeField(
                  label: '시작 시간 *',
                  value: formatDateTime(startAt),
                  onTap: pickStartDateTime,
                ),
                const SizedBox(height: 12),

                _DateTimeField(
                  label: '종료 시간 *',
                  value: formatDateTime(endAt),
                  onTap: pickEndDateTime,
                ),
                const SizedBox(height: 16),

                Text('낚시 장르 *', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),

                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: genres.map((genre) {
                    return ChoiceChip(
                      label: Text(genre),
                      selected: selectedGenre == genre,
                      onSelected: (_) {
                        setState(() {
                          selectedGenre = genre;

                          if (genre != '기타') {
                            customGenreController.clear();
                          }
                        });
                        _handleDraftChange();
                      },
                    );
                  }).toList(),
                ),

                if (selectedGenre == '기타') ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: customGenreController,
                    maxLength: FishingRecordValidator.maxGenreNameLength,
                    decoration: const InputDecoration(
                      labelText: '기타 낚시 장르 *',
                      hintText: '예: 에깅, 플라이낚시, 문어낚시',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],

                const SizedBox(height: 24),

                _SectionTitle(title: '외부 데이터'),
                const SizedBox(height: 4),
                Text(
                  '조회에 실패한 값은 직접 입력하세요.',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Colors.grey.shade600),
                ),
                const SizedBox(height: 12),

                TextField(
                  controller: tideController,
                  maxLength: FishingRecordValidator.maxTideLength,
                  decoration: const InputDecoration(
                    labelText: '물때 *',
                    hintText: '예: 7물',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),

                TextField(
                  controller: weatherController,
                  maxLength: FishingRecordValidator.maxWeatherLength,
                  decoration: const InputDecoration(
                    labelText: '날씨 *',
                    hintText: '예: 흐림',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),

                TextField(
                  controller: airTemperatureController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '기온 *',
                    hintText: '예: 18',
                    suffixText: '℃',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),

                TextField(
                  controller: waterTemperatureController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '수온 *',
                    hintText: '예: 16.2',
                    suffixText: '℃',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 24),

                _SectionTitle(title: '선택 정보'),
                const SizedBox(height: 12),

                Text('조과', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),

                ...catchItems.asMap().entries.map((entry) {
                  final index = entry.key;
                  final item = entry.value;

                  return _CatchItemCard(
                    index: index,
                    item: item,
                    onRemove: () => removeCatchItem(index),
                  );
                }),

                OutlinedButton.icon(
                  onPressed: addCatchItem,
                  icon: const Icon(Icons.add),
                  label: const Text('조과 추가'),
                ),

                const SizedBox(height: 16),

                Text('사진', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),

                OutlinedButton.icon(
                  onPressed:
                      isPickingPhoto ||
                          photos.length >= FishingRecordValidator.maxPhotoCount
                      ? null
                      : pickPhoto,
                  icon: isPickingPhoto
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add_photo_alternate_outlined),
                  label: Text(
                    isPickingPhoto
                        ? '사진 저장 중'
                        : '사진 추가 (${photos.length}/${FishingRecordValidator.maxPhotoCount})',
                  ),
                ),
                const SizedBox(height: 8),

                if (photos.isEmpty)
                  Text(
                    '첨부된 사진이 없습니다.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey.shade600,
                    ),
                  )
                else
                  SizedBox(
                    height: 96,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: photos.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        final photo = photos[index];

                        return Stack(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: _PhotoPreview(photo: photo),
                            ),
                            Positioned(
                              top: 4,
                              right: 4,
                              child: InkWell(
                                onTap: () => removePhoto(index),
                                borderRadius: BorderRadius.circular(16),
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.6),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.close,
                                    color: Colors.white,
                                    size: 16,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),

                const SizedBox(height: 16),

                TextField(
                  controller: memoController,
                  maxLength: FishingRecordValidator.maxMemoLength,
                  minLines: 3,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: '메모',
                    hintText: '출조 상황, 입질, 채비 등을 기록하세요.',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 24),

                FilledButton(
                  onPressed: isPickingPhoto || _isSaving || _isPreparingEdit
                      ? null
                      : saveRecord,
                  child: Text(_isSaving ? '저장 중…' : '저장'),
                ),
              ],
            ),
          ),
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

class _DateTimeField extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onTap;

  const _DateTimeField({
    required this.label,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          suffixIcon: const Icon(Icons.calendar_month_outlined),
        ),
        child: Text(value),
      ),
    );
  }
}

class _CatchItemInput {
  final speciesController = TextEditingController();
  final lengthController = TextEditingController();
  final weightController = TextEditingController();

  _CatchItemInput({CatchRecord? catchRecord}) {
    if (catchRecord == null) {
      return;
    }

    speciesController.text = catchRecord.speciesName;
    lengthController.text = catchRecord.lengthCm?.toString() ?? '';
    weightController.text = catchRecord.weightG?.toString() ?? '';
  }

  void addListener(VoidCallback listener) {
    speciesController.addListener(listener);
    lengthController.addListener(listener);
    weightController.addListener(listener);
  }

  void dispose() {
    speciesController.dispose();
    lengthController.dispose();
    weightController.dispose();
  }
}

class _CatchItemCard extends StatelessWidget {
  final int index;
  final _CatchItemInput item;
  final VoidCallback onRemove;

  const _CatchItemCard({
    required this.index,
    required this.item,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '조과 ${index + 1}',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: onRemove,
                  icon: const Icon(Icons.delete_outline),
                  tooltip: '조과 삭제',
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: item.speciesController,
              maxLength: FishingRecordValidator.maxSpeciesNameLength,
              decoration: const InputDecoration(
                labelText: '어종',
                hintText: '예: 광어',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: item.lengthController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '크기',
                hintText: '예: 45',
                suffixText: 'cm',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: item.weightController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '무게',
                hintText: '예: 1200',
                suffixText: 'g',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PhotoPreview extends StatelessWidget {
  final RecordPhoto photo;

  const _PhotoPreview({required this.photo});

  @override
  Widget build(BuildContext context) {
    final localPath = photo.localPath?.trim();
    if (!kIsWeb && localPath != null && localPath.isNotEmpty) {
      return Image.file(
        File(localPath),
        width: 96,
        height: 96,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => _placeholder(
          context,
          icon: Icons.broken_image_outlined,
          label: '사진 오류',
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
              width: 96,
              height: 96,
              fit: BoxFit.cover,
            );
          }
          return _placeholder(
            context,
            icon: snapshot.hasError
                ? Icons.broken_image_outlined
                : Icons.image_outlined,
            label: snapshot.hasError ? '사진 오류' : null,
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
      width: 96,
      height: 96,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.all(6),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon),
          if (label != null) ...[
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ],
      ),
    );
  }
}
