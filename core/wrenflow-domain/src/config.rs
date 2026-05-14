//! App configuration — pure data types.
//!
//! `AppConfig` is a pure data struct — no IO, no platform paths.

use serde::{Deserialize, Serialize};

pub const DEFAULT_MINIMUM_RECORDING_DURATION_MS: f64 = 300.0;
pub const DEFAULT_SELECTED_HOTKEY: &str = "61";
pub const DEFAULT_SELECTED_MICROPHONE_ID: &str = "default";
pub const DEFAULT_SELECTED_LOCAL_MODEL_ID: &str = "parakeet-tdt-0.6b-v3-onnx";

pub fn default_selected_hotkey_keycode() -> u32 {
    DEFAULT_SELECTED_HOTKEY
        .parse()
        .expect("DEFAULT_SELECTED_HOTKEY must be a valid macOS keycode")
}

/// All user-configurable settings. Pure data, no IO.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppConfig {
    pub minimum_recording_duration_ms: f64,
    pub custom_vocabulary: String,
    pub selected_hotkey: String,
    pub selected_microphone_id: String,
    pub selected_local_model_id: String,
    pub sound_enabled: bool,
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
            sound_enabled: true,
            has_completed_setup: false,
        }
    }
}
