import 'package:flutter/material.dart';

import '../../data/repositories/auth_session_repository.dart';
import 'login_page.dart';

Future<bool> requireMemberAccess(
  BuildContext context, {
  String message = '로그인 후 사용할 수 있는 기능입니다.',
}) async {
  if (AuthSessionRepository.instance.canManageRecords) {
    return true;
  }

  final shouldLogin = await showDialog<bool>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text('로그인이 필요합니다'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop(false);
            },
            child: const Text('나중에'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop(true);
            },
            child: const Text('로그인'),
          ),
        ],
      );
    },
  );

  if (shouldLogin != true || !context.mounted) {
    return false;
  }

  await Navigator.of(
    context,
    rootNavigator: true,
  ).push(MaterialPageRoute(builder: (_) => const LoginPage()));

  return AuthSessionRepository.instance.canManageRecords;
}
