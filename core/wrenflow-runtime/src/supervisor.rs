use std::sync::Arc;

use tokio::sync::{broadcast, mpsc, oneshot, watch};
use tokio::task::JoinHandle;
use wrenflow_core::{ConfigError, ConfigStore};
use wrenflow_domain::config::{AppConfig, DEFAULT_SELECTED_MICROPHONE_ID};
use wrenflow_domain::model_management::all_local_model_catalog_entries;
use wrenflow_domain::pipeline::PipelineState;

use crate::api::{
    CommandOutcome, RuntimeCommand, RuntimeError, RuntimeEvent, RuntimeEventEnvelope,
    RuntimeRequest, SettingsPatch,
};
use crate::capabilities;
use crate::state::{
    AppSessionState, AudioDevicesSnapshot, HistorySnapshot, LaunchAtLoginSnapshot,
    LocalModelsSnapshot, OnboardingStep, PermissionStatus, PermissionsSnapshot,
    RuntimeCapabilities, RuntimePhase, RuntimeSnapshot, ShellCapabilities, ShellFacts,
    TranscriptDisposition, UpdateStatus,
};
use crate::store::RuntimeStore;
use crate::{
    history, history::HistoryHandle, model, model::ModelHandle, performance, pipeline,
    pipeline::PipelineHandle,
};

const COMMAND_CHANNEL_CAPACITY: usize = 64;
const EVENT_CHANNEL_CAPACITY: usize = 128;

#[derive(Clone, Debug, Default)]
pub struct RuntimeBootstrap {
    pub initial_config: AppConfig,
    pub runtime_capabilities: RuntimeCapabilities,
    pub shell_capabilities: ShellCapabilities,
    pub recovery: crate::recovery::RecoverySnapshot,
}

#[derive(Clone)]
pub struct RuntimeHandle {
    commands: mpsc::Sender<RuntimeRequest>,
    performance: mpsc::Sender<performance::PerformanceRuntimeRequest>,
    snapshot: watch::Receiver<Arc<RuntimeSnapshot>>,
    audio_level: watch::Receiver<f32>,
    events: broadcast::Sender<RuntimeEventEnvelope>,
}

impl RuntimeHandle {
    /// Enter the private signed-app workload. Only a request prepared before
    /// production diagnostics/runtime startup can cross this boundary.
    pub async fn run_performance_self_test(
        &self,
        request: performance::PerformanceSelfTestRequest,
    ) -> Result<(), RuntimeError> {
        let (completion, result) = oneshot::channel();
        self.performance
            .send(performance::PerformanceRuntimeRequest {
                request,
                completion,
            })
            .await
            .map_err(|_| RuntimeError::ServiceClosed("performance_self_test"))?;
        result
            .await
            .map_err(|_| RuntimeError::ServiceClosed("performance_self_test"))?
    }

    /// Enqueue a command without waiting for the subsystem result.
    pub async fn send(&self, command: RuntimeCommand) -> Result<(), RuntimeError> {
        self.commands
            .send(RuntimeRequest {
                command,
                completion: None,
            })
            .await
            .map_err(|_| RuntimeError::CommandChannelClosed)
    }

    /// Enqueue a command and wait until the canonical state transition (if
    /// any) has been published.
    pub async fn request(&self, command: RuntimeCommand) -> Result<CommandOutcome, RuntimeError> {
        let (tx, rx) = oneshot::channel();
        self.commands
            .send(RuntimeRequest {
                command,
                completion: Some(tx),
            })
            .await
            .map_err(|_| RuntimeError::CommandChannelClosed)?;
        rx.await.map_err(|_| RuntimeError::CommandResponseDropped)?
    }

    /// Return the latest complete snapshot without a request/response
    /// handshake.
    #[must_use]
    pub fn snapshot(&self) -> Arc<RuntimeSnapshot> {
        self.snapshot.borrow().clone()
    }

    #[must_use]
    pub fn subscribe_snapshots(&self) -> watch::Receiver<Arc<RuntimeSnapshot>> {
        self.snapshot.clone()
    }

    #[must_use]
    pub fn subscribe_audio_level(&self) -> watch::Receiver<f32> {
        self.audio_level.clone()
    }

    #[must_use]
    pub fn subscribe_events(&self) -> broadcast::Receiver<RuntimeEventEnvelope> {
        self.events.subscribe()
    }
}

pub struct RuntimeJoinHandle {
    task: JoinHandle<()>,
}

