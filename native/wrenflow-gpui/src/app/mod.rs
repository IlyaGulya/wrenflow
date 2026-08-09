mod action;
mod effect;
mod model;
mod navigation;
mod presentation;
mod reducer;

pub use action::{AppAction, AppActionError};
pub use effect::{ShellRequest, ShellRequestReceiver};
pub use model::AppModel;
pub use navigation::{NavigationState, NavigationTarget};
pub use presentation::{
    AboutPresentation, AppPresentation, ContentState, DiagnosticPresentation,
    HistoryItemPresentation, HistoryPresentation, LaunchAtLoginPresentation,
    MicrophoneOptionPresentation, ModelPresentation, ModelStatusPresentation, ModelsPresentation,
    OnboardingPresentation, PermissionPresentation, PermissionRecoveryPresentation,
    PermissionsPresentation, SettingsPresentation, TranscriptionTestPhase,
    TranscriptionTestPresentation, UpdatePresentation,
};
pub use reducer::{AppMutation, AppReducer, CommandKey, CommandStatus, Notice, NoticeKind};
