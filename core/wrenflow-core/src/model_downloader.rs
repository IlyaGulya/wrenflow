//! Fail-closed model downloader for immutable Hugging Face revisions.

use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fs::File;
use std::io::{Read, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::UNIX_EPOCH;
use wrenflow_domain::model_management::{
    DownloadProgress, LocalModelState, ModelDownloadListener, ModelFile, ModelInfo,
};

const HASH_BUFFER_BYTES: usize = 1024 * 1024;

fn safe_relative_path(path: &str) -> bool {
    !path.is_empty()
        && path
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-' | b'/'))
        && Path::new(path)
            .components()
            .all(|part| matches!(part, Component::Normal(_)))
}

fn valid_lower_hex(value: &str, len: usize) -> bool {
    value.len() == len
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn validate_model_manifest(model: &ModelInfo) -> Result<(), String> {
    let repo_parts: Vec<_> = model.repo_id.split('/').collect();
    if repo_parts.len() != 2 || repo_parts.iter().any(|part| !safe_relative_path(part)) {
        return Err(format!("Model {} has an invalid repository ID", model.id));
    }
    if !valid_lower_hex(&model.revision, 40) {
        return Err(format!(
            "Model {} is not pinned to an immutable 40-character revision",
            model.id
        ));
    }
    if model.expected_files.is_empty() {
        return Err(format!("Model {} has an empty asset manifest", model.id));
    }

    let mut paths = HashSet::new();
    for asset in &model.expected_files {
        if !safe_relative_path(&asset.path) {
            return Err(format!(
                "Model {} has an unsafe asset path: {}",
                model.id, asset.path
            ));
        }
        if !paths.insert(asset.path.as_str()) {
            return Err(format!(
                "Model {} repeats asset path {}",
                model.id, asset.path
            ));
        }
        if asset.size == 0 || !valid_lower_hex(&asset.sha256, 64) {
            return Err(format!(
                "Model {} has invalid integrity metadata for {}",
                model.id, asset.path
            ));
        }
    }
    for generated in &model.generated_files {
        if !safe_relative_path(generated) || paths.contains(generated.as_str()) {
            return Err(format!(
                "Model {} has an unsafe generated path: {generated}",
                model.id
            ));
        }
    }
    Ok(())
}

fn sha256_file(path: &Path) -> Result<String, String> {
    let mut file = File::open(path).map_err(|error| format!("Open {}: {error}", path.display()))?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0_u8; HASH_BUFFER_BYTES];
    loop {
        let count = file
            .read(&mut buffer)
            .map_err(|error| format!("Read {}: {error}", path.display()))?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn file_matches(asset: &ModelFile, path: &Path) -> bool {
    let Ok(metadata) = std::fs::metadata(path) else {
        return false;
    };
    metadata.is_file()
        && metadata.len() == asset.size
        && sha256_file(path).is_ok_and(|actual| actual == asset.sha256)
}

fn marker_contents(model: &ModelInfo, model_dir: &Path) -> Result<String, String> {
    let mut marker = format!(
        "format=2\nmodel_id={}\nrepo_id={}\nrevision={}\n",
        model.id, model.repo_id, model.revision
    );
    for asset in &model.expected_files {
        let path = model_dir.join(&asset.path);
        let metadata = std::fs::metadata(&path)
            .map_err(|error| format!("Read metadata for {}: {error}", asset.path))?;
        if !metadata.is_file() || metadata.len() != asset.size {
            return Err(format!("Model asset {} has the wrong size", asset.path));
        }
        let modified = metadata
            .modified()
            .map_err(|error| format!("Read mtime for {}: {error}", asset.path))?
            .duration_since(UNIX_EPOCH)
            .map_err(|error| format!("Invalid mtime for {}: {error}", asset.path))?
            .as_nanos();
        marker.push_str(&format!(
            "asset={} size={} sha256={} modified_ns={}\n",
            asset.path, asset.size, asset.sha256, modified
        ));
    }
    Ok(marker)
}

fn generated_files_match(model: &ModelInfo, model_dir: &Path, expected: &str) -> bool {
    model.generated_files.iter().all(|generated| {
        std::fs::read_to_string(model_dir.join(generated)).is_ok_and(|actual| actual == expected)
    })
}

/// Check whether every pinned asset is present and still matches the metadata
/// attested when its SHA-256 was verified. Any file change invalidates the
/// marker and forces a one-time full hash verification before reuse.
pub fn is_model_present(model: &ModelInfo, model_dir: &Path) -> bool {
    if validate_model_manifest(model).is_err() {
        return false;
    }
    if !model
        .expected_files
        .iter()
        .all(|asset| file_matches(asset, &model_dir.join(&asset.path)))
    {
        return false;
    }
    let Ok(expected_marker) = marker_contents(model, model_dir) else {
        return false;
    };
    generated_files_match(model, model_dir, &expected_marker)
}

fn write_install_markers(model: &ModelInfo, model_dir: &Path) -> Result<(), String> {
    let marker = marker_contents(model, model_dir)?;
    for generated in &model.generated_files {
        let path = model_dir.join(generated);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|error| format!("Create runtime dir for {generated}: {error}"))?;
        }
        let temporary = model_dir.join(format!("{generated}.part"));
        let mut file = File::create(&temporary)
            .map_err(|error| format!("Create runtime file {generated}: {error}"))?;
        file.write_all(marker.as_bytes())
            .map_err(|error| format!("Write runtime file {generated}: {error}"))?;
        file.sync_all()
            .map_err(|error| format!("Sync runtime file {generated}: {error}"))?;
        std::fs::rename(&temporary, &path)
            .map_err(|error| format!("Publish runtime file {generated}: {error}"))?;
    }
    Ok(())
}

/// Download model files from an immutable Hugging Face revision and verify
/// every byte against the checked-in SHA-256 manifest before publishing it.
pub async fn download_model(
    model: &ModelInfo,
    model_dir: &Path,
    listener: Arc<dyn ModelDownloadListener>,
    cancel_flag: Arc<AtomicBool>,
) -> Result<PathBuf, String> {
    validate_model_manifest(model)?;
    std::fs::create_dir_all(model_dir).map_err(|error| format!("Create model dir: {error}"))?;

    if is_model_present(model, model_dir) {
        log::info!("Model {} is already verified", model.id);
        listener.on_state_changed(LocalModelState::Ready);
        return Ok(model_dir.to_path_buf());
    }

    let client = reqwest::Client::builder()
        .user_agent(concat!("wrenflow/", env!("CARGO_PKG_VERSION")))
        .https_only(true)
        .redirect(reqwest::redirect::Policy::limited(10))
        .build()
        .map_err(|error| format!("Create model HTTP client: {error}"))?;

    let total_bytes = model.expected_files.iter().map(|asset| asset.size).sum();
    let files_total = model.expected_files.len();
    let mut bytes_downloaded = 0_u64;

    for (index, asset) in model.expected_files.iter().enumerate() {
        if cancel_flag.load(Ordering::Relaxed) {
            return Err("Cancelled".to_string());
        }

        let destination = model_dir.join(&asset.path);
        if file_matches(asset, &destination) {
            bytes_downloaded += asset.size;
            listener.on_progress(DownloadProgress {
                bytes_downloaded,
                total_bytes: Some(total_bytes),
                current_file: asset.path.clone(),
                files_completed: index + 1,
                files_total,
            });
            continue;
        }

        if let Some(parent) = destination.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|error| format!("Create parent dir for {}: {error}", asset.path))?;
        }
        let url = format!(
            "https://huggingface.co/{}/resolve/{}/{}",
            model.repo_id, model.revision, asset.path
        );
        log::info!("Downloading verified model asset {}", asset.path);
        let response = client
            .get(url)
            .send()
            .await
            .map_err(|error| format!("Download {}: {error}", asset.path))?;
        if !response.status().is_success() {
            return Err(format!(
                "Download {}: HTTP {}",
                asset.path,
                response.status()
            ));
        }
        if let Some(length) = response.content_length() {
            if length != asset.size {
                return Err(format!(
                    "Reject {}: expected {} bytes, server declared {length}",
                    asset.path, asset.size
                ));
            }
        }

        let temporary = model_dir.join(format!("{}.part", asset.path));
        let mut file =
            File::create(&temporary).map_err(|error| format!("Create {}: {error}", asset.path))?;
        let mut hasher = Sha256::new();
        let mut downloaded_file_bytes = 0_u64;
        use tokio_stream::StreamExt;
        let mut stream = response.bytes_stream();
        while let Some(chunk) = stream.next().await {
            if cancel_flag.load(Ordering::Relaxed) {
                drop(file);
                let _ = std::fs::remove_file(&temporary);
                return Err("Cancelled".to_string());
            }
            let chunk = chunk.map_err(|error| format!("Read {}: {error}", asset.path))?;
            downloaded_file_bytes += chunk.len() as u64;
            if downloaded_file_bytes > asset.size {
                drop(file);
                let _ = std::fs::remove_file(&temporary);
                return Err(format!(
                    "Reject {}: response exceeds pinned size",
                    asset.path
                ));
            }
            hasher.update(&chunk);
            file.write_all(&chunk)
                .map_err(|error| format!("Write {}: {error}", asset.path))?;
            listener.on_progress(DownloadProgress {
                bytes_downloaded: bytes_downloaded + downloaded_file_bytes,
                total_bytes: Some(total_bytes),
                current_file: asset.path.clone(),
                files_completed: index,
                files_total,
            });
        }
        file.sync_all()
            .map_err(|error| format!("Sync {}: {error}", asset.path))?;
        drop(file);

        let actual_sha256 = format!("{:x}", hasher.finalize());
        if downloaded_file_bytes != asset.size || actual_sha256 != asset.sha256 {
            let _ = std::fs::remove_file(&temporary);
            return Err(format!(
                "Reject {}: pinned SHA-256 or size does not match downloaded content",
                asset.path
            ));
        }
        std::fs::rename(&temporary, &destination)
            .map_err(|error| format!("Publish {}: {error}", asset.path))?;
        bytes_downloaded += downloaded_file_bytes;
        listener.on_progress(DownloadProgress {
            bytes_downloaded,
            total_bytes: Some(total_bytes),
            current_file: asset.path.clone(),
            files_completed: index + 1,
            files_total,
        });
    }

    // Existing unmarked files were hashed by `file_matches`; only publish the
    // marker after the complete authenticated set is present.
    write_install_markers(model, model_dir)?;
    if !is_model_present(model, model_dir) {
        return Err("Model integrity marker verification failed".to_string());
    }
    log::info!("Verified all model assets for {}", model.id);
    listener.on_state_changed(LocalModelState::Ready);
    Ok(model_dir.to_path_buf())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;
    use wrenflow_domain::model_management::{ModelFile, ModelRuntime};

    fn test_model() -> ModelInfo {
        ModelInfo {
            id: "test-model".to_string(),
            name: "Test Model".to_string(),
            repo_id: "example/model".to_string(),
            revision: "0123456789abcdef0123456789abcdef01234567".to_string(),
            directory_name: "test".to_string(),
            expected_files: vec![ModelFile {
                path: "model.bin".to_string(),
                sha256: "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
                    .to_string(),
                size: 4,
            }],
            generated_files: vec![".wrenflow-model-ready".to_string()],
            runtime: ModelRuntime::ParakeetOnnx,
        }
    }

    #[test]
    fn rejects_mutable_or_malformed_manifest() {
        let mut model = test_model();
        model.revision = "main".to_string();
        assert!(validate_model_manifest(&model).is_err());

        model = test_model();
        model.expected_files[0].path = "../escape".to_string();
        assert!(validate_model_manifest(&model).is_err());

        model = test_model();
        model.expected_files[0].sha256 = "unknown".to_string();
        assert!(validate_model_manifest(&model).is_err());
    }

    #[test]
    fn install_marker_requires_verified_bytes_and_detects_changes() {
        let directory = tempdir().expect("temp model directory");
        let model = test_model();
        std::fs::write(directory.path().join("model.bin"), b"evil").expect("write corrupt file");
        assert!(!file_matches(
            &model.expected_files[0],
            &directory.path().join("model.bin")
        ));
        assert!(!is_model_present(&model, directory.path()));

        std::fs::write(directory.path().join("model.bin"), b"test").expect("write verified file");
        assert!(file_matches(
            &model.expected_files[0],
            &directory.path().join("model.bin")
        ));
        write_install_markers(&model, directory.path()).expect("write verified marker");
        assert!(is_model_present(&model, directory.path()));

        std::fs::write(directory.path().join("model.bin"), b"evil").expect("tamper model file");
        assert!(!is_model_present(&model, directory.path()));
    }
}