impl RuntimeJoinHandle {
    pub async fn wait(self) -> Result<(), RuntimeError> {
        self.task
            .await
            .map_err(|error| RuntimeError::SupervisorFailed(error.to_string()))
    }
}

pub struct RuntimeInstance {
    pub handle: RuntimeHandle,
    pub join: RuntimeJoinHandle,
}

impl RuntimeInstance {
    pub async fn shutdown(self) -> Result<(), RuntimeError> {
        self.handle.request(RuntimeCommand::Shutdown).await?;
        self.join.wait().await?;
        crate::diagnostics::emit_diagnostic(crate::diagnostics::DiagnosticEvent::new(
            crate::diagnostics::DiagnosticCategory::Lifecycle,
            crate::diagnostics::DiagnosticLevel::Info,
            crate::diagnostics::DiagnosticCode::Shutdown,
        ));
        crate::recovery::mark_production_launch_clean().map_err(|error| {
            RuntimeError::ServiceFailed {
                service: "recovery",
                message: error.to_string(),
            }
        })?;
        Ok(())
    }
}

/// Start a runtime supervisor on the current Tokio runtime.
pub fn start_runtime(bootstrap: RuntimeBootstrap) -> Result<RuntimeInstance, RuntimeError> {
    start_runtime_inner(bootstrap, ProductionOptions::default())
}

/// Start the concrete desktop runtime with persistent settings and history.
pub fn start_production_runtime() -> Result<RuntimeInstance, RuntimeError> {
    crate::logging::install();
    let recovery = crate::recovery::begin_production_recovery().map_err(|error| {
        RuntimeError::ServiceFailed {
            service: "recovery",
            message: error.to_string(),
        }
    })?;
    if recovery.safe_mode() {
        return start_runtime_inner(
            RuntimeBootstrap {
                recovery,
                ..RuntimeBootstrap::default()
            },
            ProductionOptions::default(),
        );
    }
    let paths = crate::data_paths::current_data_paths();
    let settings_store = Arc::new(ConfigStore::new(paths.config));
    let config = match settings_store.load() {
        Ok(config) => config,
        Err(ConfigError::Io(error)) if error.kind() == std::io::ErrorKind::NotFound => {
            let config = AppConfig::default();
            settings_store
                .save(&config)
                .map_err(|error| settings_startup_error(error.to_string()))?;
            config
        }
        Err(error) => {
            log::error!("Current GPUI config recovery required: {error}");
            return Err(settings_startup_error(format!(
                "{error}. The original data was not overwritten; inspect the quarantine and use the explicit GPUI data reset flow if recovery is not required"
            )));
        }
    };
    start_runtime_inner(
        RuntimeBootstrap {
            initial_config: config,
            runtime_capabilities: capabilities::detect_runtime_capabilities(),
            recovery,
            ..RuntimeBootstrap::default()
        },
        ProductionOptions {
            settings_store: Some(settings_store),
            history_path: Some(paths.history),
            platform_services: true,
        },
    )
}

fn settings_startup_error(message: String) -> RuntimeError {
    RuntimeError::ServiceFailed {
        service: "settings",
        message,
    }
}

#[derive(Default)]
struct ProductionOptions {
    settings_store: Option<Arc<ConfigStore>>,
    history_path: Option<std::path::PathBuf>,
    platform_services: bool,
}

