import 'package:flutter/material.dart';
import 'presentation/calendar/calendar_page.dart';

class FishingBuildApp extends StatelessWidget {
  const FishingBuildApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fishing Build',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF2563EB),
      ),
      home: const CalendarPage(),
    );
  }
}
