//! UI- and transport-independent Wrenflow application runtime.
//!
//! The runtime accepts typed commands and publishes current state through
//! watch channels plus edge-triggered events through a broadcast channel.
//! Desktop shells consume this API without a UI framework or transport layer
//! leaking into the runtime.

mod api;
mod capabilities;
mod data_paths;
pub mod diagnostics;
mod history;
mod logging;
mod model;
pub mod owner_smoke;
pub mod performance;
mod pipeline;
mod platform;
pub mod recovery;
mod state;
mod store;
mod supervisor;
pub mod support;
pub mod update;

pub use api::{
    CommandOutcome, RuntimeCommand, RuntimeError, RuntimeEvent, RuntimeEventEnvelope, SettingsPatch,
};
pub use state::{
    AppSessionState, AudioDevicesSnapshot, ErrorAction, HistoryLoadState, HistorySnapshot,
    LaunchAtLoginSnapshot, LocalModelRuntimeState, LocalModelsSnapshot, ModelInventoryState,
    ModelOperationState, OnboardingStep, PermissionStatus, PermissionsSnapshot,
    RuntimeCapabilities, RuntimePhase, RuntimeSnapshot, ShellCapabilities, ShellFacts,
    SupportBundleStatus, TranscriptDisposition, UpdateStatus,
};
pub use supervisor::{
    start_production_runtime, start_runtime, RuntimeBootstrap, RuntimeHandle, RuntimeInstance,
    RuntimeJoinHandle,
};
pub use wrenflow_domain::config::ThemePreference;
pub use wrenflow_domain::history::HistoryEntry;
pub use wrenflow_domain::pipeline::{PipelineSound, PipelineState};