fn start_runtime_inner(
    bootstrap: RuntimeBootstrap,
    options: ProductionOptions,
) -> Result<RuntimeInstance, RuntimeError> {
    tokio::runtime::Handle::try_current().map_err(|_| RuntimeError::NoAsyncRuntime)?;

    let initial_snapshot = initial_snapshot(&bootstrap);
    let (command_tx, command_rx) = mpsc::channel(COMMAND_CHANNEL_CAPACITY);
    let (snapshot_tx, snapshot_rx) = watch::channel(Arc::new(initial_snapshot.clone()));
    let (audio_level_tx, audio_level_rx) = watch::channel(0.0_f32);
    let (event_tx, _) = broadcast::channel(EVENT_CHANNEL_CAPACITY);
    let store = RuntimeStore::new(
        initial_snapshot,
        snapshot_tx,
        audio_level_tx,
        event_tx.clone(),
    );
    if options.platform_services {
        capabilities::refresh_audio_devices(&store)?;
    }
    let history_runtime = options
        .history_path
        .map(|path| history::start(path, store.clone()))
        .transpose()?;
    let history_handle = history_runtime
        .as_ref()
        .map(|runtime| runtime.handle.clone());
    let history_join = history_runtime.map(|runtime| runtime.join);
    let model_runtime = options
        .platform_services
        .then(|| model::start(store.clone(), options.settings_store.clone()));
    let model_handle = model_runtime.as_ref().map(|runtime| runtime.handle.clone());
    let model_join = model_runtime.map(|runtime| runtime.join);
    let pipeline_runtime = model_handle.as_ref().map(|models| {
        pipeline::start(
            store.clone(),
            models.transcription(),
            history_handle.clone(),
        )
    });
    let pipeline_handle = pipeline_runtime
        .as_ref()
        .map(|runtime| runtime.handle.clone());
    let pipeline_join = pipeline_runtime.map(|runtime| runtime.join);
    let (performance_tx, performance_rx) = performance::channel();
    let performance_join = performance::start(
        performance_rx,
        model_handle.clone(),
        history_handle.clone(),
        store.clone(),
    );

    let task = tokio::spawn(async move {
        RuntimeSupervisor {
            commands: command_rx,
            store,
            settings_store: options.settings_store,
            history: history_handle,
            history_join,
            models: model_handle,
            model_join,
            pipeline: pipeline_handle,
            pipeline_join,
            performance_join: Some(performance_join),
            platform_services: options.platform_services,
        }
        .run()
        .await;
    });

    Ok(RuntimeInstance {
        handle: RuntimeHandle {
            commands: command_tx,
            performance: performance_tx,
            snapshot: snapshot_rx,
            audio_level: audio_level_rx,
            events: event_tx,
        },
        join: RuntimeJoinHandle { task },
    })
}

pub(crate) fn initial_snapshot(bootstrap: &RuntimeBootstrap) -> RuntimeSnapshot {
    let selected_model_id = bootstrap.initial_config.selected_local_model_id.clone();
    let selected_microphone_id = bootstrap.initial_config.selected_microphone_id.clone();

    RuntimeSnapshot {
        revision: 0,
        phase: RuntimePhase::Running,
        settings: bootstrap.initial_config.clone(),
        session: AppSessionState::Initializing,
        pipeline: PipelineState::Idle,
        models: LocalModelsSnapshot {
            models: all_local_model_catalog_entries(),
            selected_model_id,
            active_model_id: None,
            installed_model_ids: Vec::new(),
            model_states: Vec::new(),
        },
        permissions: PermissionsSnapshot::default(),
        history: HistorySnapshot {
            has_snapshot: false,
            entries: Vec::new(),
        },
        audio_devices: AudioDevicesSnapshot {
            has_snapshot: false,
            devices: Vec::new(),
            default_device_name: String::new(),
            selected_device_id: selected_microphone_id.clone(),
            effective_selected_device_id: DEFAULT_SELECTED_MICROPHONE_ID.to_string(),
        },
        runtime_capabilities: bootstrap.runtime_capabilities.clone(),
        shell: ShellFacts {
            capabilities: bootstrap.shell_capabilities.clone(),
            launch_at_login: LaunchAtLoginSnapshot {
                is_available: true,
                is_loading: true,
                ..LaunchAtLoginSnapshot::default()
            },
            update_status: UpdateStatus::default(),
            support_bundle_status: crate::SupportBundleStatus::default(),
        },
        recovery: bootstrap.recovery.clone(),
        transcript_disposition: TranscriptDisposition::DisplayOnly,
        permission_lost_count: 0,
    }
}

struct RuntimeSupervisor {
    commands: mpsc::Receiver<RuntimeRequest>,
    store: RuntimeStore,
    settings_store: Option<Arc<ConfigStore>>,
    history: Option<HistoryHandle>,
    history_join: Option<std::thread::JoinHandle<()>>,
    models: Option<ModelHandle>,
    model_join: Option<JoinHandle<()>>,
    pipeline: Option<PipelineHandle>,
    pipeline_join: Option<JoinHandle<()>>,
    performance_join: Option<JoinHandle<()>>,
    platform_services: bool,
}

impl RuntimeSupervisor {
    async fn run(mut self) {
        while let Some(request) = self.commands.recv().await {
            let should_stop = matches!(&request.command, RuntimeCommand::Shutdown);
            let result = self.apply(request.command).await;
            if let Some(completion) = request.completion {
                let _ = completion.send(result);
            }
            if should_stop {
                break;
            }
        }

        if let Some(pipeline) = &self.pipeline {
            pipeline.shutdown().await;
        }
        if let Some(join) = self.performance_join.take() {
            if !join.is_finished() {
                join.abort();
            }
            let _ = join.await;
        }
        if let Some(models) = &self.models {
            models.shutdown().await;
        }
        if let Some(join) = self.pipeline_join.take() {
            if let Err(error) = join.await {
                log::error!("Pipeline runtime task failed during shutdown: {error}");
            }
        }
        if let Some(history) = &self.history {
            history.shutdown();
        }
        if let Some(join) = self.history_join.take() {
            if join.join().is_err() {
                log::error!("History runtime thread panicked during shutdown");
            }
        }
        if let Some(join) = self.model_join.take() {
            if let Err(error) = join.await {
                log::error!("Model runtime task failed during shutdown: {error}");
            }
        }
    }

