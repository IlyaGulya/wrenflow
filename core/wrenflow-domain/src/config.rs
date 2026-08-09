//! App configuration — pure data types.
//!
//! `AppConfig` is a pure data struct — no IO, no platform paths.

use serde::{Deserialize, Serialize};

pub const DEFAULT_MINIMUM_RECORDING_DURATION_MS: f64 = 300.0;
pub const DEFAULT_SELECTED_HOTKEY_KEYCODE: u32 = 63;
pub const DEFAULT_SELECTED_HOTKEY: &str = "63";
pub const DEFAULT_SELECTED_MICROPHONE_ID: &str = "default";
pub const DEFAULT_SELECTED_LOCAL_MODEL_ID: &str = "parakeet-tdt-0.6b-v3-onnx";

pub const fn default_selected_hotkey_keycode() -> u32 {
    DEFAULT_SELECTED_HOTKEY_KEYCODE
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ThemePreference {
    #[default]
    System,
    Light,
    Dark,
}

/// All user-configurable settings. Pure data, no IO.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppConfig {
    pub minimum_recording_duration_ms: f64,
    pub custom_vocabulary: String,
    pub selected_hotkey: String,
    pub selected_microphone_id: String,
    pub selected_local_model_id: String,
    #[serde(default)]
    pub last_active_model_id: Option<String>,
    pub sound_enabled: bool,
    #[serde(default)]
    pub theme_preference: ThemePreference,
    pub has_completed_setup: bool,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            minimum_recording_duration_ms: DEFAULT_MINIMUM_RECORDING_DURATION_MS,
            custom_vocabulary: String::new(),
            selected_hotkey: DEFAULT_SELECTED_HOTKEY.to_string(),
            selected_microphone_id: DEFAULT_SELECTED_MICROPHONE_ID.to_string(),
            selected_local_model_id: DEFAULT_SELECTED_LOCAL_MODEL_ID.to_string(),
            last_active_model_id: None,
            sound_enabled: true,
            theme_preference: ThemePreference::System,
            has_completed_setup: false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        default_selected_hotkey_keycode, AppConfig, ThemePreference, DEFAULT_SELECTED_HOTKEY,
        DEFAULT_SELECTED_HOTKEY_KEYCODE,
    };

    #[test]
    fn clean_install_defaults_to_the_fn_key() {
        let config = AppConfig::default();

        assert_eq!(DEFAULT_SELECTED_HOTKEY_KEYCODE, 63);
        assert_eq!(default_selected_hotkey_keycode(), 63);
        assert_eq!(DEFAULT_SELECTED_HOTKEY, "63");
        assert_eq!(config.selected_hotkey, "63");
        assert_eq!(config.theme_preference, ThemePreference::System);
    }

    #[test]
    fn theme_preference_uses_stable_current_format_values() {
        assert_eq!(
            serde_json::to_string(&ThemePreference::System).unwrap(),
            "\"system\""
        );
        assert_eq!(
            serde_json::to_string(&ThemePreference::Light).unwrap(),
            "\"light\""
        );
        assert_eq!(
            serde_json::to_string(&ThemePreference::Dark).unwrap(),
            "\"dark\""
        );
    }
}
