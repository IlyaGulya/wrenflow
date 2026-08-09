use std::time::Duration;

use tokio::sync::oneshot;
use wrenflow_domain::config::ThemePreference;
use wrenflow_domain::history::HistoryEntry;
use wrenflow_domain::pipeline::PipelineSound;

use crate::state::{
    ErrorAction, LaunchAtLoginSnapshot, PermissionsSnapshot, ShellCapabilities,
    SupportBundleStatus, TranscriptDisposition, UpdateStatus,
};

/// A single typed input to the product runtime.
#[derive(Clone, Debug, PartialEq)]
pub enum RuntimeCommand {
    UpdateSettings(SettingsPatch),
    ActivateSelectedModel,
    CancelModelOperation,
    HotkeyPressed,
    HotkeyReleased { duration: Duration },
    ReloadAudioDevices,
    DeleteHistoryEntry { id: String },
    ClearHistory,
    AdvanceOnboarding,
    RetreatOnboarding,
    SetTranscriptDisposition(TranscriptDisposition),
    ReportPermissions(PermissionsSnapshot),
    ReportLaunchAtLogin(LaunchAtLoginSnapshot),
    ReportUpdateStatus(UpdateStatus),
    ReportSupportBundleStatus(SupportBundleStatus),
    ReportShellCapabilities(ShellCapabilities),
    RequestQuit,
    Shutdown,
}

impl RuntimeCommand {
    pub(crate) const fn subsystem_name(&self) -> Option<&'static str> {
        match self {
            Self::ActivateSelectedModel | Self::CancelModelOperation => Some("models"),
            Self::HotkeyPressed | Self::HotkeyReleased { .. } => Some("pipeline"),
            Self::ReloadAudioDevices => Some("audio_devices"),
            Self::DeleteHistoryEntry { .. } | Self::ClearHistory => Some("history"),
            _ => None,
        }
    }
}

/// A focused mutation of the persisted application settings.
#[derive(Clone, Debug, PartialEq)]
pub enum SettingsPatch {
    SelectedLocalModelId(String),
    SelectedHotkey(String),
    SelectedMicrophoneId(String),
    SoundEnabled(bool),
    ThemePreference(ThemePreference),
    CustomVocabulary(String),
    MinimumRecordingDuration(Duration),
    HasCompletedSetup(bool),
}

/// Edge-triggered runtime output. Current product state belongs in
/// [`crate::RuntimeSnapshot`] instead.
#[derive(Clone, Debug, PartialEq)]
pub enum RuntimeEvent {
    PlaySound(PipelineSound),
    TranscriptReady {
        transcript: String,
    },
    PipelineError {
        message: String,
        action: Option<ErrorAction>,
    },
    PasteCompleted,
    HistoryEntryAdded(HistoryEntry),
    QuitRequested,
}

/// Sequencing makes dropped or lagged event diagnostics deterministic.
#[derive(Clone, Debug, PartialEq)]
pub struct RuntimeEventEnvelope {
    pub sequence: u64,
    pub event: RuntimeEvent,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CommandOutcome {
    Applied { revision: u64 },
    NoChange { revision: u64 },
    ShuttingDown { revision: u64 },
}

impl CommandOutcome {
    #[must_use]
    pub const fn revision(&self) -> u64 {
        match self {
            Self::Applied { revision }
            | Self::NoChange { revision }
            | Self::ShuttingDown { revision } => *revision,
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum RuntimeError {
    #[error("the runtime command channel is closed")]
    CommandChannelClosed,
    #[error("the runtime dropped a command response")]
    CommandResponseDropped,
    #[error("runtime subsystem '{0}' is not wired yet")]
    SubsystemUnavailable(&'static str),
    #[error("the canonical runtime state lock is unavailable")]
    StateUnavailable,
    #[error("runtime service '{service}' failed: {message}")]
    ServiceFailed {
        service: &'static str,
        message: String,
    },
    #[error("runtime service '{0}' is closed")]
    ServiceClosed(&'static str),
    #[error("start_runtime must be called from a Tokio runtime")]
    NoAsyncRuntime,
    #[error("runtime supervisor task failed: {0}")]
    SupervisorFailed(String),
}

pub(crate) struct RuntimeRequest {
    pub command: RuntimeCommand,
    pub completion: Option<oneshot::Sender<Result<CommandOutcome, RuntimeError>>>,
}
