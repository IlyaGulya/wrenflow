import 'dart:convert';
import 'dart:io';

/// Information about an available update.
class UpdateInfo {
  const UpdateInfo({
    required this.isAvailable,
    this.latestVersion = '',
    this.releaseUrl = '',
    this.downloadUrl = '',
    this.publishedAt,
  });

  final bool isAvailable;
  final String latestVersion;
  final String releaseUrl;
  final String downloadUrl;
  final DateTime? publishedAt;

  static const none = UpdateInfo(isAvailable: false);

  /// Whether the release is less than 3 days old.
  bool get isRecent {
    if (publishedAt == null) return false;
    return DateTime.now().difference(publishedAt!).inHours < 72;
  }
}

/// Abstract update source — implement for each distribution channel.
abstract class UpdateSource {
  Future<UpdateInfo> checkForUpdate();
}

/// Checks GitHub releases API for available updates.
class GitHubUpdateSource implements UpdateSource {
  GitHubUpdateSource({
    this.owner = 'IlyaGulya',
    this.repo = 'wrenflow',
  });

  final String owner;
  final String repo;

  static const currentVersion = '1.0.0';

  @override
  Future<UpdateInfo> checkForUpdate() async {
    try {
      final client = HttpClient();
      try {
        client.connectionTimeout = const Duration(seconds: 10);
        final url = 'https://api.github.com/repos/$owner/$repo/releases/latest';
        final request = await client.getUrl(Uri.parse(url));
        request.headers.set(HttpHeaders.userAgentHeader, 'Wrenflow');
        request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');

        final response = await request.close();
        if (response.statusCode != 200) {
          await response.drain<void>();
          return UpdateInfo.none;
        }

        final body = await response.transform(utf8.decoder).join();
        final json = jsonDecode(body) as Map<String, dynamic>;

        final tagName = json['tag_name'] as String? ?? '';
        final htmlUrl = json['html_url'] as String? ?? '';
        final publishedAtStr = json['published_at'] as String?;
        final publishedAt = publishedAtStr != null
            ? DateTime.tryParse(publishedAtStr)
            : null;

        final latestVersion =
            tagName.startsWith('v') ? tagName.substring(1) : tagName;

        if (latestVersion.isEmpty) return UpdateInfo.none;
        if (!_isNewerVersion(latestVersion, currentVersion)) {
          return UpdateInfo.none;
        }

        // Find DMG asset for download.
        final assets = json['assets'] as List<dynamic>? ?? [];
        String downloadUrl = '';
        for (final asset in assets) {
          final name = (asset['name'] as String? ?? '').toLowerCase();
          if (name.endsWith('.dmg') || name.endsWith('.zip')) {
            downloadUrl = asset['browser_download_url'] as String? ?? '';
            break;
          }
        }

        return UpdateInfo(
          isAvailable: true,
          latestVersion: latestVersion,
          releaseUrl: htmlUrl,
          downloadUrl: downloadUrl,
          publishedAt: publishedAt,
        );
      } finally {
        client.close();
      }
    } on Exception {
      return UpdateInfo.none;
    }
  }

  static bool _isNewerVersion(String latest, String current) {
    final latestParts = _parseVersion(latest);
    final currentParts = _parseVersion(current);
    if (latestParts == null || currentParts == null) return false;

    for (var i = 0; i < 3; i++) {
      if (latestParts[i] > currentParts[i]) return true;
      if (latestParts[i] < currentParts[i]) return false;
    }
    return false;
  }

  static List<int>? _parseVersion(String version) {
    final base = version.split('-').first;
    final parts = base.split('.');
    if (parts.length < 3) return null;
    try {
      return [int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2])];
    } on FormatException {
      return null;
    }
  }
}
