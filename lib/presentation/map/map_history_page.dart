import 'package:flutter/material.dart';

class MapHistoryPage extends StatefulWidget {
  final String selectedLocation;

  const MapHistoryPage({
    super.key,
    required this.selectedLocation,
  });

  @override
  State<MapHistoryPage> createState() => _MapHistoryPageState();
}

class _MapHistoryPageState extends State<MapHistoryPage> {
  DateTime selectedDate = DateTime.now().subtract(const Duration(days: 1));

  Future<void> pickDate() async {
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );

    if (pickedDate == null) {
      return;
    }

    setState(() {
      selectedDate = pickedDate;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('과거 정보 조회'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              widget.selectedLocation,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              '외부 제공사 기준으로 조회 가능한 과거 데이터만 표시합니다.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),

            OutlinedButton.icon(
              onPressed: pickDate,
              icon: const Icon(Icons.calendar_month_outlined),
              label: Text(_formatDate(selectedDate)),
            ),
            const SizedBox(height: 24),

            _SectionTitle(title: '조회 결과'),
            const SizedBox(height: 8),

            _InfoCard(
              children: [
                _InfoRow(
                  label: '날짜',
                  value: _formatDate(selectedDate),
                ),
                const _InfoRow(
                  label: '날씨',
                  value: '흐림 / 17℃',
                ),
                const _InfoRow(
                  label: '물때',
                  value: '6물',
                ),
                const _InfoRow(
                  label: '수온',
                  value: '15.8℃',
                ),
              ],
            ),
            const SizedBox(height: 24),

            _InfoCard(
              children: [
                Text(
                  '현재는 mock 데이터입니다. 실제 과거 날씨/물때/수온 조회는 외부 데이터 연동 단계에서 구현합니다.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    String twoDigits(int value) => value.toString().padLeft(2, '0');

    return '${date.year}.${twoDigits(date.month)}.${twoDigits(date.day)}';
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;

  const _SectionTitle({
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final List<Widget> children;

  const _InfoCard({
    required this.children,
  });

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

  const _InfoRow({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: TextStyle(
                color: Colors.grey.shade600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}