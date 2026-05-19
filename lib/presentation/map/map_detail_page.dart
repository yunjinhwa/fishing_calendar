import 'package:flutter/material.dart';

import 'map_history_page.dart';
import '../record/record_form_page.dart';

class MapDetailPage extends StatelessWidget {
  final String selectedLocation;

  const MapDetailPage({super.key, required this.selectedLocation});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('지도 상세')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              selectedLocation,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              '기준 관측점: 인근 관측소',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),

            _SectionTitle(title: '현재 외부 데이터'),
            const SizedBox(height: 8),
            const _InfoCard(
              children: [
                _InfoRow(label: '날씨', value: '흐림 / 18℃'),
                _InfoRow(label: '물때', value: '7물'),
                _InfoRow(label: '수온', value: '16.2℃'),
              ],
            ),
            const SizedBox(height: 24),

            _SectionTitle(title: '정확도 안내'),
            const SizedBox(height: 8),
            const _InfoCard(
              children: [
                Text(
                  '표시되는 날씨, 물때, 수온 정보는 선택 위치와 가장 가까운 관측 지점 기준의 예시 데이터입니다. 실제 API 연동 후 제공사 데이터 기준으로 표시됩니다.',
                ),
              ],
            ),
            const SizedBox(height: 24),

            OutlinedButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        MapHistoryPage(selectedLocation: selectedLocation),
                  ),
                );
              },
              icon: const Icon(Icons.history),
              label: const Text('과거 정보 조회'),
            ),
            const SizedBox(height: 12),

            FilledButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => RecordFormPage(
                      initialLocation: selectedLocation,
                      initialTide: '7물',
                      initialWeather: '흐림',
                      initialAirTemperature: 18,
                      initialWaterTemperature: 16.2,
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

  const _InfoCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Card(
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
            width: 64,
            child: Text(label, style: TextStyle(color: Colors.grey.shade600)),
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
