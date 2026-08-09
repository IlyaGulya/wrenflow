//! UI- and transport-independent Wrenflow application runtime.
//!
//! The runtime accepts typed commands and publishes current state through
//! watch channels plus edge-triggered events through a broadcast channel.
//! Desktop shells consume this API without a UI framework or transport layer
//! leaking into the runtime.

mod api;
mod capabilities;
mod history;
mod logging;
mod model;
mod pipeline;
mod platform;
mod state;
mod store;
mod supervisor;

pub use api::{
    CommandOutcome, RuntimeCommand, RuntimeError, RuntimeEvent, RuntimeEventEnvelope, SettingsPatch,
};
pub use state::{
    AppSessionState, AudioDevicesSnapshot, ErrorAction, HistorySnapshot, LaunchAtLoginSnapshot,
    LocalModelRuntimeState, LocalModelsSnapshot, ModelOperationState, OnboardingStep,
    PermissionStatus, PermissionsSnapshot, RuntimeCapabilities, RuntimePhase, RuntimeSnapshot,
    ShellCapabilities, ShellFacts, TranscriptDisposition, UpdateStatus,
};
pub use supervisor::{
    start_production_runtime, start_runtime, RuntimeBootstrap, RuntimeHandle, RuntimeInstance,
    RuntimeJoinHandle,
};
pub use wrenflow_domain::history::HistoryEntry;
pub use wrenflow_domain::pipeline::{PipelineSound, PipelineState};
