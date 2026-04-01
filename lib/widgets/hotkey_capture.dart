import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../theme/wrenflow_theme.dart';

/// Platform-specific hotkey presets.
class HotkeyPreset {
  const HotkeyPreset(this.value, this.label);

  /// Value stored in prefs — keycode string for macOS, name for others.
  final String value;

  /// Human-readable label.
  final String label;
}

/// macOS presets (keycode-based).
const _macPresets = [
  HotkeyPreset('63', 'Fn'),
  HotkeyPreset('61', 'Right Option'),
  HotkeyPreset('96', 'F5'),
];

List<HotkeyPreset> get platformPresets {
  if (Platform.isMacOS) return _macPresets;
  // Add Windows/Linux presets here later.
  return _macPresets;
}

/// Known macOS keycodes → human-readable names.
const _keycodeNames = <int, String>{
  // Modifier keys
  54: 'Right Command',
  55: 'Left Command',
  56: 'Left Shift',
  57: 'Caps Lock',
  58: 'Left Option',
  59: 'Left Control',
  60: 'Right Shift',
  61: 'Right Option',
  62: 'Right Control',
  63: 'Fn',
  // Function keys
  96: 'F5',
  97: 'F6',
  98: 'F7',
  99: 'F3',
  100: 'F8',
  101: 'F9',
  103: 'F11',
  105: 'F13',
  107: 'F14',
  109: 'F10',
  111: 'F12',
  113: 'F15',
  118: 'F4',
  120: 'F2',
  122: 'F1',
  // Special
  36: 'Return',
  48: 'Tab',
  49: 'Space',
  51: 'Delete',
  53: 'Escape',
  117: 'Forward Delete',
};

/// Convert a hotkey value to display name.
String hotkeyDisplayName(String value) {
  final code = int.tryParse(value);
  if (code != null) {
    return _keycodeNames[code] ?? 'Key $code';
  }
  // Legacy name mapping.
  return switch (value) {
    'fn' || 'fnKey' => 'Fn',
    'rightOption' => 'Right Option',
    'f5' => 'F5',
    _ => value,
  };
}

/// Hotkey selector: presets + custom key capture.
class HotkeyCapture extends StatefulWidget {
  const HotkeyCapture({
    super.key,
    required this.currentValue,
    required this.onKeySelected,
  });

  final String currentValue;
  final ValueChanged<String> onKeySelected;

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
      platformPresets.any((p) => p.value == widget.currentValue);

  void _startListening() {
    setState(() => _listening = true);
    _focusNode.requestFocus();
  }

  void _onKey(KeyEvent event) {
    if (!_listening) return;
    if (event is! KeyDownEvent) return;

    final macKeycode = _flutterToMacKeycode(event);
    if (macKeycode != null) {
      widget.onKeySelected(macKeycode.toString());
      setState(() => _listening = false);
    }
  }

  int? _flutterToMacKeycode(KeyEvent event) {
    return _physicalToMacKeycode[event.physicalKey];
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Presets
        for (final preset in platformPresets) _buildPresetRow(preset),
        // Custom
        _buildCustomRow(),
      ],
    );
  }

  Widget _buildPresetRow(HotkeyPreset preset) {
    final isSelected = widget.currentValue == preset.value;
    return GestureDetector(
      onTap: () => widget.onKeySelected(preset.value),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 10),
        margin: const EdgeInsets.only(bottom: 4),
        decoration: BoxDecoration(
          color: isSelected ? WrenflowStyle.textOp05 : CupertinoColors.extraLightBackgroundGray.withAlpha(0),
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
    final isCustomSelected = !_isPreset;
    return KeyboardListener(
      focusNode: _focusNode,
      onKeyEvent: _onKey,
      child: GestureDetector(
        onTap: () {
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
            color: isCustomSelected ? WrenflowStyle.textOp05 : CupertinoColors.extraLightBackgroundGray.withAlpha(0),
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
                Text('Press any key...',
                    style: WrenflowStyle.body(12)
                        .copyWith(color: WrenflowStyle.textOp50))
              else if (isCustomSelected)
                Text(
                    'Custom: ${hotkeyDisplayName(widget.currentValue)}',
                    style: WrenflowStyle.body(12))
              else
                Text('Custom...', style: WrenflowStyle.body(12)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Flutter PhysicalKeyboardKey → macOS virtual keycode.
final _physicalToMacKeycode = <PhysicalKeyboardKey, int>{
  PhysicalKeyboardKey.fn: 63,
  PhysicalKeyboardKey.capsLock: 57,
  PhysicalKeyboardKey.shiftLeft: 56,
  PhysicalKeyboardKey.shiftRight: 60,
  PhysicalKeyboardKey.controlLeft: 59,
  PhysicalKeyboardKey.controlRight: 62,
  PhysicalKeyboardKey.altLeft: 58,
  PhysicalKeyboardKey.altRight: 61,
  PhysicalKeyboardKey.metaLeft: 55,
  PhysicalKeyboardKey.metaRight: 54,
  PhysicalKeyboardKey.f1: 122,
  PhysicalKeyboardKey.f2: 120,
  PhysicalKeyboardKey.f3: 99,
  PhysicalKeyboardKey.f4: 118,
  PhysicalKeyboardKey.f5: 96,
  PhysicalKeyboardKey.f6: 97,
  PhysicalKeyboardKey.f7: 98,
  PhysicalKeyboardKey.f8: 100,
  PhysicalKeyboardKey.f9: 101,
  PhysicalKeyboardKey.f10: 109,
  PhysicalKeyboardKey.f11: 103,
  PhysicalKeyboardKey.f12: 111,
  PhysicalKeyboardKey.f13: 105,
  PhysicalKeyboardKey.f14: 107,
  PhysicalKeyboardKey.f15: 113,
  PhysicalKeyboardKey.escape: 53,
  PhysicalKeyboardKey.tab: 48,
  PhysicalKeyboardKey.space: 49,
  PhysicalKeyboardKey.enter: 36,
  PhysicalKeyboardKey.backspace: 51,
  PhysicalKeyboardKey.delete: 117,
};
