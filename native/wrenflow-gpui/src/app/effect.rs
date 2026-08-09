use tokio::sync::mpsc;

/// Typed requests whose implementation belongs to the AppKit shell.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ShellRequest {
    RequestMicrophonePermission,
    RequestAccessibilityPermission,
    OpenMicrophoneSettings,
    OpenAccessibilitySettings,
    SetLaunchAtLogin(bool),
    CheckForUpdates,
    OpenUrl { url: String },
}

pub type ShellRequestReceiver = mpsc::UnboundedReceiver<ShellRequest>;

pub(crate) type ShellRequestSender = mpsc::UnboundedSender<ShellRequest>;

pub(crate) fn channel() -> (ShellRequestSender, ShellRequestReceiver) {
    mpsc::unbounded_channel()
}
