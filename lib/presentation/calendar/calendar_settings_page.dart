import 'package:flutter/material.dart';

class CalendarSettingsPage extends StatelessWidget {
  const CalendarSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('캘린더 설정'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: SwitchListTile(
                value: true,
                onChanged: (_) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('월간 캘린더 표시 설정은 현재 기본값으로 고정되어 있습니다.'),
                    ),
                  );
                },
                title: const Text('월간 캘린더 표시'),
                subtitle: const Text('캘린더 탭에서 월 단위로 출조 기록을 확인합니다.'),
              ),
            ),
            const SizedBox(height: 8),

            Card(
              child: SwitchListTile(
                value: true,
                onChanged: (_) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('기록 요약 표시 설정은 현재 기본값으로 고정되어 있습니다.'),
                    ),
                  );
                },
                title: const Text('날짜 칸에 기록 요약 표시'),
                subtitle: const Text('날짜 칸 안에 대표 출조 기록을 표시합니다.'),
              ),
            ),
            const SizedBox(height: 8),

            Card(
              child: ListTile(
                leading: const Icon(Icons.today_outlined),
                title: const Text('오늘의 요약'),
                subtitle: const Text('오늘 날짜의 출조 기록과 외부 데이터를 요약합니다.'),
                trailing: const Text('표시 중'),
              ),
            ),
            const SizedBox(height: 8),

            Card(
              child: ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('안내'),
                subtitle: const Text(
                  '세부 캘린더 설정 저장은 영구 저장소 적용 이후 확장할 예정입니다.',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}