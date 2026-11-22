import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../data/services/network_status_service.dart';
import '../common/top_card_notification.dart';

class NetworkStatusSummary extends StatelessWidget {
  final NetworkStatusService service;
  final double iconSize;
  final bool compact;

  const NetworkStatusSummary({
    super.key,
    required this.service,
    this.iconSize = 64,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) {
        final presentation = _presentationFor(context, service);
        final text = Theme.of(context).textTheme;
        if (compact) {
          return Card(
            color: AppTheme.coolGray,
            child: ListTile(
              leading: Icon(presentation.icon, color: presentation.color),
              title: Text(
                presentation.title,
                style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(presentation.description),
            ),
          );
        }
        return Column(
          children: [
            DecoratedBox(
              decoration: const BoxDecoration(
                color: AppTheme.coolGray,
                shape: BoxShape.circle,
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Icon(
                  presentation.icon,
                  size: iconSize,
                  color: presentation.color,
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              presentation.title,
              style: text.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              presentation.description,
              style: text.bodyMedium?.copyWith(color: AppTheme.muted),
              textAlign: TextAlign.center,
            ),
          ],
        );
      },
    );
  }

  _NetworkStatusPresentation _presentationFor(
    BuildContext context,
    NetworkStatusService service,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    if (service.isChecking) {
      return _NetworkStatusPresentation(
        icon: Icons.cloud_sync_outlined,
        color: colorScheme.primary,
        title: '네트워크 상태를 확인하는 중입니다',
        description: '현재 연결 상태를 확인하고 있습니다.',
      );
    }

    switch (service.status) {
      case NetworkStatus.connected:
        return _NetworkStatusPresentation(
          icon: Icons.cloud_done_outlined,
          color: colorScheme.primary,
          title: '네트워크에 연결되어 있습니다',
          description: 'Wi-Fi 또는 모바일 네트워크 연결이 감지되었습니다.',
        );
      case NetworkStatus.disconnected:
        return _NetworkStatusPresentation(
          icon: Icons.cloud_off_outlined,
          color: colorScheme.error,
          title: '오프라인 상태입니다',
          description: '사용할 수 있는 네트워크 연결이 감지되지 않았습니다.',
        );
      case NetworkStatus.unknown:
        return _NetworkStatusPresentation(
          icon: Icons.cloud_sync_outlined,
          color: colorScheme.outline,
          title: '네트워크 상태를 확인할 수 없습니다',
          description: service.lastError == null
              ? '다시 시도하여 현재 연결 상태를 확인해 주세요.'
              : '상태 확인 중 오류가 발생했습니다. 잠시 후 다시 시도해 주세요.',
        );
    }
  }
}

class NetworkStatusRetryButton extends StatelessWidget {
  final NetworkStatusService service;

  const NetworkStatusRetryButton({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) {
        return TextButton.icon(
          onPressed: service.isChecking
              ? null
              : () => _refreshNetworkStatus(context),
          icon: service.isChecking
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
          label: const Text('다시 시도'),
        );
      },
    );
  }

  Future<void> _refreshNetworkStatus(BuildContext context) async {
    if (service.isInitialized) {
      await service.refresh();
    } else {
      await service.initialize();
    }
    if (!context.mounted) {
      return;
    }

    final message = switch (service.status) {
      NetworkStatus.connected => '네트워크 연결이 확인되었습니다.',
      NetworkStatus.disconnected => '네트워크 연결을 찾지 못했습니다.',
      NetworkStatus.unknown => '네트워크 상태를 확인하지 못했습니다.',
    };
    TopCardNotification.show(
      context,
      message,
      type: service.status == NetworkStatus.connected
          ? TopCardNotificationType.success
          : TopCardNotificationType.warning,
    );
  }
}

class _NetworkStatusPresentation {
  final IconData icon;
  final Color color;
  final String title;
  final String description;

  const _NetworkStatusPresentation({
    required this.icon,
    required this.color,
    required this.title,
    required this.description,
  });
}
