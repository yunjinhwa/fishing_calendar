import 'package:flutter/material.dart';

import 'record_form_page.dart';
import '../search/record_search_page.dart';

class RecordPage extends StatelessWidget {
  const RecordPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('기록'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(
                Icons.add_circle_outline,
                size: 64,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 24),
              Text(
                '출조 기록 작성',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                '위치, 낚시 시간, 장르, 물때, 날씨, 기온, 수온을 입력해 출조 기록을 작성합니다.',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              FilledButton.icon(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const RecordFormPage(),
                    ),
                  );
                },
                icon: const Icon(Icons.edit_note),
                label: const Text('출조 기록 작성하기'),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const RecordSearchPage(),
                    ),
                  );
                },
                icon: const Icon(Icons.search),
                label: const Text('기록 검색'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}