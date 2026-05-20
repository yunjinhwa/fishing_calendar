import 'package:flutter/material.dart';

import '../record/record_form_page.dart';

class OfflineFreePage extends StatelessWidget {
  const OfflineFreePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('오프라인 모드'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 24),

            Text(
              '오프라인 상태입니다',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),

            Text(
              '무료 회원은 이 기기에 저장된 로컬 기록을 작성하고 조회할 수 있습니다. '
              '단, 날씨/물때/수온 같은 외부 데이터는 제공되지 않습니다.',
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),

            Card(
              child: ListTile(
                leading: const Icon(Icons.save_outlined),
                title: const Text('이 기기에 저장됨'),
                subtitle: const Text('로컬 기록은 현재 기기에만 보관됩니다.'),
                trailing: const Icon(Icons.phone_android),
              ),
            ),
            const SizedBox(height: 16),

            FilledButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const RecordFormPage(),
                  ),
                );
              },
              icon: const Icon(Icons.edit_note),
              label: const Text('기록 작성'),
            ),
            const SizedBox(height: 12),

            OutlinedButton.icon(
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('로컬 기록 목록은 캘린더 화면에서 확인할 수 있습니다.'),
                  ),
                );
              },
              icon: const Icon(Icons.list_alt),
              label: const Text('로컬 기록 보기'),
            ),
            const SizedBox(height: 12),

            TextButton.icon(
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('네트워크 연결 상태를 다시 확인합니다.'),
                  ),
                );
              },
              icon: const Icon(Icons.refresh),
              label: const Text('다시 시도'),
            ),
          ],
        ),
      ),
    );
  }
}