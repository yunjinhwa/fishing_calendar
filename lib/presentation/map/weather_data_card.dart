import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/history/historical_conditions.dart';
import '../../data/maps/water_area.dart';
import '../../data/models/external_data.dart';
import '../../data/tides/tide_name.dart';
import '../../data/water_temperature/water_temperature_models.dart';

class WeatherDataCard extends StatefulWidget {
  const WeatherDataCard({
    super.key,
    this.data,
    this.tideName,
    this.waterArea = WaterArea.unknown,
    this.embedded = false,
    this.marineControls,
    this.waterTemperatureObservation,
    this.historicalWeather,
    this.historicalWaterTemperature,
    this.clock,
  });

  final ExternalData? data;
  final TideName? tideName;
  final WaterArea waterArea;
  final bool embedded;
  final Widget? marineControls;
  final WaterTemperatureObservation? waterTemperatureObservation;
  final HistoricalWeatherObservation? historicalWeather;
  final HistoricalWaterTemperatureObservation? historicalWaterTemperature;
  final DateTime Function()? clock;

  @override
  State<WeatherDataCard> createState() => _WeatherDataCardState();
}

class _WeatherDataCardState extends State<WeatherDataCard>
    with WidgetsBindingObserver {
  Timer? _expiryTimer;
  bool _isForeground = true;

  DateTime _now() => (widget.clock ?? DateTime.now)().toUtc();

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _isForeground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _scheduleExpiry();
  }

  @override
  void didUpdateWidget(WeatherDataCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleExpiry();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isForeground = state == AppLifecycleState.resumed;
    _expiryTimer?.cancel();
    if (_isForeground) {
      setState(() {});
      _scheduleExpiry();
    }
  }

  // Snapshot/detail cards can outlive their originating map build. These
  // deadlines update only the display; the card never requests remote data.
  void _scheduleExpiry() {
    _expiryTimer?.cancel();
    if (!_isForeground) return;
    final now = _now();
    final weather = widget.historicalWeather == null ? widget.data : null;
    final water =
        widget.historicalWaterTemperature == null &&
            widget.waterArea.providesMarineData
        ? widget.waterTemperatureObservation
        : null;
    final deadlines = <DateTime>[
      if (weather != null) ...[
        weather.validAt.toUtc(),
        weather.validAt.toUtc().add(const Duration(hours: 1)),
      ],
      if (water != null)
        water.observedAt
            .toUtc()
            .add(WaterTemperatureObservation.maxObservationAge)
            .add(const Duration(milliseconds: 1)),
    ].where((deadline) => deadline.isAfter(now));
    if (deadlines.isEmpty) return;
    final next = deadlines.reduce((a, b) => a.isBefore(b) ? a : b);
    _expiryTimer = Timer(next.difference(now), () {
      if (!mounted) return;
      setState(() {});
      _scheduleExpiry();
    });
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final metrics = LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(1);
        final columns = constraints.maxWidth >= 280 && textScale <= 1.5 ? 2 : 1;
        const spacing = 12.0;
        final width =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        final history = widget.historicalWeather;
        final now = (widget.clock ?? DateTime.now)();
        final current = widget.data?.isUsableAt(now) == true
            ? widget.data
            : null;
        final weather = (history == null ? current?.weather : history.weather)
            ?.trim();
        final historicalWater = widget.historicalWaterTemperature;
        final archivedWater = historicalWater?.hasValidData == true
            ? historicalWater
            : null;
        final observation = widget.waterTemperatureObservation;
        final measured = observation?.isUsableAt(now) == true
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
                detail: history == null
                    ? null
                    : '${history.station.name} · '
                          '${formatWeatherTime(history.observedAt)} 관측',
              ),
            ),
            SizedBox(
              width: width,
              child: _WeatherValue(
                icon: Icons.thermostat_outlined,
                label: '기온',
                value: _temperature(
                  history == null
                      ? current?.airTemperature
                      : history.airTemperature,
                ),
              ),
            ),
            if (widget.waterArea.providesMarineData) ...[
              if (widget.marineControls != null)
                SizedBox(
                  width: constraints.maxWidth,
                  child: widget.marineControls,
                ),
              SizedBox(
                width: width,
                child: _WeatherValue(
                  icon: Icons.waves_outlined,
                  label: '물때',
                  value: widget.tideName?.label ?? '제공되지 않음',
                ),
              ),
              SizedBox(
                width: width,
                child: _WeatherValue(
                  icon: Icons.water_drop_outlined,
                  label: '수온',
                  value: _temperature(
                    historicalWater == null
                        ? measured?.temperatureCelsius
                        : archivedWater?.temperatureCelsius,
                  ),
                  detail: archivedWater != null
                      ? '${archivedWater.station.name} · '
                            '${formatWeatherTime(archivedWater.observedAt)} 관측'
                      : measured == null || historicalWater != null
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
    if (widget.embedded) return metrics;
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
