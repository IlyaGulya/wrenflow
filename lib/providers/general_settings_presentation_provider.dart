import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../runtime/runtime_contract.dart';
import '../shell/shell_capabilities.dart';
import '../src/bindings/signals/signals.dart';
import 'audio_devices_provider.dart';
import 'launch_at_login_provider.dart';
import 'settings_provider.dart';

class MicrophoneOptionPresentation {
  const MicrophoneOptionPresentation({
    required this.id,
    required this.label,
    required this.selected,
  });

  final String id;
  final String label;
  final bool selected;
}

class GeneralSettingsPresentation {
  const GeneralSettingsPresentation({
    required this.hasSettingsSnapshot,
    required this.selectedHotkey,
    required this.soundEnabled,
    required this.minimumRecordingDurationMs,
    required this.customVocabulary,
    required this.showLaunchAtLogin,
    required this.launchAtLoginEnabled,
    required this.launchAtLoginLoading,
    required this.microphones,
  });

  final bool hasSettingsSnapshot;
  final String selectedHotkey;
  final bool soundEnabled;
  final double minimumRecordingDurationMs;
  final String customVocabulary;
  final bool showLaunchAtLogin;
  final bool launchAtLoginEnabled;
  final bool launchAtLoginLoading;
  final List<MicrophoneOptionPresentation> microphones;
}

final generalSettingsPresentationProvider =
    Provider<GeneralSettingsPresentation>((ref) {
      final settings = ref.watch(settingsProvider);
      final shellCapabilities = ref.watch(shellCapabilitiesProvider);
      final launchAtLogin = ref.watch(launchAtLoginProvider);
      final audioSnapshot = ref.watch(audioDevicesSnapshotProvider).value;

      final selectedMicId =
          audioSnapshot?.effectiveSelectedDeviceId ??
          settings.selectedMicrophoneId;
      final defaultDeviceName = audioSnapshot?.defaultDeviceName ?? '';
      final defaultLabel = defaultDeviceName.isNotEmpty
          ? 'System Default ($defaultDeviceName)'
          : 'System Default';

      final microphones = <MicrophoneOptionPresentation>[
        MicrophoneOptionPresentation(
          id: systemDefaultMicrophoneId,
          label: defaultLabel,
          selected: selectedMicId == systemDefaultMicrophoneId,
        ),
        for (final device in audioSnapshot?.devices ?? const <AudioDeviceInfo>[])
          MicrophoneOptionPresentation(
            id: device.id,
            label: device.name,
            selected: selectedMicId == device.id,
          ),
      ];

      return GeneralSettingsPresentation(
        hasSettingsSnapshot: settings.hasSnapshot,
        selectedHotkey: settings.selectedHotkey,
        soundEnabled: settings.soundEnabled,
        minimumRecordingDurationMs: settings.minimumRecordingDurationMs,
        customVocabulary: settings.customVocabulary,
        showLaunchAtLogin: shellCapabilities.launchAtLogin,
        launchAtLoginEnabled: launchAtLogin.enabled,
        launchAtLoginLoading: launchAtLogin.isLoading,
        microphones: microphones,
      );
    });
