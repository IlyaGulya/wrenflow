import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/app_version.dart';
import '../shell/shell_capabilities.dart';
import 'update_provider.dart';

enum AboutUpdateCardPhase { hidden, checking, action, available }

class AboutSettingsPresentation {
  const AboutSettingsPresentation({
    required this.versionLabel,
    required this.showUpdates,
    required this.updatePhase,
    this.updateMessage,
    this.updateActionLabel,
    this.updateDownloadUrl,
    this.isRecentUpdate = false,
  });

  final String versionLabel;
  final bool showUpdates;
  final AboutUpdateCardPhase updatePhase;
  final String? updateMessage;
  final String? updateActionLabel;
  final String? updateDownloadUrl;
  final bool isRecentUpdate;
}

final aboutSettingsPresentationProvider =
    Provider<AboutSettingsPresentation>((ref) {
      final updateState = ref.watch(updateProvider);
      final shellCapabilities = ref.watch(shellCapabilitiesProvider);

      if (!shellCapabilities.updates) {
        return AboutSettingsPresentation(
          versionLabel: 'v${AppVersion.displayVersion}',
          showUpdates: false,
          updatePhase: AboutUpdateCardPhase.hidden,
        );
      }

      return switch (updateState.phase) {
        UpdatePhase.checking => AboutSettingsPresentation(
          versionLabel: 'v${AppVersion.displayVersion}',
          showUpdates: true,
          updatePhase: AboutUpdateCardPhase.checking,
          updateMessage: 'Checking for updates...',
        ),
        UpdatePhase.error => AboutSettingsPresentation(
          versionLabel: 'v${AppVersion.displayVersion}',
          showUpdates: true,
          updatePhase: AboutUpdateCardPhase.action,
          updateMessage: 'Could not check for updates',
          updateActionLabel: 'Retry',
        ),
        UpdatePhase.available => AboutSettingsPresentation(
          versionLabel: 'v${AppVersion.displayVersion}',
          showUpdates: true,
          updatePhase: AboutUpdateCardPhase.available,
          updateMessage: 'v${updateState.latestVersion} is available',
          updateDownloadUrl: updateState.downloadUrl.isNotEmpty
              ? updateState.downloadUrl
              : updateState.releaseUrl,
          isRecentUpdate: updateState.isRecent,
        ),
        _ => AboutSettingsPresentation(
          versionLabel: 'v${AppVersion.displayVersion}',
          showUpdates: true,
          updatePhase: AboutUpdateCardPhase.action,
          updateMessage: 'You\'re up to date',
          updateActionLabel: 'Check now',
        ),
      };
    });
