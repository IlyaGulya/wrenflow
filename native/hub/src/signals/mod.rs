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
    Downloading {
        progress: f64,
        speed_bps: f64,
        eta_secs: f64,
    },
    Loading,
    Warming,
    Ready,
    Error {
        message: String,
    },
}

#[derive(Serialize, Deserialize, SignalPiece, Clone, Debug)]
pub struct AudioDeviceInfo {
    pub id: String,
    pub name: String,
}

#[derive(Serialize, Deserialize, SignalPiece, Clone, Debug)]
pub struct AudioDevicesSnapshot {
    pub has_snapshot: bool,
    pub devices: Vec<AudioDeviceInfo>,
    pub default_device_name: String,
    pub selected_device_id: String,
    pub effective_selected_device_id: String,
}

#[derive(Serialize, Deserialize, SignalPiece, Clone, Debug)]
pub struct ShellCapabilitiesSnapshot {
    pub launch_at_login: bool,
    pub updates: bool,
    pub local_transcription: bool,
    pub microphone_selection: bool,
    pub tray: bool,
    pub overlays: bool,
}

#[derive(Serialize, Deserialize, SignalPiece, Clone, Debug, PartialEq, Eq)]
pub enum PermissionStatus {
    Unknown,
    Requesting,
    Granted,
    Denied,
    Restricted,
    NotApplicable,
}

#[derive(Serialize, Deserialize, SignalPiece, Clone, Debug, PartialEq, Eq)]
pub enum AppSessionOnboardingStep {
    Microphone,
    Accessibility,
    Hotkey,
    Model,
    Vocabulary,
    Complete,
}

#[derive(Serialize, Deserialize, SignalPiece, Clone, Debug, PartialEq, Eq)]
pub enum AppSessionState {
    Initializing,
    Onboarding {
        step: AppSessionOnboardingStep,
    },
    PermissionRecovery {
        microphone_missing: bool,
        accessibility_missing: bool,
    },
    Ready,
    ShuttingDown,
}

#[derive(Serialize, Deserialize, SignalPiece, Clone, Debug, PartialEq, Eq)]
pub enum UpdateStatus {
    Unsupported,
    Idle,
    Checking,
    UpToDate,
    Available {
        latest_version: String,
        release_url: String,
        download_url: String,
        published_at_iso: Option<String>,
    },
    Error {
        message: String,
    },
}

#[derive(Serialize, Deserialize, SignalPiece, Clone, Debug)]
pub struct LocalModelCatalogItem {
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

#[derive(Serialize, Deserialize, SignalPiece, Clone, Debug)]
pub struct LocalModelRuntimeState {
    pub model_id: String,
    pub state: ModelState,
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

/// Rust → Dart: full local model snapshot owned by the Rust runtime
#[derive(Serialize, RustSignal)]
pub struct LocalModelsSnapshotChanged {
    pub models: Vec<LocalModelCatalogItem>,
    pub selected_model_id: String,
    pub active_model_id: Option<String>,
    pub installed_model_ids: Vec<String>,
    pub model_states: Vec<LocalModelRuntimeState>,
}

/// Dart → Rust: start downloading/loading local model
#[derive(Deserialize, DartSignal)]
pub struct InitializeLocalModel;

/// Dart → Rust: request the latest local model snapshot
#[derive(Deserialize, DartSignal)]
pub struct RequestLocalModelsSnapshot;

/// Dart → Rust: select which local model should be active
#[derive(Deserialize, DartSignal)]
pub struct SelectLocalModel {
    pub model_id: String,
}

/// Dart → Rust: cancel model download
#[derive(Deserialize, DartSignal)]
pub struct CancelModelDownload;

// ============================================================================
// Permissions signals (bidirectional)
// ============================================================================

/// Rust → Dart: latest permission snapshot owned by the Rust runtime
#[derive(Serialize, RustSignal)]
pub struct PermissionsSnapshotChanged {
    pub has_snapshot: bool,
    pub microphone: PermissionStatus,
    pub accessibility: PermissionStatus,
}

/// Dart → Rust: request latest permission snapshot
#[derive(Deserialize, DartSignal)]
pub struct RequestPermissionsSnapshot;

/// Dart → Rust: report the latest shell-observed permission snapshot
#[derive(Deserialize, DartSignal)]
pub struct ReportPermissionsSnapshot {
    pub microphone: PermissionStatus,
    pub accessibility: PermissionStatus,
}

// ============================================================================
// App session signals (bidirectional)
// ============================================================================

/// Rust → Dart: current app session snapshot
#[derive(Serialize, RustSignal)]
pub struct AppSessionSnapshotChanged {
    pub state: AppSessionState,
}

/// Dart → Rust: request current app session snapshot
#[derive(Deserialize, DartSignal)]
pub struct RequestAppSessionSnapshot;

/// Dart → Rust: provide persisted bootstrap facts needed by the FSM
#[derive(Deserialize, DartSignal)]
pub struct BootstrapAppSession {
    pub has_completed_setup: bool,
}

/// Dart → Rust: advance onboarding flow
#[derive(Deserialize, DartSignal)]
pub struct AdvanceOnboarding;

/// Dart → Rust: move onboarding back
#[derive(Deserialize, DartSignal)]
pub struct RetreatOnboarding;

/// Dart → Rust: mark onboarding complete
#[derive(Deserialize, DartSignal)]
pub struct CompleteOnboarding;

/// Dart → Rust: request application shutdown
#[derive(Deserialize, DartSignal)]
pub struct RequestQuit;

// ============================================================================
// Updates signals (bidirectional)
// ============================================================================

/// Rust → Dart: current updates snapshot
#[derive(Serialize, RustSignal)]
pub struct UpdatesSnapshotChanged {
    pub status: UpdateStatus,
}

/// Dart → Rust: request current updates snapshot
#[derive(Deserialize, DartSignal)]
pub struct RequestUpdatesSnapshot;

/// Dart → Rust: report the latest updater status observed by shell/UI layer
#[derive(Deserialize, DartSignal)]
pub struct ReportUpdatesStatus {
    pub status: UpdateStatus,
}

// ============================================================================
// Shell capabilities signals (bidirectional)
// ============================================================================

/// Rust → Dart: current shell/platform capability snapshot
#[derive(Serialize, RustSignal)]
pub struct ShellCapabilitiesSnapshotChanged {
    pub snapshot: ShellCapabilitiesSnapshot,
}

/// Dart → Rust: request current shell capability snapshot
#[derive(Deserialize, DartSignal)]
pub struct RequestShellCapabilitiesSnapshot;

/// Dart → Rust: report shell/platform capabilities observed locally
#[derive(Deserialize, DartSignal)]
pub struct ReportShellCapabilitiesSnapshot {
    pub snapshot: ShellCapabilitiesSnapshot,
}

// ============================================================================
// Device signals (Rust → Dart)
// ============================================================================

#[derive(Serialize, RustSignal)]
pub struct AudioDevicesSnapshotChanged {
    pub snapshot: AudioDevicesSnapshot,
}

#[derive(Deserialize, DartSignal)]
pub struct RequestAudioDevicesSnapshot;
