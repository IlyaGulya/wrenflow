use tokio::sync::mpsc;
use wrenflow_runtime::update::UpdateChannel;

/// Typed requests whose implementation belongs to the AppKit shell.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ShellRequest {
    RequestMicrophonePermission,
    RequestAccessibilityPermission,
    OpenMicrophoneSettings,
    OpenAccessibilitySettings,
    SetLaunchAtLogin(bool),
    CheckForUpdates(UpdateChannel),
    DownloadAvailableUpdate,
    InstallReadyUpdate,
    ExportSupportBundle,
    ResetCurrentData,
}

pub type ShellRequestReceiver = mpsc::UnboundedReceiver<ShellRequest>;

pub(crate) type ShellRequestSender = mpsc::UnboundedSender<ShellRequest>;

pub(crate) fn channel() -> (ShellRequestSender, ShellRequestReceiver) {
    mpsc::unbounded_channel()
}
