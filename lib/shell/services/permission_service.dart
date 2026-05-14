import 'package:flutter/services.dart';

enum MicrophonePermission { granted, denied, notDetermined }

/// Service for managing permissions via platform channels.
class PermissionService {
  static const _channel = MethodChannel('dev.gulya.wrenflow/permissions');

  Future<MicrophonePermission> checkMicrophone() async {
    final String status = await _channel.invokeMethod(
      'checkMicrophonePermission',
    );
    switch (status) {
      case 'granted':
        return MicrophonePermission.granted;
      case 'denied':
        return MicrophonePermission.denied;
      case 'notDetermined':
      default:
        return MicrophonePermission.notDetermined;
    }
  }

  Future<bool> requestMicrophone() async {
    final bool granted = await _channel.invokeMethod(
      'requestMicrophonePermission',
    );
    return granted;
  }

  Future<bool> checkAccessibility() async {
    final bool trusted = await _channel.invokeMethod(
      'checkAccessibilityPermission',
    );
    return trusted;
  }

  Future<bool> requestAccessibility() async {
    final bool trusted = await _channel.invokeMethod(
      'requestAccessibilityPermission',
    );
    return trusted;
  }

  Future<void> openAccessibilitySettings() async {
    await _channel.invokeMethod('openAccessibilitySettings');
  }

  Future<void> openMicrophoneSettings() async {
    await _channel.invokeMethod('openMicrophoneSettings');
  }
}
