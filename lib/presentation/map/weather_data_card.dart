import 'package:flutter/material.dart';

import '../../data/models/external_data.dart';

class WeatherDataCard extends StatelessWidget {
  const WeatherDataCard({super.key, required this.data});

  final ExternalData data;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('선택 위치 날씨 예보', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(data.locationName),
          Text('제공: ${data.sourceName}'),
          Text('예보 격자: ${data.gridX}, ${data.gridY}'),
          Text('발표 기준: ${formatWeatherTime(data.issuedAt)} (KST)'),
          Text('예보: ${formatWeatherTime(data.validAt)} (KST)'),
          const SizedBox(height: 16),
          Wrap(
            spacing: 24,
            runSpacing: 12,
            children: [
              _WeatherValue(label: '날씨', value: data.weather ?? '정보 없음'),
              _WeatherValue(
                label: '기온',
                value: data.airTemperature == null
                    ? '정보 없음'
                    : '${data.airTemperature}℃',
              ),
              const _WeatherValue(label: '물때', value: '수동 입력'),
              const _WeatherValue(label: '수온', value: '수동 입력'),
            ],
          ),
          const SizedBox(height: 12),
          const Text('물때·수온은 아직 연동되지 않았습니다. 기록 작성 화면에서 직접 입력해 주세요.'),
          if (data.weather == null || data.airTemperature == null)
            const Text('제공되지 않은 날씨 항목도 직접 입력할 수 있습니다.'),
        ],
      ),
    ),
  );
}

String formatWeatherTime(DateTime value) {
  final kst = value.toUtc().add(const Duration(hours: 9));
  String two(int number) => number.toString().padLeft(2, '0');
  return '${kst.year}.${two(kst.month)}.${two(kst.day)} '
      '${two(kst.hour)}:${two(kst.minute)}';
}

class _WeatherValue extends StatelessWidget {
  const _WeatherValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 4),
      Text(value, style: Theme.of(context).textTheme.titleSmall),
    ],
  );
}