    async fn apply(&mut self, command: RuntimeCommand) -> Result<CommandOutcome, RuntimeError> {
        diagnose_command(&command);
        let command = match command {
            RuntimeCommand::DeleteHistoryEntry { id } => {
                let history = self
                    .history
                    .as_ref()
                    .ok_or(RuntimeError::SubsystemUnavailable("history"))?;
                let revision = history.delete(id).await?;
                return Ok(CommandOutcome::Applied { revision });
            }
            RuntimeCommand::ClearHistory => {
                let history = self
                    .history
                    .as_ref()
                    .ok_or(RuntimeError::SubsystemUnavailable("history"))?;
                let revision = history.clear().await?;
                return Ok(CommandOutcome::Applied { revision });
            }
            RuntimeCommand::ReloadAudioDevices => {
                if !self.platform_services {
                    return Err(RuntimeError::SubsystemUnavailable("audio_devices"));
                }
                let update = capabilities::refresh_audio_devices(&self.store)?;
                return Ok(if update.changed {
                    CommandOutcome::Applied {
                        revision: update.revision,
                    }
                } else {
                    CommandOutcome::NoChange {
                        revision: update.revision,
                    }
                });
            }
            RuntimeCommand::ActivateSelectedModel => {
                let models = self
                    .models
                    .as_ref()
                    .ok_or(RuntimeError::SubsystemUnavailable("models"))?;
                models.activate_selected().await?;
                return Ok(CommandOutcome::Applied {
                    revision: self.store.snapshot().revision,
                });
            }
            RuntimeCommand::CancelModelOperation => {
                let models = self
                    .models
                    .as_ref()
                    .ok_or(RuntimeError::SubsystemUnavailable("models"))?;
                models.cancel().await?;
                return Ok(CommandOutcome::Applied {
                    revision: self.store.snapshot().revision,
                });
            }
            RuntimeCommand::HotkeyPressed => {
                let pipeline = self
                    .pipeline
                    .as_ref()
                    .ok_or(RuntimeError::SubsystemUnavailable("pipeline"))?;
                pipeline.hotkey_pressed()?;
                return Ok(CommandOutcome::Applied {
                    revision: self.store.snapshot().revision,
                });
            }
            RuntimeCommand::HotkeyReleased { duration } => {
                let pipeline = self
                    .pipeline
                    .as_ref()
                    .ok_or(RuntimeError::SubsystemUnavailable("pipeline"))?;
                pipeline.hotkey_released(duration)?;
                return Ok(CommandOutcome::Applied {
                    revision: self.store.snapshot().revision,
                });
            }
            other => other,
        };
        if let Some(subsystem) = command.subsystem_name() {
            return Err(RuntimeError::SubsystemUnavailable(subsystem));
        }

        if let RuntimeCommand::UpdateSettings(patch) = &command {
            let mut candidate = (*self.store.snapshot()).clone();
            if !apply_settings_patch(&mut candidate, patch.clone()) {
                return Ok(CommandOutcome::NoChange {
                    revision: candidate.revision,
                });
            }
            if let Some(settings_store) = &self.settings_store {
                if let Err(error) = settings_store.save(&candidate.settings) {
                    let message = format!("Failed to persist settings atomically: {error}");
                    crate::diagnostics::emit_diagnostic(crate::diagnostics::DiagnosticEvent::new(
                        crate::diagnostics::DiagnosticCategory::Lifecycle,
                        crate::diagnostics::DiagnosticLevel::Error,
                        crate::diagnostics::DiagnosticCode::SettingsWriteFailed,
                    ));
                    log::error!("{message}");
                    self.store.emit(RuntimeEvent::PipelineError {
                        message: message.clone(),
                        action: None,
                    });
                    return Err(RuntimeError::ServiceFailed {
                        service: "settings",
                        message,
                    });
                }
            }
            let update = self
                .store
                .update(|state| apply_settings_patch(state, patch.clone()))?;
            return Ok(CommandOutcome::Applied {
                revision: update.revision,
            });
        }
        let mut shutting_down = false;
        let mut emit_quit = false;
        let update = self.store.update(|state| match command {
            RuntimeCommand::UpdateSettings(_) => unreachable!("handled before match"),
            RuntimeCommand::AdvanceOnboarding => advance_onboarding(state),
            RuntimeCommand::RetreatOnboarding => retreat_onboarding(state),
            RuntimeCommand::SetTranscriptDisposition(disposition) => {
                if state.transcript_disposition == disposition {
                    false
                } else {
                    state.transcript_disposition = disposition;
                    true
                }
            }
            RuntimeCommand::ReportPermissions(permissions) => apply_permissions(state, permissions),
            RuntimeCommand::ReportLaunchAtLogin(snapshot) => {
                if state.shell.launch_at_login == snapshot {
                    false
                } else {
                    state.shell.launch_at_login = snapshot;
                    true
                }
            }
            RuntimeCommand::ReportUpdateStatus(status) => {
                if state.shell.update_status == status {
                    false
                } else {
                    state.shell.update_status = status;
                    true
                }
            }
            RuntimeCommand::ReportSupportBundleStatus(status) => {
                if state.shell.support_bundle_status == status {
                    false
                } else {
                    state.shell.support_bundle_status = status;
                    true
                }
            }
            RuntimeCommand::ReportShellCapabilities(capabilities) => {
                if state.shell.capabilities == capabilities {
                    false
                } else {
                    state.shell.capabilities = capabilities;
                    true
                }
            }
            RuntimeCommand::RequestQuit => {
                if state.session == AppSessionState::ShuttingDown {
                    false
                } else {
                    state.session = AppSessionState::ShuttingDown;
                    emit_quit = true;
                    true
                }
            }
            RuntimeCommand::Shutdown => {
                shutting_down = true;
                if state.phase == RuntimePhase::ShuttingDown {
                    false
                } else {
                    state.phase = RuntimePhase::ShuttingDown;
                    state.session = AppSessionState::ShuttingDown;
                    true
                }
            }
            RuntimeCommand::ActivateSelectedModel
            | RuntimeCommand::CancelModelOperation
            | RuntimeCommand::HotkeyPressed
            | RuntimeCommand::HotkeyReleased { .. }
            | RuntimeCommand::ReloadAudioDevices
            | RuntimeCommand::DeleteHistoryEntry { .. }
            | RuntimeCommand::ClearHistory => unreachable!("handled before match"),
        })?;

        if emit_quit {
            self.store.emit(RuntimeEvent::QuitRequested);
        }
        if shutting_down {
            Ok(CommandOutcome::ShuttingDown {
                revision: update.revision,
            })
        } else if update.changed {
            Ok(CommandOutcome::Applied {
                revision: update.revision,
            })
        } else {
            Ok(CommandOutcome::NoChange {
                revision: update.revision,
            })
        }
    }
}

