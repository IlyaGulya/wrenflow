//! Model downloader — fetches ONNX model files from HuggingFace.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use wrenflow_domain::model_management::{
    DownloadProgress, LocalModelState, ModelDownloadListener, ModelInfo,
};

/// Check if a model is already fully downloaded.
pub fn is_model_present(model: &ModelInfo, model_dir: &Path) -> bool {
    model.expected_files.iter().all(|f| model_dir.join(f).exists())
}

/// Download model files from HuggingFace.
/// Supports cancellation via `cancel_flag`.
/// Gets total size from Content-Length of each GET response.
pub async fn download_model(
    model: &ModelInfo,
    model_dir: &Path,
    listener: Arc<dyn ModelDownloadListener>,
    cancel_flag: Arc<AtomicBool>,
) -> Result<PathBuf, String> {
    std::fs::create_dir_all(model_dir).map_err(|e| format!("Create dir: {e}"))?;

    if is_model_present(model, model_dir) {
        log::info!("Model {} already present at {:?}", model.id, model_dir);
        listener.on_state_changed(LocalModelState::Ready);
        return Ok(model_dir.to_path_buf());
    }

    let client = reqwest::Client::builder()
        .user_agent("wrenflow/0.1")
        .redirect(reqwest::redirect::Policy::limited(10))
        .build()
        .map_err(|e| format!("HTTP client: {e}"))?;

    let files = &model.expected_files;
    let total_files = files.len();
    let mut bytes_so_far: u64 = 0;
    let mut total_bytes: u64 = 0;
    let mut total_known = false;

    // Count already-downloaded file sizes
    for filename in files {
        let dest = model_dir.join(filename);
        if dest.exists() {
            if let Ok(meta) = std::fs::metadata(&dest) {
                let size = meta.len();
                bytes_so_far += size;
                total_bytes += size;
            }
        }
    }

    for (i, filename) in files.iter().enumerate() {
        if cancel_flag.load(Ordering::Relaxed) {
            return Err("Cancelled".to_string());
        }

        let dest = model_dir.join(filename);

        // Skip if already exists
        if dest.exists() {
            listener.on_progress(DownloadProgress {
                bytes_downloaded: bytes_so_far,
                total_bytes: if total_known { Some(total_bytes) } else { None },
                current_file: filename.clone(),
                files_completed: i + 1,
                files_total: total_files,
            });
            continue;
        }

        let url = format!("https://huggingface.co/{}/resolve/main/{}", model.repo_id, filename);
        log::info!("Downloading {} → {:?}", url, dest);

        let response = client.get(&url)
            .send()
            .await
            .map_err(|e| format!("Download {filename}: {e}"))?;

        if !response.status().is_success() {
            return Err(format!("Download {filename}: HTTP {}", response.status()));
        }

        // Get file size from Content-Length header
        let file_size = response.content_length();
        if let Some(size) = file_size {
            total_bytes += size;
            total_known = true;
        }

        listener.on_progress(DownloadProgress {
            bytes_downloaded: bytes_so_far,
            total_bytes: if total_known { Some(total_bytes) } else { None },
            current_file: filename.clone(),
            files_completed: i,
            files_total: total_files,
        });

        // Write to temp file
        let tmp_dest = model_dir.join(format!("{filename}.tmp"));
        let mut file = std::fs::File::create(&tmp_dest)
            .map_err(|e| format!("Create {filename}: {e}"))?;

        use std::io::Write;
        use tokio_stream::StreamExt;
        let mut stream = response.bytes_stream();

        while let Some(chunk) = stream.next().await {
            if cancel_flag.load(Ordering::Relaxed) {
                let _ = std::fs::remove_file(&tmp_dest);
                return Err("Cancelled".to_string());
            }

            let chunk = chunk.map_err(|e| format!("Read {filename}: {e}"))?;
            file.write_all(&chunk).map_err(|e| format!("Write {filename}: {e}"))?;
            bytes_so_far += chunk.len() as u64;

            listener.on_progress(DownloadProgress {
                bytes_downloaded: bytes_so_far,
                total_bytes: if total_known { Some(total_bytes) } else { None },
                current_file: filename.clone(),
                files_completed: i,
                files_total: total_files,
            });
        }

        // Rename temp to final
        std::fs::rename(&tmp_dest, &dest)
            .map_err(|e| format!("Rename {filename}: {e}"))?;

        listener.on_progress(DownloadProgress {
            bytes_downloaded: bytes_so_far,
            total_bytes: if total_known { Some(total_bytes) } else { None },
            current_file: filename.clone(),
            files_completed: i + 1,
            files_total: total_files,
        });
    }

    log::info!("All model files downloaded to {:?}", model_dir);
    Ok(model_dir.to_path_buf())
}
