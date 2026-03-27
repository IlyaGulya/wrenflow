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
    pub sound_enabled: bool,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            minimum_recording_duration_ms: 200.0,
            custom_vocabulary: String::new(),
            selected_hotkey: "fn".to_string(),
            selected_microphone_id: "default".to_string(),
            sound_enabled: true,
        }
    }
}
