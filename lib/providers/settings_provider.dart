import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wrenflow/src/bindings/signals/signals.dart';

import 'rust_snapshot_bridge.dart';

/// App settings state mirrored from the Rust-owned persisted config.
class AppSettings {
  const AppSettings({
    this.selectedLocalModelId = 'parakeet-tdt-0.6b-v3-onnx',
    this.selectedHotkey = '61',
    this.selectedMicrophoneId = 'default',
    this.soundEnabled = true,
    this.customVocabulary = '',
    this.minimumRecordingDurationMs = 300.0,
    this.hasCompletedSetup = false,
  });

  final String selectedLocalModelId;
  final String selectedHotkey;
  final String selectedMicrophoneId;
  final bool soundEnabled;
  final String customVocabulary;
  final double minimumRecordingDurationMs;
  final bool hasCompletedSetup;

  AppSettings copyWith({
    String? selectedLocalModelId,
    String? selectedHotkey,
    String? selectedMicrophoneId,
    bool? soundEnabled,
    String? customVocabulary,
    double? minimumRecordingDurationMs,
    bool? hasCompletedSetup,
  }) {
    return AppSettings(
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

  UpdateConfig toUpdateConfig() {
    return UpdateConfig(
      selectedHotkey: selectedHotkey,
      selectedMicrophoneId: selectedMicrophoneId,
      soundEnabled: soundEnabled,
      customVocabulary: customVocabulary,
      minimumRecordingDurationMs: minimumRecordingDurationMs,
    );
  }

  SettingsSnapshot toSignalSnapshot() {
    return SettingsSnapshot(
      selectedLocalModelId: selectedLocalModelId,
      selectedHotkey: selectedHotkey,
      selectedMicrophoneId: selectedMicrophoneId,
      soundEnabled: soundEnabled,
      customVocabulary: customVocabulary,
      minimumRecordingDurationMs: minimumRecordingDurationMs,
      hasCompletedSetup: hasCompletedSetup,
    );
  }

  static AppSettings fromSignalSnapshot(SettingsSnapshot snapshot) {
    return AppSettings(
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
    return const AppSettings();
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

  void _persistSnapshot(AppSettings nextState) {
    UpdateSettingsSnapshot(
      snapshot: nextState.toSignalSnapshot(),
    ).sendSignalToRust();
  }

  void _syncRuntime(AppSettings snapshot) {
    SelectLocalModel(modelId: snapshot.selectedLocalModelId).sendSignalToRust();
    snapshot.toUpdateConfig().sendSignalToRust();
  }

  Future<void> _updateAndSync(
    AppSettings nextState, {
    bool syncRuntime = true,
  }) async {
    state = nextState;
    _persistSnapshot(nextState);
    if (syncRuntime) {
      _syncRuntime(nextState);
    }
  }

  Future<void> setSelectedLocalModelId(String value) =>
      _updateAndSync(state.copyWith(selectedLocalModelId: value));

  Future<void> setSelectedHotkey(String value) =>
      _updateAndSync(state.copyWith(selectedHotkey: _normalizeHotkey(value)));

  Future<void> setSelectedMicrophoneId(String value) =>
      _updateAndSync(state.copyWith(selectedMicrophoneId: value));

  Future<void> setSoundEnabled(bool value) =>
      _updateAndSync(state.copyWith(soundEnabled: value));

  Future<void> setCustomVocabulary(String value) =>
      _updateAndSync(state.copyWith(customVocabulary: value));

  Future<void> setMinimumRecordingDurationMs(double value) =>
      _updateAndSync(state.copyWith(minimumRecordingDurationMs: value));

  Future<void> setHasCompletedSetup(bool value) => _updateAndSync(
    state.copyWith(hasCompletedSetup: value),
    syncRuntime: false,
  );

  void syncRuntime() => _syncRuntime(state);
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);
