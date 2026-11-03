import 'package:flutter/material.dart';

import '../../data/maps/water_area.dart';
import '../../data/models/external_data.dart';
import '../../data/tides/tide_name.dart';
import '../../data/water_temperature/water_temperature_models.dart';

class WeatherDataCard extends StatelessWidget {
  const WeatherDataCard({
    super.key,
    this.data,
    this.tideName,
    this.waterArea = WaterArea.unknown,
    this.embedded = false,
    this.marineControls,
    this.waterTemperatureObservation,
  });

  final ExternalData? data;
  final TideName? tideName;
  final WaterArea waterArea;
  final bool embedded;
  final Widget? marineControls;
  final WaterTemperatureObservation? waterTemperatureObservation;

  @override
  Widget build(BuildContext context) {
    final metrics = LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(1);
        final columns = constraints.maxWidth >= 280 && textScale <= 1.5 ? 2 : 1;
        const spacing = 12.0;
        final width =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        final weather = data?.weather?.trim();
        final observation = waterTemperatureObservation;
        final measured = observation?.isUsableAt(DateTime.now()) == true
            ? observation
            : null;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            SizedBox(
              width: width,
              child: _WeatherValue(
                icon: Icons.cloud_outlined,
                label: '날씨',
                value: weather == null || weather.isEmpty ? '제공되지 않음' : weather,
              ),
            ),
            SizedBox(
              width: width,
              child: _WeatherValue(
                icon: Icons.thermostat_outlined,
                label: '기온',
                value: _temperature(data?.airTemperature),
              ),
            ),
            if (waterArea.providesMarineData) ...[
              if (marineControls != null)
                SizedBox(width: constraints.maxWidth, child: marineControls),
              SizedBox(
                width: width,
                child: _WeatherValue(
                  icon: Icons.waves_outlined,
                  label: '물때',
                  value: tideName?.label ?? '제공되지 않음',
                ),
              ),
              SizedBox(
                width: width,
                child: _WeatherValue(
                  icon: Icons.water_drop_outlined,
                  label: '수온',
                  value: _temperature(measured?.temperatureCelsius),
                  detail: measured == null
                      ? null
                      : '${measured.station.name} · '
                            '${formatWeatherTime(measured.observedAt)} 관측',
                ),
              ),
            ],
          ],
        );
      },
    );
    if (embedded) return metrics;
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('날씨·낚시 정보', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            metrics,
          ],
        ),
      ),
    );
  }
}

String _temperature(double? value) {
  if (value == null || !value.isFinite) return '제공되지 않음';
  final number = value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toString();
  return '$number℃';
}

String formatWeatherTime(DateTime value) {
  final kst = value.toUtc().add(const Duration(hours: 9));
  String two(int number) => number.toString().padLeft(2, '0');
  return '${kst.year}.${two(kst.month)}.${two(kst.day)} '
      '${two(kst.hour)}:${two(kst.minute)}';
}

class _WeatherValue extends StatelessWidget {
  const _WeatherValue({
    required this.icon,
    required this.label,
    required this.value,
    this.detail,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: value == '제공되지 않음'
                ? theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  )
                : theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
          ),
          if (detail != null) ...[
            const SizedBox(height: 4),
            Text(
              detail!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
