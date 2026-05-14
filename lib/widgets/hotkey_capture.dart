// ignore_for_file: deprecated_member_use

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../shell/hotkey_policy.dart';
import '../theme/wrenflow_theme.dart';

/// Hotkey selector: presets + custom key capture.
class HotkeyCapture extends StatefulWidget {
  const HotkeyCapture({
    super.key,
    required this.policy,
    required this.currentValue,
    required this.onKeySelected,
    this.enabled = true,
  });

  final HotkeyPolicy policy;
  final String currentValue;
  final ValueChanged<String> onKeySelected;
  final bool enabled;

  @override
  State<HotkeyCapture> createState() => _HotkeyCaptureState();
}

class _HotkeyCaptureState extends State<HotkeyCapture> {
  bool _listening = false;
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  bool get _isPreset =>
      widget.policy.presets.any((p) => p.value == widget.currentValue);

  void _startListening() {
    setState(() => _listening = true);
    _focusNode.requestFocus();
  }

  void _onKey(RawKeyEvent event) {
    if (!_listening) return;
    if (event is! RawKeyDownEvent) return;

    final capturedValue = widget.policy.captureValue(event);
    if (capturedValue != null) {
      widget.onKeySelected(capturedValue);
      setState(() => _listening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.policy.supported) {
      return _buildUnsupportedState();
    }

    return Column(
      children: [
        for (final preset in widget.policy.presets) _buildPresetRow(preset),
        _buildCustomRow(),
      ],
    );
  }

  Widget _buildPresetRow(HotkeyPreset preset) {
    final isSelected = widget.currentValue == preset.value;
    return GestureDetector(
      onTap: widget.enabled ? () => widget.onKeySelected(preset.value) : null,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 10),
        margin: const EdgeInsets.only(bottom: 4),
        decoration: BoxDecoration(
          color: isSelected
              ? WrenflowStyle.textOp05
              : CupertinoColors.extraLightBackgroundGray.withAlpha(0),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Row(
          children: [
            Icon(
              isSelected
                  ? CupertinoIcons.checkmark_circle_fill
                  : CupertinoIcons.circle,
              size: 13,
              color: isSelected
                  ? WrenflowStyle.text
                  : WrenflowStyle.textTertiary,
            ),
            const SizedBox(width: 8),
            Text(preset.label, style: WrenflowStyle.body(12)),
          ],
        ),
      ),
    );
  }

  Widget _buildCustomRow() {
    final isCustomSelected = widget.currentValue.isNotEmpty && !_isPreset;
    return RawKeyboardListener(
      focusNode: _focusNode,
      onKey: _onKey,
      child: GestureDetector(
        onTap: !widget.enabled
            ? null
            : () {
                if (isCustomSelected && !_listening) {
                  _startListening();
                } else if (!isCustomSelected) {
                  _startListening();
                }
              },
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 10),
          decoration: BoxDecoration(
            color: isCustomSelected
                ? WrenflowStyle.textOp05
                : CupertinoColors.extraLightBackgroundGray.withAlpha(0),
            borderRadius: BorderRadius.circular(7),
            border: _listening
                ? Border.all(color: WrenflowStyle.textOp50, width: 1)
                : null,
          ),
          child: Row(
            children: [
              Icon(
                isCustomSelected
                    ? CupertinoIcons.checkmark_circle_fill
                    : CupertinoIcons.circle,
                size: 13,
                color: isCustomSelected
                    ? WrenflowStyle.text
                    : WrenflowStyle.textTertiary,
              ),
              const SizedBox(width: 8),
              if (_listening)
                Text(
                  'Press any key...',
                  style: WrenflowStyle.body(
                    12,
                  ).copyWith(color: WrenflowStyle.textOp50),
                )
              else if (isCustomSelected)
                Text(
                  'Custom: ${widget.policy.displayName(widget.currentValue)}',
                  style: WrenflowStyle.body(12),
                )
              else if (!widget.enabled && widget.currentValue.isEmpty)
                Text(
                  'Loading current hotkey...',
                  style: WrenflowStyle.body(
                    12,
                  ).copyWith(color: WrenflowStyle.textTertiary),
                )
              else
                Text('Custom...', style: WrenflowStyle.body(12)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUnsupportedState() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
      decoration: BoxDecoration(
        color: CupertinoColors.extraLightBackgroundGray.withAlpha(0),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        widget.policy.unsupportedMessage ??
            'Global hotkey remapping is unavailable on this platform.',
        style: WrenflowStyle.body(
          12,
        ).copyWith(color: WrenflowStyle.textTertiary),
      ),
    );
  }
}
