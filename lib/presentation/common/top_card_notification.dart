import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

enum TopCardNotificationType { info, success, warning, error }

/// One floating, non-modal notice per root overlay. No application host needed.
class TopCardNotification extends StatefulWidget {
  const TopCardNotification._({
    required _NoticeController controller,
    required this.revision,
    required this.message,
    required this.type,
    required this.duration,
    required this.sourceRoute,
  }) : _controller = controller;

  static final _controllers = Expando<_NoticeController>();
  static final _active = <_NoticeController>{};

  static void show(
    BuildContext context,
    String message, {
    TopCardNotificationType type = TopCardNotificationType.info,
    Duration duration = const Duration(seconds: 4),
    bool persistAfterPop = false,
  }) {
    if (!context.mounted || message.trim().isEmpty) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    final scope = context
        .getInheritedWidgetOfExactType<TopCardNotificationScope>();
    if (scope != null && (!scope.canShow || scope.route?.isCurrent == false)) {
      return;
    }
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null || !overlay.mounted) return;
    final controller = _controllers[overlay] ??= _NoticeController(overlay);
    controller.show(message, type, duration, route, persistAfterPop);
  }

  static void dismiss(BuildContext context) {
    if (!context.mounted) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay != null) _controllers[overlay]?.dismiss();
  }

  static void dismissAll() {
    for (final controller in _active.toList()) {
      controller.dismiss();
    }
  }

  final _NoticeController _controller;
  final int revision;
  final String message;
  final TopCardNotificationType type;
  final Duration duration;
  final ModalRoute<dynamic>? sourceRoute;

  @override
  State<TopCardNotification> createState() => _TopCardNotificationState();
}

/// Prevents delayed actions on an offstage tab from showing a new notice.
class TopCardNotificationScope extends InheritedWidget {
  const TopCardNotificationScope({
    super.key,
    required this.enabled,
    required this.route,
    this.isActive,
    required super.child,
  });

  final bool enabled;
  final ModalRoute<dynamic>? route;
  final bool Function()? isActive;

  bool get canShow => enabled && (isActive?.call() ?? true);

  @override
  bool updateShouldNotify(TopCardNotificationScope oldWidget) =>
      oldWidget.enabled != enabled ||
      oldWidget.route != route ||
      oldWidget.isActive != isActive;
}

/// Each Navigator must have its own observer instance.
class TopCardNotificationObserver extends NavigatorObserver {
  OverlayState? get _rootOverlay {
    final nav = navigator;
    if (nav == null || !nav.mounted) return null;
    return Overlay.maybeOf(nav.context, rootOverlay: true) ?? nav.overlay;
  }

