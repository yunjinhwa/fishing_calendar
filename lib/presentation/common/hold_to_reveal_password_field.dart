import 'package:flutter/material.dart';

class HoldToRevealPasswordField extends StatefulWidget {
  final TextEditingController controller;
  final InputDecoration decoration;
  final bool enabled;
  final Iterable<String>? autofillHints;
  final FocusNode? focusNode;
  final bool autofocus;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;

  const HoldToRevealPasswordField({
    super.key,
    required this.controller,
    required this.decoration,
    this.enabled = true,
    this.autofillHints,
    this.focusNode,
    this.autofocus = false,
    this.textInputAction,
    this.onSubmitted,
  });

  @override
  State<HoldToRevealPasswordField> createState() =>
      _HoldToRevealPasswordFieldState();
}

class _HoldToRevealPasswordFieldState extends State<HoldToRevealPasswordField> {
  final Set<int> _activePointers = <int>{};

  bool get _isRevealed => _activePointers.isNotEmpty;

  @override
  void didUpdateWidget(HoldToRevealPasswordField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _isRevealed) {
      _activePointers.clear();
    }
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (!widget.enabled || !_activePointers.add(event.pointer)) {
      return;
    }
    setState(() {});
  }

  void _handlePointerEnd(PointerEvent event) {
    if (!_activePointers.remove(event.pointer)) {
      return;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      enabled: widget.enabled,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      keyboardType: TextInputType.visiblePassword,
      textInputAction: widget.textInputAction,
      obscureText: !_isRevealed,
      autocorrect: false,
      enableSuggestions: false,
      autofillHints: widget.autofillHints,
      onSubmitted: widget.onSubmitted,
      decoration: widget.decoration.copyWith(
        suffixIcon: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onLongPressStart: widget.enabled ? (_) {} : null,
          child: Listener(
            onPointerDown: widget.enabled ? _handlePointerDown : null,
            onPointerUp: widget.enabled ? _handlePointerEnd : null,
            onPointerCancel: widget.enabled ? _handlePointerEnd : null,
            child: Tooltip(
              message: '누르고 있는 동안 비밀번호 표시',
              triggerMode: TooltipTriggerMode.manual,
              child: IconButton(
                onPressed: widget.enabled ? () {} : null,
                icon: Icon(
                  _isRevealed
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
