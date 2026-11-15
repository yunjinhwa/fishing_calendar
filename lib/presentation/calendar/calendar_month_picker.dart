import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Lets the user choose a calendar month without selecting a day.
Future<DateTime?> showCalendarMonthPicker(
  BuildContext context, {
  required DateTime initialMonth,
}) {
  assert(initialMonth.year >= 1 && initialMonth.year <= 9999);
  return showDialog<DateTime>(
    context: context,
    builder: (_) => _CalendarMonthPicker(initialMonth: initialMonth),
  );
}

class _CalendarMonthPicker extends StatefulWidget {
  const _CalendarMonthPicker({required this.initialMonth});

  final DateTime initialMonth;

  @override
  State<_CalendarMonthPicker> createState() => _CalendarMonthPickerState();
}

class _CalendarMonthPickerState extends State<_CalendarMonthPicker> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _yearController;
  late int _selectedMonth;

  @override
  void initState() {
    super.initState();
    _yearController = TextEditingController(
      text: widget.initialMonth.year.toString(),
    );
    _selectedMonth = widget.initialMonth.month;
  }

  @override
  void dispose() {
    _yearController.dispose();
    super.dispose();
  }

  String? _validateYear(String? value) {
    if (value == null || !RegExp(r'^[0-9]{1,4}$').hasMatch(value)) {
      return '1~9999 사이의 연도를 입력해 주세요.';
    }
    final year = int.tryParse(value);
    if (year == null || year < 1 || year > 9999) {
      return '1~9999 사이의 연도를 입력해 주세요.';
    }
    return null;
  }

  void _confirm() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(
      context,
    ).pop(DateTime(int.parse(_yearController.text), _selectedMonth));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Measure outside AlertDialog, whose content uses intrinsic sizing.
        final contentWidth = math.min(
          320.0,
          math.max(0.0, constraints.maxWidth - 80),
        );
        return _buildDialog(context, contentWidth);
      },
    );
  }

  Widget _buildDialog(BuildContext context, double contentWidth) {
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final columns = math.max(
      1,
      math.min(4, ((contentWidth + 8) / (40 * textScale + 40)).floor()),
    );
    final monthWidth = (contentWidth - (columns - 1) * 8) / columns;
    return AlertDialog(
      title: const Text('연·월 선택'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      scrollable: true,
      content: SizedBox(
        width: contentWidth,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                key: const ValueKey('calendar-picker-year'),
                controller: _yearController,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                maxLength: 4,
                // Keep invalid input visible so confirmation can reject it.
                maxLengthEnforcement: MaxLengthEnforcement.none,
                decoration: const InputDecoration(
                  labelText: '연도',
                  helperText: '1~9999년',
                  errorMaxLines: 3,
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
                autovalidateMode: AutovalidateMode.onUserInteraction,
                validator: _validateYear,
                onFieldSubmitted: (_) => _confirm(),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var month = 1; month <= 12; month++)
                    SizedBox(
                      width: monthWidth,
                      child: ChoiceChip(
                        key: ValueKey('calendar-picker-month-$month'),
                        selected: _selectedMonth == month,
                        showCheckmark: false,
                        label: Center(child: Text('$month월')),
                        materialTapTargetSize: MaterialTapTargetSize.padded,
                        onSelected: (_) {
                          setState(() => _selectedMonth = month);
                        },
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('calendar-picker-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const ValueKey('calendar-picker-confirm'),
          onPressed: _confirm,
          child: const Text('이동'),
        ),
      ],
    );
  }
}
