import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/audio_devices_provider.dart';
import '../providers/app_lifecycle_provider.dart';
import '../providers/app_version_provider.dart';
import '../providers/launch_at_login_provider.dart';
import '../providers/local_models_snapshot_provider.dart';
import '../providers/runtime_capabilities_provider.dart';
import '../providers/settings_provider.dart';
import '../runtime/runtime_contract.dart';
import '../state/app_lifecycle_state.dart';
import 'shell_pipeline_presentation.dart';
import '../src/bindings/signals/signals.dart';

class TrayMicrophoneItem {
  const TrayMicrophoneItem({
    required this.id,
    required this.label,
    required this.selected,
  });

  final String id;
  final String label;
  final bool selected;
}

class TrayMenuPresentation {
  const TrayMenuPresentation({
    required this.versionLabel,
    required this.statusText,
    required this.settingsLabel,
    required this.settingsEnabled,
    required this.showHistory,
    required this.microphoneSelectionAvailable,
    required this.microphoneHint,
    required this.showLaunchAtLogin,
    required this.launchAtLoginEnabled,
    required this.launchAtLoginLoading,
    required this.launchAtLoginHint,
    required this.microphones,
  });

  final String versionLabel;
  final String statusText;
  final String settingsLabel;
  final bool settingsEnabled;
  final bool showHistory;
  final bool microphoneSelectionAvailable;
  final String? microphoneHint;
  final bool showLaunchAtLogin;
  final bool launchAtLoginEnabled;
  final bool launchAtLoginLoading;
  final String? launchAtLoginHint;
  final List<TrayMicrophoneItem> microphones;
}

final trayMenuPresentationProvider = Provider<TrayMenuPresentation>((ref) {
  final pipeline = ref.watch(shellPipelinePresentationProvider);
  final lifecycle = ref.watch(appLifecycleProvider);
  final launchAtLogin = ref.watch(launchAtLoginProvider);
  final audioSnapshot = ref.watch(audioDevicesSnapshotProvider).value;
  final runtimeCapabilities = ref.watch(runtimeCapabilitiesProvider).value;
  final localModelsSnapshot = ref.watch(localModelsSnapshotProvider).value;
  final settings = ref.watch(settingsProvider);
  final versionLabel = ref.watch(appVersionLabelProvider);

  final selectedMicId =
      audioSnapshot?.effectiveSelectedDeviceId ?? settings.selectedMicrophoneId;
  final defaultDeviceName = audioSnapshot?.defaultDeviceName ?? '';
  final defaultLabel = defaultDeviceName.isNotEmpty
      ? 'System Default ($defaultDeviceName)'
      : 'System Default';

  final microphones = <TrayMicrophoneItem>[
    TrayMicrophoneItem(
      id: systemDefaultMicrophoneId,
      label: defaultLabel,
      selected: selectedMicId == systemDefaultMicrophoneId,
    ),
    for (final device in audioSnapshot?.devices ?? const [])
      TrayMicrophoneItem(
        id: device.id,
        label: device.name,
        selected: selectedMicId == device.id,
      ),
  ];

  String statusText = switch (lifecycle) {
    Initializing() => 'Starting up...',
    Onboarding(currentStep: final step) => switch (step) {
      OnboardingStep.microphone => 'Setup: microphone',
      OnboardingStep.accessibility => 'Setup: accessibility',
      OnboardingStep.hotkey => 'Setup: hotkey',
      OnboardingStep.model => 'Setup: model',
      OnboardingStep.vocabulary => 'Setup: vocabulary',
      OnboardingStep.complete => 'Setup: complete',
    },
    PermissionRecovery() => 'Permissions required',
    ShuttingDown() => 'Quitting...',
    Running() => pipeline.statusText,
  };

  if (lifecycle is Running && statusText == 'Ready') {
    statusText = switch (runtimeCapabilities) {
      null => 'Loading runtime...',
      RuntimeCapabilities(audioCapture: false) => 'Audio unavailable',
      RuntimeCapabilities(globalHotkey: false) => 'Hotkey unavailable',
      RuntimeCapabilities(localTranscription: false) => 'Runtime unavailable',
      RuntimeCapabilities(modelActivation: false) =>
        'Model activation unavailable',
      RuntimeCapabilities(modelDownload: false) => 'Model storage unavailable',
      _ => _modelTrayStatus(localModelsSnapshot),
    };
  }

  final microphoneSelectionAvailable =
      runtimeCapabilities?.audioCapture ?? false;
  final microphoneHint = microphoneSelectionAvailable
      ? null
      : runtimeCapabilities == null
      ? 'Loading runtime support...'
      : 'Audio capture is unavailable in the current runtime.';

  return TrayMenuPresentation(
    versionLabel: 'Wrenflow $versionLabel',
    statusText: statusText,
    settingsLabel: switch (lifecycle) {
      Onboarding() => 'Setup in progress',
      PermissionRecovery() => 'Permissions required',
      _ => 'Settings...',
    },
    settingsEnabled: lifecycle is Running,
    showHistory: lifecycle is Running,
    microphoneSelectionAvailable: microphoneSelectionAvailable,
    microphoneHint: microphoneHint,
    showLaunchAtLogin: launchAtLogin.isAvailable,
    launchAtLoginEnabled: launchAtLogin.enabled,
    launchAtLoginLoading: launchAtLogin.isLoading,
    launchAtLoginHint: launchAtLogin.unavailableReason ?? launchAtLogin.errorMessage,
    microphones: microphones,
  );
});

String _modelTrayStatus(LocalModelsSnapshot? snapshot) {
  if (snapshot == null) return 'Loading models...';

  final activeModelId = snapshot.activeModelId;
  if (activeModelId != null && snapshot.stateFor(activeModelId) is ModelStateReady) {
    return 'Ready';
  }

  final selectedModel = snapshot.findModel(snapshot.selectedModelId);
  final selectedState = snapshot.stateFor(snapshot.selectedModelId);

  if (selectedModel == null) {
    return 'No preferred model';
  }

  return switch (selectedState) {
    ModelStateDownloading() => '${selectedModel.displayName} downloading',
    ModelStateLoading() => '${selectedModel.displayName} loading',
    ModelStateWarming() => '${selectedModel.displayName} warming',
    ModelStateError() => '${selectedModel.displayName} failed',
    ModelStateReady() => '${selectedModel.displayName} inactive',
    _ => 'No active model',
  };
}
