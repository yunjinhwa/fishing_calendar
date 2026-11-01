import 'package:flutter/material.dart';

import '../search/record_search_page.dart';

class RecordPage extends StatelessWidget {
  const RecordPage({super.key, this.isActive = true});

  final bool isActive;

  @override
  Widget build(BuildContext context) {
    return RecordSearchPage(
      isActive: isActive,
      showAppBar: true,
      appBarTitle: '기록',
    );
  }
}
