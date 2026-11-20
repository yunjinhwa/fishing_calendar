import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../data/services/app_startup_controller.dart';
import '../../data/services/record_sync_service.dart';

/// Mounts the normal app only after the required data preparation succeeds.
class StartupGate extends StatefulWidget {
  const StartupGate({
    super.key,
    required this.child,
    this.controller,
    this.onReady,
  });
  final Widget child;
  final AppStartupController? controller;
  final VoidCallback? onReady;

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  late final AppStartupController _controller;
  late final bool _ownsController;
  late AppStartupState _visibleState;
  late final ThemeData _startupTheme = AppTheme.lightTheme;
  bool _readyScheduled = false;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? AppStartupController.production();
    _ownsController = widget.controller == null;
    _visibleState = _controller.state;
    _controller.addListener(_onChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_controller.state == AppStartupState.ready) {
        _onChanged();
      } else {
        unawaited(_controller.start());
      }
    });
  }

  void _onChanged() {
    if (!mounted) return;
    if (_visibleState != _controller.state) {
      _visibleState = _controller.state;
      setState(() {});
    }
    if (_controller.state == AppStartupState.ready && !_readyScheduled) {
      _readyScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final onReady = widget.onReady;
        if (onReady != null) {
          onReady();
        } else {
          unawaited(RecordSyncService.instance.syncNow());
        }
      });
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller.state == AppStartupState.ready) return widget.child;
    final failed = _controller.state == AppStartupState.failed;
    final stage = _controller.stage ?? AppStartupStage.storage;
    return MaterialApp(
      title: 'Fishing Build',
      debugShowCheckedModeBanner: false,
      theme: _startupTheme,
      home: Scaffold(
        body: SafeArea(
          child: failed
              ? Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(32),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.error_outline, size: 48),
                          const SizedBox(height: 24),
                          const Text(
                            '앱을 시작하지 못했습니다.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '${stage.failureMessage}\n저장 공간을 확인한 뒤 다시 시도해 주세요.',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            '다시 시도해도 저장된 기록과 사진은 초기화하지 않습니다.',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 24),
                          FilledButton(
                            key: const ValueKey('startup-retry'),
                            onPressed: () => unawaited(_controller.start()),
                            child: const Text('다시 시도'),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              : const _StartupSplash(),
        ),
      ),
    );
  }
}

class _StartupSplash extends StatelessWidget {
  const _StartupSplash();

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.phishing,
            size: 72,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 24),
          const Text(
            '낚시 캘린더',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 32),
          const SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              semanticsLabel: '앱을 준비하고 있습니다.',
            ),
          ),
        ],
      ),
    ),
  );
}
