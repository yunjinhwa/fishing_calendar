import 'package:fishing_build/data/models/external_data.dart';
import 'package:fishing_build/presentation/map/weather_data_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final forecast = ExternalData(
    locationName: 'Harbor',
    latitude: 35,
    longitude: 129,
    weather: '맑음',
    airTemperature: 20,
    gridX: 1,
    gridY: 1,
    issuedAt: DateTime.utc(2026, 11, 15, 14, 30),
    validAt: DateTime.utc(2026, 11, 15, 15), // Midnight KST.
    fetchedAt: DateTime.utc(2026, 11, 15, 15, 5),
  );

  test('current forecasts use an exclusive hourly end in every device TZ', () {
    for (final (instant, usable) in [
      (DateTime.utc(2026, 11, 15, 14, 59, 59, 999), false),
      (DateTime.utc(2026, 11, 15, 15), true),
      (DateTime.utc(2026, 11, 15, 15, 59, 59, 999), true),
      (DateTime.utc(2026, 11, 15, 16), false),
    ]) {
      expect(forecast.isUsableAt(instant), usable);
      expect(forecast.isUsableAt(instant.toLocal()), usable);
    }
  });

  testWidgets('a rebuilt current card hides future and expired forecasts', (
    tester,
  ) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    var now = DateTime.utc(2026, 11, 15, 15, 10);
    Widget page() => MaterialApp(
      home: Scaffold(
        body: WeatherDataCard(data: forecast, clock: () => now),
      ),
    );
    await tester.pumpWidget(page());
    expect(find.text('맑음'), findsOneWidget);
    expect(find.text('20℃'), findsOneWidget);

    // A detail/snapshot card must expire without its parent rebuilding.
    now = DateTime.utc(2026, 11, 15, 16);
    await tester.pump(const Duration(minutes: 50));
    expect(find.text('맑음'), findsNothing);
    expect(find.text('20℃'), findsNothing);

    for (final instant in [
      DateTime.utc(2026, 11, 15, 16),
      DateTime.utc(2026, 11, 15, 14, 59),
    ]) {
      now = instant;
      await tester.pumpWidget(page());
      expect(find.text('맑음'), findsNothing);
      expect(find.text('20℃'), findsNothing);
      expect(find.text('제공되지 않음'), findsNWidgets(2));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('a snapshot card rechecks expiry when the app resumes', (
    tester,
  ) async {
    var now = DateTime.utc(2026, 11, 15, 15, 10);
    void change(AppLifecycleState state) =>
        tester.binding.handleAppLifecycleStateChanged(state);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      if (tester.binding.lifecycleState == AppLifecycleState.paused) {
        change(AppLifecycleState.hidden);
      }
      if (tester.binding.lifecycleState == AppLifecycleState.hidden) {
        change(AppLifecycleState.inactive);
      }
      change(AppLifecycleState.resumed);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WeatherDataCard(data: forecast, clock: () => now),
        ),
      ),
    );
    expect(find.text('맑음'), findsOneWidget);
    change(AppLifecycleState.inactive);
    change(AppLifecycleState.hidden);
    change(AppLifecycleState.paused);
    now = DateTime.utc(2026, 11, 15, 16, 10);
    await tester.pump(const Duration(hours: 1));
    change(AppLifecycleState.hidden);
    change(AppLifecycleState.inactive);
    change(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('맑음'), findsNothing);
    expect(find.text('20℃'), findsNothing);
    expect(find.text('제공되지 않음'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
