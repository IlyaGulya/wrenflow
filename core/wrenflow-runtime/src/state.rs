use wrenflow_domain::audio::device::AudioDeviceInfo;
use wrenflow_domain::config::AppConfig;
use wrenflow_domain::history::HistoryEntry;
use wrenflow_domain::model_management::LocalModelCatalogEntry;
use wrenflow_domain::pipeline::PipelineState;

use crate::recovery::RecoverySnapshot;
use crate::support::SupportBundleFailureCode;
use crate::update::{UpdateChannel, UpdateFailureCode};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RuntimePhase {
    Starting,
    Running,
    ShuttingDown,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PermissionStatus {
    Unknown,
    Requesting,
    Granted,
    Denied,
    Restricted,
    NotApplicable,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PermissionsSnapshot {
    pub has_snapshot: bool,
    pub microphone: PermissionStatus,
    pub accessibility: PermissionStatus,
}

impl Default for PermissionsSnapshot {
    fn default() -> Self {
        Self {
            has_snapshot: false,
            microphone: PermissionStatus::Unknown,
            accessibility: PermissionStatus::Unknown,
        }
    }
}

impl PermissionsSnapshot {
    #[must_use]
    pub const fn all_granted(&self) -> bool {
        matches!(self.microphone, PermissionStatus::Granted)
            && matches!(self.accessibility, PermissionStatus::Granted)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OnboardingStep {
    Microphone,
    Accessibility,
    Hotkey,
    Model,
    Vocabulary,
    Complete,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AppSessionState {
    Initializing,
    Onboarding {
        step: OnboardingStep,
    },
    PermissionRecovery {
        microphone_missing: bool,
        accessibility_missing: bool,
    },
    Ready,
    ShuttingDown,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TranscriptDisposition {
    Paste,
    DisplayOnly,
}

#[derive(Clone, Debug, PartialEq)]
pub struct LocalModelRuntimeState {
    pub model_id: String,
    pub state: ModelOperationState,
}

/// Product-facing model lifecycle. Download rate and warmup are runtime
/// concerns, so they intentionally do not leak into the domain model type.
#[derive(Clone, Debug, PartialEq)]
pub enum ModelOperationState {
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

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum ModelInventoryState {
    #[default]
    Loading,
    Ready,
    Error,
}

#[derive(Clone, Debug, PartialEq)]
pub struct LocalModelsSnapshot {
    pub models: Vec<LocalModelCatalogEntry>,
    pub inventory_state: ModelInventoryState,
    pub selected_model_id: String,
    pub active_model_id: Option<String>,
    pub installed_model_ids: Vec<String>,
    pub model_states: Vec<LocalModelRuntimeState>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct AudioDevicesSnapshot {
    pub has_snapshot: bool,
    pub devices: Vec<AudioDeviceInfo>,
    pub default_device_name: String,
    pub selected_device_id: String,
    pub effective_selected_device_id: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct HistorySnapshot {
    pub load_state: HistoryLoadState,
    /// Compatibility signal for consumers that have not yet adopted
    /// [`HistoryLoadState`]. It is true if and only if `load_state` is Ready.
    pub has_snapshot: bool,
    pub entries: Vec<HistoryEntry>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum HistoryLoadState {
    #[default]
    Loading,
    Ready,
    Error {
        message: String,
    },
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RuntimeCapabilities {
    pub global_hotkey: bool,
    pub paste_injection: bool,
    pub local_transcription: bool,
    pub audio_capture: bool,
    pub model_download: bool,
    pub model_activation: bool,
    pub history_persistence: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ShellCapabilities {
    pub launch_at_login: bool,
    pub updates: bool,
    pub local_transcription: bool,
    pub microphone_selection: bool,
    pub tray: bool,
    pub overlays: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct LaunchAtLoginSnapshot {
    pub is_available: bool,
    pub enabled: bool,
    pub is_loading: bool,
    pub unavailable_reason: Option<String>,
    pub error_message: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum UpdateStatus {
    Unsupported,
    #[default]
    Idle,
    Checking {
        channel: UpdateChannel,
    },
    UpToDate {
        channel: UpdateChannel,
    },
    Available {
        latest_version: String,
        channel: UpdateChannel,
        published_at_iso: Option<String>,
        size_bytes: u64,
    },
    Downloading {
        latest_version: String,
        total_bytes: u64,
    },
    ReadyToInstall {
        latest_version: String,
    },
    Installing {
        latest_version: String,
    },
    RecoveryRequired {
        code: UpdateFailureCode,
    },
    Error {
        code: UpdateFailureCode,
        retryable: bool,
        retry_after_seconds: Option<u64>,
    },
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum SupportBundleStatus {
    #[default]
    Idle,
    Exporting,
    Ready {
        suggested_filename: String,
        size_bytes: u64,
    },
    Error {
        code: SupportBundleFailureCode,
    },
}

#[derive(Clone, Debug, Default)]
pub struct ShellFacts {
    pub capabilities: ShellCapabilities,
    pub launch_at_login: LaunchAtLoginSnapshot,
    pub update_status: UpdateStatus,
    pub support_bundle_status: SupportBundleStatus,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ErrorAction {
    pub id: String,
    pub label: String,
}

/// Complete, immutable current product state.
///
/// Large snapshots are shared through `Arc`, so cloning a watch value does not
/// clone history or model catalog data.
#[derive(Clone, Debug)]
pub struct RuntimeSnapshot {
    pub revision: u64,
    pub phase: RuntimePhase,
    pub settings: AppConfig,
    pub session: AppSessionState,
    pub pipeline: PipelineState,
    pub models: LocalModelsSnapshot,
    pub permissions: PermissionsSnapshot,
    pub history: HistorySnapshot,
    pub audio_devices: AudioDevicesSnapshot,
    pub runtime_capabilities: RuntimeCapabilities,
    pub shell: ShellFacts,
    pub recovery: RecoverySnapshot,
    pub transcript_disposition: TranscriptDisposition,
    pub(crate) permission_lost_count: u8,
}
