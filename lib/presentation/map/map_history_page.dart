import 'package:flutter/material.dart';

class MapHistoryPage extends StatefulWidget {
  const MapHistoryPage({super.key, required this.selectedLocation});

  final String selectedLocation;

  @override
  State<MapHistoryPage> createState() => _MapHistoryPageState();
}

class _MapHistoryPageState extends State<MapHistoryPage> {
  DateTime _selectedDate = DateTime.now().subtract(const Duration(days: 1));

  Future<void> _pickDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (!mounted || date == null) return;
    setState(() => _selectedDate = date);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('과거 정보 조회')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            widget.selectedLocation,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: _pickDate,
            icon: const Icon(Icons.calendar_month_outlined),
            label: Text(_formatDate(_selectedDate)),
          ),
          const SizedBox(height: 24),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('과거 날씨 조회는 아직 지원하지 않습니다.'),
                  SizedBox(height: 8),
                  Text('과거 날짜의 날씨·기온과 물때·수온은 기록 작성 화면에서 직접 입력해 주세요.'),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );

  String _formatDate(DateTime date) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${date.year}.${two(date.month)}.${two(date.day)}';
  }
}
