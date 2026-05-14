// ignore_for_file: deprecated_member_use

import 'dart:io';

import 'package:flutter/services.dart';

class HotkeyPreset {
  const HotkeyPreset(this.value, this.label);

  final String value;
  final String label;
}

class HotkeyPolicy {
  const HotkeyPolicy({
    required this.presets,
    required this.displayName,
    required this.captureValue,
  });

  final List<HotkeyPreset> presets;
  final String Function(String value) displayName;
  final String? Function(RawKeyEvent event) captureValue;
}

const _macPresets = [
  HotkeyPreset('63', 'Fn'),
  HotkeyPreset('61', 'Right Option'),
  HotkeyPreset('96', 'F5'),
];

const _macKeycodeNames = <int, String>{
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
  36: 'Return',
  48: 'Tab',
  49: 'Space',
  51: 'Delete',
  53: 'Escape',
  117: 'Forward Delete',
};

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

String _macDisplayName(String value) {
  final code = int.tryParse(value);
  if (code != null) {
    return _macKeycodeNames[code] ?? 'Key $code';
  }

  return switch (value) {
    'fn' || 'fnKey' => 'Fn',
    'rightOption' => 'Right Option',
    'rightCommand' => 'Right Command',
    'leftCommand' => 'Left Command',
    'f5' => 'F5',
    _ => value,
  };
}

String? _captureMacValue(RawKeyEvent event) {
  if (Platform.isMacOS && event.data is RawKeyEventDataMacOs) {
    return (event.data as RawKeyEventDataMacOs).keyCode.toString();
  }

  return _physicalToMacKeycode[event.physicalKey]?.toString();
}

const _macHotkeyPolicy = HotkeyPolicy(
  presets: _macPresets,
  displayName: _macDisplayName,
  captureValue: _captureMacValue,
);

HotkeyPolicy get platformHotkeyPolicy {
  if (Platform.isMacOS) return _macHotkeyPolicy;
  return _macHotkeyPolicy;
}
