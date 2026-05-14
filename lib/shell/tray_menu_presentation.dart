import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/audio_devices_provider.dart';
import '../providers/app_version_provider.dart';
import '../providers/launch_at_login_provider.dart';
import '../providers/settings_provider.dart';
import '../runtime/runtime_contract.dart';
import 'shell_pipeline_presentation.dart';

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
    required this.showLaunchAtLogin,
    required this.launchAtLoginEnabled,
    required this.launchAtLoginLoading,
    required this.launchAtLoginHint,
    required this.microphones,
  });

  final String versionLabel;
  final String statusText;
  final bool showLaunchAtLogin;
  final bool launchAtLoginEnabled;
  final bool launchAtLoginLoading;
  final String? launchAtLoginHint;
  final List<TrayMicrophoneItem> microphones;
}

final trayMenuPresentationProvider = Provider<TrayMenuPresentation>((ref) {
  final pipeline = ref.watch(shellPipelinePresentationProvider);
  final launchAtLogin = ref.watch(launchAtLoginProvider);
  final audioSnapshot = ref.watch(audioDevicesSnapshotProvider).value;
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

  return TrayMenuPresentation(
    versionLabel: 'Wrenflow $versionLabel',
    statusText: pipeline.statusText,
    showLaunchAtLogin: launchAtLogin.isAvailable,
    launchAtLoginEnabled: launchAtLogin.enabled,
    launchAtLoginLoading: launchAtLogin.isLoading,
    launchAtLoginHint: launchAtLogin.unavailableReason ?? launchAtLogin.errorMessage,
    microphones: microphones,
  );
});
