//! App configuration — pure data types.
//!
//! `AppConfig` is a pure data struct — no IO, no platform paths.

use serde::{Deserialize, Serialize};

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
            minimum_recording_duration_ms: 300.0,
            custom_vocabulary: String::new(),
            selected_hotkey: "61".to_string(),
            selected_microphone_id: "default".to_string(),
            selected_local_model_id: "parakeet-tdt-0.6b-v3-onnx".to_string(),
            sound_enabled: true,
            has_completed_setup: false,
        }
    }
}
