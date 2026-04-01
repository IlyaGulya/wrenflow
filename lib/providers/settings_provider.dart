import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wrenflow/src/bindings/signals/signals.dart';

/// Keys used for shared_preferences storage.
class _SettingsKeys {
  static const apiKey = 'settings_api_key';
  static const apiBaseUrl = 'settings_api_base_url';
  static const selectedHotkey = 'settings_selected_hotkey';
  static const selectedMicrophoneId = 'settings_selected_microphone_id';
  static const soundEnabled = 'settings_sound_enabled';
  static const customVocabulary = 'settings_custom_vocabulary';
  static const transcriptionProvider = 'settings_transcription_provider';
  static const transcriptionModel = 'settings_transcription_model';
  static const minimumRecordingDurationMs =
      'settings_minimum_recording_duration_ms';
}

/// App settings state, mirrors the fields in UpdateConfig signal.
class AppSettings {
  const AppSettings({
    this.apiKey = '',
    this.apiBaseUrl = 'https://api.groq.com/openai/v1',
    this.selectedHotkey = '61',
    this.selectedMicrophoneId = 'default',
    this.soundEnabled = true,
    this.customVocabulary = '',
    this.transcriptionProvider = 'groq',
    this.transcriptionModel = 'whisper-large-v3-turbo',
    this.minimumRecordingDurationMs = 300.0,
  });

  final String apiKey;
  final String apiBaseUrl;
  final String selectedHotkey;
  final String selectedMicrophoneId;
  final bool soundEnabled;
  final String customVocabulary;
  final String transcriptionProvider;
  final String transcriptionModel;
  final double minimumRecordingDurationMs;

  AppSettings copyWith({
    String? apiKey,
    String? apiBaseUrl,
    String? selectedHotkey,
    String? selectedMicrophoneId,
    bool? soundEnabled,
    String? customVocabulary,
    String? transcriptionProvider,
    String? transcriptionModel,
    double? minimumRecordingDurationMs,
  }) {
    return AppSettings(
      apiKey: apiKey ?? this.apiKey,
      apiBaseUrl: apiBaseUrl ?? this.apiBaseUrl,
      selectedHotkey: selectedHotkey ?? this.selectedHotkey,
      selectedMicrophoneId: selectedMicrophoneId ?? this.selectedMicrophoneId,
      soundEnabled: soundEnabled ?? this.soundEnabled,
      customVocabulary: customVocabulary ?? this.customVocabulary,
      transcriptionProvider:
          transcriptionProvider ?? this.transcriptionProvider,
      transcriptionModel: transcriptionModel ?? this.transcriptionModel,
      minimumRecordingDurationMs:
          minimumRecordingDurationMs ?? this.minimumRecordingDurationMs,
    );
  }

  /// Convert to the rinf UpdateConfig signal for sending to Rust.
  UpdateConfig toUpdateConfig() {
    return UpdateConfig(
      selectedHotkey: selectedHotkey,
      selectedMicrophoneId: selectedMicrophoneId,
      soundEnabled: soundEnabled,
      customVocabulary: customVocabulary,
      minimumRecordingDurationMs: minimumRecordingDurationMs,
    );
  }
}

/// Manages app settings with persistence via shared_preferences.
/// Automatically sends UpdateConfig to Rust when settings change.
class SettingsNotifier extends Notifier<AppSettings> {
  SharedPreferences? _prefs;

  @override
  AppSettings build() {
    return const AppSettings();
  }

  /// Normalize legacy hotkey names to keycode strings.
  static String _normalizeHotkey(String value) {
    return switch (value) {
      'fn' || 'fnKey' => '63',
      'rightOption' => '61',
      'f5' => '96',
      _ => value,
    };
  }

  /// Load saved settings from shared_preferences.
  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    state = AppSettings(
      apiKey: _prefs!.getString(_SettingsKeys.apiKey) ?? '',
      apiBaseUrl: _prefs!.getString(_SettingsKeys.apiBaseUrl) ??
          'https://api.groq.com/openai/v1',
      selectedHotkey: _normalizeHotkey(
          _prefs!.getString(_SettingsKeys.selectedHotkey) ?? '61'),
      selectedMicrophoneId:
          _prefs!.getString(_SettingsKeys.selectedMicrophoneId) ?? 'default',
      soundEnabled: _prefs!.getBool(_SettingsKeys.soundEnabled) ?? true,
      customVocabulary:
          _prefs!.getString(_SettingsKeys.customVocabulary) ?? '',
      transcriptionProvider:
          _prefs!.getString(_SettingsKeys.transcriptionProvider) ?? 'groq',
      transcriptionModel:
          _prefs!.getString(_SettingsKeys.transcriptionModel) ??
              'whisper-large-v3-turbo',
      minimumRecordingDurationMs:
          _prefs!.getDouble(_SettingsKeys.minimumRecordingDurationMs) ?? 300.0,
    );
  }

  Future<void> _save() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    _prefs = prefs;
    await Future.wait([
      prefs.setString(_SettingsKeys.apiKey, state.apiKey),
      prefs.setString(_SettingsKeys.apiBaseUrl, state.apiBaseUrl),
      prefs.setString(_SettingsKeys.selectedHotkey, state.selectedHotkey),
      prefs.setString(
          _SettingsKeys.selectedMicrophoneId, state.selectedMicrophoneId),
      prefs.setBool(_SettingsKeys.soundEnabled, state.soundEnabled),
      prefs.setString(_SettingsKeys.customVocabulary, state.customVocabulary),
      prefs.setString(
          _SettingsKeys.transcriptionProvider, state.transcriptionProvider),
      prefs.setString(
          _SettingsKeys.transcriptionModel, state.transcriptionModel),
      prefs.setDouble(_SettingsKeys.minimumRecordingDurationMs,
          state.minimumRecordingDurationMs),
    ]);
  }

  void _syncToRust() {
    state.toUpdateConfig().sendSignalToRust();
  }

  Future<void> _updateAndSync(AppSettings newState) async {
    state = newState;
    await _save();
    _syncToRust();
  }

  Future<void> setApiKey(String value) =>
      _updateAndSync(state.copyWith(apiKey: value));

  Future<void> setApiBaseUrl(String value) =>
      _updateAndSync(state.copyWith(apiBaseUrl: value));

  Future<void> setSelectedHotkey(String value) =>
      _updateAndSync(state.copyWith(selectedHotkey: value));

  Future<void> setSelectedMicrophoneId(String value) =>
      _updateAndSync(state.copyWith(selectedMicrophoneId: value));

  Future<void> setSoundEnabled(bool value) =>
      _updateAndSync(state.copyWith(soundEnabled: value));

  Future<void> setCustomVocabulary(String value) =>
      _updateAndSync(state.copyWith(customVocabulary: value));

  Future<void> setTranscriptionProvider(String value) =>
      _updateAndSync(state.copyWith(transcriptionProvider: value));

  Future<void> setTranscriptionModel(String value) =>
      _updateAndSync(state.copyWith(transcriptionModel: value));

  Future<void> setMinimumRecordingDurationMs(double value) =>
      _updateAndSync(state.copyWith(minimumRecordingDurationMs: value));

  /// Send the current settings to Rust without changing them.
  void syncToRust() => _syncToRust();
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);
