import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum MicrophonePermission { granted, denied, notDetermined }

abstract class PermissionsShell {
  bool get isSupported;
  Future<MicrophonePermission> checkMicrophone();
  Future<bool> requestMicrophone();
  Future<bool> checkAccessibility();
  Future<bool> requestAccessibility();
  Future<void> openAccessibilitySettings();
  Future<void> openMicrophoneSettings();
}

PermissionsShell get platformPermissionsShell {
  if (defaultTargetPlatform == TargetPlatform.macOS) {
    return const _MacOsPermissionsShell();
  }
  return const _UnsupportedPermissionsShell();
}

class _MacOsPermissionsShell implements PermissionsShell {
  const _MacOsPermissionsShell();

  @override
  bool get isSupported => true;

  static const _channel = MethodChannel('dev.gulya.wrenflow/permissions');

  @override
  Future<MicrophonePermission> checkMicrophone() async {
    try {
      final String status = await _channel.invokeMethod(
        'checkMicrophonePermission',
      );
      return switch (status) {
        'granted' => MicrophonePermission.granted,
        'denied' => MicrophonePermission.denied,
        _ => MicrophonePermission.notDetermined,
      };
    } on MissingPluginException {
      return MicrophonePermission.denied;
    } on PlatformException {
      return MicrophonePermission.denied;
    }
  }

  @override
  Future<bool> requestMicrophone() async {
    try {
      return await _channel.invokeMethod('requestMicrophonePermission');
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<bool> checkAccessibility() async {
    try {
      return await _channel.invokeMethod('checkAccessibilityPermission');
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<bool> requestAccessibility() async {
    try {
      return await _channel.invokeMethod('requestAccessibilityPermission');
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> openAccessibilitySettings() async {
    try {
      await _channel.invokeMethod('openAccessibilitySettings');
    } on MissingPluginException {
      // Not available on this platform.
    } on PlatformException {
      // Not available in the current shell integration.
    }
  }

  @override
  Future<void> openMicrophoneSettings() async {
    try {
      await _channel.invokeMethod('openMicrophoneSettings');
    } on MissingPluginException {
      // Not available on this platform.
    } on PlatformException {
      // Not available in the current shell integration.
    }
  }
}

class _UnsupportedPermissionsShell implements PermissionsShell {
  const _UnsupportedPermissionsShell();

  @override
  bool get isSupported => false;

  @override
  Future<MicrophonePermission> checkMicrophone() async {
    return MicrophonePermission.denied;
  }

  @override
  Future<bool> requestMicrophone() async {
    return false;
  }

  @override
  Future<bool> checkAccessibility() async {
    return false;
  }

  @override
  Future<bool> requestAccessibility() async {
    return false;
  }

  @override
  Future<void> openAccessibilitySettings() async {}

  @override
  Future<void> openMicrophoneSettings() async {}
}
