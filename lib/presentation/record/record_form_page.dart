import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/theme/app_theme.dart';
import '../../core/validation/fishing_record_validator.dart';
import '../../data/history/historical_conditions.dart';
import '../../data/maps/map_location.dart';
import '../../data/models/external_data.dart';
import '../../data/models/fishing_record.dart';
import '../../data/models/record_cache_policy.dart';
import '../../data/models/record_edit_snapshot.dart';
import '../../data/photos/record_photo_file_store.dart';
import '../../data/photos/record_photo_file_store_utils.dart';
import '../../data/repositories/auth_session_repository.dart';
import '../../data/repositories/fishing_record_repository.dart';
import '../../data/services/network_status_service.dart';
import '../../data/services/record_location_conditions_service.dart';
import '../../data/services/record_mutation_service.dart';
import '../../data/services/record_photo_cleanup_service.dart';
import '../../data/services/record_sync_service.dart';
import '../../data/tides/tide_models.dart';
import '../../data/tides/tide_name.dart';
import '../../data/tides/tide_station_catalog.dart';
import '../../data/water_temperature/water_temperature_models.dart';
import '../auth/auth_access_guard.dart';
import '../common/top_card_notification.dart';
import 'record_location_search_page.dart';
import 'record_photo_thumbnail.dart';
import 'record_photo_viewer.dart';

class RecordFormPage extends StatefulWidget {
  final FishingRecord? editingRecord;

  final DateTime? initialStartAt;
  final String? initialLocation;
  final double? initialLatitude;
  final double? initialLongitude;
  final String? initialTide;
  final String? initialWeather;
  final double? initialAirTemperature;
  final double? initialWaterTemperature;
  final String? initialFishName;
  final ExternalData? initialExternalData;
  final TideRecordReference? initialTideReference;
  final bool allowAutomaticTide;
  final WaterTemperatureObservation? initialWaterTemperatureObservation;
  final HistoricalWeatherObservation? initialHistoricalWeather;
  final HistoricalWaterTemperatureObservation?
  initialHistoricalWaterTemperature;
  final bool allowAutomaticWaterTemperature;
  final RecordLocationConditionsService locationConditionsService;

  const RecordFormPage({
    super.key,
    this.editingRecord,
    this.initialStartAt,
    this.initialLocation,
    this.initialLatitude,
    this.initialLongitude,
    this.initialTide,
    this.initialWeather,
    this.initialAirTemperature,
    this.initialWaterTemperature,
    this.initialFishName,
    this.initialExternalData,
    this.initialTideReference,
    this.allowAutomaticTide = true,
    this.initialWaterTemperatureObservation,
    this.initialHistoricalWeather,
    this.initialHistoricalWaterTemperature,
    this.allowAutomaticWaterTemperature = true,
    this.locationConditionsService = RecordLocationConditionsService.instance,
  });

  @override
  State<RecordFormPage> createState() => _RecordFormPageState();
}

class _RecordFormPageState extends State<RecordFormPage> {
  bool get isEditMode => widget.editingRecord != null;

  final locationController = TextEditingController();
  final locationAliasController = TextEditingController();
  String _coordinateLocation = '';
  double? _sourceLatitude;
  double? _sourceLongitude;
  bool _isChoosingLocation = false;
  MapLocation? _searchedLocation;
  Object? _locationConditionsRequest;
  bool _loadingLocationConditions = false;
  bool _locationConditionsUnavailable = false;
  bool _applyingLocationConditions = false;
  final _locationAutoFields = <TextEditingController>{};

  // Coordinates belong to the place selected on the map or the loaded record.
  // Renaming a place cannot silently attach that place's old coordinates.
  bool get _matchesCoordinateLocation =>
      locationController.text.trim() == _coordinateLocation;
  double? get _latitude => _matchesCoordinateLocation ? _sourceLatitude : null;
  double? get _longitude =>
      _matchesCoordinateLocation ? _sourceLongitude : null;
  final tideController = TextEditingController();
  final weatherController = TextEditingController();
  final airTemperatureController = TextEditingController();
  final waterTemperatureController = TextEditingController();
  final memoController = TextEditingController();
  final customGenreController = TextEditingController();

  final imagePicker = ImagePicker();
  final photos = <RecordPhoto>[];
  RecordPhotoDraftLease? _photoDraft;
  VoidCallback? _releaseCacheRecord;
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
  bool _automaticWeather = false;
  bool _automaticAirTemperature = false;
  bool _automaticHistoricalWeather = false;
  bool _automaticHistoricalAirTemperature = false;
  bool _weatherManuallyEdited = false;
  bool _airTemperatureManuallyEdited = false;
  bool _reconcilingWeather = false;
  bool _tideManuallyEdited = false;
  bool _reconcilingTide = false;
  bool _automaticWaterTemperature = false;
  bool _automaticHistoricalWaterTemperature = false;
  bool _waterTemperatureManuallyEdited = false;
  bool _reconcilingWaterTemperature = false;
  TideName? _calculatedTideName;
  ({TideDay day, String location, double? latitude, double? longitude})?
  _tideNameInput;
  VoidCallback? _stopRecordWatch;
  bool isPickingPhoto = false;
  bool _isChoosingPhotoSource = false;
  int nextPhotoSequence = 0;

