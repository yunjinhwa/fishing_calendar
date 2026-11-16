import 'package:fishing_build/presentation/calendar/calendar_today_summary.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('calendar summary retains the original card design', (
    tester,
  ) async {
    await _open(tester, onPressed: () {});
    expect(find.text('오늘의 요약'), findsOneWidget);
    expect(find.byType(Card), findsOneWidget);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.byIcon(Icons.waves_outlined), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    expect(find.text('오늘의 출조 기록을 확인할 수 있습니다.'), findsOneWidget);
    expect(find.textContaining('출조 0건'), findsNothing);
    expect(find.text('기록 작성'), findsNothing);
    expect(find.byType(SingleChildScrollView), findsNothing);
    expect(tester.getSize(_button).height, greaterThanOrEqualTo(48));
  });

  testWidgets('summary button calls the supplied action', (tester) async {
    var opened = 0;
    await _open(tester, onPressed: () => opened++);
    await tester.tap(_button);
    expect(opened, 1);
  });

  testWidgets('null action disables the summary button', (tester) async {
    await _open(tester);
    expect(tester.widget<InkWell>(_button).onTap, isNull);
    await tester.tap(_button);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow summary button supports large text', (tester) async {
    var opened = 0;
    await _open(tester, width: 320, textScale: 2, onPressed: () => opened++);
    expect(tester.takeException(), isNull);
    expect(_button.hitTestable(), findsOneWidget);
    await tester.tap(_button);
    expect(opened, 1);
    expect(tester.takeException(), isNull);
  });
}

Finder get _button => find.byKey(const ValueKey('calendar-today-open'));

Future<void> _open(
  WidgetTester tester, {
  VoidCallback? onPressed,
  double width = 600,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: CalendarTodaySummary(onPressed: onPressed),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
