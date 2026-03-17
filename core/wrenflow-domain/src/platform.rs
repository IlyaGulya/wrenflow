//! Platform abstraction layer.
//!
//! Defines the cross-platform types and traits that native shells implement.

// ---------------------------------------------------------------------------
// Permissions FSM
// ---------------------------------------------------------------------------

/// Every permission the app may need, across all platforms.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum PermissionKind {
    Microphone,
    Accessibility,
    ScreenRecording,
}

/// What the OS reports for a single permission.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OsPermissionStatus {
    Granted,
    NotGranted,
    Denied,
    NotApplicable,
}

/// The lifecycle state of a single permission (FSM).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PermissionState {
    /// Haven't checked yet.
    Unknown,
    /// OS says not granted, user hasn't been prompted.
    NotGranted,
    /// The OS prompt is showing or we opened System Settings.
    Requesting,
    /// Permission granted.
    Granted,
    /// User explicitly denied.
    Denied,
    /// Permission doesn't exist on this platform.
    NotApplicable,
}

impl PermissionState {
    pub fn is_satisfied(self) -> bool {
        matches!(self, Self::Granted | Self::NotApplicable)
    }

    pub fn is_blocking(self) -> bool {
        matches!(self, Self::Unknown | Self::NotGranted | Self::Requesting | Self::Denied)
    }
}

// ---------------------------------------------------------------------------
// Other shared types
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
pub struct AudioDevice {
    pub id: String,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq)]
pub enum LocalModelState {
    NotLoaded,
    Downloading { progress: Option<f64> },
    Compiling,
    Ready,
    Error(String),
}

#[derive(Debug, Clone, PartialEq)]
pub enum UpdateStatus {
    Idle,
    Checking,
    Available { version: String },
    Downloading { progress: Option<f64> },
    Installing,
    ReadyToRelaunch,
    Error(String),
    UpToDate,
}

#[derive(Debug, Clone, PartialEq)]
pub struct CliToolStatus {
    pub installed: bool,
    pub path: Option<String>,
}

// ---------------------------------------------------------------------------
// Capability flags
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default)]
pub struct PlatformCapabilities {
    pub launch_at_login: bool,
    pub updates: bool,
    pub local_transcription: bool,
    pub microphone_selection: bool,
    pub cli_tool: bool,
}

// ---------------------------------------------------------------------------
// PlatformHost trait
// ---------------------------------------------------------------------------

/// Platform-specific operations. Each native shell implements this.
pub trait PlatformHost: Send + Sync + 'static {
    fn capabilities(&self) -> PlatformCapabilities;

    // -- Permissions (generic, 2 methods for all permission types) --

    fn get_permission(&self, _kind: PermissionKind) -> OsPermissionStatus {
        OsPermissionStatus::NotApplicable
    }
    fn request_permission(&self, _kind: PermissionKind) {}

    // -- Launch at Login --

    fn get_launch_at_login(&self) -> bool { false }
    fn set_launch_at_login(&self, _enabled: bool) {}
    fn launch_at_login_requires_approval(&self) -> bool { false }
    fn open_launch_at_login_settings(&self) {}

    // -- Updates --

    fn get_auto_check_updates(&self) -> bool { true }
    fn set_auto_check_updates(&self, _enabled: bool) {}
    fn check_for_updates(&self) {}
    fn get_update_status(&self) -> UpdateStatus { UpdateStatus::Idle }
    fn download_and_install_update(&self) {}
    fn cancel_update_download(&self) {}

    // -- Local Transcription Model --

    fn get_local_model_state(&self) -> LocalModelState { LocalModelState::NotLoaded }
    fn load_local_model(&self) {}
    fn retry_local_model(&self) {}

    // -- Microphone --

    fn list_microphones(&self) -> Vec<AudioDevice> { vec![] }
    fn refresh_microphones(&self) {}

    // -- CLI Tool --

    fn get_cli_status(&self) -> CliToolStatus { CliToolStatus { installed: false, path: None } }
    fn install_cli(&self) {}
}

// ---------------------------------------------------------------------------
// Stub
// ---------------------------------------------------------------------------

pub struct StubPlatformHost;

impl PlatformHost for StubPlatformHost {
    fn capabilities(&self) -> PlatformCapabilities {
        PlatformCapabilities::default()
    }
}
