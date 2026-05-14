import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wrenflow/src/bindings/signals/signals.dart';

import 'rust_snapshot_bridge.dart';

/// App settings state mirrored from the Rust-owned persisted config.
class AppSettings {
  const AppSettings({
    this.hasSnapshot = false,
    this.selectedLocalModelId = '',
    this.selectedHotkey = '',
    this.selectedMicrophoneId = '',
    this.soundEnabled = false,
    this.customVocabulary = '',
    this.minimumRecordingDurationMs = 0,
    this.hasCompletedSetup = false,
  });

  const AppSettings.loading()
    : hasSnapshot = false,
      selectedLocalModelId = '',
      selectedHotkey = '',
      selectedMicrophoneId = '',
      soundEnabled = false,
      customVocabulary = '',
      minimumRecordingDurationMs = 0,
      hasCompletedSetup = false;

  final bool hasSnapshot;
  final String selectedLocalModelId;
  final String selectedHotkey;
  final String selectedMicrophoneId;
  final bool soundEnabled;
  final String customVocabulary;
  final double minimumRecordingDurationMs;
  final bool hasCompletedSetup;

  AppSettings copyWith({
    bool? hasSnapshot,
    String? selectedLocalModelId,
    String? selectedHotkey,
    String? selectedMicrophoneId,
    bool? soundEnabled,
    String? customVocabulary,
    double? minimumRecordingDurationMs,
    bool? hasCompletedSetup,
  }) {
    return AppSettings(
      hasSnapshot: hasSnapshot ?? this.hasSnapshot,
      selectedLocalModelId: selectedLocalModelId ?? this.selectedLocalModelId,
      selectedHotkey: selectedHotkey ?? this.selectedHotkey,
      selectedMicrophoneId: selectedMicrophoneId ?? this.selectedMicrophoneId,
      soundEnabled: soundEnabled ?? this.soundEnabled,
      customVocabulary: customVocabulary ?? this.customVocabulary,
      minimumRecordingDurationMs:
          minimumRecordingDurationMs ?? this.minimumRecordingDurationMs,
      hasCompletedSetup: hasCompletedSetup ?? this.hasCompletedSetup,
    );
  }

  static AppSettings fromSignalSnapshot(SettingsSnapshot snapshot) {
    return AppSettings(
      hasSnapshot: true,
      selectedLocalModelId: snapshot.selectedLocalModelId,
      selectedHotkey: snapshot.selectedHotkey,
      selectedMicrophoneId: snapshot.selectedMicrophoneId,
      soundEnabled: snapshot.soundEnabled,
      customVocabulary: snapshot.customVocabulary,
      minimumRecordingDurationMs: snapshot.minimumRecordingDurationMs,
      hasCompletedSetup: snapshot.hasCompletedSetup,
    );
  }
}

class SettingsNotifier extends RustSnapshotNotifier<AppSettings> {
  @override
  AppSettings build() {
    bindRustSnapshotState<SettingsSnapshotChanged>(
      requestSnapshot: () => const RequestSettingsSnapshot().sendSignalToRust(),
      signalStream: SettingsSnapshotChanged.rustSignalStream,
      map: (message) => AppSettings.fromSignalSnapshot(message.snapshot),
    );
    return const AppSettings.loading();
  }

  static String _normalizeHotkey(String value) {
    return switch (value) {
      'fn' || 'fnKey' => '63',
      'rightOption' => '61',
      'rightCommand' => '54',
      'leftCommand' => '55',
      'f5' => '96',
      _ => value,
    };
  }

  Future<void> _updateAndSend(
    AppSettings nextState,
    void Function() sendSignal,
  ) async {
    state = nextState.copyWith(hasSnapshot: true);
    sendSignal();
  }

  Future<void> setSelectedLocalModelId(String value) => _updateAndSend(
    state.copyWith(selectedLocalModelId: value),
    () => SelectLocalModel(modelId: value).sendSignalToRust(),
  );

  Future<void> setSelectedHotkey(String value) {
    final normalized = _normalizeHotkey(value);
    return _updateAndSend(
      state.copyWith(selectedHotkey: normalized),
      () => SetSelectedHotkey(selectedHotkey: normalized).sendSignalToRust(),
    );
  }

  Future<void> setSelectedMicrophoneId(String value) => _updateAndSend(
    state.copyWith(selectedMicrophoneId: value),
    () =>
        SetSelectedMicrophoneId(selectedMicrophoneId: value).sendSignalToRust(),
  );

  Future<void> setSoundEnabled(bool value) => _updateAndSend(
    state.copyWith(soundEnabled: value),
    () => SetSoundEnabled(soundEnabled: value).sendSignalToRust(),
  );

  Future<void> setCustomVocabulary(String value) => _updateAndSend(
    state.copyWith(customVocabulary: value),
    () => SetCustomVocabulary(customVocabulary: value).sendSignalToRust(),
  );

  Future<void> setMinimumRecordingDurationMs(double value) => _updateAndSend(
    state.copyWith(minimumRecordingDurationMs: value),
    () => SetMinimumRecordingDurationMs(
      minimumRecordingDurationMs: value,
    ).sendSignalToRust(),
  );

  Future<void> setHasCompletedSetup(bool value) => _updateAndSend(
    state.copyWith(hasCompletedSetup: value),
    () => SetHasCompletedSetup(hasCompletedSetup: value).sendSignalToRust(),
  );
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);
