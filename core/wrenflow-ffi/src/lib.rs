//! FFI bridge: exposes PipelineEngine to Swift/Kotlin via UniFFI.
//! All types that cross the FFI boundary are defined here with UniFFI derives,
//! and converted to/from wrenflow-core types internally.

use std::sync::Mutex;
use wrenflow_core::pipeline as core;

uniffi::setup_scaffolding!();

// ---------------------------------------------------------------------------
// FFI types (mirrors of wrenflow-core types, with UniFFI derives)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum PipelineState {
    Idle,
    Starting,
    Initializing,
    Recording,
    Transcribing { showing_indicator: bool },
    PostProcessing { showing_indicator: bool },
    Pasting,
    Error { message: String },
}

#[derive(Debug, Clone, Copy, PartialEq, uniffi::Enum)]
pub enum PipelineSound {
    RecordingStarted,
    RecordingStopped,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct TranscriptionResult {
    pub raw_transcript: String,
    pub duration_ms: f64,
    pub provider: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct PostProcessingResult {
    pub transcript: String,
    pub prompt: String,
    pub reasoning: String,
    pub duration_ms: f64,
    pub status: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct HistoryEntry {
    pub id: String,
    pub timestamp: f64,
    pub raw_transcript: String,
    pub post_processed_transcript: String,
    pub post_processing_prompt: Option<String>,
    pub post_processing_reasoning: Option<String>,
    pub context_summary: String,
    pub context_prompt: Option<String>,
    pub context_screenshot_data_url: Option<String>,
    pub context_screenshot_status: String,
    pub post_processing_status: String,
    pub debug_status: String,
    pub custom_vocabulary: String,
    pub audio_file_name: Option<String>,
    pub metrics_json: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AppConfig {
    pub post_processing_enabled: bool,
    pub post_processing_model: String,
    pub api_base_url: String,
    pub minimum_recording_duration_ms: f64,
    pub custom_vocabulary: String,
    pub custom_system_prompt: String,
    pub custom_context_prompt: String,
    pub selected_hotkey: String,
    pub selected_microphone_id: String,
    pub sound_enabled: bool,
}

// ---------------------------------------------------------------------------
// Conversions core ↔ FFI
// ---------------------------------------------------------------------------

impl From<core::PipelineState> for PipelineState {
    fn from(s: core::PipelineState) -> Self {
        match s {
            core::PipelineState::Idle => Self::Idle,
            core::PipelineState::Starting => Self::Starting,
            core::PipelineState::Initializing => Self::Initializing,
            core::PipelineState::Recording => Self::Recording,
            core::PipelineState::Transcribing { showing_indicator } => Self::Transcribing { showing_indicator },
            core::PipelineState::PostProcessing { showing_indicator } => Self::PostProcessing { showing_indicator },
            core::PipelineState::Pasting => Self::Pasting,
            core::PipelineState::Error { message } => Self::Error { message },
        }
    }
}

impl From<core::PipelineSound> for PipelineSound {
    fn from(s: core::PipelineSound) -> Self {
        match s { core::PipelineSound::RecordingStarted => Self::RecordingStarted, core::PipelineSound::RecordingStopped => Self::RecordingStopped }
    }
}

impl From<wrenflow_core::history::HistoryEntry> for HistoryEntry {
    fn from(e: wrenflow_core::history::HistoryEntry) -> HistoryEntry {
        Self { id: e.id, timestamp: e.timestamp, raw_transcript: e.raw_transcript, post_processed_transcript: e.post_processed_transcript, post_processing_prompt: e.post_processing_prompt, post_processing_reasoning: e.post_processing_reasoning, context_summary: e.context_summary, context_prompt: e.context_prompt, context_screenshot_data_url: e.context_screenshot_data_url, context_screenshot_status: e.context_screenshot_status, post_processing_status: e.post_processing_status, debug_status: e.debug_status, custom_vocabulary: e.custom_vocabulary, audio_file_name: e.audio_file_name, metrics_json: e.metrics_json }
    }
}

impl From<TranscriptionResult> for core::TranscriptionResult {
    fn from(r: TranscriptionResult) -> Self {
        Self { raw_transcript: r.raw_transcript, duration_ms: r.duration_ms, provider: r.provider }
    }
}

impl From<PostProcessingResult> for core::PostProcessingResult {
    fn from(r: PostProcessingResult) -> Self {
        Self { transcript: r.transcript, prompt: r.prompt, reasoning: r.reasoning, duration_ms: r.duration_ms, status: r.status }
    }
}

impl From<AppConfig> for wrenflow_core::config::AppConfig {
    fn from(c: AppConfig) -> Self {
        Self { post_processing_enabled: c.post_processing_enabled, post_processing_model: c.post_processing_model, api_base_url: c.api_base_url, minimum_recording_duration_ms: c.minimum_recording_duration_ms, custom_vocabulary: c.custom_vocabulary, custom_system_prompt: c.custom_system_prompt, custom_context_prompt: c.custom_context_prompt, selected_hotkey: c.selected_hotkey, selected_microphone_id: c.selected_microphone_id, sound_enabled: c.sound_enabled }
    }
}

// ---------------------------------------------------------------------------
// Callback interface
// ---------------------------------------------------------------------------

#[uniffi::export(callback_interface)]
pub trait FfiPipelineListener: Send + Sync {
    fn on_state_changed(&self, old: PipelineState, new: PipelineState);
    fn on_paste_text(&self, text: String);
    fn on_play_sound(&self, sound: PipelineSound);
    fn on_error(&self, message: String);
    fn on_history_entry_added(&self, entry: HistoryEntry);
}

/// Adapter: bridges FfiPipelineListener → core::PipelineListener
struct ListenerBridge(Box<dyn FfiPipelineListener>);

impl core::PipelineListener for ListenerBridge {
    fn on_state_changed(&self, old: core::PipelineState, new: core::PipelineState) {
        self.0.on_state_changed(old.into(), new.into());
    }
    fn on_paste_text(&self, text: String) { self.0.on_paste_text(text); }
    fn on_play_sound(&self, sound: core::PipelineSound) { self.0.on_play_sound(sound.into()); }
    fn on_error(&self, message: String) { self.0.on_error(message); }
    fn on_history_entry_added(&self, entry: wrenflow_core::history::HistoryEntry) {
        self.0.on_history_entry_added(entry.into());
    }
}

// ---------------------------------------------------------------------------
// FfiPipelineEngine
// ---------------------------------------------------------------------------

#[derive(uniffi::Object)]
pub struct FfiPipelineEngine {
    inner: Mutex<core::PipelineEngine>,
    listener: ListenerBridge,
}

#[uniffi::export]
impl FfiPipelineEngine {
    #[uniffi::constructor]
    pub fn new(config: AppConfig, listener: Box<dyn FfiPipelineListener>) -> Self {
        Self {
            inner: Mutex::new(core::PipelineEngine::new(config.into())),
            listener: ListenerBridge(listener),
        }
    }

    pub fn state(&self) -> PipelineState { self.inner.lock().unwrap().state().clone().into() }
    pub fn handle_hotkey_down(&self) -> bool { self.inner.lock().unwrap().handle_hotkey_down(&self.listener) }
    pub fn handle_hotkey_up(&self, recording_duration_ms: f64) -> bool { self.inner.lock().unwrap().handle_hotkey_up(recording_duration_ms, &self.listener) }
    pub fn on_first_audio(&self) { self.inner.lock().unwrap().on_first_audio(&self.listener); }
    pub fn on_init_timeout(&self) { self.inner.lock().unwrap().on_init_timeout(&self.listener); }
    pub fn on_indicator_timeout(&self) { self.inner.lock().unwrap().on_indicator_timeout(&self.listener); }
    pub fn on_transcription_complete(&self, result: TranscriptionResult) { self.inner.lock().unwrap().on_transcription_complete(result.into(), &self.listener); }
    pub fn on_post_processing_complete(&self, raw_transcript: String, result: PostProcessingResult) { self.inner.lock().unwrap().on_post_processing_complete(&raw_transcript, result.into(), &self.listener); }
    pub fn on_pipeline_error(&self, message: String) { self.inner.lock().unwrap().on_pipeline_error(&message, &self.listener); }
    pub fn on_dismiss_timeout(&self) { self.inner.lock().unwrap().on_dismiss_timeout(&self.listener); }
    pub fn update_config(&self, config: AppConfig) { self.inner.lock().unwrap().update_config(config.into()); }
}

// ---------------------------------------------------------------------------
// Local Transcription Engine (wraps parakeet-rs)
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Local Transcription Engine with model download
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum ModelState {
    NotDownloaded,
    Downloading { progress_fraction: f64, bytes_downloaded: u64, total_bytes: u64, current_file: String },
    Loading,
    Ready,
    Error { message: String },
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct TranscribeResult {
    pub text: String,
    pub error: Option<String>,
}

/// Callback for model download/load progress.
#[uniffi::export(callback_interface)]
pub trait FfiModelProgressListener: Send + Sync {
    fn on_state_changed(&self, state: ModelState);
}

/// Bridge: FfiModelProgressListener → domain ModelDownloadListener
struct ProgressBridge(Box<dyn FfiModelProgressListener>);

impl wrenflow_core::model_management::ModelDownloadListener for ProgressBridge {
    fn on_progress(&self, p: wrenflow_core::model_management::DownloadProgress) {
        let fraction = p.fraction().unwrap_or(0.0);
        self.0.on_state_changed(ModelState::Downloading {
            progress_fraction: fraction,
            bytes_downloaded: p.bytes_downloaded,
            total_bytes: p.total_bytes.unwrap_or(0),
            current_file: p.current_file,
        });
    }
    fn on_state_changed(&self, s: wrenflow_core::model_management::LocalModelState) {
        let state = match s {
            wrenflow_core::model_management::LocalModelState::NotDownloaded => ModelState::NotDownloaded,
            wrenflow_core::model_management::LocalModelState::Downloading(p) => ModelState::Downloading {
                progress_fraction: p.fraction().unwrap_or(0.0),
                bytes_downloaded: p.bytes_downloaded,
                total_bytes: p.total_bytes.unwrap_or(0),
                current_file: p.current_file,
            },
            wrenflow_core::model_management::LocalModelState::Loading => ModelState::Loading,
            wrenflow_core::model_management::LocalModelState::Ready => ModelState::Ready,
            wrenflow_core::model_management::LocalModelState::Error(msg) => ModelState::Error { message: msg },
        };
        self.0.on_state_changed(state);
    }
}

#[derive(uniffi::Object)]
pub struct FfiLocalTranscriptionEngine {
    inner: std::sync::Mutex<wrenflow_core::transcription_local::LocalTranscriptionEngine>,
    runtime: tokio::runtime::Runtime,
    cancel_flag: std::sync::Arc<std::sync::atomic::AtomicBool>,
}

#[uniffi::export]
impl FfiLocalTranscriptionEngine {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self {
            inner: std::sync::Mutex::new(wrenflow_core::transcription_local::LocalTranscriptionEngine::new()),
            runtime: tokio::runtime::Runtime::new().expect("tokio runtime"),
            cancel_flag: std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false)),
        }
    }

    /// Cancel an ongoing download.
    pub fn cancel_download(&self) {
        self.cancel_flag.store(true, std::sync::atomic::Ordering::Relaxed);
    }

    /// Current model state.
    pub fn state(&self) -> ModelState {
        let s = self.inner.lock().unwrap().state().clone();
        match s {
            wrenflow_core::transcription::local::ModelState::NotLoaded => ModelState::NotDownloaded,
            wrenflow_core::transcription::local::ModelState::Downloading => ModelState::Downloading {
                progress_fraction: 0.0, bytes_downloaded: 0, total_bytes: 0, current_file: String::new(),
            },
            wrenflow_core::transcription::local::ModelState::Compiling => ModelState::Loading,
            wrenflow_core::transcription::local::ModelState::Ready => ModelState::Ready,
            wrenflow_core::transcription::local::ModelState::Error(msg) => ModelState::Error { message: msg },
        }
    }

    /// Check if model files exist at the given path.
    pub fn is_model_downloaded(&self, model_dir: String) -> bool {
        let model = wrenflow_core::model_management::default_parakeet_model();
        wrenflow_core::model_downloader::is_model_present(&model, std::path::Path::new(&model_dir))
    }

    /// Download model files (blocking — call from background thread).
    /// Reports progress via listener.
    pub fn download_model(&self, model_dir: String, listener: Box<dyn FfiModelProgressListener>) -> Option<String> {
        // Reset cancel flag
        self.cancel_flag.store(false, std::sync::atomic::Ordering::Relaxed);

        let model = wrenflow_core::model_management::default_parakeet_model();
        let bridge = std::sync::Arc::new(ProgressBridge(listener));
        bridge.0.on_state_changed(ModelState::Downloading {
            progress_fraction: 0.0, bytes_downloaded: 0, total_bytes: 0, current_file: String::new(),
        });

        match self.runtime.block_on(wrenflow_core::model_downloader::download_model(
            &model,
            std::path::Path::new(&model_dir),
            bridge,
            self.cancel_flag.clone(),
        )) {
            Ok(_) => None,
            Err(e) => Some(e),
        }
    }

    /// Load the model into memory for inference (blocking).
    pub fn load_model(&self, model_dir: String) -> Option<String> {
        match self.inner.lock().unwrap().initialize(std::path::Path::new(&model_dir), None) {
            Ok(()) => None,
            Err(e) => Some(e.to_string()),
        }
    }

    /// Download (if needed) + load model. Full initialization flow.
    pub fn initialize_with_download(&self, model_dir: String, listener: Box<dyn FfiModelProgressListener>) -> Option<String> {
        // Step 1: Download if needed
        if !self.is_model_downloaded(model_dir.clone()) {
            if let Some(err) = self.download_model(model_dir.clone(), listener) {
                return Some(err);
            }
        }

        // Step 2: Load
        // Note: listener was consumed by download_model. For the loading phase,
        // the caller polls state() to see Loading → Ready.
        self.load_model(model_dir)
    }

    /// Transcribe a WAV file.
    pub fn transcribe_file(&self, file_path: String) -> TranscribeResult {
        match self.inner.lock().unwrap().transcribe_file(std::path::Path::new(&file_path)) {
            Ok(text) => TranscribeResult { text, error: None },
            Err(e) => TranscribeResult { text: String::new(), error: Some(e.to_string()) },
        }
    }
}
