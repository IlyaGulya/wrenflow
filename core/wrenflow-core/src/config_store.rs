//! Config persistence — IO operations for AppConfig.
//!
//! `ConfigStore` handles load/save from disk.
//! `AppConfig` type itself lives in `wrenflow_domain::config`.

use wrenflow_domain::config::AppConfig;
use std::path::{Path, PathBuf};
use thiserror::Error;

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

    #[test]
    fn default_config_roundtrip() {
        let dir = tempfile::tempdir().unwrap();
        let store = ConfigStore::new(dir.path().join("config.json"));
        let config = AppConfig::default();
        store.save(&config).unwrap();
        let loaded = store.load().unwrap();
        assert!(loaded.sound_enabled);
        assert_eq!(loaded.selected_hotkey, "fn");
    }

    #[test]
    fn load_or_default_missing_file() {
        let store = ConfigStore::new(PathBuf::from("/nonexistent/config.json"));
        let config = store.load_or_default();
        assert_eq!(config.minimum_recording_duration_ms, 200.0);
    }
}
