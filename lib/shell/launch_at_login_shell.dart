import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract class LaunchAtLoginShell {
  bool get isSupported;
  Future<bool> isEnabled();
  Future<void> setEnabled(bool enabled);
}

LaunchAtLoginShell get platformLaunchAtLoginShell {
  if (defaultTargetPlatform == TargetPlatform.macOS) {
    return const _MacOsLaunchAtLoginShell();
  }
  return const _UnsupportedLaunchAtLoginShell();
}

class _MacOsLaunchAtLoginShell implements LaunchAtLoginShell {
  const _MacOsLaunchAtLoginShell();

  @override
  bool get isSupported => true;

  static const _channel = MethodChannel('dev.gulya.wrenflow/launch_at_login');

  @override
  Future<bool> isEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('isEnabled') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> setEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod('setEnabled', {'enabled': enabled});
    } on MissingPluginException {
      // Not available on this platform.
    } on PlatformException catch (e) {
      throw Exception('Failed to set launch at login: ${e.message}');
    }
  }
}

class _UnsupportedLaunchAtLoginShell implements LaunchAtLoginShell {
  const _UnsupportedLaunchAtLoginShell();

  @override
  bool get isSupported => false;

  @override
  Future<bool> isEnabled() async {
    return false;
  }

  @override
  Future<void> setEnabled(bool enabled) async {}
}
