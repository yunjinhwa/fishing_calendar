import 'package:flutter/material.dart';

import '../../data/models/user_plan_policy.dart';
import '../../data/repositories/auth_session_repository.dart';
import '../plan/plan_page.dart';
import 'login_page.dart';
import 'signup_page.dart';

enum _AuthChoice { login, signup }

Future<bool> requireAccess(
  BuildContext context,
  UserCapability capability, {
  String memberMessage = '로그인 후 사용할 수 있는 기능입니다.',
  String paidMessage = '유료 플랜에서 사용할 수 있는 기능입니다.',
  WidgetBuilder? migrationDestinationBuilder,
}) async {
  final authSession = AuthSessionRepository.instance;
  if (authSession.allows(capability)) {
    return true;
  }

  if (authSession.isGuest) {
    final authenticated = await _requestAuthentication(
      context,
      message: memberMessage,
    );
    if (!authenticated || !context.mounted) {
      return false;
    }

    if (authSession.allows(capability)) {
      return true;
    }
  }

  if (authSession.isPaid && authSession.isPlanMigrationPending) {
    return _requestMigrationCompletion(
      context,
      capability: capability,
      destinationBuilder: migrationDestinationBuilder,
    );
  }

  return _requestPaidPlan(
    context,
    capability: capability,
    message: paidMessage,
  );
}

Future<bool> requireMemberAccess(
  BuildContext context, {
  String message = '로그인 후 사용할 수 있는 기능입니다.',
}) {
  return requireAccess(
    context,
    UserCapability.manageRecords,
    memberMessage: message,
  );
}

Future<bool> requirePaidAccess(
  BuildContext context, {
  String message = '클라우드 동기화는 유료 플랜에서 사용할 수 있습니다.',
  WidgetBuilder? migrationDestinationBuilder,
}) {
  return requireAccess(
    context,
    UserCapability.cloudSync,
    memberMessage: '로그인 후 사용할 수 있는 기능입니다.',
    paidMessage: message,
    migrationDestinationBuilder: migrationDestinationBuilder,
  );
}

Future<bool> requireOutboxAccess(
  BuildContext context, {
  String message = '업로드 대기열은 유료 플랜에서 사용할 수 있습니다.',
}) {
  return requireAccess(
    context,
    UserCapability.outbox,
    memberMessage: '로그인 후 사용할 수 있는 기능입니다.',
    paidMessage: message,
  );
}

Future<bool> _requestAuthentication(
  BuildContext context, {
  required String message,
}) async {
  final choice = await showDialog<_AuthChoice>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text('로그인이 필요합니다'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('나중에'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.of(context).pop(_AuthChoice.signup),
            child: const Text('회원가입'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(_AuthChoice.login),
            child: const Text('로그인'),
          ),
        ],
      );
    },
  );

  if (choice == null || !context.mounted) {
    return false;
  }

  final authenticated = await Navigator.of(context, rootNavigator: true)
      .push<bool>(
        MaterialPageRoute(
          builder: (_) => choice == _AuthChoice.login
              ? const LoginPage(returnToPrevious: true)
              : const SignupPage(returnToPrevious: true),
        ),
      );

  return authenticated == true && AuthSessionRepository.instance.isMember;
}

Future<bool> _requestPaidPlan(
  BuildContext context, {
  required UserCapability capability,
  required String message,
}) async {
  final shouldOpenPlan = await showDialog<bool>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text('유료 플랜이 필요합니다'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('나중에'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('플랜 보기'),
          ),
        ],
      );
    },
  );

  if (shouldOpenPlan != true || !context.mounted) {
    return false;
  }

  await Navigator.of(
    context,
    rootNavigator: true,
  ).push(MaterialPageRoute(builder: (_) => const PlanPage()));

  return AuthSessionRepository.instance.allows(capability);
}

Future<bool> _requestMigrationCompletion(
  BuildContext context, {
  required UserCapability capability,
  WidgetBuilder? destinationBuilder,
}) async {
  final openQueue = await showDialog<bool>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text('기존 기록 이전이 필요합니다'),
        content: const Text('업로드 대기열에서 기존 기록을 모두 처리하면 동기화 기능을 사용할 수 있습니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('나중에'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(destinationBuilder == null ? '확인' : '대기열 보기'),
          ),
        ],
      );
    },
  );

  if (openQueue == true && destinationBuilder != null && context.mounted) {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: destinationBuilder));
  }

  return AuthSessionRepository.instance.allows(capability);
}

class PaidFeatureGate extends StatelessWidget {
  final String title;
  final String message;
  final UserCapability capability;
  final WidgetBuilder? migrationDestinationBuilder;
  final Widget child;

  const PaidFeatureGate({
    super.key,
    required this.title,
    required this.message,
    this.capability = UserCapability.cloudSync,
    this.migrationDestinationBuilder,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final authSession = AuthSessionRepository.instance;

    return AnimatedBuilder(
      animation: authSession,
      builder: (context, _) {
        if (authSession.allows(capability)) {
          return child;
        }

        final migrationPending =
            authSession.isPaid && authSession.isPlanMigrationPending;

        return Scaffold(
          appBar: AppBar(title: Text(title)),
          body: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.lock_outline,
                      size: 64,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      authSession.isGuest
                          ? '로그인이 필요합니다'
                          : migrationPending
                          ? '기존 기록 이전이 필요합니다'
                          : '유료 플랜이 필요합니다',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      migrationPending
                          ? '업로드 대기열에서 기존 기록을 모두 처리해 주세요.'
                          : message,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: () {
                        final migrationDestination =
                            migrationPending &&
                                migrationDestinationBuilder != null
                            ? migrationDestinationBuilder!(context)
                            : null;
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                migrationDestination ??
                                (authSession.isGuest
                                    ? const LoginPage(returnToPrevious: true)
                                    : const PlanPage()),
                          ),
                        );
                      },
                      child: Text(
                        authSession.isGuest
                            ? '로그인'
                            : migrationPending &&
                                  migrationDestinationBuilder != null
                            ? '대기열 보기'
                            : '플랜 보기',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
