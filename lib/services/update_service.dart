import 'dart:convert';
import 'dart:io';

import 'app_version.dart';

class UpdateCheckException implements Exception {
  const UpdateCheckException(this.message);

  final String message;

  @override
  String toString() => message;
}

String summarizeUpdateError(Object? error) {
  final text = error?.toString().trim();
  if (text == null || text.isEmpty) {
    return 'Could not check for updates.';
  }

  const prefix = 'Exception: ';
  if (text.startsWith(prefix)) {
    return text.substring(prefix.length);
  }
  return text;
}

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
  GitHubUpdateSource({this.owner = 'IlyaGulya', this.repo = 'wrenflow'});

  final String owner;
  final String repo;

  @override
  Future<UpdateInfo> checkForUpdate() async {
    final client = HttpClient();
    try {
      client.connectionTimeout = const Duration(seconds: 10);
      final url = 'https://api.github.com/repos/$owner/$repo/releases/latest';
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'Wrenflow');
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.github+json',
      );

      final response = await request.close();
      if (response.statusCode != 200) {
        final body = await response.transform(utf8.decoder).join();
        throw UpdateCheckException(
          'GitHub update check failed (${response.statusCode})'
          '${body.isNotEmpty ? ': $body' : ''}',
        );
      }

      final body = await response.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;

      final tagName = json['tag_name'] as String? ?? '';
      final htmlUrl = json['html_url'] as String? ?? '';
      final publishedAtStr = json['published_at'] as String?;
      final publishedAt = publishedAtStr != null
          ? DateTime.tryParse(publishedAtStr)
          : null;

      final latestVersion = tagName.startsWith('v')
          ? tagName.substring(1)
          : tagName;
      final currentVersion = AppVersion.currentVersion;

      if (latestVersion.isEmpty) return UpdateInfo.none;
      if (currentVersion.isEmpty) {
        throw const UpdateCheckException(
          'Current app version is unavailable, so updates cannot be compared.',
        );
      }
      if (!_isNewerVersion(latestVersion, currentVersion)) {
        return UpdateInfo.none;
      }

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
    } on SocketException catch (error) {
      throw UpdateCheckException('Network error while checking for updates: $error');
    } on HandshakeException catch (error) {
      throw UpdateCheckException('TLS error while checking for updates: $error');
    } on FormatException catch (error) {
      throw UpdateCheckException('Invalid update response: $error');
    } finally {
      client.close();
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
