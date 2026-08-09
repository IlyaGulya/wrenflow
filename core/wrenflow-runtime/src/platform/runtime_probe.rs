use std::path::{Path, PathBuf};

fn repo_root() -> Option<PathBuf> {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .ok()
}

fn has_payload(path: &Path) -> bool {
    std::fs::metadata(path)
        .map(|metadata| metadata.is_file() && metadata.len() > 0)
        .unwrap_or(false)
}

fn probe_writable_dir(directory: &Path, marker_name: &str) -> bool {
    if std::fs::create_dir_all(directory).is_err() {
        return false;
    }

    let probe = directory.join(marker_name);
    match std::fs::write(&probe, b"ok") {
        Ok(()) => {
            let _ = std::fs::remove_file(probe);
            true
        }
        Err(_) => false,
    }
}

pub(crate) fn onnx_runtime_available() -> bool {
    let library_name = if cfg!(target_os = "macos") {
        "libonnxruntime.dylib"
    } else if cfg!(target_os = "windows") {
        "onnxruntime.dll"
    } else {
        "libonnxruntime.so"
    };

    let bundled_path = std::env::current_exe()
        .ok()
        .and_then(|path| path.parent().map(|parent| parent.join(library_name)));
    let vendor_path =
        repo_root().map(|root| root.join("vendor/onnxruntime/lib").join(library_name));

    [bundled_path, vendor_path]
        .into_iter()
        .flatten()
        .any(|path| has_payload(&path))
}

pub(crate) fn model_storage_writable() -> bool {
    probe_writable_dir(
        &crate::data_paths::current_data_paths().models,
        ".write-probe",
    )
}

pub(crate) fn history_storage_writable() -> bool {
    probe_writable_dir(
        &crate::data_paths::current_data_paths().root,
        ".history-write-probe",
    )
}
