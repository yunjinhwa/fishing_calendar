import 'package:flutter/material.dart';

import '../common/placeholder_screen.dart';

class MyPage extends StatelessWidget {
  const MyPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderScreen(
      title: '내정보',
      icon: Icons.person_outline,
      description: '내정보 화면은 다음 단계에서 만듭니다.',
    );
  }
}