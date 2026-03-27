import 'dart:convert';
import 'dart:io';

/// Information about an available update.
class UpdateInfo {
  const UpdateInfo({
    required this.isAvailable,
    this.latestVersion = '',
    this.releaseUrl = '',
  });

  /// Whether a newer version is available.
  final bool isAvailable;

  /// The latest version tag from GitHub (e.g. "1.2.0").
  final String latestVersion;

  /// URL to the GitHub release page.
  final String releaseUrl;

  /// Convenience constant for "no update available".
  static const none = UpdateInfo(isAvailable: false);
}

/// Service that checks GitHub releases for available updates.
class UpdateService {
  /// The current app version. Hardcoded for now; can be replaced with
  /// package_info_plus later.
  static const currentVersion = '1.0.0';

  static const _releaseUrl =
      'https://api.github.com/repos/IlyaGulya/wrenflow/releases/latest';

  /// Check GitHub for a newer release.
  ///
  /// Returns [UpdateInfo.none] on any network or parsing error so callers
  /// never need to handle exceptions.
  Future<UpdateInfo> checkForUpdate() async {
    try {
      final client = HttpClient();
      try {
        client.connectionTimeout = const Duration(seconds: 10);

        final request = await client.getUrl(Uri.parse(_releaseUrl));
        // GitHub API requires a User-Agent header.
        request.headers.set(HttpHeaders.userAgentHeader, 'Wrenflow');
        request.headers
            .set(HttpHeaders.acceptHeader, 'application/vnd.github+json');

        final response = await request.close();
        if (response.statusCode != 200) {
          await response.drain<void>();
          return UpdateInfo.none;
        }

        final body = await response.transform(utf8.decoder).join();
        final json = jsonDecode(body) as Map<String, dynamic>;

        final tagName = json['tag_name'] as String? ?? '';
        final htmlUrl = json['html_url'] as String? ?? '';

        // Strip leading "v" if present (e.g. "v1.2.0" -> "1.2.0").
        final latestVersion =
            tagName.startsWith('v') ? tagName.substring(1) : tagName;

        if (latestVersion.isEmpty) {
          return UpdateInfo.none;
        }

        final isNewer = _isNewerVersion(latestVersion, currentVersion);

        return UpdateInfo(
          isAvailable: isNewer,
          latestVersion: latestVersion,
          releaseUrl: htmlUrl,
        );
      } finally {
        client.close();
      }
    } on Exception {
      // Network errors, DNS failures, timeouts, JSON parse errors, etc.
      return UpdateInfo.none;
    }
  }

  /// Simple semver comparison: returns true if [latest] is newer than [current].
  ///
  /// Compares major.minor.patch numerically. Pre-release suffixes are ignored
  /// (everything after the first hyphen is stripped).
  static bool _isNewerVersion(String latest, String current) {
    final latestParts = _parseVersion(latest);
    final currentParts = _parseVersion(current);

    if (latestParts == null || currentParts == null) return false;

    for (var i = 0; i < 3; i++) {
      if (latestParts[i] > currentParts[i]) return true;
      if (latestParts[i] < currentParts[i]) return false;
    }

    return false; // Versions are equal.
  }

  /// Parse a version string like "1.2.3" or "1.2.3-beta" into [major, minor, patch].
  /// Returns null if the string cannot be parsed.
  static List<int>? _parseVersion(String version) {
    // Strip pre-release suffix.
    final base = version.split('-').first;
    final parts = base.split('.');

    if (parts.length < 3) return null;

    try {
      return [
        int.parse(parts[0]),
        int.parse(parts[1]),
        int.parse(parts[2]),
      ];
    } on FormatException {
      return null;
    }
  }
}