  void _clear({Route<dynamic>? popped, Route<dynamic>? previous}) {
    final overlay = _rootOverlay;
    for (final controller in TopCardNotification._active.toList()) {
      if (controller.overlay != overlay) continue;
      if (popped != null &&
          previous != null &&
          identical(controller.route, popped) &&
          controller.persistAfterPop) {
        controller.route = previous;
        controller.persistAfterPop = false;
      } else {
        controller.dismiss();
      }
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _clear();

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _clear(popped: route, previous: previousRoute);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _clear();

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _clear();
}

class _NoticeController {
  _NoticeController(this.overlay);

  final OverlayState overlay;
  OverlayEntry? _entry;
  Route<dynamic>? route;
  bool persistAfterPop = false;
  int _revision = 0;

  void show(
    String message,
    TopCardNotificationType type,
    Duration duration,
    ModalRoute<dynamic>? sourceRoute,
    bool persist,
  ) {
    dismiss();
    route = sourceRoute;
    persistAfterPop = persist;
    final revision = ++_revision;
    _entry = OverlayEntry(
      builder: (_) => TopCardNotification._(
        controller: this,
        revision: revision,
        message: message,
        type: type,
        duration: duration,
        sourceRoute: sourceRoute,
      ),
    );
    TopCardNotification._active.add(this);
    overlay.insert(_entry!);
  }

  void dismiss([int? revision]) {
    if (revision != null && revision != _revision) return;
    final entry = _entry;
    _entry = null;
    route = null;
    persistAfterPop = false;
    TopCardNotification._active.remove(this);
    entry?.remove();
    entry?.dispose();
  }

  void viewDisposed(int revision) {
    if (revision != _revision || _entry == null) return;
    // The overlay can itself be unmounting: do not mark its locked tree dirty.
    final entry = _entry!;
    _entry = null;
    route = null;
    persistAfterPop = false;
    TopCardNotification._active.remove(this);
    scheduleMicrotask(() {
      entry.remove();
      entry.dispose();
    });
  }
}

class _TopCardNotificationState extends State<TopCardNotification>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool? _accessibleNavigation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.sourceRoute?.animation?.addStatusListener(_onRouteAnimation);
    widget.sourceRoute?.secondaryAnimation?.addStatusListener(
      _onCoverAnimation,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final accessible = MediaQuery.accessibleNavigationOf(context);
    if (_accessibleNavigation == accessible) return;
    _accessibleNavigation = accessible;
    _timer?.cancel();
    if (!accessible) {
      _timer = Timer(widget.duration, _dismiss);
    }
  }

  void _dismiss() => widget._controller.dismiss(widget.revision);

  // Animation listeners also clean up standalone MaterialApp callers without
  // our observer; production uses observers for replace/remove/dialog changes.
  void _onRouteAnimation(AnimationStatus status) {
    if (!identical(widget._controller.route, widget.sourceRoute)) return;
    if (status == AnimationStatus.reverse &&
        !widget._controller.persistAfterPop) {
      _dismiss();
    } else if (status == AnimationStatus.dismissed) {
      if (widget._controller.persistAfterPop) {
        widget._controller.route = null;
        widget._controller.persistAfterPop = false;
      } else {
        _dismiss();
      }
    }
  }

  void _onCoverAnimation(AnimationStatus status) {
    if (status == AnimationStatus.forward ||
        status == AnimationStatus.completed) {
      _dismiss();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _dismiss();
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.sourceRoute?.animation?.removeStatusListener(_onRouteAnimation);
    widget.sourceRoute?.secondaryAnimation?.removeStatusListener(
      _onCoverAnimation,
    );
    widget._controller.viewDisposed(widget.revision);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    var top = media.viewPadding.top + kToolbarHeight + 8;
    final bottom =
        math.max(media.viewInsets.bottom, media.viewPadding.bottom) + 8;
    if (media.size.height - top - bottom < 96) top = media.viewPadding.top + 8;
    final available = math.max(0.0, media.size.height - top - bottom);
    if (available < 56) return const SizedBox.shrink();
    final cap = math.min(available, math.max(120.0, media.size.height * 0.4));
    final seed = switch (widget.type) {
      TopCardNotificationType.info => Colors.blue,
      TopCardNotificationType.success => Colors.green,
      TopCardNotificationType.warning => Colors.orange,
      TopCardNotificationType.error => Colors.red,
    };
    final colors = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Theme.of(context).brightness,
    );
    final icon = switch (widget.type) {
      TopCardNotificationType.info => Icons.info_outline,
      TopCardNotificationType.success => Icons.check_circle_outline,
      TopCardNotificationType.warning => Icons.warning_amber_rounded,
      TopCardNotificationType.error => Icons.error_outline,
    };
    return Positioned(
      top: top,
      left: math.max(16.0, media.viewPadding.left + 8),
      right: math.max(16.0, media.viewPadding.right + 8),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 600,
            minHeight: 56,
            maxHeight: cap,
          ),
          child: Semantics(
            container: true,
            liveRegion: true,
            child: Card(
              key: const ValueKey('top-card-notification'),
              margin: EdgeInsets.zero,
              elevation: 6,
              color: colors.primaryContainer,
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 56, 16),
                    child: SingleChildScrollView(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ExcludeSemantics(
                            child: Icon(icon, color: colors.onPrimaryContainer),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              widget.message,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: colors.onPrimaryContainer,
                                    height: 1.4,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: IconButton(
                      tooltip: '알림 닫기',
                      color: colors.onPrimaryContainer,
                      onPressed: _dismiss,
                      icon: const Icon(Icons.close),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