  late DateTime startAt;
  late DateTime endAt;

  String? selectedGenre;

  final genres = const ['루어', '찌낚시', '선상', '원투', '기타'];

  @override
  void initState() {
    super.initState();

    startAt = widget.initialStartAt?.toLocal() ?? DateTime.now();
    endAt = startAt.add(const Duration(hours: 2));

    recordId =
        widget.editingRecord?.id ??
        DateTime.now().microsecondsSinceEpoch.toString();
    _editingOwnerKey = AuthSessionRepository.instance.dataOwnerKey;
    _editingSessionGeneration =
        AuthSessionRepository.instance.sessionGeneration;
    _releaseCacheRecord = RecordCachePolicy.instance.holdRecord(
      _editingOwnerKey,
      recordId,
    );

    locationController.text = widget.initialLocation ?? '';
    _coordinateLocation = locationController.text.trim();
    _sourceLatitude = widget.initialLatitude;
    _sourceLongitude = widget.initialLongitude;
    tideController.text = widget.initialTide ?? '';
    _tideManuallyEdited = widget.initialTide != null;
    weatherController.text = widget.initialWeather ?? '';
    _weatherManuallyEdited = widget.initialWeather != null;
    airTemperatureController.text =
        widget.initialAirTemperature?.toString() ?? '';
    _airTemperatureManuallyEdited = widget.initialAirTemperature != null;
    waterTemperatureController.text =
        widget.initialWaterTemperature?.toString() ?? '';
    _waterTemperatureManuallyEdited = widget.initialWaterTemperature != null;

    _reconcileHistoricalWeatherPrefill();
    final forecast = widget.initialExternalData;
    if (!isEditMode && forecast != null && _forecastApplies) {
      if (widget.initialWeather == null &&
          !_automaticHistoricalWeather &&
          forecast.weather != null) {
        weatherController.text = forecast.weather!;
        _automaticWeather = true;
      }
      if (widget.initialAirTemperature == null &&
          !_automaticHistoricalAirTemperature &&
          forecast.airTemperature != null) {
        airTemperatureController.text = forecast.airTemperature.toString();
        _automaticAirTemperature = true;
      }
    }

    if (widget.initialFishName != null && catchItems.isNotEmpty) {
      catchItems.first.speciesController.text = widget.initialFishName!;
    }

    final editingRecord = widget.editingRecord;

    if (editingRecord != null) {
      _initializeEditingRecord(editingRecord);
      FishingRecordRepository.instance.addListener(_handleEditSourceChange);
      _stopRecordWatch = RecordSyncService.instance.observeRecord(recordId);
      _isPreparingEdit = true;
      unawaited(_prepareEditingRecord(editingRecord));
    }
    AuthSessionRepository.instance.addListener(_handleEditSourceChange);
    _photoDraft = RecordPhotoCleanupService.instance.createDraft(
      ownerKey: _editingOwnerKey,
      paths: _photoPaths,
    );
    _reconcileTidePrefill();
    _reconcileWaterTemperaturePrefill();
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
    locationAliasController,
    tideController,
    weatherController,
    airTemperatureController,
    waterTemperatureController,
    memoController,
    customGenreController,
  ];

  Iterable<String> get _photoPaths =>
      photos.map((photo) => photo.localPath).whereType<String>();

