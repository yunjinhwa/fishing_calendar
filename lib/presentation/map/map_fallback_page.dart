import 'package:flutter/material.dart';

import '../../core/validation/fishing_record_validator.dart';

class MapFallbackPage extends StatefulWidget {
  const MapFallbackPage({super.key});

  @override
  State<MapFallbackPage> createState() => _MapFallbackPageState();
}

class _MapFallbackPageState extends State<MapFallbackPage> {
  final _locationController = TextEditingController();
  static const _suggestions = ['부산 영도구 동삼동', '통영 욕지도', '여수 국동항', '거제 지세포항'];

  void _submit() {
    final location = _locationController.text.trim();
    if (location.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('직접 입력할 위치를 작성하세요.')));
      return;
    }
    if (location.length > FishingRecordValidator.maxLocationLength) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('위치는 200자 이하로 입력하세요.')));
      return;
    }
    Navigator.of(context).pop(location);
  }

  @override
  void dispose() {
    _locationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('위치 입력')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Icon(Icons.edit_location_alt_outlined, size: 56),
          const SizedBox(height: 16),
          const Text('지도를 사용하지 않고 장소 이름을 입력할 수 있습니다.'),
          const SizedBox(height: 24),
          TextField(
            controller: _locationController,
            maxLength: FishingRecordValidator.maxLocationLength,
            decoration: const InputDecoration(
              labelText: '위치명',
              hintText: '예: 부산광역시 영도구 동삼동',
              border: OutlineInputBorder(),
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _submit,
            icon: const Icon(Icons.check),
            label: const Text('위치 확정'),
          ),
          const SizedBox(height: 24),
          Text('장소 이름 선택', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          for (final name in _suggestions)
            Card(
              child: ListTile(
                leading: const Icon(Icons.place_outlined),
                title: Text(name),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).pop(name),
              ),
            ),
        ],
      ),
    ),
  );
}
