//! Config persistence — IO operations for AppConfig.
//!
//! `ConfigStore` handles load/save from disk.
//! `AppConfig` type itself lives in `wrenflow_domain::config`.

use std::fs::{File, OpenOptions};
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use thiserror::Error;
use wrenflow_domain::config::AppConfig;

static FILE_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("current config at {path} was invalid and was quarantined at {quarantined}: {source}")]
    CorruptQuarantined {
        path: PathBuf,
        quarantined: PathBuf,
        #[source]
        source: serde_json::Error,
    },
    #[error(
        "current config at {path} is invalid ({source}) and could not be quarantined: {quarantine_error}"
    )]
    CorruptNotQuarantined {
        path: PathBuf,
        #[source]
        source: serde_json::Error,
        quarantine_error: std::io::Error,
    },
}

/// Loads and saves AppConfig to a JSON file.
pub struct ConfigStore {
    path: PathBuf,
}

impl ConfigStore {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn load(&self) -> Result<AppConfig, ConfigError> {
        let data = std::fs::read(&self.path)?;
        match serde_json::from_slice(&data) {
            Ok(config) => Ok(config),
            Err(source) => match quarantine_file(&self.path) {
                Ok(quarantined) => Err(ConfigError::CorruptQuarantined {
                    path: self.path.clone(),
                    quarantined,
                    source,
                }),
                Err(quarantine_error) => Err(ConfigError::CorruptNotQuarantined {
                    path: self.path.clone(),
                    source,
                    quarantine_error,
                }),
            },
        }
    }

    pub fn save(&self, config: &AppConfig) -> Result<(), ConfigError> {
        let mut data = serde_json::to_vec_pretty(config)?;
        data.push(b'\n');
        atomic_write(&self.path, &data, |_| Ok(()))?;
        Ok(())
    }
}

fn atomic_write(
    path: &Path,
    contents: &[u8],
    before_rename: impl FnOnce(&Path) -> std::io::Result<()>,
) -> std::io::Result<()> {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    std::fs::create_dir_all(parent)?;

    let temporary = unique_sibling(path, "tmp");
    let result = (|| {
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temporary)?;
        file.write_all(contents)?;
        file.flush()?;
        file.sync_all()?;
        before_rename(&temporary)?;
        std::fs::rename(&temporary, path)?;
        sync_directory(parent)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}

fn quarantine_file(path: &Path) -> std::io::Result<PathBuf> {
    let quarantined = unique_sibling(path, "corrupt");
    std::fs::rename(path, &quarantined)?;
    sync_directory(path.parent().unwrap_or_else(|| Path::new(".")))?;
    Ok(quarantined)
}

fn unique_sibling(path: &Path, marker: &str) -> PathBuf {
    let sequence = FILE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("config.json");
    path.with_file_name(format!(
        "{file_name}.{marker}-{timestamp}-{}-{sequence}",
        std::process::id()
    ))
}

#[cfg(unix)]
fn sync_directory(directory: &Path) -> std::io::Result<()> {
    File::open(directory)?.sync_all()
}

#[cfg(not(unix))]
fn sync_directory(_directory: &Path) -> std::io::Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use wrenflow_domain::config::{DEFAULT_SELECTED_HOTKEY, DEFAULT_SELECTED_LOCAL_MODEL_ID};

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
    fn missing_file_is_explicit() {
        let store = ConfigStore::new(PathBuf::from("/nonexistent/config.json"));
        assert!(matches!(
            store.load(),
            Err(ConfigError::Io(error)) if error.kind() == std::io::ErrorKind::NotFound
        ));
    }

    #[test]
    fn corrupt_config_is_preserved_in_quarantine() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.json");
        std::fs::write(&path, b"{not-json").unwrap();

        let error = ConfigStore::new(path.clone()).load().unwrap_err();
        let ConfigError::CorruptQuarantined { quarantined, .. } = error else {
            panic!("expected quarantined config");
        };
        assert!(!path.exists());
        assert_eq!(std::fs::read(quarantined).unwrap(), b"{not-json");
    }

    #[test]
    fn interrupted_atomic_write_retains_previous_config() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.json");
        let store = ConfigStore::new(path.clone());
        let mut original = AppConfig::default();
        original.selected_hotkey = "54".to_string();
        store.save(&original).unwrap();

        let replacement = serde_json::to_vec(&AppConfig::default()).unwrap();
        let error = atomic_write(&path, &replacement, |_| {
            Err(std::io::Error::other("injected interruption"))
        })
        .unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::Other);
        assert_eq!(store.load().unwrap().selected_hotkey, "54");
        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 1);
    }

    #[test]
    fn concurrent_writers_never_publish_partial_json() {
        let dir = tempfile::tempdir().unwrap();
        let path = std::sync::Arc::new(dir.path().join("config.json"));
        let writers: Vec<_> = (0..16)
            .map(|index| {
                let path = path.clone();
                std::thread::spawn(move || {
                    let mut config = AppConfig::default();
                    config.selected_hotkey = index.to_string();
                    ConfigStore::new((*path).clone()).save(&config).unwrap();
                })
            })
            .collect();
        for writer in writers {
            writer.join().unwrap();
        }

        let loaded = ConfigStore::new((*path).clone()).load().unwrap();
        assert!((0..16).any(|index| loaded.selected_hotkey == index.to_string()));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn populated_flutter_plist_is_ignored() {
        let dir = tempfile::tempdir().unwrap();
        let legacy = dir
            .path()
            .join("Library/Preferences/me.gulya.wrenflow.plist");
        std::fs::create_dir_all(legacy.parent().unwrap()).unwrap();
        std::fs::write(
            &legacy,
            br#"<?xml version="1.0"?><plist version="1.0"><dict><key>flutter.has_completed_setup</key><true/></dict></plist>"#,
        )
        .unwrap();
        let current_path = dir
            .path()
            .join("Library/Application Support/me.gulya.wrenflow/gpui-v1/config.json");
        let store = ConfigStore::new(current_path);
        store.save(&AppConfig::default()).unwrap();

        assert!(!store.load().unwrap().has_completed_setup);
        assert!(legacy.exists());
    }
}
