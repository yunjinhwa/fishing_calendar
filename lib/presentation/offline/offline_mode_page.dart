import 'package:flutter/material.dart';

import '../../data/repositories/auth_session_repository.dart';
import '../../data/services/network_status_service.dart';
import 'offline_free_page.dart';
import 'offline_guest_page.dart';
import 'offline_paid_page.dart';

class OfflineModePage extends StatelessWidget {
  final NetworkStatusService? networkStatusService;

  const OfflineModePage({super.key, this.networkStatusService});

  @override
  Widget build(BuildContext context) {
    final authSession = AuthSessionRepository.instance;

    return AnimatedBuilder(
      animation: authSession,
      builder: (context, _) {
        if (authSession.isPaid) {
          return OfflinePaidPage(networkStatusService: networkStatusService);
        }

        if (authSession.isFree) {
          return OfflineFreePage(networkStatusService: networkStatusService);
        }

        return OfflineGuestPage(networkStatusService: networkStatusService);
      },
    );
  }
}
