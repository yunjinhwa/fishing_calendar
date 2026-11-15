import 'package:fishing_build/presentation/calendar/calendar_month_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('opens on the initial year and month without a day picker', (
    tester,
  ) async {
    DateTime? selected;
    await _openPicker(
      tester,
      initialMonth: DateTime(2026, 11, 16),
      onResult: (result) => selected = result,
    );

    expect(find.text('연·월 선택'), findsOneWidget);
    expect(tester.widget<TextFormField>(_year).controller!.text, '2026');
    expect(tester.widget<ChoiceChip>(_month(11)).selected, isTrue);
    expect(tester.widget<ChoiceChip>(_month(10)).selected, isFalse);
    expect(find.byType(CalendarDatePicker), findsNothing);

    await tester.tap(_confirm);
    await tester.pumpAndSettle();

    expect(selected, DateTime(2026, 11));
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('directly selects a distant year and month', (tester) async {
    DateTime? selected;
    await _openPicker(tester, onResult: (result) => selected = result);

    await tester.enterText(_year, '1742');
    await tester.tap(_month(3));
    await tester.pump();
    expect(tester.widget<ChoiceChip>(_month(3)).selected, isTrue);
    expect(tester.widget<ChoiceChip>(_month(11)).selected, isFalse);
    await tester.tap(_confirm);
    await tester.pumpAndSettle();

    expect(selected, DateTime(1742, 3));
  });

  for (final year in [1, 9999]) {
    testWidgets('accepts supported boundary year $year', (tester) async {
      DateTime? selected;
      await _openPicker(tester, onResult: (result) => selected = result);

      await tester.enterText(_year, '$year');
      await tester.tap(_month(12));
      await tester.tap(_confirm);
      await tester.pumpAndSettle();

      expect(selected, DateTime(year, 12));
    });
  }

  testWidgets('cancel discards the pending selection', (tester) async {
    DateTime? selected = DateTime(2000);
    await _openPicker(tester, onResult: (result) => selected = result);

    await tester.enterText(_year, '1888');
    await tester.tap(_month(4));
    await tester.tap(find.byKey(const ValueKey('calendar-picker-cancel')));
    await tester.pumpAndSettle();

    expect(selected, isNull);
    expect(find.byType(AlertDialog), findsNothing);
  });

  for (final invalidYear in ['', '0', '10000', '-1', '20a6']) {
    testWidgets('rejects invalid year "$invalidYear" without closing', (
      tester,
    ) async {
      var completed = false;
      DateTime? selected;
      await _openPicker(
        tester,
        onResult: (result) {
          completed = true;
          selected = result;
        },
      );

      await tester.enterText(_year, invalidYear);
      await tester.tap(_confirm);
      await tester.pumpAndSettle();

      expect(find.text('1~9999 사이의 연도를 입력해 주세요.'), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.widget<TextFormField>(_year).controller!.text, invalidYear);
      expect(completed, isFalse);
      expect(selected, isNull);

      await tester.enterText(_year, '2001');
      await tester.tap(_confirm);
      await tester.pumpAndSettle();
      expect(completed, isTrue);
      expect(selected, DateTime(2001, 11));
    });
  }

  testWidgets('works at 320 pixels with large text and the keyboard open', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    DateTime? selected;
    await _openPicker(
      tester,
      textScale: 2,
      onResult: (result) => selected = result,
    );

    await tester.tap(_year);
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    await tester.pumpAndSettle();
    await tester.enterText(_year, '1');
    await tester.ensureVisible(_month(12));
    await tester.tap(_month(12));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(tester.getRect(_confirm).bottom, lessThanOrEqualTo(380));
    await tester.tap(_confirm);
    await tester.pumpAndSettle();

    expect(selected, DateTime(1, 12));
    expect(tester.takeException(), isNull);
  });
}

Finder get _year => find.byKey(const ValueKey('calendar-picker-year'));
Finder get _confirm => find.byKey(const ValueKey('calendar-picker-confirm'));
Finder _month(int month) =>
    find.byKey(ValueKey('calendar-picker-month-$month'));

Future<void> _openPicker(
  WidgetTester tester, {
  DateTime? initialMonth,
  double textScale = 1,
  required ValueChanged<DateTime?> onResult,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () async {
                onResult(
                  await showCalendarMonthPicker(
                    context,
                    initialMonth: initialMonth ?? DateTime(2026, 11),
                  ),
                );
              },
              child: const Text('연·월 선택 열기'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('연·월 선택 열기'));
  await tester.pumpAndSettle();
}
