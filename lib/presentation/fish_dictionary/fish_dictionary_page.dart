import 'package:flutter/material.dart';

import '../common/placeholder_screen.dart';

class FishDictionaryPage extends StatelessWidget {
  const FishDictionaryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderScreen(
      title: '도감',
      icon: Icons.menu_book_outlined,
      description: '어류도감 화면은 다음 단계에서 만듭니다.',
    );
  }
}