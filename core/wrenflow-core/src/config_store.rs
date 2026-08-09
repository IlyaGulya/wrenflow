//! Config persistence — IO operations for AppConfig.
//!
//! `ConfigStore` handles load/save from disk.
//! `AppConfig` type itself lives in `wrenflow_domain::config`.

use std::path::{Path, PathBuf};
use thiserror::Error;
use wrenflow_domain::config::{
    AppConfig, DEFAULT_SELECTED_HOTKEY, DEFAULT_SELECTED_LOCAL_MODEL_ID,
};

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),
}

/// Loads and saves AppConfig to a JSON file.
pub struct ConfigStore {
    path: PathBuf,
}

impl ConfigStore {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    /// Create a store at the platform-default path.
    pub fn default_for(app_name: &str) -> Self {
        Self::new(default_config_path(app_name))
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn load(&self) -> Result<AppConfig, ConfigError> {
        let data = std::fs::read_to_string(&self.path)?;
        Ok(serde_json::from_str(&data)?)
    }

    pub fn save(&self, config: &AppConfig) -> Result<(), ConfigError> {
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let data = serde_json::to_string_pretty(config)?;
        std::fs::write(&self.path, data)?;
        Ok(())
    }

    pub fn load_or_default(&self) -> AppConfig {
        self.load().unwrap_or_default()
    }
}

#[cfg(target_os = "macos")]
fn legacy_preferences_path() -> Option<PathBuf> {
    let home = std::env::var("HOME").ok()?;
    Some(
        PathBuf::from(home)
            .join("Library/Preferences")
            .join("me.gulya.wrenflow.plist"),
    )
}

#[cfg(target_os = "macos")]
fn legacy_string(dict: &plist::Dictionary, key: &str) -> Option<String> {
    dict.get(key)?.as_string().map(ToOwned::to_owned)
}

#[cfg(target_os = "macos")]
fn legacy_bool(dict: &plist::Dictionary, key: &str) -> Option<bool> {
    dict.get(key)?.as_boolean()
}

#[cfg(target_os = "macos")]
fn legacy_f64(dict: &plist::Dictionary, key: &str) -> Option<f64> {
    dict.get(key)
        .and_then(|value| value.as_signed_integer().map(|v| v as f64))
        .or_else(|| dict.get(key).and_then(|value| value.as_real()))
}

#[cfg(target_os = "macos")]
pub fn merge_legacy_preferences(config: AppConfig) -> AppConfig {
    let Some(path) = legacy_preferences_path() else {
        return config;
    };
    let Ok(value) = plist::Value::from_file(&path) else {
        return config;
    };
    let Some(dict) = value.as_dictionary() else {
        return config;
    };

    merge_legacy_preferences_from_dict(config, dict)
}

#[cfg(target_os = "macos")]
fn merge_legacy_preferences_from_dict(
    mut config: AppConfig,
    dict: &plist::Dictionary,
) -> AppConfig {
    if !config.has_completed_setup {
        if let Some(has_completed_setup) = legacy_bool(dict, "flutter.has_completed_setup") {
            if has_completed_setup {
                config.has_completed_setup = true;
            }
        }
    }

    if config.selected_hotkey == DEFAULT_SELECTED_HOTKEY {
        if let Some(selected_hotkey) = legacy_string(dict, "flutter.settings_selected_hotkey") {
            if !selected_hotkey.is_empty() {
                config.selected_hotkey = selected_hotkey;
            }
        }
    }

    if config.selected_local_model_id == DEFAULT_SELECTED_LOCAL_MODEL_ID {
        if let Some(selected_model_id) =
            legacy_string(dict, "flutter.settings_selected_local_model_id")
        {
            if !selected_model_id.is_empty() {
                config.selected_local_model_id = selected_model_id;
            }
        }
    }

    if config.selected_microphone_id == "default" {
        if let Some(selected_microphone_id) =
            legacy_string(dict, "flutter.settings_selected_microphone_id")
        {
            if !selected_microphone_id.is_empty() {
                config.selected_microphone_id = selected_microphone_id;
            }
        }
    }

    if config.custom_vocabulary.is_empty() {
        if let Some(custom_vocabulary) = legacy_string(dict, "flutter.settings_custom_vocabulary") {
            if !custom_vocabulary.is_empty() {
                config.custom_vocabulary = custom_vocabulary;
            }
        }
    }

    if config.minimum_recording_duration_ms == 300.0 {
        if let Some(min_duration) =
            legacy_f64(dict, "flutter.settings_minimum_recording_duration_ms")
        {
            if min_duration > 0.0 {
                config.minimum_recording_duration_ms = min_duration;
            }
        }
    }

    if config.sound_enabled {
        if let Some(sound_enabled) = legacy_bool(dict, "flutter.settings_sound_enabled") {
            config.sound_enabled = sound_enabled;
        }
    }

    config
}

#[cfg(not(target_os = "macos"))]
pub fn merge_legacy_preferences(config: AppConfig) -> AppConfig {
    config
}

/// Default config file path for the current platform.
pub fn default_config_path(app_name: &str) -> PathBuf {
    #[cfg(target_os = "macos")]
    {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
        PathBuf::from(home)
            .join("Library/Application Support")
            .join(app_name)
            .join("config.json")
    }
    #[cfg(target_os = "android")]
    {
        PathBuf::from("/data/data/me.gulya.wrenflow/files/config.json")
    }
    #[cfg(target_os = "windows")]
    {
        let appdata = std::env::var("APPDATA").unwrap_or_else(|_| ".".to_string());
        PathBuf::from(appdata).join(app_name).join("config.json")
    }
    #[cfg(not(any(target_os = "macos", target_os = "android", target_os = "windows")))]
    {
        PathBuf::from(".").join("config.json")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wrenflow_domain::config::{
        DEFAULT_MINIMUM_RECORDING_DURATION_MS, DEFAULT_SELECTED_HOTKEY,
        DEFAULT_SELECTED_LOCAL_MODEL_ID,
    };

    #[test]
    fn default_config_roundtrip() {
        let dir = tempfile::tempdir().unwrap();
        let store = ConfigStore::new(dir.path().join("config.json"));
        let config = AppConfig::default();
        store.save(&config).unwrap();
        let loaded = store.load().unwrap();
        assert!(loaded.sound_enabled);
        assert_eq!(loaded.selected_hotkey, DEFAULT_SELECTED_HOTKEY);
        assert_eq!(
            loaded.selected_local_model_id,
            DEFAULT_SELECTED_LOCAL_MODEL_ID
        );
    }

    #[test]
    fn load_or_default_missing_file() {
        let store = ConfigStore::new(PathBuf::from("/nonexistent/config.json"));
        let config = store.load_or_default();
        assert_eq!(
            config.minimum_recording_duration_ms,
            DEFAULT_MINIMUM_RECORDING_DURATION_MS
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn legacy_preferences_fill_missing_defaults() {
        let mut dict = plist::Dictionary::new();
        dict.insert("flutter.has_completed_setup".into(), true.into());
        dict.insert("flutter.settings_selected_hotkey".into(), "54".into());
        dict.insert(
            "flutter.settings_selected_local_model_id".into(),
            "whisper-large-v3-turbo-onnx".into(),
        );
        dict.insert(
            "flutter.settings_selected_microphone_id".into(),
            "usb-mic".into(),
        );
        dict.insert("flutter.settings_custom_vocabulary".into(), "OpenAI".into());
        dict.insert(
            "flutter.settings_minimum_recording_duration_ms".into(),
            450.into(),
        );
        dict.insert("flutter.settings_sound_enabled".into(), false.into());

        let merged = merge_legacy_preferences_from_dict(AppConfig::default(), &dict);

        assert!(merged.has_completed_setup);
        assert_eq!(merged.selected_hotkey, "54");
        assert_eq!(
            merged.selected_local_model_id,
            "whisper-large-v3-turbo-onnx"
        );
        assert_eq!(merged.selected_microphone_id, "usb-mic");
        assert_eq!(merged.custom_vocabulary, "OpenAI");
        assert_eq!(merged.minimum_recording_duration_ms, 450.0);
        assert!(!merged.sound_enabled);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn legacy_preferences_do_not_override_non_default_config() {
        let mut dict = plist::Dictionary::new();
        dict.insert("flutter.has_completed_setup".into(), true.into());
        dict.insert("flutter.settings_selected_hotkey".into(), "54".into());
        dict.insert(
            "flutter.settings_selected_local_model_id".into(),
            "whisper-large-v3-turbo-onnx".into(),
        );
        dict.insert(
            "flutter.settings_selected_microphone_id".into(),
            "usb-mic".into(),
        );
        dict.insert("flutter.settings_custom_vocabulary".into(), "legacy".into());
        dict.insert(
            "flutter.settings_minimum_recording_duration_ms".into(),
            450.into(),
        );
        dict.insert("flutter.settings_sound_enabled".into(), false.into());

        let config = AppConfig {
            // A persisted pre-migration choice remains authoritative even when
            // the clean-install default changes.
            selected_hotkey: "61".to_string(),
            selected_local_model_id: "user-picked-model".to_string(),
            selected_microphone_id: "built-in".to_string(),
            custom_vocabulary: "current".to_string(),
            minimum_recording_duration_ms: 600.0,
            sound_enabled: false,
            has_completed_setup: true,
            last_active_model_id: Some("parakeet-tdt-0.6b-v3-onnx".to_string()),
        };

        let merged = merge_legacy_preferences_from_dict(config, &dict);

        assert_eq!(merged.selected_hotkey, "61");
        assert_eq!(merged.selected_local_model_id, "user-picked-model");
        assert_eq!(merged.selected_microphone_id, "built-in");
        assert_eq!(merged.custom_vocabulary, "current");
        assert_eq!(merged.minimum_recording_duration_ms, 600.0);
        assert!(!merged.sound_enabled);
        assert_eq!(
            merged.last_active_model_id.as_deref(),
            Some("parakeet-tdt-0.6b-v3-onnx")
        );
    }
}
