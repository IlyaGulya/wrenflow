import 'package:package_info_plus/package_info_plus.dart';

class AppVersionInfo {
  const AppVersionInfo({
    required this.version,
    required this.buildNumber,
  });

  const AppVersionInfo.unavailable()
    : version = '',
      buildNumber = '';

  final String version;
  final String buildNumber;

  bool get isAvailable => version.isNotEmpty;

  String get displayVersion {
    if (!isAvailable) return 'Version unavailable';
    if (buildNumber.isEmpty || buildNumber == version) {
      return version;
    }
    return '$version ($buildNumber)';
  }
}

/// Shared runtime app version sourced from bundle metadata.
class AppVersion {
  AppVersion._();

  static AppVersionInfo _current = const AppVersionInfo.unavailable();

  static AppVersionInfo get current => _current;
  static String get currentVersion => _current.version;

  static Future<AppVersionInfo> load() async {
    try {
      final info = await PackageInfo.fromPlatform();
      _current = AppVersionInfo(
        version: info.version,
        buildNumber: info.buildNumber,
      );
    } on Exception {
      _current = const AppVersionInfo.unavailable();
    }
    return _current;
  }
}
