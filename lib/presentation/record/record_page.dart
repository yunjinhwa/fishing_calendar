import 'package:flutter/material.dart';

import '../search/record_search_page.dart';

class RecordPage extends StatelessWidget {
  const RecordPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const RecordSearchPage(
      showAppBar: true,
      appBarTitle: '기록',
    );
  }
}