  String _captureDraft() => jsonEncode([
    for (final controller in _textControllers) controller.text,
    _latitude?.toString(),
    _longitude?.toString(),
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
    if (!mounted ||
        _draftBaseline == null ||
        _applyingLocationConditions ||
        _reconcilingWeather ||
        _reconcilingTide ||
        _reconcilingWaterTemperature) {
      return;
    }
    var conditionsChanged = false;
    if (_searchedLocation == null) {
      final clearedForecast = _reconcileWeatherPrefill();
      final historicalWeatherChanged = _reconcileHistoricalWeatherPrefill();
      final tideNameChanged = _reconcileTidePrefill();
      final waterTemperatureChanged = _reconcileWaterTemperaturePrefill();
      conditionsChanged =
          clearedForecast ||
          historicalWeatherChanged ||
          tideNameChanged ||
          waterTemperatureChanged;
    } else if (!_matchesCoordinateLocation &&
        _locationConditionsRequest != null) {
      _resetLocationConditions();
      conditionsChanged = true;
    }
    final changed = _captureDraft() != _draftBaseline;
    if (changed != _hasUnsavedChanges || conditionsChanged) {
      setState(() {
        _hasUnsavedChanges = changed;
      });
    }
  }

  bool get _forecastApplies =>
      widget.initialExternalData?.appliesToRecord(
        startAt: startAt,
        locationName: locationController.text,
        latitude: _latitude,
        longitude: _longitude,
      ) ??
      false;

  bool _reconcileTidePrefill() {
    final input = (
      day: TideDay.fromInstant(startAt),
      location: locationController.text.trim(),
      latitude: _latitude,
      longitude: _longitude,
    );
    if (input == _tideNameInput) return false;
    _tideNameInput = input;
    _calculatedTideName = null;
    final latitude = input.latitude;
    final longitude = input.longitude;
    if (widget.allowAutomaticTide &&
        input.location.isNotEmpty &&
        input.location.length <= FishingRecordValidator.maxLocationLength &&
        latitude != null &&
        longitude != null &&
        latitude.isFinite &&
        longitude.isFinite &&
        latitude >= -90 &&
        latitude <= 90 &&
        longitude >= -180 &&
        longitude <= 180) {
      final original = widget.initialTideReference;
      final sameCoordinates =
          original?.location.latitude == latitude &&
          original?.location.longitude == longitude;
      // A changed name alone must not reuse the map's old coordinates.
      final renamedOriginal =
          original != null &&
          sameCoordinates &&
          original.location.name != input.location;
      if (!renamedOriginal) {
        _calculatedTideName = original != null && sameCoordinates
            ? TideName.calculate(
                day: input.day,
                station: original.forecast.station,
              )
            : _nearbyTideName(
                MapLocation(
                  name: input.location,
                  latitude: latitude,
                  longitude: longitude,
                ),
                input.day,
              );
      }
    }

    if (!isEditMode && !_tideManuallyEdited) {
      _reconcilingTide = true;
      try {
        tideController.text = _calculatedTideName?.label ?? '';
      } finally {
        _reconcilingTide = false;
      }
    }
    return true;
  }

  TideName? _nearbyTideName(MapLocation location, TideDay day) {
    final stations = TideStationCatalog().nearby(location, limit: 1);
    return stations.isEmpty
        ? null
        : TideName.calculate(day: day, station: stations.first);
  }

  bool _reconcileWeatherPrefill() {
    if (isEditMode ||
        _reconcilingWeather ||
        (!_automaticWeather && !_automaticAirTemperature) ||
        _forecastApplies) {
      return false;
    }
    _reconcilingWeather = true;
    try {
      if (_automaticWeather) {
        _automaticWeather = false;
        weatherController.clear();
      }
      if (_automaticAirTemperature) {
        _automaticAirTemperature = false;
        airTemperatureController.clear();
      }
    } finally {
      _reconcilingWeather = false;
    }
    return true;
  }

  bool _reconcileHistoricalWeatherPrefill() {
    if (isEditMode || _reconcilingWeather) return false;
    final observation = widget.initialHistoricalWeather;
    final applies =
        observation?.appliesToRecord(
          startAt: startAt,
          locationName: locationController.text,
          latitude: _latitude,
          longitude: _longitude,
        ) ??
        false;
    final weatherApplies =
        applies && observation!.weather?.trim().isNotEmpty == true;
    final temperature = observation?.airTemperature;
    final airTemperatureApplies =
        applies &&
        temperature != null &&
        temperature.isFinite &&
        temperature.abs() < 100;
    var changed = false;
    _reconcilingWeather = true;
    try {
      if (!_weatherManuallyEdited &&
          weatherApplies != _automaticHistoricalWeather) {
        _automaticHistoricalWeather = weatherApplies;
        _automaticWeather = false;
        weatherController.text = weatherApplies ? observation.weather! : '';
        changed = true;
      }
      if (!_airTemperatureManuallyEdited &&
          airTemperatureApplies != _automaticHistoricalAirTemperature) {
        _automaticHistoricalAirTemperature = airTemperatureApplies;
        _automaticAirTemperature = false;
        airTemperatureController.text = airTemperatureApplies
            ? temperature.toString()
            : '';
        changed = true;
      }
    } finally {
      _reconcilingWeather = false;
    }
    return changed;
  }

  bool _reconcileWaterTemperaturePrefill() {
    if (isEditMode ||
        _waterTemperatureManuallyEdited ||
        _reconcilingWaterTemperature) {
      return false;
    }
    final historical = widget.initialHistoricalWaterTemperature;
    final historicalApplies =
        widget.allowAutomaticWaterTemperature &&
        (historical?.appliesToRecord(
              startAt: startAt,
              locationName: locationController.text,
              latitude: _latitude,
              longitude: _longitude,
            ) ??
            false);
    final observation = widget.initialWaterTemperatureObservation;
    final applies =
        historicalApplies ||
        (widget.allowAutomaticWaterTemperature &&
            (observation?.appliesToRecord(
                  startAt: startAt,
                  locationName: locationController.text,
                  latitude: _latitude,
                  longitude: _longitude,
                ) ??
                false));
    if (applies == _automaticWaterTemperature &&
        historicalApplies == _automaticHistoricalWaterTemperature) {
      return false;
    }

    _reconcilingWaterTemperature = true;
    try {
      _automaticWaterTemperature = applies;
      _automaticHistoricalWaterTemperature = historicalApplies;
      waterTemperatureController.text = applies
          ? (historicalApplies
                    ? historical!.temperatureCelsius
                    : observation!.temperatureCelsius)
                .toString()
          : '';
    } finally {
      _reconcilingWaterTemperature = false;
    }
    return true;
  }

  bool get _canSearchLocation =>
      !_isChoosingLocation &&
      !_isSaving &&
      !_isPreparingEdit &&
      !isPickingPhoto &&
      !_isChoosingPhotoSource &&
      !_isConfirmingDiscard &&
      !_isConfirmingReload &&
      _isEditingSessionCurrent &&
      _editConflictReason == null &&
      _editLoadError == null;

  Future<void> _searchLocation() async {
    if (!_canSearchLocation) return;
    FocusScope.of(context).unfocus();
    final name = locationController.text.trim();
    final validCoordinates =
        FishingRecordValidator.validateCoordinates(_latitude, _longitude) ==
        null;
    final initialLocation =
        name.isNotEmpty &&
            name.length <= FishingRecordValidator.maxLocationLength
        ? MapLocation(
            name: name,
            latitude: validCoordinates ? _latitude : null,
            longitude: validCoordinates ? _longitude : null,
          )
        : null;
    setState(() => _isChoosingLocation = true);
    try {
      final selected = await Navigator.of(context).push<MapLocation>(
        MaterialPageRoute(
          builder: (_) =>
              RecordLocationSearchPage(initialLocation: initialLocation),
        ),
      );
      if (!mounted || selected == null) return;
      if (!_isEditingSessionCurrent ||
          _editConflictReason != null ||
          _editLoadError != null ||
          _isSaving ||
          _isPreparingEdit ||
          isPickingPhoto) {
        showMessage('기록 상태가 변경되었습니다. 기록 정보를 확인한 뒤 위치를 다시 선택해 주세요.');
        return;
      }
      if (!selected.hasCoordinates) {
        showMessage('좌표가 있는 검색 결과를 선택해 주세요.');
        return;
      }
      final sameLocation =
          selected.name == locationController.text.trim() &&
          selected.latitude == _latitude &&
          selected.longitude == _longitude;
      if (sameLocation &&
          _locationConditionsRequest != null &&
          !_locationConditionsUnavailable) {
        return;
      }
      if (_searchedLocation == null && !isEditMode) {
        _locationAutoFields.addAll([
          if (_automaticWeather || _automaticHistoricalWeather)
            weatherController,
          if (_automaticAirTemperature || _automaticHistoricalAirTemperature)
            airTemperatureController,
          if (_automaticWaterTemperature) waterTemperatureController,
          if (!_tideManuallyEdited && _calculatedTideName != null)
            tideController,
        ]);
      }
      _resetLocationConditions(clearValues: !sameLocation);
      _searchedLocation = selected;
      _coordinateLocation = selected.name;
      _sourceLatitude = selected.latitude;
      _sourceLongitude = selected.longitude;
      locationController.value = TextEditingValue(
        text: selected.name,
        selection: TextSelection.collapsed(offset: selected.name.length),
      );
      // Coordinates can change even when the visible name stays the same.
      _handleDraftChange();
      unawaited(_loadLocationConditions(selected));
    } on Object {
      if (mounted) {
        showMessage(
          '위치 검색을 열지 못했습니다. 다시 시도하거나 위치를 직접 입력해 주세요.',
          type: TopCardNotificationType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _isChoosingLocation = false);
    }
  }

  void _resetLocationConditions({bool clearValues = true}) {
    _locationConditionsRequest = null;
    _loadingLocationConditions = false;
    _locationConditionsUnavailable = false;
    if (clearValues) _clearLocationAutoFields(_locationAutoFields.toList());
  }

  void _clearLocationAutoFields(Iterable<TextEditingController> fields) {
    _applyingLocationConditions = true;
    try {
      for (final field in fields) {
        if (_locationAutoFields.remove(field)) field.clear();
      }
    } finally {
      _applyingLocationConditions = false;
    }
  }

  void _applyLocationConditions(Map<TextEditingController, String?> values) {
    _applyingLocationConditions = true;
    try {
      for (final entry in values.entries) {
        final value = entry.value;
        if (value == null) continue;
        _locationAutoFields.add(entry.key);
        if (entry.key.text != value) entry.key.text = value;
      }
    } finally {
      _applyingLocationConditions = false;
    }
    _handleDraftChange();
  }

  Future<void> _loadLocationConditions(MapLocation location) async {
    if (!_isEditingSessionCurrent || _editConflictReason != null) return;
    final needsWeather =
        !_weatherManuallyEdited || !_airTemperatureManuallyEdited;
    final needsMarine =
        !_tideManuallyEdited || !_waterTemperatureManuallyEdited;
    if (!needsWeather && !needsMarine) return;

    final request = Object();
    final requestedAt = startAt;
    final offline = NetworkStatusService.instance.isDisconnected;
    setState(() {
      _locationConditionsRequest = request;
      _locationConditionsUnavailable = offline;
      _loadingLocationConditions = !offline;
    });
    if (offline) return;

    bool isCurrent() =>
        mounted &&
        identical(_locationConditionsRequest, request) &&
        _matchesCoordinateLocation &&
        startAt == requestedAt &&
        _isEditingSessionCurrent &&
        _editConflictReason == null;

    final results = await Future.wait([
      if (needsWeather) _loadLocationWeather(location, requestedAt, isCurrent),
      if (needsMarine)
        _loadLocationMarineData(location, requestedAt, isCurrent),
    ]);
    if (!isCurrent()) return;
    setState(() {
      _loadingLocationConditions = false;
      _locationConditionsUnavailable = results.contains(false);
    });
  }

  Future<bool> _loadLocationWeather(
    MapLocation location,
    DateTime requestedAt,
    bool Function() isCurrent,
  ) async {
    try {
      final weather = await widget.locationConditionsService.fetchWeather(
        location,
        requestedAt,
      );
      if (!isCurrent()) return false;
      _applyLocationConditions({
        if (!_weatherManuallyEdited) weatherController: weather?.weather,
        if (!_airTemperatureManuallyEdited)
          airTemperatureController: weather?.airTemperature?.toString(),
      });
      return weatherController.text.trim().isNotEmpty &&
          airTemperatureController.text.trim().isNotEmpty;
    } on Object {
      return false;
    }
  }

  Future<bool> _loadLocationMarineData(
    MapLocation location,
    DateTime requestedAt,
    bool Function() isCurrent,
  ) async {
    try {
      final service = widget.locationConditionsService;
      final marine = await service.isMarine(location);
      if (!isCurrent()) return false;
      if (!marine) {
        _clearLocationAutoFields([tideController, waterTemperatureController]);
        _handleDraftChange();
        return true;
      }
      if (!_tideManuallyEdited) {
        final tide = _nearbyTideName(
          location,
          TideDay.fromInstant(requestedAt),
        );
        _applyLocationConditions({tideController: tide?.label});
      }
      if (_waterTemperatureManuallyEdited) return true;
      final water = await service.fetchMarineWaterTemperature(
        location,
        requestedAt,
      );
      if (!isCurrent()) return false;
      if (!_waterTemperatureManuallyEdited) {
        _applyLocationConditions({
          waterTemperatureController: water?.toString(),
        });
      }
      return _waterTemperatureManuallyEdited || water != null;
    } on Object {
      return false;
    }
  }

  Future<void> _requestExit() async {
    if (_isSaving) {
      showMessage(
        '기록을 저장하는 중입니다. 잠시만 기다려 주세요.',
        type: TopCardNotificationType.info,
      );
      return;
    }
    if (_isPreparingEdit || isPickingPhoto || _isChoosingLocation) {
      showMessage(
        '기록 정보를 처리하는 중입니다. 잠시만 기다려 주세요.',
        type: TopCardNotificationType.info,
      );
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
        builder: (context) {
          final theme = Theme.of(context);
          return AlertDialog(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            insetPadding: const EdgeInsets.all(20),
            scrollable: true,
            titleTextStyle: theme.textTheme.titleMedium?.copyWith(
              color: AppTheme.ink,
              fontWeight: FontWeight.w700,
            ),
            title: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppTheme.primaryContainer,
                    borderRadius: BorderRadius.all(Radius.circular(14)),
                  ),
                  child: SizedBox.square(
                    dimension: 48,
                    child: Icon(
                      Icons.edit_note_rounded,
                      color: AppTheme.primary,
                      size: 26,
                    ),
                  ),
                ),
                SizedBox(height: 16),
                Text('저장하지 않고 나가시겠습니까?'),
              ],
            ),
            contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            contentTextStyle: theme.textTheme.bodyMedium?.copyWith(
              color: AppTheme.muted,
            ),
            content: const Text('작성한 내용이 저장되지 않습니다.'),
            actionsPadding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
            actionsOverflowButtonSpacing: 8,
            actions: [
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.errorContainer,
                  foregroundColor: theme.colorScheme.onErrorContainer,
                  minimumSize: const Size(0, 48),
                ),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('나가기'),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 48),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('계속 작성'),
              ),
            ],
          );
        },
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
      setState(() {
        _editConflictReason = reason;
        _resetLocationConditions(clearValues: false);
      });
    }
  }

  Future<void> _reloadLatestRecord() async {
    if (_isPreparingEdit ||
        _isSaving ||
        _isChoosingLocation ||
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
      showMessage(
        '기록을 불러오지 못했습니다. 입력한 내용은 유지됩니다. 다시 시도해 주세요.',
        type: TopCardNotificationType.error,
      );
    } finally {
      if (mounted) setState(() => _isPreparingEdit = false);
    }
  }

  void _initializeEditingRecord(FishingRecord record) {
    _resetLocationConditions(clearValues: false);
    _locationAutoFields.clear();
    _searchedLocation = null;
    _coordinateLocation = record.location.trim();
    _sourceLatitude = record.latitude;
    _sourceLongitude = record.longitude;
    locationController.text = record.location;
    locationAliasController.text = record.locationAlias ?? '';
    tideController.text = record.tide ?? '';
    weatherController.text = record.weather ?? '';
    airTemperatureController.text = record.airTemperature?.toString() ?? '';
    waterTemperatureController.text = record.waterTemperature?.toString() ?? '';
    _tideManuallyEdited = tideController.text.isNotEmpty;
    _weatherManuallyEdited = weatherController.text.isNotEmpty;
    _airTemperatureManuallyEdited = airTemperatureController.text.isNotEmpty;
    _waterTemperatureManuallyEdited =
        waterTemperatureController.text.isNotEmpty;
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
    _photoDraft?.updatePaths(_photoPaths);
    _reconcileTidePrefill();
  }

  @override
  void dispose() {
    _releaseCacheRecord?.call();
    _stopRecordWatch?.call();
    final photoDraft = _photoDraft;
    if (photoDraft != null) unawaited(photoDraft.release());
    AuthSessionRepository.instance.removeListener(_handleEditSourceChange);
    if (isEditMode) {
      FishingRecordRepository.instance.removeListener(_handleEditSourceChange);
    }
    locationController.dispose();
    locationAliasController.dispose();
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
        _isChoosingLocation ||
        isPickingPhoto ||
        _isConfirmingDiscard ||
        _isConfirmingReload) {
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _isSaving = true);
    try {
      if (!_isEditingSessionCurrent) {
        throw const RecordEditConflictException(
          RecordEditConflictReason.sessionChanged,
        );
      }
      if (isEditMode) {
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
      showMessage(
        '기록을 저장하지 못했습니다. 입력한 내용은 유지됩니다. 다시 시도해 주세요.',
        type: TopCardNotificationType.error,
      );
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
    if (!_isEditingSessionCurrent) {
      throw const RecordEditConflictException(
        RecordEditConflictReason.sessionChanged,
      );
    }

    if (_searchedLocation == null) {
      _reconcileWeatherPrefill();
      _reconcileHistoricalWeatherPrefill();
      _reconcileWaterTemperaturePrefill();
    } else if (_loadingLocationConditions &&
        (weatherController.text.trim().isEmpty ||
            airTemperatureController.text.trim().isEmpty)) {
      showMessage('외부 정보를 불러오는 중입니다. 잠시 기다리거나 날씨와 기온을 직접 입력해 주세요.');
      return;
    }
    final location = locationController.text.trim();
    final locationAlias = locationAliasController.text.trim();
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

    final latitude = _latitude;
    final longitude = _longitude;
    final coordinateError = FishingRecordValidator.validateCoordinates(
      latitude,
      longitude,
    );
    if (coordinateError != null) {
      showMessage(coordinateError);
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

    final waterTemperatureValue = waterTemperature.isEmpty
        ? null
        : double.tryParse(waterTemperature);

    if (waterTemperature.isNotEmpty &&
        (waterTemperatureValue == null || !waterTemperatureValue.isFinite)) {
      showMessage('수온은 유한한 숫자로 입력하세요.');
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
      locationAlias: locationAlias.isEmpty ? null : locationAlias,
      latitude: latitude,
      longitude: longitude,
      startAt: startAt,
      endAt: endAt,
      genreName: genreName,
      tide: tide.isEmpty ? null : tide,
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

    TopCardNotification.show(
      context,
      AuthSessionRepository.instance.isPaid
          ? isEditMode
                ? '기록을 기기에 수정했습니다. 사진은 이 기기에만 보관되며 기록 동기화 상태는 업로드 대기열에서 확인할 수 있습니다.'
                : '기록을 기기에 저장했습니다. 사진은 이 기기에만 보관되며 기록 동기화 상태는 업로드 대기열에서 확인할 수 있습니다.'
          : isEditMode
          ? '출조 기록이 수정되었습니다.'
          : '출조 기록이 저장되었습니다.',
      type: TopCardNotificationType.success,
      persistAfterPop: true,
    );

    Navigator.of(context).pop(true);
  }

  void showMessage(
    String message, {
    TopCardNotificationType type = TopCardNotificationType.warning,
  }) {
    TopCardNotification.show(context, message, type: type);
  }

  Future<void> pickPhoto() async {
    if (isPickingPhoto ||
        _isChoosingLocation ||
        _isChoosingPhotoSource ||
        _isSaving ||
        _isPreparingEdit) {
      return;
    }
    if (!_isEditingSessionCurrent) {
      showMessage('로그인 계정이 변경되었습니다. 기록 작성 화면을 다시 열어 주세요.');
      return;
    }
    if (photos.length >= FishingRecordValidator.maxPhotoCount) {
      showMessage(
        '사진은 최대 ${FishingRecordValidator.maxPhotoCount}장까지 첨부할 수 있습니다.',
      );
      return;
    }
    _isChoosingPhotoSource = true;
    try {
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
      if (source == null || !mounted) return;
      if (!_isEditingSessionCurrent) {
        showMessage('로그인 계정이 변경되어 사진 첨부를 중단했습니다.');
        return;
      }
      setState(() {
        isPickingPhoto = true;
      });
      final remaining = FishingRecordValidator.maxPhotoCount - photos.length;
      if (remaining <= 0) return;
      final List<XFile> picked;
      // image_picker requires a multi-selection limit of at least two.
      if (source == ImageSource.gallery && remaining > 1) {
        picked = await imagePicker.pickMultiImage(limit: remaining);
      } else {
        final single = await imagePicker.pickImage(source: source);
        picked = single == null ? <XFile>[] : [single];
      }
      if (!mounted || picked.isEmpty) return;
      var added = 0;
      var rejected = 0;
      var failed = 0;
      var overflow = 0;
      String? firstIssue;
      // Read, validate and copy one file at a time, never ten originals at once.
      for (var index = 0; index < picked.length; index++) {
        if (!mounted) return;
        if (!_isEditingSessionCurrent) {
          _photoDraft?.updatePaths(_photoPaths);
          showMessage('로그인 계정이 변경되어 사진 첨부를 중단했습니다.');
          return;
        }
        if (photos.length >= FishingRecordValidator.maxPhotoCount) {
          overflow = picked.length - index;
          break;
        }
        try {
          final selected = picked[index];
          final length = await selected.length();
          if (!mounted) return;
          if (length < 1 || length > FishingRecordValidator.maxPhotoBytes) {
            rejected++;
            firstIssue ??= length < 1
                ? '비어 있는 사진 파일은 첨부할 수 없습니다.'
                : '사진은 10 MiB 이하 파일만 첨부할 수 있습니다.';
            continue;
          }
          final bytes = await selected.readAsBytes();
          if (!mounted) return;
          if (!_isEditingSessionCurrent) {
            showMessage('로그인 계정이 변경되어 사진 첨부를 중단했습니다.');
            return;
          }
          final contentType = detectRecordPhotoContentType(bytes);
          if (contentType == null ||
              !FishingRecordValidator.allowedPhotoContentTypes.contains(
                contentType,
              )) {
            rejected++;
            firstIssue ??= 'JPEG, PNG, WebP 형식의 사진만 첨부할 수 있습니다.';
            continue;
          }
          final photoId = _newPhotoId();
          final stored = await _photoDraft!.persistSelection(
            recordId: recordId,
            photoId: photoId,
            bytes: bytes,
            contentType: contentType,
          );
          if (!mounted) return;
          if (!_isEditingSessionCurrent) {
            _photoDraft?.updatePaths(_photoPaths);
            showMessage('로그인 계정이 변경되어 사진 첨부를 중단했습니다.');
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
          _photoDraft?.updatePaths(_photoPaths);
          _handleDraftChange();
          added++;
        } on RecordPhotoTooLargeException {
          rejected++;
          firstIssue ??= '사진은 10 MiB 이하 파일만 첨부할 수 있습니다.';
        } on RecordPhotoFileStoreException {
          failed++;
          firstIssue ??= '사진을 앱 저장소에 복사하지 못했습니다. 다시 시도해 주세요.';
        } on Object {
          failed++;
          firstIssue ??= '사진을 불러오지 못했습니다. 다시 선택해 주세요.';
        }
      }
      if (!mounted) return;
      if (rejected + failed + overflow > 0) {
        if (picked.length == 1 && added == 0 && firstIssue != null) {
          showMessage(firstIssue);
        } else {
          final issues = [
            if (rejected > 0) '형식·크기 제한으로 제외 $rejected장',
            if (failed > 0) '불러오기·저장 실패 $failed장',
            if (overflow > 0) '10장 제한으로 제외 $overflow장',
          ];
          showMessage('사진 $added장을 추가했습니다. ${issues.join(' · ')}');
        }
      }
    } on Object {
      if (mounted) {
        showMessage(
          '사진을 불러오지 못했습니다. 다시 선택해 주세요.',
          type: TopCardNotificationType.error,
        );
      }
    } finally {
      _isChoosingPhotoSource = false;
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
    _photoDraft?.updatePaths(_photoPaths);
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

    final updatedStart = DateTime(
      pickedDate.year,
      pickedDate.month,
      pickedDate.day,
      pickedTime.hour,
      pickedTime.minute,
    );
    if (startAt.isAtSameMomentAs(updatedStart)) return;
    setState(() {
      startAt = updatedStart;
      if (_searchedLocation != null) _resetLocationConditions();
    });
    _handleDraftChange();
    final searched = _searchedLocation;
    if (searched != null && _matchesCoordinateLocation) {
      unawaited(_loadLocationConditions(searched));
    }
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
    final canSave =
        !isPickingPhoto &&
        !_isSaving &&
        !_isPreparingEdit &&
        !_isChoosingLocation;
    final theme = Theme.of(context);
    final String? conditionsNotice;
    if (_loadingLocationConditions) {
      conditionsNotice = '선택한 위치의 외부 정보를 불러오는 중입니다.';
    } else if (_locationConditionsUnavailable) {
      conditionsNotice = '일부 정보를 자동으로 입력하지 못했습니다. 필요한 값은 직접 입력해 주세요.';
    } else if (_locationAutoFields.isNotEmpty) {
      conditionsNotice = '선택한 위치의 외부 정보를 자동 입력했습니다.';
    } else {
      conditionsNotice = null;
    }
    return PopScope<bool>(
      canPop:
          !_hasUnsavedChanges &&
          !_isSaving &&
          !_isPreparingEdit &&
          !_isChoosingLocation &&
          !isPickingPhoto,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_requestExit());
      },
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: _requestExit),
          title: Text(isEditMode ? '출조 기록 수정' : '출조 기록 작성'),
          actions: [
            TextButton(
              key: const ValueKey('record-toolbar-save'),
              onPressed: canSave ? saveRecord : null,
              style: TextButton.styleFrom(foregroundColor: AppTheme.ink),
              child: const Text('저장'),
            ),
            const SizedBox(width: 4),
          ],
          bottom: _isPreparingEdit || _isSaving
              ? const PreferredSize(
                  preferredSize: Size.fromHeight(2),
                  child: LinearProgressIndicator(minHeight: 2),
                )
              : null,
        ),
        body: SafeArea(
          child: AbsorbPointer(
            absorbing: _isSaving || _isPreparingEdit || _isChoosingLocation,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_editConflictReason != null || _editLoadError != null)
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
                const _SectionTitle(title: '필수 정보'),
                const SizedBox(height: 12),

                TextField(
                  key: const ValueKey('record-location'),
                  controller: locationController,
                  maxLength: FishingRecordValidator.maxLocationLength,
                  decoration: InputDecoration(
                    labelText: '위치 *',
                    hintText: '예: 부산 영도구 동삼동',
                    prefixIcon: const Icon(Icons.place_outlined),
                    suffixIcon: IconButton(
                      key: const ValueKey('record-location-search'),
                      tooltip: '위치 검색',
                      onPressed: _canSearchLocation ? _searchLocation : null,
                      icon: const Icon(Icons.search),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('record-location-alias'),
                  controller: locationAliasController,
                  maxLength: FishingRecordValidator.maxLocationAliasLength,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    labelText: '위치 별칭 (선택)',
                    hintText: '예: 자주 가는 방파제',
                  ),
                ),
                const SizedBox(height: 16),

                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('낚시 시간', style: theme.textTheme.titleSmall),
                        const SizedBox(height: 12),
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
                      ],
                    ),
                  ),
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

                const _SectionTitle(title: '날씨·낚시 정보'),
                const SizedBox(height: 12),
                if (conditionsNotice != null) ...[
                  Semantics(
                    liveRegion: true,
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: _locationConditionsUnavailable
                            ? const Color(0xFFFFF5E5)
                            : AppTheme.coolGray,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            _locationConditionsUnavailable
                                ? Icons.warning_amber_rounded
                                : _loadingLocationConditions
                                ? Icons.cloud_download_outlined
                                : Icons.check_circle_outline,
                            size: 20,
                            color: _locationConditionsUnavailable
                                ? const Color(0xFF8F4E00)
                                : AppTheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(child: Text(conditionsNotice)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],

                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        TextField(
                          key: const ValueKey('record-tide'),
                          controller: tideController,
                          onChanged: (_) {
                            setState(() {
                              _tideManuallyEdited = true;
                              _locationAutoFields.remove(tideController);
                            });
                          },
                          maxLength: FishingRecordValidator.maxTideLength,
                          decoration: const InputDecoration(
                            labelText: '물때 (선택)',
                            hintText: '예: 7물',
                          ),
                        ),
                        const SizedBox(height: 16),

                        TextField(
                          key: const ValueKey('record-weather'),
                          controller: weatherController,
                          onChanged: (_) {
                            setState(() {
                              _weatherManuallyEdited = true;
                              _locationAutoFields.remove(weatherController);
                              _automaticWeather = false;
                              _automaticHistoricalWeather = false;
                            });
                          },
                          maxLength: FishingRecordValidator.maxWeatherLength,
                          decoration: const InputDecoration(
                            labelText: '날씨 *',
                            hintText: '예: 흐림',
                          ),
                        ),
                        const SizedBox(height: 16),

                        TextField(
                          key: const ValueKey('record-air-temperature'),
                          controller: airTemperatureController,
                          onChanged: (_) {
                            setState(() {
                              _airTemperatureManuallyEdited = true;
                              _locationAutoFields.remove(
                                airTemperatureController,
                              );
                              _automaticAirTemperature = false;
                              _automaticHistoricalAirTemperature = false;
                            });
                          },
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                            signed: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: '기온 *',
                            hintText: '예: 18',
                            suffixText: '℃',
                          ),
                        ),
                        const SizedBox(height: 16),

                        TextField(
                          key: const ValueKey('record-water-temperature'),
                          controller: waterTemperatureController,
                          onChanged: (_) {
                            setState(() {
                              _waterTemperatureManuallyEdited = true;
                              _locationAutoFields.remove(
                                waterTemperatureController,
                              );
                              _automaticWaterTemperature = false;
                              _automaticHistoricalWaterTemperature = false;
                            });
                          },
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                            signed: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: '수온 (선택)',
                            hintText: '예: 16.2',
                            suffixText: '℃',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                const _SectionTitle(title: '선택 정보'),
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
                              child: RecordPhotoThumbnail(
                                photo: photo,
                                size: 96,
                                compact: true,
                                errorLabel: '사진 오류',
                                onTap: () => openRecordPhoto(context, photo),
                              ),
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
                  onPressed: canSave ? saveRecord : null,
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
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.bold,
        color: AppTheme.primary,
      ),
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
      borderRadius: BorderRadius.circular(10),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
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