fn diagnose_command(command: &RuntimeCommand) {
    use crate::diagnostics::{emit_diagnostic, DiagnosticEvent, DiagnosticLevel as Level};

    if let Some((category, code)) = diagnostic_marker_for_command(command) {
        emit_diagnostic(DiagnosticEvent::new(category, Level::Info, code));
    }
}

fn diagnostic_marker_for_command(
    command: &RuntimeCommand,
) -> Option<(
    crate::diagnostics::DiagnosticCategory,
    crate::diagnostics::DiagnosticCode,
)> {
    use crate::diagnostics::{DiagnosticCategory as Category, DiagnosticCode as Code};

    match command {
        RuntimeCommand::ReportPermissions(_) => {
            Some((Category::Permissions, Code::PermissionStateObserved))
        }
        RuntimeCommand::ReportLaunchAtLogin(_) => {
            Some((Category::Lifecycle, Code::LaunchAtLoginObserved))
        }
        RuntimeCommand::HotkeyPressed => Some((Category::Hotkey, Code::HotkeyPressed)),
        RuntimeCommand::HotkeyReleased { .. } => Some((Category::Hotkey, Code::HotkeyReleased)),
        RuntimeCommand::ActivateSelectedModel => {
            Some((Category::Models, Code::ModelActivationRequested))
        }
        RuntimeCommand::CancelModelOperation => {
            Some((Category::Models, Code::ModelCancellationRequested))
        }
        RuntimeCommand::DeleteHistoryEntry { .. } => {
            Some((Category::History, Code::HistoryDeleteRequested))
        }
        RuntimeCommand::ClearHistory => Some((Category::History, Code::HistoryClearRequested)),
        RuntimeCommand::ReportUpdateStatus(_) => {
            Some((Category::Updates, Code::UpdateStatusObserved))
        }
        RuntimeCommand::ReportSupportBundleStatus(_) => {
            Some((Category::Lifecycle, Code::SupportBundleStatusObserved))
        }
        RuntimeCommand::ReportShellCapabilities(_) => {
            Some((Category::Bridge, Code::ShellCapabilitiesObserved))
        }
        RuntimeCommand::UpdateSettings(_)
        | RuntimeCommand::ReloadAudioDevices
        | RuntimeCommand::AdvanceOnboarding
        | RuntimeCommand::RetreatOnboarding
        | RuntimeCommand::SetTranscriptDisposition(_)
        | RuntimeCommand::RequestQuit
        | RuntimeCommand::Shutdown => None,
    }
}

