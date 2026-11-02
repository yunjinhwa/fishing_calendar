import 'package:flutter/material.dart';

import 'map_history_page.dart';
import '../auth/auth_access_guard.dart';
import '../record/record_form_page.dart';
import '../../data/models/external_data.dart';
import 'weather_data_card.dart';

class MapDetailPage extends StatelessWidget {
  final String selectedLocation;
  final double? latitude;
  final double? longitude;
  final ExternalData? externalData;

  const MapDetailPage({
    super.key,
    required this.selectedLocation,
    this.latitude,
    this.longitude,
    this.externalData,
  });

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
            if (externalData != null)
              WeatherDataCard(data: externalData!)
            else
              const _InfoCard(
                children: [Text('조회된 날씨 예보가 없습니다. 기록 작성 화면에서 직접 입력할 수 있습니다.')],
              ),
            const SizedBox(height: 24),

            _SectionTitle(title: '정확도 안내'),
            const SizedBox(height: 8),
            const _InfoCard(
              children: [
                Text(
                  '날씨·기온은 표시된 시간의 예보입니다. 다른 시간대의 기록은 직접 입력해 주세요. 물때·수온은 아직 연동되지 않았습니다.',
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
              onPressed: () async {
                final allowed = await requireMemberAccess(
                  context,
                  message: '지도 정보를 출조 기록으로 저장하려면 로그인이 필요합니다.',
                );

                if (!allowed || !context.mounted) {
                  return;
                }

                if (externalData == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('외부 데이터가 없어 기록 화면에서 값을 직접 입력해야 합니다.'),
                    ),
                  );
                }

                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => RecordFormPage(
                      initialLocation: selectedLocation,
                      initialLatitude: latitude,
                      initialLongitude: longitude,
                      initialExternalData: externalData,
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
