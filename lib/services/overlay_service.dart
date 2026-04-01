import 'package:flutter/services.dart';

/// Native overlay control via platform channel.
///
/// Manages an NSPanel at screenSaver level that shows recording/transcribing
/// status independently of the main Flutter window.
class OverlayService {
  static const _channel = MethodChannel('dev.gulya.wrenflow/overlay');

  /// Show overlay with the given pipeline state.
  /// [state] is one of: "initializing", "recording", "transcribing".
  Future<void> show(String state, {double audioLevel = 0.0}) async {
    await _channel.invokeMethod('show', {
      'state': state,
      'audioLevel': audioLevel,
    });
  }

  /// Update audio level during recording (0.0–1.0).
  Future<void> updateAudioLevel(double level) async {
    await _channel.invokeMethod('updateAudioLevel', {
      'level': level,
    });
  }

  /// Hide the overlay.
  Future<void> hide() async {
    await _channel.invokeMethod('hide');
  }

  /// Show an error toast notification. Auto-dismisses after 6 seconds.
  Future<void> showError(String message) async {
    await _channel.invokeMethod('showError', {
      'message': message,
    });
  }
}