fn apply_settings_patch(state: &mut RuntimeSnapshot, patch: SettingsPatch) -> bool {
    let affects_session = matches!(&patch, SettingsPatch::HasCompletedSetup(_));
    let changed = match patch {
        SettingsPatch::SelectedLocalModelId(value) => {
            if state.settings.selected_local_model_id == value {
                false
            } else {
                state.settings.selected_local_model_id = value.clone();
                state.models.selected_model_id = value;
                true
            }
        }
        SettingsPatch::SelectedHotkey(value) => {
            replace_if_different(&mut state.settings.selected_hotkey, value)
        }
        SettingsPatch::SelectedMicrophoneId(value) => {
            if state.settings.selected_microphone_id == value {
                false
            } else {
                state.settings.selected_microphone_id = value.clone();
                state.audio_devices.selected_device_id = value.clone();
                state.audio_devices.effective_selected_device_id = if value
                    == DEFAULT_SELECTED_MICROPHONE_ID
                    || state
                        .audio_devices
                        .devices
                        .iter()
                        .any(|device| device.id == value)
                {
                    value
                } else {
                    DEFAULT_SELECTED_MICROPHONE_ID.to_string()
                };
                true
            }
        }
        SettingsPatch::SoundEnabled(value) => {
            if state.settings.sound_enabled == value {
                false
            } else {
                state.settings.sound_enabled = value;
                true
            }
        }
        SettingsPatch::ThemePreference(value) => {
            if state.settings.theme_preference == value {
                false
            } else {
                state.settings.theme_preference = value;
                true
            }
        }
        SettingsPatch::CustomVocabulary(value) => {
            replace_if_different(&mut state.settings.custom_vocabulary, value)
        }
        SettingsPatch::MinimumRecordingDuration(value) => {
            let milliseconds = value.as_secs_f64() * 1_000.0;
            if state.settings.minimum_recording_duration_ms == milliseconds {
                false
            } else {
                state.settings.minimum_recording_duration_ms = milliseconds;
                true
            }
        }
        SettingsPatch::HasCompletedSetup(value) => {
            if state.settings.has_completed_setup == value {
                false
            } else {
                state.settings.has_completed_setup = value;
                true
            }
        }
    };

    if changed && affects_session {
        let _ = evaluate_session(state);
    }
    changed
}

fn replace_if_different(target: &mut String, value: String) -> bool {
    if *target == value {
        false
    } else {
        *target = value;
        true
    }
}

fn evaluate_session(state: &mut RuntimeSnapshot) -> bool {
    if matches!(state.session, AppSessionState::ShuttingDown) {
        return false;
    }

    let next = if !state.permissions.has_snapshot {
        AppSessionState::Initializing
    } else if !state.settings.has_completed_setup {
        AppSessionState::Onboarding {
            step: initial_onboarding_step(&state.permissions),
        }
    } else if state.permissions.all_granted() {
        AppSessionState::Ready
    } else {
        AppSessionState::PermissionRecovery {
            microphone_missing: state.permissions.microphone != PermissionStatus::Granted,
            accessibility_missing: state.permissions.accessibility != PermissionStatus::Granted,
        }
    };

    if state.session == next {
        false
    } else {
        state.session = next;
        true
    }
}

