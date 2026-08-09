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
    /// Immutable upstream Git commit used in every download URL.
    pub revision: String,
    /// Directory name under the local models root.
    pub directory_name: String,
    /// Files downloaded from the upstream model repo.
    pub expected_files: Vec<ModelFile>,
    /// Runtime files synthesized locally after download.
    pub generated_files: Vec<String>,
    /// Runtime family used to load the model.
    pub runtime: ModelRuntime,
}

/// Authenticated metadata for one immutable model asset.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModelFile {
    pub path: String,
    pub sha256: String,
    pub size: u64,
}

fn model_file(path: &str, sha256: &str, size: u64) -> ModelFile {
    ModelFile {
        path: path.to_string(),
        sha256: sha256.to_string(),
        size,
    }
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
        revision: "8f23f0c03c8761650bdb5b40aaf3e40d2c15f1ce".to_string(),
        directory_name: "parakeet-tdt".to_string(),
        expected_files: vec![
            model_file(
                "encoder-model.int8.onnx",
                "6139d2fa7e1b086097b277c7149725edbab89cc7c7ae64b23c741be4055aff09",
                652_183_999,
            ),
            model_file(
                "decoder_joint-model.int8.onnx",
                "eea7483ee3d1a30375daedc8ed83e3960c91b098812127a0d99d1c8977667a70",
                18_202_004,
            ),
            model_file(
                "nemo128.onnx",
                "a9fde1486ebfcc08f328d75ad4610c67835fea58c73ba57e3209a6f6cf019e9f",
                139_764,
            ),
            model_file(
                "vocab.txt",
                "d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d",
                93_939,
            ),
            model_file(
                "config.json",
                "666903c76b9798caf2c210afd4f6cd60b08a8dbf9800ec8d7a3bc0d2148ac466",
                97,
            ),
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
        revision: "f2d0148f21bb07751a7e6e9a4377e1ae7146607f".to_string(),
        directory_name: "whisper-large-v3-turbo".to_string(),
        expected_files: vec![
            model_file(
                "config.json",
                "fdd959b061c832e534dea5c3d606fae22fbbd3ab12ad126d0d2eb602779eb9a3",
                1_223,
            ),
            model_file(
                "generation_config.json",
                "8568ddf83476167b4607014956b87142763fa6923e71259a606734beb39bdfc8",
                3_797,
            ),
            model_file(
                "preprocessor_config.json",
                "7ccc62c6f2765af1f3b46c00c9b5894426835a05021c8b9c01eecb6dfb542711",
                340,
            ),
            model_file(
                "tokenizer.json",
                "b3c8202bbf06d8ee4232c5984baa563784ac4737e2e7fdc42fa180200d3cfcdb",
                2_480_645,
            ),
            model_file(
                "tokenizer_config.json",
                "844b642c73a91359722f47b35705f7174686df33d252695d8572cf9ac03a6389",
                282_843,
            ),
            model_file(
                "special_tokens_map.json",
                "baea4ea09372eb4fca86b4e4346139fd73cb807d5087e9de0948e971739c3e74",
                2_186,
            ),
            model_file(
                "added_tokens.json",
                "3c51f66c4c21f9e126970078f11ae77a78c74aee8df606ee9daba86e467108e0",
                34_648,
            ),
            model_file(
                "merges.txt",
                "2df2990a395e35e8dfbc7511e08c12d56018d8d04691e0133e5d63b21e154dc6",
                493_869,
            ),
            model_file(
                "normalizer.json",
                "bf1c507dc8724ca9cf9903640dacfb69dae2f00edee4f21ceba106a7392f26dd",
                52_666,
            ),
            model_file(
                "vocab.json",
                "e2aa043ef015641d363d8288e7c241c85e36a5c761fb303598e0710233344387",
                1_036_558,
            ),
            model_file(
                "onnx/encoder_model_int8.onnx",
                "e44c0d5cfcc6ad283011602a738fa28dfa1ad7f7540c9503205479072a9cc1ef",
                644_822_094,
            ),
            model_file(
                "onnx/decoder_model_int8.onnx",
                "fe2eb71adea258a0153071660ba9d21b8062705b56389d672be916c675ceb04d",
                437_936_043,
            ),
            model_file(
                "onnx/decoder_with_past_model_int8.onnx",
                "da041a6cdb493360796acc07030e7e04cc40a6e30ef210a4defd676d74363b9d",
                424_790_944,
            ),
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
