//! Model downloader — fetches ONNX model files from HuggingFace.
//!
//! Downloads each expected file, reports progress, and verifies completeness.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use wrenflow_domain::model_management::*;

/// Check if a model is already fully downloaded.
pub fn is_model_present(model: &ModelInfo, model_dir: &Path) -> bool {
    model.expected_files.iter().all(|f| model_dir.join(f).exists())
}

/// Download model files from HuggingFace to a local directory.
/// Calls `listener.on_progress()` as bytes are received.
/// Calls `listener.on_state_changed()` on major transitions.
pub async fn download_model(
    model: &ModelInfo,
    model_dir: &Path,
    listener: Arc<dyn ModelDownloadListener>,
) -> Result<PathBuf, String> {
    std::fs::create_dir_all(model_dir).map_err(|e| format!("Create dir: {e}"))?;

    // Check if already present
    if is_model_present(model, model_dir) {
        log::info!("Model {} already present at {:?}", model.id, model_dir);
        listener.on_state_changed(LocalModelState::Ready);
        return Ok(model_dir.to_path_buf());
    }

    let client = reqwest::Client::builder()
        .user_agent("wrenflow/0.1")
        .build()
        .map_err(|e| format!("HTTP client: {e}"))?;

    let files = &model.expected_files;
    let total_files = files.len();

    // Estimate total size: if we know it, use it; otherwise unknown
    let total_bytes = model.download_size_bytes;

    let mut bytes_so_far: u64 = 0;

    for (i, filename) in files.iter().enumerate() {
        let dest = model_dir.join(filename);

        // Skip if already exists
        if dest.exists() {
            if let Ok(meta) = std::fs::metadata(&dest) {
                bytes_so_far += meta.len();
            }
            listener.on_progress(DownloadProgress {
                bytes_downloaded: bytes_so_far,
                total_bytes,
                current_file: filename.clone(),
                files_completed: i + 1,
                files_total: total_files,
            });
            continue;
        }

        let url = format!(
            "https://huggingface.co/{}/resolve/main/{}",
            model.repo_id, filename
        );

        log::info!("Downloading {} → {:?}", url, dest);
        listener.on_progress(DownloadProgress {
            bytes_downloaded: bytes_so_far,
            total_bytes,
            current_file: filename.clone(),
            files_completed: i,
            files_total: total_files,
        });

        let response = client.get(&url)
            .send()
            .await
            .map_err(|e| format!("Download {filename}: {e}"))?;

        if !response.status().is_success() {
            return Err(format!("Download {filename}: HTTP {}", response.status()));
        }

        let mut file = std::fs::File::create(&dest)
            .map_err(|e| format!("Create {filename}: {e}"))?;

        use std::io::Write;
        let mut stream = response.bytes_stream();
        use tokio_stream::StreamExt;

        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(|e| format!("Read {filename}: {e}"))?;
            file.write_all(&chunk).map_err(|e| format!("Write {filename}: {e}"))?;
            bytes_so_far += chunk.len() as u64;

            listener.on_progress(DownloadProgress {
                bytes_downloaded: bytes_so_far,
                total_bytes,
                current_file: filename.clone(),
                files_completed: i,
                files_total: total_files,
            });
        }

        listener.on_progress(DownloadProgress {
            bytes_downloaded: bytes_so_far,
            total_bytes,
            current_file: filename.clone(),
            files_completed: i + 1,
            files_total: total_files,
        });
    }

    log::info!("All model files downloaded to {:?}", model_dir);
    Ok(model_dir.to_path_buf())
}