fn apply_permissions(state: &mut RuntimeSnapshot, permissions: PermissionsSnapshot) -> bool {
    let mut changed = state.permissions != permissions;
    state.permissions = permissions;

    match state.session.clone() {
        AppSessionState::Initializing => {
            changed |= evaluate_session(state);
        }
        AppSessionState::Onboarding { step } => {
            let should_advance = matches!(
                step,
                OnboardingStep::Microphone
                    if state.permissions.microphone == PermissionStatus::Granted
            ) || matches!(
                step,
                OnboardingStep::Accessibility
                    if state.permissions.accessibility == PermissionStatus::Granted
            );
            if should_advance {
                let next = AppSessionState::Onboarding {
                    step: initial_onboarding_step(&state.permissions),
                };
                if state.session != next {
                    state.session = next;
                    changed = true;
                }
            }
        }
        AppSessionState::PermissionRecovery { .. } => {
            let next = if state.permissions.all_granted() {
                state.permission_lost_count = 0;
                AppSessionState::Ready
            } else {
                AppSessionState::PermissionRecovery {
                    microphone_missing: state.permissions.microphone != PermissionStatus::Granted,
                    accessibility_missing: state.permissions.accessibility
                        != PermissionStatus::Granted,
                }
            };
            if state.session != next {
                state.session = next;
                changed = true;
            }
        }
        AppSessionState::Ready => {
            if state.permissions.all_granted() {
                if state.permission_lost_count != 0 {
                    state.permission_lost_count = 0;
                    changed = true;
                }
            } else {
                state.permission_lost_count = state.permission_lost_count.saturating_add(1);
                changed = true;
                if state.permission_lost_count >= 3 {
                    state.permission_lost_count = 0;
                    state.session = AppSessionState::PermissionRecovery {
                        microphone_missing: state.permissions.microphone
                            != PermissionStatus::Granted,
                        accessibility_missing: state.permissions.accessibility
                            != PermissionStatus::Granted,
                    };
                }
            }
        }
        AppSessionState::ShuttingDown => {}
    }
    changed
}

fn initial_onboarding_step(permissions: &PermissionsSnapshot) -> OnboardingStep {
    if permissions.microphone != PermissionStatus::Granted {
        OnboardingStep::Microphone
    } else if permissions.accessibility != PermissionStatus::Granted {
        OnboardingStep::Accessibility
    } else {
        OnboardingStep::Hotkey
    }
}

fn advance_onboarding(state: &mut RuntimeSnapshot) -> bool {
    let AppSessionState::Onboarding { step } = state.session else {
        return false;
    };

    let next = match step {
        OnboardingStep::Microphone => initial_onboarding_step(&state.permissions),
        OnboardingStep::Accessibility => OnboardingStep::Hotkey,
        OnboardingStep::Hotkey => OnboardingStep::Model,
        OnboardingStep::Model => OnboardingStep::Vocabulary,
        OnboardingStep::Vocabulary => OnboardingStep::Complete,
        OnboardingStep::Complete => return false,
    };
    if next == step {
        return false;
    }
    state.session = AppSessionState::Onboarding { step: next };
    true
}

