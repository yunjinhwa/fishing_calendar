import 'package:flutter/material.dart';

import '../../data/tides/tide_models.dart';
import '../../data/tides/tide_name.dart';

const tidePredictionNote = '만조·간조는 예측값입니다.';

/// A compact reference for the selected forecast date and station.
class TideDataCard extends StatelessWidget {
  const TideDataCard({
    super.key,
    required this.reference,
    this.compact = false,
    this.showTideName = true,
  });

  final TideRecordReference reference;
  final bool compact;
  final bool showTideName;

  @override
  Widget build(BuildContext context) {
    final forecast = reference.forecast;
    final tideName = showTideName
        ? TideName.calculate(day: forecast.day, station: forecast.station)
        : null;
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: EdgeInsets.all(compact ? 12 : 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('만조·간조', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '${forecast.day.label} · ${forecast.station.name}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (showTideName) ...[
              const SizedBox(height: 12),
              Text('물때: ${tideName?.label ?? '제공되지 않음'}'),
            ],
            const SizedBox(height: 12),
            TideEventList(events: forecast.events),
          ],
        ),
      ),
    );
  }
}

/// Forecast rows shared by the unified conditions card and record references.
class TideEventList extends StatelessWidget {
  const TideEventList({super.key, required this.events});

  final List<TideEvent> events;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) return const Text('제공되지 않음');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < events.length; index++) ...[
          if (index > 0) const SizedBox(height: 12),
          _TideEventRow(event: events[index]),
        ],
      ],
    );
  }
}

class _TideEventRow extends StatelessWidget {
  const _TideEventRow({required this.event});

  final TideEvent event;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final high = event.kind == TideEventKind.high;
    final color = high ? const Color(0xffb84f43) : const Color(0xff2778ad);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            high ? '만조' : '간조',
            style: theme.textTheme.labelLarge?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              spacing: 12,
              runSpacing: 4,
              children: [
                Text(
                  formatTideTime(event.at),
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${formatTideHeight(event.heightCm)} cm',
                  style: theme.textTheme.bodyLarge,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

String formatTideTime(DateTime instant) {
  final kst = instant.toUtc().add(const Duration(hours: 9));
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(kst.hour)}:${two(kst.minute)}';
}

String formatTideHeight(double value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toString();
