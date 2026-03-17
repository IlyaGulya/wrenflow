//! App configuration.
//!
//! `AppConfig` is a pure data struct — no IO, no platform paths.
//! `ConfigStore` handles persistence (load/save from disk).

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use thiserror::Error;

// ---------------------------------------------------------------------------
// Domain: pure config data
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Persistence: ConfigStore
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Platform paths (kept here for convenience, no IO)
// ---------------------------------------------------------------------------

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

// Backward-compat: keep the old methods on AppConfig for now
// so existing callers don't break. These delegate to ConfigStore.
impl AppConfig {
    #[deprecated(note = "Use ConfigStore::new(path).load() instead")]
    pub fn load(path: &Path) -> Result<Self, ConfigError> {
        ConfigStore::new(path.to_path_buf()).load()
    }

    #[deprecated(note = "Use ConfigStore::new(path).save(&config) instead")]
    pub fn save(&self, path: &Path) -> Result<(), ConfigError> {
        ConfigStore::new(path.to_path_buf()).save(self)
    }

    #[deprecated(note = "Use ConfigStore::new(path).load_or_default() instead")]
    pub fn load_or_default(path: &Path) -> Self {
        ConfigStore::new(path.to_path_buf()).load_or_default()
    }

    #[deprecated(note = "Use default_config_path(app_name) instead")]
    pub fn default_path(app_name: &str) -> PathBuf {
        default_config_path(app_name)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_config_roundtrip() {
        let dir = tempfile::tempdir().unwrap();
        let store = ConfigStore::new(dir.path().join("config.json"));
        let config = AppConfig::default();
        store.save(&config).unwrap();
        let loaded = store.load().unwrap();
        assert_eq!(loaded.transcription_provider, "local");
        assert!(!loaded.post_processing_enabled);
        assert!(loaded.sound_enabled);
    }

    #[test]
    fn load_or_default_missing_file() {
        let store = ConfigStore::new(PathBuf::from("/nonexistent/config.json"));
        let config = store.load_or_default();
        assert_eq!(config.minimum_recording_duration_ms, 200.0);
    }
}
