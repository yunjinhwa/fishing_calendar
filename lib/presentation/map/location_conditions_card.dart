import 'package:flutter/material.dart';

import '../../data/maps/water_area.dart';
import '../../data/models/external_data.dart';
import '../../data/tides/tide_models.dart';
import '../../data/tides/tide_name.dart';
import '../../data/water_temperature/water_temperature_models.dart';
import 'tide_data_card.dart';
import 'weather_data_card.dart';

class LocationConditionsCard extends StatelessWidget {
  const LocationConditionsCard({
    super.key,
    required this.waterArea,
    this.weatherData,
    this.tideName,
    this.tideForecast,
    this.weatherLoading = false,
    this.tideLoading = false,
    this.weatherError,
    this.tideError,
    this.onRetryWeather,
    this.onRetryTide,
    this.waterAreaSelector,
    this.tideControls,
    this.compact = false,
    this.waterTemperatureObservation,
    this.waterTemperatureLoading = false,
    this.waterTemperatureError,
    this.onRetryWaterTemperature,
  });

  final WaterArea waterArea;
  final ExternalData? weatherData;
  final TideName? tideName;
  final TideForecast? tideForecast;
  final bool weatherLoading;
  final bool tideLoading;
  final String? weatherError;
  final String? tideError;
  final VoidCallback? onRetryWeather;
  final VoidCallback? onRetryTide;
  final Widget? waterAreaSelector;
  final Widget? tideControls;
  final bool compact;
  final WaterTemperatureObservation? waterTemperatureObservation;
  final bool waterTemperatureLoading;
  final String? waterTemperatureError;
  final VoidCallback? onRetryWaterTemperature;

  @override
  Widget build(BuildContext context) => Card(
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    child: Padding(
      padding: EdgeInsets.all(compact ? 12 : 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('날씨·낚시 정보', style: Theme.of(context).textTheme.titleMedium),
          if (waterAreaSelector != null) ...[
            const SizedBox(height: 12),
            waterAreaSelector!,
          ],
          const SizedBox(height: 16),
          if (weatherLoading) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
          ],
          WeatherDataCard(
            embedded: true,
            data: weatherData,
            waterArea: waterArea,
            tideName: tideName,
            marineControls: tideControls,
            waterTemperatureObservation: waterTemperatureObservation,
          ),
          if (weatherError != null) ...[
            const SizedBox(height: 8),
            _ConditionError(label: '날씨 다시 조회', onRetry: onRetryWeather),
          ],
          if (waterArea.providesMarineData) ...[
            if (waterTemperatureLoading) ...[
              const SizedBox(height: 8),
              const LinearProgressIndicator(
                key: ValueKey('water-temperature-loading'),
              ),
            ],
            if (waterTemperatureError != null)
              _ConditionError(
                label: '수온 다시 조회',
                onRetry: onRetryWaterTemperature,
              ),
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 16),
            Text('만조·간조', style: Theme.of(context).textTheme.titleSmall),
            if (tideControls == null && tideForecast != null)
              Text(
                '${tideForecast!.day.label} · ${tideForecast!.station.name}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            const SizedBox(height: 12),
            if (tideLoading) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 12),
            ],
            TideEventList(events: tideForecast?.events ?? const []),
            if (tideError != null) ...[
              const SizedBox(height: 8),
              _ConditionError(label: '만조·간조 다시 조회', onRetry: onRetryTide),
            ],
          ],
        ],
      ),
    ),
  );
}

class _ConditionError extends StatelessWidget {
  const _ConditionError({required this.label, this.onRetry});

  final String label;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => onRetry == null
      ? const SizedBox.shrink()
      : Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(label),
          ),
        );
}
