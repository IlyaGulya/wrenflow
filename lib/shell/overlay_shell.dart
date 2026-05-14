import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract class OverlayShell {
  bool get isSupported;
  Future<void> show(String state, {double audioLevel = 0.0});
  Future<void> updateAudioLevel(double level);
  Future<void> hide();
  Future<void> showError(String message);
}

OverlayShell get platformOverlayShell {
  if (defaultTargetPlatform == TargetPlatform.macOS) {
    return const _MacOsOverlayShell();
  }
  return const _UnsupportedOverlayShell();
}

class _MacOsOverlayShell implements OverlayShell {
  const _MacOsOverlayShell();

  @override
  bool get isSupported => true;

  static const _channel = MethodChannel('dev.gulya.wrenflow/overlay');

  @override
  Future<void> show(String state, {double audioLevel = 0.0}) async {
    try {
      await _channel.invokeMethod('show', {
        'state': state,
        'audioLevel': audioLevel,
      });
    } on MissingPluginException {
      // Not available on this platform.
    } on PlatformException {
      // Overlay bridge failed; keep shell resilient.
    }
  }

  @override
  Future<void> updateAudioLevel(double level) async {
    try {
      await _channel.invokeMethod('updateAudioLevel', {'level': level});
    } on MissingPluginException {
      // Not available on this platform.
    } on PlatformException {
      // Ignore transient shell bridge failures.
    }
  }

  @override
  Future<void> hide() async {
    try {
      await _channel.invokeMethod('hide');
    } on MissingPluginException {
      // Not available on this platform.
    } on PlatformException {
      // Ignore transient shell bridge failures.
    }
  }

  @override
  Future<void> showError(String message) async {
    try {
      await _channel.invokeMethod('showError', {'message': message});
    } on MissingPluginException {
      // Not available on this platform.
    } on PlatformException {
      // Ignore transient shell bridge failures.
    }
  }
}

class _UnsupportedOverlayShell implements OverlayShell {
  const _UnsupportedOverlayShell();

  @override
  bool get isSupported => false;

  @override
  Future<void> show(String state, {double audioLevel = 0.0}) async {}

  @override
  Future<void> updateAudioLevel(double level) async {}

  @override
  Future<void> hide() async {}

  @override
  Future<void> showError(String message) async {}
}
