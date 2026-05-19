import 'package:flutter/material.dart';

import 'map_fallback_page.dart';
import 'map_detail_page.dart';
import '../record/record_form_page.dart';

class MapPage extends StatefulWidget {
  const MapPage({super.key});

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  final searchController = TextEditingController();

  String selectedLocation = '부산 영도구 동삼동';

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  void searchLocation() {
    final keyword = searchController.text.trim();

    if (keyword.isEmpty) {
      showMessage('검색할 위치를 입력하세요.');
      return;
    }

    setState(() {
      selectedLocation = keyword;
    });

    showMessage('$keyword 위치를 선택했습니다.');
  }

  Future<void> openFallbackPage() async {
    final result = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const MapFallbackPage()));

    if (result == null || result.trim().isEmpty) {
      return;
    }

    setState(() {
      selectedLocation = result;
      searchController.text = result;
    });
  }

  void showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('지도'),
        actions: [
          IconButton(
            onPressed: openFallbackPage,
            icon: const Icon(Icons.location_off_outlined),
            tooltip: '위치 대체 입력',
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: searchController,
              decoration: InputDecoration(
                labelText: '위치 검색',
                hintText: '예: 부산 영도구 동삼동',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  onPressed: searchLocation,
                  icon: const Icon(Icons.search),
                ),
              ),
              onSubmitted: (_) => searchLocation(),
            ),
            const SizedBox(height: 16),

            _MapPlaceholder(selectedLocation: selectedLocation),
            const SizedBox(height: 16),

            _ExternalDataCard(selectedLocation: selectedLocation),
            const SizedBox(height: 16),

            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              MapDetailPage(selectedLocation: selectedLocation),
                        ),
                      );
                    },
                    icon: const Icon(Icons.info_outline),
                    label: const Text('자세히 보기'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
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
                    label: const Text('기록 작성'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MapPlaceholder extends StatelessWidget {
  final String selectedLocation;

  const _MapPlaceholder({required this.selectedLocation});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 280,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Stack(
        children: [
          const Center(child: Icon(Icons.map_outlined, size: 72)),
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: Card(
              child: ListTile(
                leading: const Icon(Icons.place_outlined),
                title: Text(selectedLocation),
                subtitle: const Text('실제 지도 연동은 다음 단계에서 구현합니다.'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ExternalDataCard extends StatelessWidget {
  final String selectedLocation;

  const _ExternalDataCard({required this.selectedLocation});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '선택 위치 외부 데이터',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              selectedLocation,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),

            const Row(
              children: [
                Expanded(
                  child: _ExternalDataItem(
                    label: '날씨',
                    value: '흐림',
                    icon: Icons.cloud_outlined,
                  ),
                ),
                Expanded(
                  child: _ExternalDataItem(
                    label: '물때',
                    value: '7물',
                    icon: Icons.waves_outlined,
                  ),
                ),
                Expanded(
                  child: _ExternalDataItem(
                    label: '수온',
                    value: '16.2℃',
                    icon: Icons.thermostat_outlined,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ExternalDataItem extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  const _ExternalDataItem({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 6),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 4),
        Text(
          value,
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
        ),
      ],
    );
  }
}
