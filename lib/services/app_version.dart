import 'package:package_info_plus/package_info_plus.dart';

/// Shared runtime app version sourced from bundle metadata.
class AppVersion {
  AppVersion._();

  static const _fallbackVersion = '0.3.0';

  static String _version = _fallbackVersion;
  static String _buildNumber = '1';

  static String get currentVersion => _version;
  static String get buildNumber => _buildNumber;

  static String get displayVersion {
    if (_buildNumber.isEmpty ||
        _buildNumber == '1' ||
        _buildNumber == _version) {
      return _version;
    }
    return '$_version ($_buildNumber)';
  }

  static Future<void> load() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (info.version.isNotEmpty) {
        _version = info.version;
      }
      if (info.buildNumber.isNotEmpty) {
        _buildNumber = info.buildNumber;
      }
    } on Exception {
      // Fall back to the checked-in release version when platform metadata
      // is unavailable, such as in some test environments.
    }
  }
}
