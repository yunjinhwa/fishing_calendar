import 'package:flutter/material.dart';

class MapFallbackPage extends StatefulWidget {
  const MapFallbackPage({super.key});

  @override
  State<MapFallbackPage> createState() => _MapFallbackPageState();
}

class _MapFallbackPageState extends State<MapFallbackPage> {
  final searchController = TextEditingController();
  final manualLocationController = TextEditingController();

  final recommendedLocations = const [
    '부산 영도구 동삼동',
    '통영 욕지도',
    '여수 국동항',
    '거제 지세포항',
  ];

  @override
  void dispose() {
    searchController.dispose();
    manualLocationController.dispose();
    super.dispose();
  }

  void selectLocation(String location) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$location 위치가 선택되었습니다.')));

    Navigator.of(context).pop(location);
  }

  void searchLocation() {
    final keyword = searchController.text.trim();

    if (keyword.isEmpty) {
      showMessage('검색할 위치를 입력하세요.');
      return;
    }

    showMessage('위치 검색 API는 다음 단계에서 구현합니다.');
  }

  void submitManualLocation() {
    final location = manualLocationController.text.trim();

    if (location.isEmpty) {
      showMessage('직접 입력할 위치를 작성하세요.');
      return;
    }

    selectLocation(location);
  }

  void showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('위치 입력')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Icon(
              Icons.location_off_outlined,
              size: 56,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),

            Text(
              '위치 권한이 꺼져 있거나 지도를 사용할 수 없습니다.',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),

            Text(
              '장소 검색 또는 직접 입력으로 위치를 선택할 수 있습니다.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),

            TextField(
              controller: searchController,
              decoration: InputDecoration(
                labelText: '장소 검색',
                hintText: '예: 동삼동, 욕지도',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  onPressed: searchLocation,
                  icon: const Icon(Icons.search),
                ),
              ),
              onSubmitted: (_) => searchLocation(),
            ),
            const SizedBox(height: 24),

            Text('추천 장소', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),

            ...recommendedLocations.map(
              (location) => Card(
                child: ListTile(
                  leading: const Icon(Icons.place_outlined),
                  title: Text(location),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => selectLocation(location),
                ),
              ),
            ),

            const SizedBox(height: 24),

            Text('직접 입력', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),

            TextField(
              controller: manualLocationController,
              decoration: const InputDecoration(
                labelText: '위치명',
                hintText: '예: 부산광역시 영도구 동삼동',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),

            FilledButton.icon(
              onPressed: submitManualLocation,
              icon: const Icon(Icons.check),
              label: const Text('위치 확정'),
            ),
            const SizedBox(height: 12),

            OutlinedButton.icon(
              onPressed: () {
                showMessage('권한 설정 이동은 실제 지도 연동 단계에서 구현합니다.');
              },
              icon: const Icon(Icons.settings_outlined),
              label: const Text('권한 설정'),
            ),
          ],
        ),
      ),
    );
  }
}
