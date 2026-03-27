import 'package:flutter/services.dart';

/// Status of microphone permission.
enum MicrophonePermission {
  granted,
  denied,
  notDetermined,
}

/// Service for managing macOS permissions via platform channels.
///
/// Wraps the native MethodChannel for microphone and accessibility
/// permission checks, requests, and settings navigation.
class PermissionService {
  static const _channel = MethodChannel('dev.gulya.wrenflow/permissions');

  // MARK: - Microphone

  /// Check the current microphone authorization status.
  Future<MicrophonePermission> checkMicrophone() async {
    final String status = await _channel.invokeMethod('checkMicrophonePermission');
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

  /// Request microphone access. Shows system dialog if not yet determined.
  /// Returns true if access was granted.
  Future<bool> requestMicrophone() async {
    final bool granted = await _channel.invokeMethod('requestMicrophonePermission');
    return granted;
  }

  // MARK: - Accessibility

  /// Check whether the app has accessibility permission (AXIsProcessTrusted).
  Future<bool> checkAccessibility() async {
    final bool trusted = await _channel.invokeMethod('checkAccessibilityPermission');
    return trusted;
  }

  /// Request accessibility permission. Shows system prompt and opens
  /// System Settings if not already trusted. Returns the current trust
  /// status (may still be false if user hasn't toggled the setting yet).
  Future<bool> requestAccessibility() async {
    final bool trusted = await _channel.invokeMethod('requestAccessibilityPermission');
    return trusted;
  }

  // MARK: - Open Settings

  /// Open System Settings to the Accessibility privacy pane.
  Future<void> openAccessibilitySettings() async {
    await _channel.invokeMethod('openAccessibilitySettings');
  }

  /// Open System Settings to the Microphone privacy pane.
  Future<void> openMicrophoneSettings() async {
    await _channel.invokeMethod('openMicrophoneSettings');
  }
}
