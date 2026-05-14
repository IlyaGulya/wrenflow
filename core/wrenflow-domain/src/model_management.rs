//! Model management domain types.
//!
//! Pure data — no IO, no downloads. Infrastructure implements the actual operations.

/// Information about a downloadable model.
#[derive(Debug, Clone, PartialEq)]
pub struct ModelInfo {
    /// Unique model identifier (e.g., "parakeet-tdt-0.6b-v3-onnx").
    pub id: String,
    /// Human-readable name.
    pub name: String,
    /// HuggingFace repo ID (e.g., "istupakov/parakeet-tdt-0.6b-v3-onnx").
    pub repo_id: String,
    /// Directory name under the local models root.
    pub directory_name: String,
    /// Files downloaded from the upstream model repo.
    pub expected_files: Vec<String>,
    /// Runtime files synthesized locally after download.
    pub generated_files: Vec<String>,
    /// Runtime family used to load the model.
    pub runtime: ModelRuntime,
}

/// Product-facing catalog metadata for a local model option.
#[derive(Debug, Clone, PartialEq)]
pub struct LocalModelCatalogEntry {
    pub id: String,
    pub display_name: String,
    pub subtitle: String,
    pub download_label: String,
    pub family: String,
    pub runtime_label: String,
    pub is_recommended: bool,
    pub is_available: bool,
    pub supports_current_runtime: bool,
}

pub const MODEL_INSTALL_MARKER_FILE: &str = ".wrenflow-model-ready";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModelRuntime {
    ParakeetOnnx,
    WhisperOnnx,
}

/// Progress of an ongoing download.
#[derive(Debug, Clone, PartialEq)]
pub struct DownloadProgress {
    /// Bytes downloaded so far.
    pub bytes_downloaded: u64,
    /// Total bytes (if known).
    pub total_bytes: Option<u64>,
    /// Current file being downloaded (e.g., "encoder.onnx").
    pub current_file: String,
    /// Files completed / total files.
    pub files_completed: usize,
    pub files_total: usize,
}

impl DownloadProgress {
    /// Fraction 0.0..1.0, or None if total unknown.
    pub fn fraction(&self) -> Option<f64> {
        self.total_bytes.map(|total| {
            if total == 0 {
                0.0
            } else {
                self.bytes_downloaded as f64 / total as f64
            }
        })
    }
}

/// Lifecycle state of a local model. Extends the simpler ModelState in transcription/.
#[derive(Debug, Clone, PartialEq)]
pub enum LocalModelState {
    /// No model files found locally.
    NotDownloaded,
    /// Download in progress.
    Downloading(DownloadProgress),
    /// Files downloaded, loading/compiling into runtime.
    Loading,
    /// Model is ready for inference.
    Ready,
    /// Something went wrong.
    Error(String),
}

impl LocalModelState {
    pub fn is_ready(&self) -> bool {
        matches!(self, Self::Ready)
    }
    pub fn is_busy(&self) -> bool {
        matches!(self, Self::Downloading(_) | Self::Loading)
    }
}

/// Callback trait for model download progress.
/// Infrastructure implements the actual download and calls these.
/// UI layer implements this to show progress.
pub trait ModelDownloadListener: Send + Sync {
    fn on_progress(&self, progress: DownloadProgress);
    fn on_state_changed(&self, state: LocalModelState);
}

/// The default Parakeet TDT ONNX model.
pub fn default_parakeet_model() -> ModelInfo {
    ModelInfo {
        id: "parakeet-tdt-0.6b-v3-onnx".to_string(),
        name: "Parakeet TDT 0.6B".to_string(),
        repo_id: "istupakov/parakeet-tdt-0.6b-v3-onnx".to_string(),
        directory_name: "parakeet-tdt".to_string(),
        expected_files: vec![
            "encoder-model.int8.onnx".to_string(),
            "decoder_joint-model.int8.onnx".to_string(),
            "nemo128.onnx".to_string(),
            "vocab.txt".to_string(),
            "config.json".to_string(),
        ],
        generated_files: vec![MODEL_INSTALL_MARKER_FILE.to_string()],
        runtime: ModelRuntime::ParakeetOnnx,
    }
}

pub fn whisper_large_v3_turbo_model() -> ModelInfo {
    ModelInfo {
        id: "whisper-large-v3-turbo-onnx".to_string(),
        name: "Whisper Large V3 Turbo".to_string(),
        repo_id: "onnx-community/whisper-large-v3-turbo-ONNX".to_string(),
        directory_name: "whisper-large-v3-turbo".to_string(),
        expected_files: vec![
            "config.json".to_string(),
            "generation_config.json".to_string(),
            "preprocessor_config.json".to_string(),
            "tokenizer.json".to_string(),
            "tokenizer_config.json".to_string(),
            "special_tokens_map.json".to_string(),
            "added_tokens.json".to_string(),
            "merges.txt".to_string(),
            "normalizer.json".to_string(),
            "vocab.json".to_string(),
            "onnx/encoder_model_int8.onnx".to_string(),
            "onnx/decoder_model_int8.onnx".to_string(),
            "onnx/decoder_with_past_model_int8.onnx".to_string(),
        ],
        generated_files: vec![MODEL_INSTALL_MARKER_FILE.to_string()],
        runtime: ModelRuntime::WhisperOnnx,
    }
}

pub fn all_local_models() -> Vec<ModelInfo> {
    vec![default_parakeet_model(), whisper_large_v3_turbo_model()]
}

pub fn all_local_model_catalog_entries() -> Vec<LocalModelCatalogEntry> {
    vec![
        LocalModelCatalogEntry {
            id: "parakeet-tdt-0.6b-v3-onnx".to_string(),
            display_name: "Parakeet Realtime".to_string(),
            subtitle: "Fastest local dictation for the current ONNX runtime.".to_string(),
            download_label: "~400 MB".to_string(),
            family: "Parakeet".to_string(),
            runtime_label: "ONNX".to_string(),
            is_recommended: true,
            is_available: true,
            supports_current_runtime: true,
        },
        LocalModelCatalogEntry {
            id: "whisper-large-v3-turbo-onnx".to_string(),
            display_name: "Whisper Turbo".to_string(),
            subtitle: "Fast high-quality Whisper with the new local ONNX runtime.".to_string(),
            download_label: "~1.2 GB".to_string(),
            family: "Whisper".to_string(),
            runtime_label: "ONNX".to_string(),
            is_recommended: false,
            is_available: true,
            supports_current_runtime: true,
        },
        LocalModelCatalogEntry {
            id: "whisper-large-v3-onnx".to_string(),
            display_name: "Whisper Large".to_string(),
            subtitle: "Highest Whisper accuracy target once the ONNX path lands.".to_string(),
            download_label: "Whisper runtime pending".to_string(),
            family: "Whisper".to_string(),
            runtime_label: "Planned ONNX".to_string(),
            is_recommended: false,
            is_available: false,
            supports_current_runtime: false,
        },
    ]
}

pub fn local_model_by_id(model_id: &str) -> Option<ModelInfo> {
    match model_id {
        "parakeet-tdt-0.6b-v3-onnx" => Some(default_parakeet_model()),
        "whisper-large-v3-turbo-onnx" => Some(whisper_large_v3_turbo_model()),
        _ => None,
    }
}
