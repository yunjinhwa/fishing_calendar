import 'package:flutter/material.dart';

import '../../data/repositories/auth_session_repository.dart';
import 'offline_free_page.dart';
import 'offline_guest_page.dart';
import 'offline_paid_page.dart';

class OfflineModePage extends StatelessWidget {
  const OfflineModePage({super.key});

  @override
  Widget build(BuildContext context) {
    final authSession = AuthSessionRepository.instance;

    return AnimatedBuilder(
      animation: authSession,
      builder: (context, _) {
        if (authSession.isPaid) {
          return const OfflinePaidPage();
        }

        if (authSession.isFree) {
          return const OfflineFreePage();
        }

        return const OfflineGuestPage();
      },
    );
  }
}