fn retreat_onboarding(state: &mut RuntimeSnapshot) -> bool {
    let AppSessionState::Onboarding { step } = state.session else {
        return false;
    };

    let previous = match step {
        OnboardingStep::Microphone => return false,
        OnboardingStep::Accessibility => {
            if state.permissions.microphone == PermissionStatus::Granted {
                return false;
            }
            OnboardingStep::Microphone
        }
        OnboardingStep::Hotkey => match (
            state.permissions.microphone == PermissionStatus::Granted,
            state.permissions.accessibility == PermissionStatus::Granted,
        ) {
            (false, _) => OnboardingStep::Microphone,
            (true, false) => OnboardingStep::Accessibility,
            (true, true) => return false,
        },
        OnboardingStep::Model => OnboardingStep::Hotkey,
        OnboardingStep::Vocabulary => OnboardingStep::Model,
        OnboardingStep::Complete => OnboardingStep::Vocabulary,
    };
    state.session = AppSessionState::Onboarding { step: previous };
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn operational_commands_map_to_closed_markers_without_payloads() {
        use crate::diagnostics::{DiagnosticCategory as Category, DiagnosticCode as Code};

        let cases = [
            (
                RuntimeCommand::ReportPermissions(PermissionsSnapshot::default()),
                (Category::Permissions, Code::PermissionStateObserved),
            ),
            (
                RuntimeCommand::ReportLaunchAtLogin(LaunchAtLoginSnapshot {
                    error_message: Some("private localized failure".to_string()),
                    ..LaunchAtLoginSnapshot::default()
                }),
                (Category::Lifecycle, Code::LaunchAtLoginObserved),
            ),
            (
                RuntimeCommand::HotkeyPressed,
                (Category::Hotkey, Code::HotkeyPressed),
            ),
            (
                RuntimeCommand::HotkeyReleased {
                    duration: Duration::from_millis(275),
                },
                (Category::Hotkey, Code::HotkeyReleased),
            ),
            (
                RuntimeCommand::ActivateSelectedModel,
                (Category::Models, Code::ModelActivationRequested),
            ),
            (
                RuntimeCommand::CancelModelOperation,
                (Category::Models, Code::ModelCancellationRequested),
            ),
            (
                RuntimeCommand::DeleteHistoryEntry {
                    id: "private-history-id".to_string(),
                },
                (Category::History, Code::HistoryDeleteRequested),
            ),
            (
                RuntimeCommand::ClearHistory,
                (Category::History, Code::HistoryClearRequested),
            ),
            (
                RuntimeCommand::ReportUpdateStatus(UpdateStatus::Error {
                    code: crate::update::UpdateFailureCode::Offline,
                    retryable: true,
                    retry_after_seconds: None,
                }),
                (Category::Updates, Code::UpdateStatusObserved),
            ),
            (
                RuntimeCommand::ReportSupportBundleStatus(crate::SupportBundleStatus::Error {
                    code: crate::support::SupportBundleFailureCode::StorageUnavailable,
                }),
                (Category::Lifecycle, Code::SupportBundleStatusObserved),
            ),
            (
                RuntimeCommand::ReportShellCapabilities(ShellCapabilities::default()),
                (Category::Bridge, Code::ShellCapabilitiesObserved),
            ),
        ];
        for (command, expected) in cases {
            assert_eq!(diagnostic_marker_for_command(&command), Some(expected));
        }
        assert_eq!(
            diagnostic_marker_for_command(&RuntimeCommand::UpdateSettings(
                SettingsPatch::CustomVocabulary("private vocabulary".to_string())
            )),
            None
        );
    }

    #[tokio::test]
    async fn failed_settings_write_does_not_publish_unpersisted_state() {
        let dir = tempfile::tempdir().unwrap();
        let occupied = dir.path().join("occupied");
        std::fs::write(&occupied, b"not-a-directory").unwrap();
        let settings_store = Arc::new(ConfigStore::new(occupied.join("config.json")));
        let runtime = start_runtime_inner(
            RuntimeBootstrap::default(),
            ProductionOptions {
                settings_store: Some(settings_store),
                history_path: None,
                platform_services: false,
            },
        )
        .unwrap();
        let mut events = runtime.handle.subscribe_events();

        let result = runtime
            .handle
            .request(RuntimeCommand::UpdateSettings(SettingsPatch::SoundEnabled(
                false,
            )))
            .await;
        assert!(matches!(
            result,
            Err(RuntimeError::ServiceFailed {
                service: "settings",
                ..
            })
        ));
        assert!(runtime.handle.snapshot().settings.sound_enabled);
        assert_eq!(runtime.handle.snapshot().revision, 0);
        assert!(matches!(
            events.recv().await.unwrap().event,
            RuntimeEvent::PipelineError { .. }
        ));

        runtime.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn successful_settings_write_is_durable_before_acknowledgement() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.json");
        let settings_store = Arc::new(ConfigStore::new(path.clone()));
        let runtime = start_runtime_inner(
            RuntimeBootstrap::default(),
            ProductionOptions {
                settings_store: Some(settings_store),
                history_path: None,
                platform_services: false,
            },
        )
        .unwrap();

        let outcome = runtime
            .handle
            .request(RuntimeCommand::UpdateSettings(SettingsPatch::SoundEnabled(
                false,
            )))
            .await
            .unwrap();
        assert!(matches!(outcome, CommandOutcome::Applied { .. }));
        assert!(!ConfigStore::new(path.clone()).load().unwrap().sound_enabled);
        assert!(!runtime.handle.snapshot().settings.sound_enabled);

        let outcome = runtime
            .handle
            .request(RuntimeCommand::UpdateSettings(
                SettingsPatch::ThemePreference(wrenflow_domain::config::ThemePreference::Light),
            ))
            .await
            .unwrap();
        assert!(matches!(outcome, CommandOutcome::Applied { .. }));
        assert_eq!(
            ConfigStore::new(path.clone())
                .load()
                .unwrap()
                .theme_preference,
            wrenflow_domain::config::ThemePreference::Light
        );
        assert_eq!(
            runtime.handle.snapshot().settings.theme_preference,
            wrenflow_domain::config::ThemePreference::Light
        );

        runtime.shutdown().await.unwrap();
    }
}
