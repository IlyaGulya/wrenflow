import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../shell/shell_capabilities.dart';
import '../src/bindings/signals/signals.dart';
import 'app_version_provider.dart';
import 'launch_at_login_provider.dart';
import 'local_models_snapshot_provider.dart';
import 'runtime_capabilities_provider.dart';
import 'update_provider.dart';
import '../services/update_service.dart';

enum AboutUpdateCardPhase { hidden, checking, action, available }

class AboutDiagnosticItem {
  const AboutDiagnosticItem({
    required this.label,
    required this.value,
    required this.healthy,
  });

  final String label;
  final String value;
  final bool healthy;
}

String _modelHealthValue(LocalModelsSnapshot? snapshot) {
  if (snapshot == null) {
    return 'Loading...';
  }

  final selected = snapshot.findModel(snapshot.selectedModelId);
  final active = snapshot.findModel(snapshot.activeModelId);
  final selectedState = snapshot.stateFor(snapshot.selectedModelId);

  if (active != null) {
    return '${active.displayName} active';
  }

  if (selected == null) {
    return 'No preferred model';
  }

  return switch (selectedState) {
    ModelStateDownloading() => '${selected.displayName} downloading',
    ModelStateLoading() => '${selected.displayName} loading',
    ModelStateWarming() => '${selected.displayName} warming up',
    ModelStateError() => '${selected.displayName} failed',
    ModelStateReady() => '${selected.displayName} ready but inactive',
    _ => '${selected.displayName} not installed',
  };
}

bool _modelHealthOk(LocalModelsSnapshot? snapshot) {
  if (snapshot == null) return false;
  return snapshot.activeModelId != null &&
      snapshot.stateFor(snapshot.activeModelId) is ModelStateReady;
}

class AboutSettingsPresentation {
  const AboutSettingsPresentation({
    required this.versionLabel,
    required this.showUpdates,
    required this.updatePhase,
    required this.diagnostics,
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
  final List<AboutDiagnosticItem> diagnostics;
}

final aboutSettingsPresentationProvider =
    Provider<AboutSettingsPresentation>((ref) {
      final updateState = ref.watch(updateProvider);
      final shellCapabilities = ref.watch(shellCapabilitiesProvider);
      final versionLabel = ref.watch(appVersionLabelProvider);
      final runtimeCapabilities = ref.watch(runtimeCapabilitiesProvider).value;
      final launchAtLogin = ref.watch(launchAtLoginProvider);
      final localModelsSnapshot = ref.watch(localModelsSnapshotProvider).value;
      final diagnostics = <AboutDiagnosticItem>[
        AboutDiagnosticItem(
          label: 'Runtime',
          value: runtimeCapabilities == null
              ? 'Loading...'
              : runtimeCapabilities.localTranscription
              ? 'Local transcription ready'
              : 'Local transcription unavailable',
          healthy: runtimeCapabilities?.localTranscription ?? false,
        ),
        AboutDiagnosticItem(
          label: 'Audio',
          value: runtimeCapabilities == null
              ? 'Loading...'
              : runtimeCapabilities.audioCapture
              ? 'Audio capture ready'
              : 'Audio capture unavailable',
          healthy: runtimeCapabilities?.audioCapture ?? false,
        ),
        AboutDiagnosticItem(
          label: 'Hotkey',
          value: runtimeCapabilities == null
              ? 'Loading...'
              : runtimeCapabilities.globalHotkey
              ? 'Global hotkey ready'
              : 'Global hotkey unavailable',
          healthy: runtimeCapabilities?.globalHotkey ?? false,
        ),
        AboutDiagnosticItem(
          label: 'Paste',
          value: runtimeCapabilities == null
              ? 'Loading...'
              : runtimeCapabilities.pasteInjection
              ? 'Paste injection ready'
              : 'Paste injection unavailable',
          healthy: runtimeCapabilities?.pasteInjection ?? false,
        ),
        AboutDiagnosticItem(
          label: 'Models',
          value: runtimeCapabilities == null
              ? 'Loading...'
              : !runtimeCapabilities.modelDownload
              ? 'Model storage unavailable'
              : !runtimeCapabilities.modelActivation
              ? 'Model activation unavailable'
              : _modelHealthValue(localModelsSnapshot),
          healthy: runtimeCapabilities?.modelDownload == true &&
              runtimeCapabilities?.modelActivation == true &&
              _modelHealthOk(localModelsSnapshot),
        ),
        AboutDiagnosticItem(
          label: 'History',
          value: runtimeCapabilities == null
              ? 'Loading...'
              : runtimeCapabilities.historyPersistence
              ? 'History storage writable'
              : 'History storage unavailable',
          healthy: runtimeCapabilities?.historyPersistence ?? false,
        ),
        if (shellCapabilities.launchAtLogin)
          AboutDiagnosticItem(
            label: 'Login item',
            value: launchAtLogin.isAvailable
                ? 'Launch at login available'
                : (launchAtLogin.unavailableReason ??
                    'Launch at login unavailable'),
            healthy: launchAtLogin.isAvailable,
          ),
      ];

      if (!shellCapabilities.updates) {
        return AboutSettingsPresentation(
          versionLabel: versionLabel,
          showUpdates: false,
          updatePhase: AboutUpdateCardPhase.hidden,
          diagnostics: diagnostics,
        );
      }

      return switch (updateState.phase) {
        UpdatePhase.checking => AboutSettingsPresentation(
          versionLabel: versionLabel,
          showUpdates: true,
          updatePhase: AboutUpdateCardPhase.checking,
          diagnostics: diagnostics,
          updateMessage: 'Checking for updates...',
        ),
        UpdatePhase.error => AboutSettingsPresentation(
          versionLabel: versionLabel,
          showUpdates: true,
          updatePhase: AboutUpdateCardPhase.action,
          diagnostics: diagnostics,
          updateMessage: summarizeUpdateError(updateState.errorMessage),
          updateActionLabel: 'Retry',
        ),
        UpdatePhase.available => AboutSettingsPresentation(
          versionLabel: versionLabel,
          showUpdates: true,
          updatePhase: AboutUpdateCardPhase.available,
          diagnostics: diagnostics,
          updateMessage: 'v${updateState.latestVersion} is available',
          updateDownloadUrl: updateState.downloadUrl.isNotEmpty
              ? updateState.downloadUrl
              : updateState.releaseUrl,
          isRecentUpdate: updateState.isRecent,
        ),
        _ => AboutSettingsPresentation(
          versionLabel: versionLabel,
          showUpdates: true,
          updatePhase: AboutUpdateCardPhase.action,
          diagnostics: diagnostics,
          updateMessage: 'You\'re up to date',
          updateActionLabel: 'Check now',
        ),
      };
    });
