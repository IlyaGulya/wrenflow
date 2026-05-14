import 'package:flutter/services.dart';

class LaunchAtLoginService {
  static const _channel = MethodChannel('dev.gulya.wrenflow/launch_at_login');

  Future<bool> isEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('isEnabled') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> setEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod('setEnabled', {'enabled': enabled});
    } on MissingPluginException {
      // Not available on this platform
    } on PlatformException catch (e) {
      throw Exception('Failed to set launch at login: ${e.message}');
    }
  }
}
