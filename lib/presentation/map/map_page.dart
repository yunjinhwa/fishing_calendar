import 'package:flutter/material.dart';

import 'map_fallback_page.dart';
import 'map_detail_page.dart';
import '../record/record_form_page.dart';
import '../../data/models/external_data.dart';
import '../../data/services/mock_external_data_service.dart';

class MapPage extends StatefulWidget {
  const MapPage({super.key});

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  final searchController = TextEditingController();
  final externalDataService = MockExternalDataService();

  String selectedLocation = '부산 영도구 동삼동';
  ExternalData? externalData;
  bool isLoadingExternalData = false;
  String? externalDataErrorMessage;

  @override
  void initState() {
    super.initState();
    fetchExternalData();
  }

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  Future<void> fetchExternalData() async {
    setState(() {
      isLoadingExternalData = true;
      externalDataErrorMessage = null;
    });

    try {
      final data = await externalDataService.fetchCurrentData(
        locationName: selectedLocation,
      );

      if (!mounted) return;

      setState(() {
        externalData = data;
        isLoadingExternalData = false;
      });
    } catch (_) {
      if (!mounted) return;

      setState(() {
        externalData = null;
        isLoadingExternalData = false;
        externalDataErrorMessage = '외부 데이터를 가져오지 못했습니다.';
      });
    }
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
    fetchExternalData();
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

    fetchExternalData();
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

            _ExternalDataCard(
              selectedLocation: selectedLocation,
              externalData: externalData,
              isLoading: isLoadingExternalData,
              errorMessage: externalDataErrorMessage,
              onRetry: fetchExternalData,
            ),
            const SizedBox(height: 16),

            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => MapDetailPage(
                            selectedLocation: selectedLocation,
                            externalData: externalData,
                          ),
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
                      if (externalDataErrorMessage != null) {
                        showMessage('외부 데이터 조회에 실패했습니다. 위치만 입력한 상태로 기록을 작성합니다.');
                      }

                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => RecordFormPage(
                            initialLocation: selectedLocation,
                            initialTide: externalData?.tide,
                            initialWeather: externalData?.weather,
                            initialAirTemperature: externalData?.airTemperature,
                            initialWaterTemperature: externalData?.waterTemperature,
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
  final ExternalData? externalData;
  final bool isLoading;
  final String? errorMessage;
  final VoidCallback onRetry;

  const _ExternalDataCard({
    required this.selectedLocation,
    required this.externalData,
    required this.isLoading,
    required this.errorMessage,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    if (errorMessage != null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '외부 데이터 조회 실패',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(errorMessage!),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('다시 조회'),
              ),
            ],
          ),
        ),
      );
    }

    final data = externalData;

    if (data == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('조회된 외부 데이터가 없습니다.'),
        ),
      );
    }

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
              data.locationName,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              '기준 관측점: ${data.observationPointName}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _ExternalDataItem(
                    label: '날씨',
                    value: '${data.weather} / ${data.airTemperature}℃',
                    icon: Icons.cloud_outlined,
                  ),
                ),
                Expanded(
                  child: _ExternalDataItem(
                    label: '물때',
                    value: data.tide,
                    icon: Icons.waves_outlined,
                  ),
                ),
                Expanded(
                  child: _ExternalDataItem(
                    label: '수온',
                    value: '${data.waterTemperature}℃',
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
