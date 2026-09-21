import 'package:flutter/material.dart';

import '../../data/services/network_status_service.dart';
import '../auth/login_page.dart';
import '../auth/signup_page.dart';
import 'network_status_widgets.dart';

class OfflineGuestPage extends StatelessWidget {
  final NetworkStatusService? networkStatusService;

  const OfflineGuestPage({super.key, this.networkStatusService});

  @override
  Widget build(BuildContext context) {
    final networkStatus = networkStatusService ?? NetworkStatusService.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('오프라인 모드')),
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    const Spacer(),

                    NetworkStatusSummary(service: networkStatus, iconSize: 72),
                    const SizedBox(height: 12),

                    Text(
                      '비회원은 오프라인 모드에서 사용할 수 있는 기능이 없습니다. '
                      '기록 작성과 조회를 사용하려면 로그인 또는 회원가입이 필요합니다.',
                      style: Theme.of(context).textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),

                    const Spacer(),

                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const LoginPage(),
                            ),
                          );
                        },
                        child: const Text('로그인'),
                      ),
                    ),
                    const SizedBox(height: 12),

                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const SignupPage(),
                            ),
                          );
                        },
                        child: const Text('회원가입'),
                      ),
                    ),
                    const SizedBox(height: 12),

                    NetworkStatusRetryButton(service: networkStatus),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
