import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/maps/kakao_map_configuration.dart';
import '../../data/maps/map_location.dart';
import '../../data/maps/water_area.dart';
import '../../data/models/external_data.dart';
import '../../data/tides/tide_models.dart';
import '../../data/tides/tide_name.dart';
import '../../data/water_temperature/water_temperature_models.dart';
import '../auth/auth_access_guard.dart';
import '../record/record_form_page.dart';
import 'kakao_map_canvas.dart';
import 'location_conditions_card.dart';
import 'map_history_page.dart';

class MapDetailPage extends StatelessWidget {
  final String selectedLocation;
  final KakaoMapConfiguration configuration;
  final double? latitude;
  final double? longitude;
  final ExternalData? externalData;
  final TideRecordReference? tideReference;
  final TideName? tideName;
  final WaterArea waterArea;
  final WaterTemperatureObservation? waterTemperatureObservation;

  const MapDetailPage({
    super.key,
    required this.selectedLocation,
    this.configuration = const KakaoMapConfiguration(),
    this.latitude,
    this.longitude,
    this.externalData,
    this.tideReference,
    this.tideName,
    this.waterArea = WaterArea.unknown,
    this.waterTemperatureObservation,
  });

  MapLocation? _previewLocation() {
    if (!configuration.isConfigured ||
        !configuration.supportsPlatform ||
        latitude == null ||
        longitude == null) {
      return null;
    }
    try {
      return MapLocation(
        name: selectedLocation,
        latitude: latitude,
        longitude: longitude,
      );
    } on ArgumentError {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final previewLocation = _previewLocation();
    return Scaffold(
      appBar: AppBar(title: const Text('지도 상세')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (previewLocation != null) ...[
              MapCanvasHost(
                key: const ValueKey('map-detail-preview'),
                isActive: true,
                child: KakaoMapCanvas.preview(
                  configuration: configuration,
                  selection: previewLocation,
                ),
              ),
              const SizedBox(height: 16),
            ],
            Text(
              selectedLocation,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            LocationConditionsCard(
              waterArea: waterArea,
              weatherData: externalData,
              waterTemperatureObservation: waterArea.providesMarineData
                  ? waterTemperatureObservation
                  : null,
              tideName: !waterArea.providesMarineData
                  ? null
                  : tideName ??
                        (tideReference == null
                            ? null
                            : TideName.calculate(
                                day: tideReference!.forecast.day,
                                station: tideReference!.forecast.station,
                              )),
              tideForecast: waterArea.providesMarineData
                  ? tideReference?.forecast
                  : null,
            ),
            const SizedBox(height: 24),

            OutlinedButton.icon(
              onPressed: () {
                unawaited(
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => MapHistoryPage(
                        selectedLocation: selectedLocation,
                        latitude: latitude,
                        longitude: longitude,
                        waterArea: waterArea,
                      ),
                    ),
                  ),
                );
              },
              icon: const Icon(Icons.history),
              label: const Text('과거 정보 조회'),
            ),
            const SizedBox(height: 12),

            FilledButton.icon(
              onPressed: () async {
                final allowed = await requireMemberAccess(
                  context,
                  message: '지도 정보를 출조 기록으로 저장하려면 로그인이 필요합니다.',
                );

                if (!allowed || !context.mounted) {
                  return;
                }

                unawaited(
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => RecordFormPage(
                        initialLocation: selectedLocation,
                        initialLatitude: latitude,
                        initialLongitude: longitude,
                        initialExternalData: externalData,
                        initialTideReference: waterArea.providesMarineData
                            ? tideReference
                            : null,
                        allowAutomaticTide: waterArea.providesMarineData,
                        initialWaterTemperatureObservation:
                            waterArea.providesMarineData
                            ? waterTemperatureObservation
                            : null,
                        allowAutomaticWaterTemperature:
                            waterArea.providesMarineData,
                      ),
                    ),
                  ),
                );
              },
              icon: const Icon(Icons.edit_note),
              label: const Text('기록 작성으로 이동'),
            ),
          ],
        ),
      ),
    );
  }
}
