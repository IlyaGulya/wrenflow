import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract class LaunchAtLoginShell {
  bool get isSupported;
  Future<bool> isFeatureAvailable();
  Future<String?> unsupportedReason();
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
  Future<bool> isFeatureAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<String?> unsupportedReason() async {
    try {
      return await _channel.invokeMethod<String?>('unsupportedReason');
    } on MissingPluginException {
      return 'Launch at login is unavailable in the current app build.';
    } on PlatformException catch (e) {
      return e.message;
    }
  }

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
  Future<bool> isFeatureAvailable() async {
    return false;
  }

  @override
  Future<String?> unsupportedReason() async {
    return 'Launch at login is unavailable on this platform.';
  }

  @override
  Future<bool> isEnabled() async {
    return false;
  }

  @override
  Future<void> setEnabled(bool enabled) async {}
}
