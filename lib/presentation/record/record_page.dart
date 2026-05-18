import 'package:flutter/material.dart';

import '../common/placeholder_screen.dart';

class RecordPage extends StatelessWidget {
  const RecordPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderScreen(
      title: '기록',
      icon: Icons.add_circle_outline,
      description: '출조 기록 작성 화면은 다음 단계에서 만듭니다.',
    );
  }
}