import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/audio_devices_provider.dart';
import '../providers/launch_at_login_provider.dart';
import '../providers/settings_provider.dart';
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
    required this.statusText,
    required this.launchAtLoginEnabled,
    required this.launchAtLoginLoading,
    required this.microphones,
  });

  final String statusText;
  final bool launchAtLoginEnabled;
  final bool launchAtLoginLoading;
  final List<TrayMicrophoneItem> microphones;
}

final trayMenuPresentationProvider = Provider<TrayMenuPresentation>((ref) {
  final pipeline = ref.watch(shellPipelinePresentationProvider);
  final launchAtLogin = ref.watch(launchAtLoginProvider);
  final audioSnapshot = ref.watch(audioDevicesSnapshotProvider).value;
  final settings = ref.watch(settingsProvider);

  final selectedMicId =
      audioSnapshot?.effectiveSelectedDeviceId ?? settings.selectedMicrophoneId;
  final defaultDeviceName = audioSnapshot?.defaultDeviceName ?? '';
  final defaultLabel = defaultDeviceName.isNotEmpty
      ? 'System Default ($defaultDeviceName)'
      : 'System Default';

  final microphones = <TrayMicrophoneItem>[
    TrayMicrophoneItem(
      id: 'default',
      label: defaultLabel,
      selected: selectedMicId == 'default',
    ),
    for (final device in audioSnapshot?.devices ?? const [])
      TrayMicrophoneItem(
        id: device.id,
        label: device.name,
        selected: selectedMicId == device.id,
      ),
  ];

  return TrayMenuPresentation(
    statusText: pipeline.statusText,
    launchAtLoginEnabled: launchAtLogin.enabled,
    launchAtLoginLoading: launchAtLogin.isLoading,
    microphones: microphones,
  );
});
