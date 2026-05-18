import 'package:flutter/material.dart';

import '../common/placeholder_screen.dart';

class MapPage extends StatelessWidget {
  const MapPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderScreen(
      title: '지도',
      icon: Icons.map_outlined,
      description: '지도 화면은 다음 단계에서 만듭니다.',
    );
  }
}