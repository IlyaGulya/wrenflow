import 'package:flutter/services.dart';

/// Native overlay control via platform channel.
///
/// Manages an NSPanel at screenSaver level that shows recording/transcribing
/// status independently of the main Flutter window.
class OverlayService {
  static const _channel = MethodChannel('dev.gulya.wrenflow/overlay');

  Future<void> show(String state, {double audioLevel = 0.0}) async {
    await _channel.invokeMethod('show', {
      'state': state,
      'audioLevel': audioLevel,
    });
  }

  Future<void> updateAudioLevel(double level) async {
    await _channel.invokeMethod('updateAudioLevel', {'level': level});
  }

  Future<void> hide() async {
    await _channel.invokeMethod('hide');
  }

  Future<void> showError(String message) async {
    await _channel.invokeMethod('showError', {'message': message});
  }
}
