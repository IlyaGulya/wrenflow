use std::path::{Path, PathBuf};
use std::sync::OnceLock;

/// The bundle identifier remains stable for TCC, while all GPUI-owned data is
/// isolated below this versioned namespace. No path outside this root is read
/// by the production runtime.
pub(crate) const CURRENT_DATA_NAMESPACE: &str = "me.gulya.wrenflow/gpui-v1";

static CURRENT_DATA_BASE_OVERRIDE: OnceLock<PathBuf> = OnceLock::new();

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct CurrentDataPaths {
    pub(crate) root: PathBuf,
    pub(crate) config: PathBuf,
    pub(crate) history: PathBuf,
    pub(crate) recordings: PathBuf,
    pub(crate) models: PathBuf,
    pub(crate) diagnostics: PathBuf,
    pub(crate) recovery: PathBuf,
    pub(crate) updates: PathBuf,
}

impl CurrentDataPaths {
    pub(crate) fn under(data_directory: impl AsRef<Path>) -> Self {
        let root = data_directory.as_ref().join(CURRENT_DATA_NAMESPACE);
        Self {
            config: root.join("config.json"),
            history: root.join("history.sqlite"),
            recordings: root.join("recordings"),
            models: root.join("models"),
            diagnostics: root.join("diagnostics"),
            recovery: root.join("recovery"),
            updates: root.join("updates"),
            root,
        }
    }
}

pub(crate) fn current_data_paths() -> CurrentDataPaths {
    let base = CURRENT_DATA_BASE_OVERRIDE
        .get()
        .cloned()
        .unwrap_or_else(|| dirs::data_dir().unwrap_or_else(|| PathBuf::from(".")));
    CurrentDataPaths::under(base)
}

pub(crate) fn install_current_data_base_override(base: PathBuf) -> Result<(), ()> {
    CURRENT_DATA_BASE_OVERRIDE.set(base).map_err(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;
    use wrenflow_core::ConfigStore;
    use wrenflow_domain::config::AppConfig;

    fn endurance_fixture() -> tempfile::TempDir {
        if let Some(root) = std::env::var_os("WRENFLOW_ENDURANCE_DISPOSABLE_ROOT") {
            let root = PathBuf::from(root);
            assert!(root.is_absolute() && root.is_dir() && !root.is_symlink());
            tempfile::Builder::new()
                .prefix("data-paths-")
                .tempdir_in(root)
                .unwrap()
        } else {
            tempfile::Builder::new()
                .prefix("wrenflow-gpui-v1-data-paths-")
                .tempdir()
                .unwrap()
        }
    }

    #[test]
    fn current_namespace_does_not_consume_populated_flutter_roots() {
        let fixture = tempfile::tempdir().unwrap();
        let data_dir = fixture.path().join("Library/Application Support");
        let legacy_upper = data_dir.join("Wrenflow");
        let legacy_lower = data_dir.join("wrenflow");
        std::fs::create_dir_all(&legacy_upper).unwrap();
        std::fs::create_dir_all(&legacy_lower).unwrap();
        std::fs::write(
            legacy_upper.join("config.json"),
            br#"{"selected_hotkey":"54","has_completed_setup":true}"#,
        )
        .unwrap();
        std::fs::write(legacy_upper.join("history.sqlite"), b"legacy-history").unwrap();
        std::fs::write(legacy_lower.join("crash.log"), b"legacy-crash").unwrap();

        let paths = CurrentDataPaths::under(&data_dir);
        assert_eq!(
            paths.root,
            data_dir.join("me.gulya.wrenflow").join("gpui-v1")
        );
        assert!(!paths.config.exists());
        assert!(!paths.history.exists());

        let current = AppConfig::default();
        ConfigStore::new(paths.config.clone())
            .save(&current)
            .unwrap();
        let loaded = ConfigStore::new(paths.config).load().unwrap();
        assert_eq!(loaded.selected_hotkey, current.selected_hotkey);
        assert!(!loaded.has_completed_setup);

        std::fs::create_dir_all(&paths.recordings).unwrap();
        std::fs::create_dir_all(&paths.models).unwrap();
        std::fs::write(paths.recordings.join("current.ogg"), b"current-audio").unwrap();
        std::fs::write(paths.models.join("current-model"), b"current-model").unwrap();
        let relaunched = CurrentDataPaths::under(&data_dir);
        assert_eq!(
            std::fs::read(relaunched.recordings.join("current.ogg")).unwrap(),
            b"current-audio"
        );
        assert_eq!(
            std::fs::read(relaunched.models.join("current-model")).unwrap(),
            b"current-model"
        );
        assert_eq!(
            std::fs::read(legacy_upper.join("history.sqlite")).unwrap(),
            b"legacy-history"
        );
        assert_eq!(
            std::fs::read(legacy_lower.join("crash.log")).unwrap(),
            b"legacy-crash"
        );
    }

    #[test]
    fn twenty_current_line_relaunches_preserve_only_gpui_v1_state() {
        const CYCLES: usize = 20;

        let fixture = endurance_fixture();
        let data_dir = fixture.path().join("Library/Application Support");
        let legacy = data_dir.join("Wrenflow");
        std::fs::create_dir_all(&legacy).unwrap();
        std::fs::write(legacy.join("config.json"), b"legacy-config").unwrap();
        std::fs::write(legacy.join("history.sqlite"), b"legacy-history").unwrap();

        let paths = CurrentDataPaths::under(&data_dir);
        std::fs::create_dir_all(&paths.recordings).unwrap();
        std::fs::create_dir_all(&paths.models).unwrap();
        std::fs::write(&paths.history, b"current-history").unwrap();
        std::fs::write(paths.recordings.join("current.ogg"), b"current-recording").unwrap();
        std::fs::write(paths.models.join("current.onnx"), b"current-model").unwrap();

        for cycle in 0..CYCLES {
            let relaunched = CurrentDataPaths::under(&data_dir);
            let mut config = AppConfig::default();
            config.has_completed_setup = true;
            ConfigStore::new(relaunched.config.clone())
                .save(&config)
                .unwrap();

            let loaded = ConfigStore::new(relaunched.config).load().unwrap();
            assert!(
                loaded.has_completed_setup,
                "current config was not preserved on cycle {cycle}"
            );
            assert_eq!(loaded.selected_hotkey, config.selected_hotkey);
            assert_eq!(
                std::fs::read(&relaunched.history).unwrap(),
                b"current-history"
            );
            assert_eq!(
                std::fs::read(relaunched.recordings.join("current.ogg")).unwrap(),
                b"current-recording"
            );
            assert_eq!(
                std::fs::read(relaunched.models.join("current.onnx")).unwrap(),
                b"current-model"
            );
            assert_eq!(
                std::fs::read(legacy.join("config.json")).unwrap(),
                b"legacy-config"
            );
            assert_eq!(
                std::fs::read(legacy.join("history.sqlite")).unwrap(),
                b"legacy-history"
            );
        }
    }
}
