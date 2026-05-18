import 'package:flutter/material.dart';

class RecordFormPage extends StatefulWidget {
  const RecordFormPage({super.key});

  @override
  State<RecordFormPage> createState() => _RecordFormPageState();
}

class _RecordFormPageState extends State<RecordFormPage> {
  final locationController = TextEditingController();
  final tideController = TextEditingController();
  final weatherController = TextEditingController();
  final airTemperatureController = TextEditingController();
  final waterTemperatureController = TextEditingController();
  final memoController = TextEditingController();

  final catchItems = <_CatchItemInput>[
    _CatchItemInput(),
  ];

  DateTime startAt = DateTime.now();
  DateTime endAt = DateTime.now().add(const Duration(hours: 2));

  String? selectedGenre;

  final genres = const [
    '루어',
    '찌낚시',
    '선상',
    '원투',
    '기타',
  ];

  @override
  void dispose() {
    locationController.dispose();
    tideController.dispose();
    weatherController.dispose();
    airTemperatureController.dispose();
    waterTemperatureController.dispose();
    memoController.dispose();
    for (final item in catchItems) {
      item.dispose();
    }
    super.dispose();
  }

  void saveRecord() {
    final location = locationController.text.trim();
    final airTemperature = airTemperatureController.text.trim();
    final waterTemperature = waterTemperatureController.text.trim();

    if (location.isEmpty) {
      showMessage('위치를 입력하세요.');
      return;
    }

    if (!startAt.isBefore(endAt)) {
      showMessage('종료 시간은 시작 시간보다 늦어야 합니다.');
      return;
    }

    if (airTemperature.isNotEmpty) {
      final airTemperatureValue = double.tryParse(airTemperature);

      if (airTemperatureValue == null) {
        showMessage('기온은 숫자로 입력하세요.');
        return;
      }
    }

    if (waterTemperature.isNotEmpty) {
      final waterTemperatureValue = double.tryParse(waterTemperature);

      if (waterTemperatureValue == null) {
        showMessage('수온은 숫자로 입력하세요.');
        return;
      }
    }

    for (var i = 0; i < catchItems.length; i++) {
      final item = catchItems[i];
      final species = item.speciesController.text.trim();
      final length = item.lengthController.text.trim();
      final weight = item.weightController.text.trim();

      final hasAnyValue =
          species.isNotEmpty || length.isNotEmpty || weight.isNotEmpty;

      if (!hasAnyValue) {
        continue;
      }

      if (species.isEmpty) {
        showMessage('조과 ${i + 1}의 어종을 입력하세요.');
        return;
      }

      if (length.isNotEmpty) {
        final lengthValue = double.tryParse(length);

        if (lengthValue == null || lengthValue < 0) {
          showMessage('조과 ${i + 1}의 크기는 0 이상의 숫자로 입력하세요.');
          return;
        }
      }

      if (weight.isNotEmpty) {
        final weightValue = int.tryParse(weight);

        if (weightValue == null || weightValue < 0) {
          showMessage('조과 ${i + 1}의 무게는 0 이상의 정수(g)로 입력하세요.');
          return;
        }
      }
    }
    
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('기록 저장 UI 검증이 완료되었습니다. 실제 저장은 local-storage 단계에서 구현합니다.'),
      ),
    );

    Navigator.of(context).pop();
  }

  void showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void addCatchItem() {
    setState(() {
      catchItems.add(_CatchItemInput());
    });
  }

  void removeCatchItem(int index) {
    if (catchItems.length == 1) {
      showMessage('조과 입력칸은 최소 1개가 필요합니다.');
      return;
    }

    setState(() {
      catchItems[index].dispose();
      catchItems.removeAt(index);
    });
  }

  String formatDateTime(DateTime dateTime) {
    String twoDigits(int value) => value.toString().padLeft(2, '0');

    return '${dateTime.year}.${twoDigits(dateTime.month)}.${twoDigits(dateTime.day)} '
        '${twoDigits(dateTime.hour)}:${twoDigits(dateTime.minute)}';
  }

  Future<void> pickStartDateTime() async {
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: startAt,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
    );

    if (pickedDate == null || !mounted) return;

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(startAt),
    );

    if (pickedTime == null) return;

    setState(() {
      startAt = DateTime(
        pickedDate.year,
        pickedDate.month,
        pickedDate.day,
        pickedTime.hour,
        pickedTime.minute,
      );
    });
  }

  Future<void> pickEndDateTime() async {
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: endAt,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
    );

    if (pickedDate == null || !mounted) return;

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(endAt),
    );

    if (pickedTime == null) return;

    setState(() {
      endAt = DateTime(
        pickedDate.year,
        pickedDate.month,
        pickedDate.day,
        pickedTime.hour,
        pickedTime.minute,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('출조 기록 작성'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _SectionTitle(title: '필수 정보'),
            const SizedBox(height: 12),

            TextField(
              controller: locationController,
              decoration: const InputDecoration(
                labelText: '위치 *',
                hintText: '예: 부산 영도구 동삼동',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),

            _DateTimeField(
              label: '시작 시간 *',
              value: formatDateTime(startAt),
              onTap: pickStartDateTime,
            ),
            const SizedBox(height: 12),

            _DateTimeField(
              label: '종료 시간 *',
              value: formatDateTime(endAt),
              onTap: pickEndDateTime,
            ),
            const SizedBox(height: 16),

            Text(
              '낚시 장르 *',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),

            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: genres.map((genre) {
                return ChoiceChip(
                  label: Text(genre),
                  selected: selectedGenre == genre,
                  onSelected: (_) {
                    setState(() {
                      selectedGenre = genre;
                    });
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 24),

            _SectionTitle(title: '선택 정보'),
            const SizedBox(height: 12),

            _SectionTitle(title: '외부 데이터'),
            const SizedBox(height: 12),

            TextField(
              controller: tideController,
              decoration: const InputDecoration(
                labelText: '물때',
                hintText: '예: 7물',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),

            TextField(
              controller: weatherController,
              decoration: const InputDecoration(
                labelText: '날씨',
                hintText: '예: 흐림',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),

            TextField(
              controller: airTemperatureController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '기온',
                hintText: '예: 18',
                suffixText: '℃',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),

            TextField(
              controller: waterTemperatureController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '수온',
                hintText: '예: 16.2',
                suffixText: '℃',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),


            Text(
              '조과',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),

            ...catchItems.asMap().entries.map((entry) {
              final index = entry.key;
              final item = entry.value;

              return _CatchItemCard(
                index: index,
                item: item,
                onRemove: () => removeCatchItem(index),
              );
            }),

            const SizedBox(height: 8),

            Text(
              '사진',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),

            OutlinedButton.icon(
              onPressed: () {
                showMessage('사진 선택 기능은 feature/photo 또는 local-storage 단계에서 구현합니다.');
              },
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('사진 추가'),
            ),
            const SizedBox(height: 8),

            Text(
              '아직 선택된 사진이 없습니다.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey.shade600,
                  ),
            ),
            const SizedBox(height: 16),

            TextField(
              controller: memoController,
              minLines: 3,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: '메모',
                hintText: '출조 상황, 입질, 채비 등을 기록하세요.',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),

            FilledButton(
              onPressed: saveRecord,
              child: const Text('저장'),
            ),
          ],
        ),
      ),
    );
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

class _DateTimeField extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onTap;

  const _DateTimeField({
    required this.label,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          suffixIcon: const Icon(Icons.calendar_month_outlined),
        ),
        child: Text(value),
      ),
    );
  }
}



class _CatchItemInput {
  final speciesController = TextEditingController();
  final lengthController = TextEditingController();
  final weightController = TextEditingController();

  void dispose() {
    speciesController.dispose();
    lengthController.dispose();
    weightController.dispose();
  }
}

class _CatchItemCard extends StatelessWidget {
  final int index;
  final _CatchItemInput item;
  final VoidCallback onRemove;

  const _CatchItemCard({
    required this.index,
    required this.item,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '조과 ${index + 1}',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ),
                IconButton(
                  onPressed: onRemove,
                  icon: const Icon(Icons.delete_outline),
                  tooltip: '조과 삭제',
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: item.speciesController,
              decoration: const InputDecoration(
                labelText: '어종',
                hintText: '예: 광어',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: item.lengthController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '크기',
                hintText: '예: 45',
                suffixText: 'cm',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: item.weightController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '무게',
                hintText: '예: 1200',
                suffixText: 'g',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}