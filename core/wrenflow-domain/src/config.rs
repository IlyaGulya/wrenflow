//! App configuration — pure data types.
//!
//! `AppConfig` is a pure data struct — no IO, no platform paths.

use serde::{Deserialize, Serialize};

/// All user-configurable settings. Pure data, no IO.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppConfig {
    pub transcription_provider: String,
    pub post_processing_enabled: bool,
    pub post_processing_model: String,
    pub api_base_url: String,
    pub minimum_recording_duration_ms: f64,
    pub custom_vocabulary: String,
    pub custom_system_prompt: String,
    pub custom_context_prompt: String,
    pub selected_hotkey: String,
    pub selected_microphone_id: String,
    pub sound_enabled: bool,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            transcription_provider: "local".to_string(),
            post_processing_enabled: false,
            post_processing_model: "meta-llama/llama-4-scout-17b-16e-instruct".to_string(),
            api_base_url: "https://api.groq.com/openai/v1".to_string(),
            minimum_recording_duration_ms: 200.0,
            custom_vocabulary: String::new(),
            custom_system_prompt: String::new(),
            custom_context_prompt: String::new(),
            selected_hotkey: "fn".to_string(),
            selected_microphone_id: "default".to_string(),
            sound_enabled: true,
        }
    }
}
