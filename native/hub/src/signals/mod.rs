use rinf::{DartSignal, RustSignal, SignalPiece};
use serde::{Deserialize, Serialize};

// ============================================================================
// Shared types (SignalPiece — nestable in signals)
// ============================================================================

#[derive(Serialize, Deserialize, SignalPiece, Clone, Debug)]
pub enum PipelineState {
    Idle,
    Starting,
    Initializing,
    Recording,
    Transcribing { showing_indicator: bool },
    Pasting,
    Error { message: String },
}

#[derive(Serialize, Deserialize, SignalPiece, Clone, Debug)]
pub enum SoundType {
    RecordingStarted,
    RecordingStopped,
}

#[derive(Serialize, Deserialize, SignalPiece, Clone, Debug)]
pub struct HistoryEntryData {
    pub id: String,
    pub timestamp: f64,
    pub transcript: String,
    pub custom_vocabulary: String,
    pub audio_file_name: Option<String>,
    pub metrics_json: String,
}

#[derive(Serialize, Deserialize, SignalPiece, Clone, Debug)]
pub enum ModelState {
    NotDownloaded,
    Downloading { progress: f64, speed_bps: f64, eta_secs: f64 },
    Loading,
    Warming,
    Ready,
    Error { message: String },
}

#[derive(Serialize, Deserialize, SignalPiece, Clone, Debug)]
pub struct AudioDeviceInfo {
    pub id: String,
    pub name: String,
}

// ============================================================================
// Pipeline state signals (Rust → Dart)
// ============================================================================

#[derive(Serialize, RustSignal)]
pub struct PipelineStateChanged {
    pub old_state: PipelineState,
    pub new_state: PipelineState,
}

#[derive(Serialize, RustSignal)]
pub struct PlaySound {
    pub sound: SoundType,
}

#[derive(Serialize, RustSignal)]
pub struct PipelineError {
    pub message: String,
}

#[derive(Serialize, RustSignal)]
pub struct PasteComplete;

#[derive(Serialize, RustSignal)]
pub struct TranscriptReady {
    pub transcript: String,
}

// ============================================================================
// Pipeline command signals (Dart → Rust)
// ============================================================================

#[derive(Deserialize, DartSignal)]
pub struct StartRecording {
    pub microphone_id: String,
}

#[derive(Deserialize, DartSignal)]
pub struct StopRecording {
    pub duration_ms: f64,
}

#[derive(Deserialize, DartSignal)]
pub struct UpdateConfig {
    pub selected_hotkey: String,
    pub selected_microphone_id: String,
    pub sound_enabled: bool,
    pub custom_vocabulary: String,
    pub minimum_recording_duration_ms: f64,
}

/// Dart → Rust: set what happens after transcription
#[derive(Deserialize, DartSignal)]
pub struct SetTranscriptAction {
    pub action: String, // "paste" or "display_only"
}

// ============================================================================
// Audio level signal (Rust → Dart)
// ============================================================================

#[derive(Serialize, RustSignal)]
pub struct AudioLevelUpdate {
    pub level: f32,
}

// ============================================================================
// History signals (bidirectional)
// ============================================================================

/// Rust → Dart: a new history entry was added
#[derive(Serialize, RustSignal)]
pub struct HistoryEntryAdded {
    pub entry: HistoryEntryData,
}

/// Rust → Dart: full history loaded
#[derive(Serialize, RustSignal)]
pub struct HistoryLoaded {
    pub entries: Vec<HistoryEntryData>,
}

/// Dart → Rust: request to load all history
#[derive(Deserialize, DartSignal)]
pub struct LoadHistory;

/// Dart → Rust: delete a history entry
#[derive(Deserialize, DartSignal)]
pub struct DeleteHistoryEntry {
    pub id: String,
}

/// Dart → Rust: clear all history
#[derive(Deserialize, DartSignal)]
pub struct ClearHistory;

// ============================================================================
// Model management signals (bidirectional)
// ============================================================================

/// Rust → Dart: model state changed
#[derive(Serialize, RustSignal)]
pub struct ModelStateChanged {
    pub state: ModelState,
}

/// Dart → Rust: start downloading/loading local model
#[derive(Deserialize, DartSignal)]
pub struct InitializeLocalModel;

/// Dart → Rust: cancel model download
#[derive(Deserialize, DartSignal)]
pub struct CancelModelDownload;

// ============================================================================
// Device signals (Rust → Dart)
// ============================================================================

#[derive(Serialize, RustSignal)]
pub struct AudioDevicesListed {
    pub devices: Vec<AudioDeviceInfo>,
    pub default_device_name: String,
}

#[derive(Deserialize, DartSignal)]
pub struct ListAudioDevices;
