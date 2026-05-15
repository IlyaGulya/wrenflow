use std::path::{Path, PathBuf};

fn repo_root() -> Option<PathBuf> {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .ok()
}

fn has_payload(path: &Path) -> bool {
    std::fs::metadata(path)
        .map(|meta| meta.is_file() && meta.len() > 0)
        .unwrap_or(false)
}

fn probe_writable_dir(dir: &Path, marker_name: &str) -> bool {
    if std::fs::create_dir_all(dir).is_err() {
        return false;
    }

    let probe = dir.join(marker_name);
    match std::fs::write(&probe, b"ok") {
        Ok(()) => {
            let _ = std::fs::remove_file(probe);
            true
        }
        Err(_) => false,
    }
}

pub fn onnx_runtime_available() -> bool {
    let library_name = if cfg!(target_os = "macos") {
        "libonnxruntime.dylib"
    } else if cfg!(target_os = "windows") {
        "onnxruntime.dll"
    } else {
        "libonnxruntime.so"
    };

    let bundled_path = std::env::current_exe().ok().and_then(|path| {
        path.parent()
            .map(|parent| parent.join(library_name))
    });
    let vendor_path = repo_root().map(|root| {
        root.join("vendor/onnxruntime/lib").join(library_name)
    });

    [bundled_path, vendor_path]
        .into_iter()
        .flatten()
        .any(|path| has_payload(&path))
}

pub fn model_storage_writable() -> bool {
    let Some(base) = dirs::data_local_dir() else {
        return false;
    };

    let dir = base.join("wrenflow").join("models");
    probe_writable_dir(&dir, ".write-probe")
}

pub fn history_storage_writable() -> bool {
    let Some(base) = dirs::data_local_dir() else {
        return false;
    };

    let dir = base.join("wrenflow");
    probe_writable_dir(&dir, ".history-write-probe")
}
