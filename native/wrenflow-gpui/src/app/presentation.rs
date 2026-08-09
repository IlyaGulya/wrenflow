use wrenflow_runtime::{
    recovery::RecoveryMode,
    support::SupportBundleFailureCode,
    update::{UpdateChannel, UpdateFailureCode},
    AppSessionState, HistoryEntry, LocalModelsSnapshot, ModelOperationState, OnboardingStep,
    PermissionStatus, PipelineState, RuntimeSnapshot, ThemePreference, UpdateStatus,
};

const SYSTEM_DEFAULT_MICROPHONE_ID: &str = "default";

use super::navigation::NavigationTarget;
use super::reducer::{AppReducer, CommandKey, CommandStatus, Notice};

#[derive(Clone, Debug, PartialEq)]
pub enum ContentState<T> {
    Loading,
    Empty { title: String, detail: String },
    Ready(T),
    Error { title: String, detail: String },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PermissionPresentation {
    Unknown,
    Requesting,
    Granted,
    Denied,
    Restricted,
    NotApplicable,
}

impl From<PermissionStatus> for PermissionPresentation {
    fn from(value: PermissionStatus) -> Self {
        match value {
            PermissionStatus::Unknown => Self::Unknown,
            PermissionStatus::Requesting => Self::Requesting,
            PermissionStatus::Granted => Self::Granted,
            PermissionStatus::Denied => Self::Denied,
            PermissionStatus::Restricted => Self::Restricted,
            PermissionStatus::NotApplicable => Self::NotApplicable,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PermissionsPresentation {
    pub microphone: PermissionPresentation,
    pub accessibility: PermissionPresentation,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OnboardingPresentation {
    pub step: OnboardingStep,
    pub step_number: usize,
    pub step_count: usize,
    pub permissions: PermissionsPresentation,
    pub can_go_back: bool,
    pub can_continue: bool,
    pub command: CommandStatus,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PermissionRecoveryPresentation {
    pub microphone_missing: bool,
    pub accessibility_missing: bool,
    pub permissions: PermissionsPresentation,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MicrophoneOptionPresentation {
    pub id: String,
    pub name: String,
    pub selected: bool,
    pub effective: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SettingsPresentation {
    pub selected_hotkey: String,
    pub hotkey_hint: Option<String>,
    pub sound_enabled: bool,
    pub theme_preference: ThemePreference,
    pub custom_vocabulary: String,
    pub minimum_recording_duration_ms: f64,
    pub microphones: ContentState<Vec<MicrophoneOptionPresentation>>,
    pub show_microphone_selection: bool,
    pub show_launch_at_login: bool,
    pub launch_at_login: LaunchAtLoginPresentation,
    pub command: CommandStatus,
    pub audio_devices_command: CommandStatus,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LaunchAtLoginPresentation {
    pub available: bool,
    pub enabled: bool,
    pub loading: bool,
    pub unavailable_reason: Option<String>,
    pub error_message: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum ModelStatusPresentation {
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

#[derive(Clone, Debug, PartialEq)]
pub struct ModelPresentation {
    pub id: String,
    pub display_name: String,
    pub subtitle: String,
    pub download_label: String,
    pub family: String,
    pub runtime_label: String,
    pub recommended: bool,
    pub available: bool,
    pub runtime_supported: bool,
    pub installed: bool,
    pub selected: bool,
    pub active: bool,
    pub status: ModelStatusPresentation,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ModelsPresentation {
    pub models: ContentState<Vec<ModelPresentation>>,
    pub activation: CommandStatus,
}

#[derive(Clone, Debug, PartialEq)]
pub struct HistoryItemPresentation {
    pub id: String,
    pub timestamp: f64,
    pub transcript: String,
    pub custom_vocabulary: String,
    pub audio_file_name: Option<String>,
    pub metrics_json: String,
}

impl From<&HistoryEntry> for HistoryItemPresentation {
    fn from(entry: &HistoryEntry) -> Self {
        Self {
            id: entry.id.clone(),
            timestamp: entry.timestamp,
            transcript: entry.transcript.clone(),
            custom_vocabulary: entry.custom_vocabulary.clone(),
            audio_file_name: entry.audio_file_name.clone(),
            metrics_json: entry.metrics_json.clone(),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct HistoryPresentation {
    pub entries: ContentState<Vec<HistoryItemPresentation>>,
    pub selected_entry: Option<HistoryItemPresentation>,
    pub mutation: CommandStatus,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TranscriptionTestPhase {
    LoadingCatalog,
    ModelDownloading,
    ModelLoading,
    ModelWarming,
    ModelError,
    ModelManual,
    ModelPending,
    RuntimeUnavailable,
    Transcript,
    Recording,
    Starting,
    Transcribing,
    PipelineError,
    Idle,
}

#[derive(Clone, Debug, PartialEq)]
pub struct TranscriptionTestPresentation {
    pub phase: TranscriptionTestPhase,
    pub message: Option<String>,
    pub progress: Option<f64>,
    pub audio_level: Option<f32>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum UpdatePresentation {
    Unsupported,
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

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SupportBundlePresentation {
    Idle,
    Exporting,
    Exported {
        suggested_filename: String,
        size_bytes: u64,
    },
    Error {
        code: SupportBundleFailureCode,
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RecoveryPresentation {
    pub mode: RecoveryMode,
    pub consecutive_unclean_launches: u8,
    pub cleaned_temporary_files: u16,
    pub reset_current_data_available: bool,
    pub reinstall_current_line_recommended: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AboutPresentation {
    pub version: String,
    pub show_updates: bool,
    pub update: UpdatePresentation,
    pub support_bundle: SupportBundlePresentation,
    pub recovery: RecoveryPresentation,
    pub diagnostics: Vec<DiagnosticPresentation>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DiagnosticPresentation {
    pub label: String,
    pub value: String,
    pub healthy: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct AppPresentation {
    pub revision: u64,
    pub active_route: NavigationTarget,
    pub pipeline: PipelineState,
    pub onboarding: ContentState<OnboardingPresentation>,
    pub permission_recovery: ContentState<PermissionRecoveryPresentation>,
    pub settings: SettingsPresentation,
    pub models: ModelsPresentation,
    pub history: HistoryPresentation,
    pub transcription_test: TranscriptionTestPresentation,
    pub about: AboutPresentation,
    pub notice: Option<Notice>,
    pub last_transcript: Option<String>,
    pub shutting_down: bool,
}

impl AppPresentation {
    #[must_use]
    pub fn from_reducer(reducer: &AppReducer) -> Self {
        let snapshot = reducer.snapshot();
        Self {
            revision: snapshot.revision,
            active_route: reducer.navigation().resolve(&snapshot.session),
            pipeline: snapshot.pipeline.clone(),
            onboarding: onboarding(snapshot, reducer.command_status(CommandKey::Onboarding)),
            permission_recovery: permission_recovery(snapshot),
            settings: settings(
                snapshot,
                reducer.command_status(CommandKey::Settings),
                reducer.command_status(CommandKey::AudioDevices),
            ),
            models: models(snapshot, reducer.command_status(CommandKey::Models)),
            history: history(
                snapshot,
                reducer.selected_history_entry_id(),
                reducer.command_status(CommandKey::History),
            ),
            transcription_test: transcription_test(
                snapshot,
                reducer.last_transcript(),
                reducer.audio_level(),
            ),
            about: about(snapshot),
            notice: reducer.notice().cloned(),
            last_transcript: reducer.last_transcript().map(ToOwned::to_owned),
            shutting_down: reducer.shutting_down(),
        }
    }

    /// Refresh the only projection affected by high-frequency audio samples.
    ///
    /// Snapshot, navigation and settings projections are intentionally left
    /// untouched so a waveform frame does not rebuild the whole presentation.
    pub(crate) fn refresh_audio_level(&mut self, reducer: &AppReducer) -> bool {
        let next = transcription_test(
            reducer.snapshot(),
            reducer.last_transcript(),
            reducer.audio_level(),
        );
        if self.transcription_test == next {
            false
        } else {
            self.transcription_test = next;
            true
        }
    }
}

fn permissions(snapshot: &RuntimeSnapshot) -> PermissionsPresentation {
    PermissionsPresentation {
        microphone: snapshot.permissions.microphone.into(),
        accessibility: snapshot.permissions.accessibility.into(),
    }
}

fn onboarding(
    snapshot: &RuntimeSnapshot,
    command: CommandStatus,
) -> ContentState<OnboardingPresentation> {
    if !snapshot.permissions.has_snapshot {
        return ContentState::Loading;
    }
    let AppSessionState::Onboarding { step } = &snapshot.session else {
        return ContentState::Empty {
            title: "Setup complete".to_string(),
            detail: "Wrenflow is ready for dictation.".to_string(),
        };
    };
    let step_number = match step {
        OnboardingStep::Microphone => 1,
        OnboardingStep::Accessibility => 2,
        OnboardingStep::Hotkey => 3,
        OnboardingStep::Model => 4,
        OnboardingStep::Vocabulary => 5,
        OnboardingStep::Complete => 6,
    };
    let can_continue = match step {
        OnboardingStep::Microphone => snapshot.permissions.microphone == PermissionStatus::Granted,
        OnboardingStep::Accessibility => {
            snapshot.permissions.accessibility == PermissionStatus::Granted
        }
        _ => true,
    };
    ContentState::Ready(OnboardingPresentation {
        step: *step,
        step_number,
        step_count: 6,
        permissions: permissions(snapshot),
        can_go_back: step_number > 1,
        can_continue,
        command,
    })
}

fn permission_recovery(snapshot: &RuntimeSnapshot) -> ContentState<PermissionRecoveryPresentation> {
    if !snapshot.permissions.has_snapshot {
        return ContentState::Loading;
    }
    match &snapshot.session {
        AppSessionState::PermissionRecovery {
            microphone_missing,
            accessibility_missing,
        } => ContentState::Ready(PermissionRecoveryPresentation {
            microphone_missing: *microphone_missing,
            accessibility_missing: *accessibility_missing,
            permissions: permissions(snapshot),
        }),
        _ => ContentState::Empty {
            title: "Permissions are ready".to_string(),
            detail: "No permission recovery is required.".to_string(),
        },
    }
}

fn settings(
    snapshot: &RuntimeSnapshot,
    command: CommandStatus,
    audio_devices_command: CommandStatus,
) -> SettingsPresentation {
    let microphones = if !snapshot.audio_devices.has_snapshot {
        ContentState::Loading
    } else {
        let default_name = if snapshot.audio_devices.default_device_name.is_empty() {
            "System Default".to_string()
        } else {
            format!(
                "System Default ({})",
                snapshot.audio_devices.default_device_name
            )
        };
        let mut options = vec![MicrophoneOptionPresentation {
            id: SYSTEM_DEFAULT_MICROPHONE_ID.to_string(),
            name: default_name,
            selected: snapshot.audio_devices.effective_selected_device_id
                == SYSTEM_DEFAULT_MICROPHONE_ID,
            effective: snapshot.audio_devices.effective_selected_device_id
                == SYSTEM_DEFAULT_MICROPHONE_ID,
        }];
        options.extend(
            snapshot
                .audio_devices
                .devices
                .iter()
                .filter(|device| device.id != SYSTEM_DEFAULT_MICROPHONE_ID)
                .map(|device| MicrophoneOptionPresentation {
                    id: device.id.clone(),
                    name: device.name.clone(),
                    selected: device.id == snapshot.audio_devices.effective_selected_device_id,
                    effective: device.id == snapshot.audio_devices.effective_selected_device_id,
                }),
        );
        ContentState::Ready(options)
    };
    SettingsPresentation {
        selected_hotkey: snapshot.settings.selected_hotkey.clone(),
        hotkey_hint: if snapshot.runtime_capabilities.global_hotkey || cfg!(target_os = "macos") {
            None
        } else {
            Some("Global hotkeys are unavailable in the current runtime.".to_string())
        },
        sound_enabled: snapshot.settings.sound_enabled,
        theme_preference: snapshot.settings.theme_preference,
        custom_vocabulary: snapshot.settings.custom_vocabulary.clone(),
        minimum_recording_duration_ms: snapshot.settings.minimum_recording_duration_ms,
        microphones,
        show_microphone_selection: snapshot.shell.capabilities.microphone_selection
            && snapshot.runtime_capabilities.audio_capture,
        show_launch_at_login: snapshot.shell.capabilities.launch_at_login,
        launch_at_login: LaunchAtLoginPresentation {
            available: snapshot.shell.launch_at_login.is_available,
            enabled: snapshot.shell.launch_at_login.enabled,
            loading: snapshot.shell.launch_at_login.is_loading,
            unavailable_reason: snapshot.shell.launch_at_login.unavailable_reason.clone(),
            error_message: snapshot.shell.launch_at_login.error_message.clone(),
        },
        command,
        audio_devices_command,
    }
}

fn models(snapshot: &RuntimeSnapshot, activation: CommandStatus) -> ModelsPresentation {
    ModelsPresentation {
        models: models_content(&snapshot.models),
        activation,
    }
}

fn models_content(snapshot: &LocalModelsSnapshot) -> ContentState<Vec<ModelPresentation>> {
    if snapshot.models.is_empty() {
        return ContentState::Empty {
            title: "No local models".to_string(),
            detail: "This build does not contain a local transcription catalog.".to_string(),
        };
    }
    ContentState::Ready(
        snapshot
            .models
            .iter()
            .map(|model| {
                let state = snapshot
                    .model_states
                    .iter()
                    .find(|state| state.model_id == model.id)
                    .map(|state| model_status(&state.state))
                    .unwrap_or(ModelStatusPresentation::NotDownloaded);
                ModelPresentation {
                    id: model.id.clone(),
                    display_name: model.display_name.clone(),
                    subtitle: model.subtitle.clone(),
                    download_label: model.download_label.clone(),
                    family: model.family.clone(),
                    runtime_label: model.runtime_label.clone(),
                    recommended: model.is_recommended,
                    available: model.is_available,
                    runtime_supported: model.supports_current_runtime,
                    installed: snapshot
                        .installed_model_ids
                        .iter()
                        .any(|installed| installed == &model.id),
                    selected: snapshot.selected_model_id == model.id,
                    active: snapshot.active_model_id.as_deref() == Some(model.id.as_str()),
                    status: state,
                }
            })
            .collect(),
    )
}

fn model_status(state: &ModelOperationState) -> ModelStatusPresentation {
    match state {
        ModelOperationState::NotDownloaded => ModelStatusPresentation::NotDownloaded,
        ModelOperationState::Downloading {
            progress,
            speed_bps,
            eta_secs,
        } => ModelStatusPresentation::Downloading {
            progress: *progress,
            speed_bps: *speed_bps,
            eta_secs: *eta_secs,
        },
        ModelOperationState::Loading => ModelStatusPresentation::Loading,
        ModelOperationState::Warming => ModelStatusPresentation::Warming,
        ModelOperationState::Ready => ModelStatusPresentation::Ready,
        ModelOperationState::Error { message } => ModelStatusPresentation::Error {
            message: message.clone(),
        },
    }
}

fn history(
    snapshot: &RuntimeSnapshot,
    selected_entry_id: Option<&str>,
    mutation: CommandStatus,
) -> HistoryPresentation {
    let entries = if !snapshot.history.has_snapshot {
        ContentState::Loading
    } else if snapshot.history.entries.is_empty() {
        ContentState::Empty {
            title: "No transcriptions yet".to_string(),
            detail: "Your completed dictations will appear here.".to_string(),
        }
    } else {
        ContentState::Ready(
            snapshot
                .history
                .entries
                .iter()
                .map(HistoryItemPresentation::from)
                .collect(),
        )
    };
    let selected_entry = selected_entry_id.and_then(|id| {
        snapshot
            .history
            .entries
            .iter()
            .find(|entry| entry.id == id)
            .map(HistoryItemPresentation::from)
    });
    HistoryPresentation {
        entries,
        selected_entry,
        mutation,
    }
}

fn transcription_test(
    snapshot: &RuntimeSnapshot,
    last_transcript: Option<&str>,
    audio_level: f32,
) -> TranscriptionTestPresentation {
    let unavailable = |message: String| TranscriptionTestPresentation {
        phase: TranscriptionTestPhase::RuntimeUnavailable,
        message: Some(message),
        progress: None,
        audio_level: None,
    };
    let Some(selected) = snapshot
        .models
        .models
        .iter()
        .find(|model| model.id == snapshot.models.selected_model_id)
    else {
        return TranscriptionTestPresentation {
            phase: TranscriptionTestPhase::LoadingCatalog,
            message: Some("Loading available models...".to_string()),
            progress: None,
            audio_level: None,
        };
    };

    if !snapshot.runtime_capabilities.audio_capture {
        return unavailable("Audio capture is unavailable in the current runtime.".to_string());
    }
    if !snapshot.runtime_capabilities.local_transcription {
        return unavailable(
            "Local transcription is unavailable in the current runtime.".to_string(),
        );
    }
    if !snapshot.runtime_capabilities.model_activation {
        return unavailable("Model activation is unavailable in the current runtime.".to_string());
    }
    if !selected.supports_current_runtime {
        return unavailable(format!(
            "{} is not supported by the current runtime.",
            selected.display_name
        ));
    }

    let busy = snapshot.models.model_states.iter().find(|operation| {
        matches!(
            &operation.state,
            ModelOperationState::Downloading { .. }
                | ModelOperationState::Loading
                | ModelOperationState::Warming
        )
    });
    if let Some(operation) = busy {
        let model_name = snapshot
            .models
            .models
            .iter()
            .find(|model| model.id == operation.model_id)
            .map(|model| model.display_name.as_str())
            .unwrap_or(selected.display_name.as_str());
        return match &operation.state {
            ModelOperationState::Downloading { progress, .. } => TranscriptionTestPresentation {
                phase: TranscriptionTestPhase::ModelDownloading,
                message: Some(format!("Downloading {model_name}")),
                progress: Some(*progress),
                audio_level: None,
            },
            ModelOperationState::Loading => TranscriptionTestPresentation {
                phase: TranscriptionTestPhase::ModelLoading,
                message: Some(format!("Loading {model_name}...")),
                progress: None,
                audio_level: None,
            },
            ModelOperationState::Warming => TranscriptionTestPresentation {
                phase: TranscriptionTestPhase::ModelWarming,
                message: Some(format!("Warming up {model_name}...")),
                progress: None,
                audio_level: None,
            },
            _ => unreachable!("busy model operation filter is exhaustive"),
        };
    }

    let selected_state = snapshot
        .models
        .model_states
        .iter()
        .find(|operation| operation.model_id == selected.id)
        .map(|operation| &operation.state);
    if matches!(selected_state, Some(ModelOperationState::Error { .. })) {
        return TranscriptionTestPresentation {
            phase: TranscriptionTestPhase::ModelError,
            message: Some(format!(
                "{} failed. Open its card and retry.",
                selected.display_name
            )),
            progress: None,
            audio_level: None,
        };
    }
    let active = snapshot.models.active_model_id.as_deref() == Some(selected.id.as_str());
    if !active {
        let installed = snapshot
            .models
            .installed_model_ids
            .iter()
            .any(|model_id| model_id == &selected.id);
        let message = if installed {
            format!(
                "{} is selected but not active yet. Use its card to activate it.",
                selected.display_name
            )
        } else {
            format!(
                "{} is selected but not installed yet. Use its card to download and activate it.",
                selected.display_name
            )
        };
        return TranscriptionTestPresentation {
            phase: TranscriptionTestPhase::ModelManual,
            message: Some(message),
            progress: None,
            audio_level: None,
        };
    }
    if !matches!(selected_state, Some(ModelOperationState::Ready)) {
        return TranscriptionTestPresentation {
            phase: TranscriptionTestPhase::ModelPending,
            message: Some(format!(
                "Use the selected model card to finish preparing {}.",
                selected.display_name
            )),
            progress: None,
            audio_level: None,
        };
    }

    match &snapshot.pipeline {
        PipelineState::Starting | PipelineState::Initializing => TranscriptionTestPresentation {
            phase: TranscriptionTestPhase::Starting,
            message: Some("Starting...".to_string()),
            progress: None,
            audio_level: None,
        },
        PipelineState::Recording => TranscriptionTestPresentation {
            phase: TranscriptionTestPhase::Recording,
            message: None,
            progress: None,
            audio_level: Some(audio_level),
        },
        PipelineState::Transcribing { .. } => TranscriptionTestPresentation {
            phase: TranscriptionTestPhase::Transcribing,
            message: Some("Transcribing...".to_string()),
            progress: None,
            audio_level: None,
        },
        PipelineState::Error { message } => TranscriptionTestPresentation {
            phase: TranscriptionTestPhase::PipelineError,
            message: Some(message.clone()),
            progress: None,
            audio_level: None,
        },
        PipelineState::Idle => {
            if let Some(transcript) = last_transcript.filter(|transcript| !transcript.is_empty()) {
                TranscriptionTestPresentation {
                    phase: TranscriptionTestPhase::Transcript,
                    message: Some(transcript.to_string()),
                    progress: None,
                    audio_level: None,
                }
            } else {
                TranscriptionTestPresentation {
                    phase: TranscriptionTestPhase::Idle,
                    message: Some("Press and hold your hotkey now to test.".to_string()),
                    progress: None,
                    audio_level: None,
                }
            }
        }
    }
}

fn about(snapshot: &RuntimeSnapshot) -> AboutPresentation {
    let selected = snapshot
        .models
        .models
        .iter()
        .find(|model| model.id == snapshot.models.selected_model_id);
    let active = snapshot
        .models
        .active_model_id
        .as_ref()
        .and_then(|active_id| {
            snapshot
                .models
                .models
                .iter()
                .find(|model| &model.id == active_id)
        });
    let active_ready = snapshot
        .models
        .active_model_id
        .as_ref()
        .is_some_and(|active_id| {
            snapshot.models.model_states.iter().any(|operation| {
                &operation.model_id == active_id
                    && matches!(&operation.state, ModelOperationState::Ready)
            })
        });
    let model_value = if let Some(active) = active {
        format!("{} active", active.display_name)
    } else if let Some(selected) = selected {
        format!("{} not active", selected.display_name)
    } else {
        "No preferred model".to_string()
    };
    let mut diagnostics = vec![
        DiagnosticPresentation {
            label: "Runtime".to_string(),
            value: if snapshot.runtime_capabilities.local_transcription {
                "Local transcription ready"
            } else {
                "Local transcription unavailable"
            }
            .to_string(),
            healthy: snapshot.runtime_capabilities.local_transcription,
        },
        DiagnosticPresentation {
            label: "Audio".to_string(),
            value: if snapshot.runtime_capabilities.audio_capture {
                "Audio capture ready"
            } else {
                "Audio capture unavailable"
            }
            .to_string(),
            healthy: snapshot.runtime_capabilities.audio_capture,
        },
        DiagnosticPresentation {
            label: "Hotkey".to_string(),
            value: if cfg!(target_os = "macos") {
                "Global hotkey ready"
            } else {
                "Global hotkey unavailable"
            }
            .to_string(),
            healthy: cfg!(target_os = "macos"),
        },
        DiagnosticPresentation {
            label: "Paste".to_string(),
            value: if snapshot.runtime_capabilities.paste_injection {
                "Paste injection ready"
            } else {
                "Paste injection unavailable"
            }
            .to_string(),
            healthy: snapshot.runtime_capabilities.paste_injection,
        },
        DiagnosticPresentation {
            label: "Models".to_string(),
            value: model_value,
            healthy: snapshot.runtime_capabilities.model_activation && active_ready,
        },
        DiagnosticPresentation {
            label: "History".to_string(),
            value: if snapshot.runtime_capabilities.history_persistence {
                "History storage writable"
            } else {
                "History storage unavailable"
            }
            .to_string(),
            healthy: snapshot.runtime_capabilities.history_persistence,
        },
    ];
    if snapshot.shell.capabilities.launch_at_login {
        diagnostics.push(DiagnosticPresentation {
            label: "Login item".to_string(),
            value: snapshot
                .shell
                .launch_at_login
                .unavailable_reason
                .clone()
                .unwrap_or_else(|| {
                    if snapshot.shell.launch_at_login.is_available {
                        "Launch at login available".to_string()
                    } else {
                        "Launch at login unavailable".to_string()
                    }
                }),
            healthy: snapshot.shell.launch_at_login.is_available,
        });
    }
    AboutPresentation {
        version: env!("CARGO_PKG_VERSION").to_string(),
        show_updates: snapshot.shell.capabilities.updates,
        update: update(&snapshot.shell.update_status),
        support_bundle: support_bundle(&snapshot.shell.support_bundle_status),
        recovery: RecoveryPresentation {
            mode: snapshot.recovery.mode,
            consecutive_unclean_launches: snapshot.recovery.consecutive_unclean_launches,
            cleaned_temporary_files: snapshot.recovery.cleanup.total(),
            reset_current_data_available: snapshot.recovery.reset_current_data_available,
            reinstall_current_line_recommended: snapshot
                .recovery
                .reinstall_current_line_recommended,
        },
        diagnostics,
    }
}

fn update(status: &UpdateStatus) -> UpdatePresentation {
    match status {
        UpdateStatus::Unsupported => UpdatePresentation::Unsupported,
        UpdateStatus::Idle => UpdatePresentation::Idle,
        UpdateStatus::Checking { channel } => UpdatePresentation::Checking { channel: *channel },
        UpdateStatus::UpToDate { channel } => UpdatePresentation::UpToDate { channel: *channel },
        UpdateStatus::Available {
            latest_version,
            channel,
            published_at_iso,
            size_bytes,
        } => UpdatePresentation::Available {
            latest_version: latest_version.clone(),
            channel: *channel,
            published_at_iso: published_at_iso.clone(),
            size_bytes: *size_bytes,
        },
        UpdateStatus::Downloading {
            latest_version,
            total_bytes,
        } => UpdatePresentation::Downloading {
            latest_version: latest_version.clone(),
            total_bytes: *total_bytes,
        },
        UpdateStatus::ReadyToInstall { latest_version } => UpdatePresentation::ReadyToInstall {
            latest_version: latest_version.clone(),
        },
        UpdateStatus::Installing { latest_version } => UpdatePresentation::Installing {
            latest_version: latest_version.clone(),
        },
        UpdateStatus::RecoveryRequired { code } => {
            UpdatePresentation::RecoveryRequired { code: *code }
        }
        UpdateStatus::Error {
            code,
            retryable,
            retry_after_seconds,
        } => UpdatePresentation::Error {
            code: *code,
            retryable: *retryable,
            retry_after_seconds: *retry_after_seconds,
        },
    }
}

fn support_bundle(status: &wrenflow_runtime::SupportBundleStatus) -> SupportBundlePresentation {
    match status {
        wrenflow_runtime::SupportBundleStatus::Idle => SupportBundlePresentation::Idle,
        wrenflow_runtime::SupportBundleStatus::Exporting => SupportBundlePresentation::Exporting,
        wrenflow_runtime::SupportBundleStatus::Ready {
            suggested_filename,
            size_bytes,
        } => SupportBundlePresentation::Exported {
            suggested_filename: suggested_filename.clone(),
            size_bytes: *size_bytes,
        },
        wrenflow_runtime::SupportBundleStatus::Error { code } => {
            SupportBundlePresentation::Error { code: *code }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::*;
    use crate::app::AppMutation;
    use wrenflow_runtime::{
        start_runtime, LocalModelRuntimeState, RuntimeBootstrap, RuntimeCapabilities,
    };

    type TestResult = Result<(), Box<dyn std::error::Error>>;

    #[tokio::test]
    async fn projects_loading_then_empty_history_and_default_microphone() -> TestResult {
        let instance = start_runtime(RuntimeBootstrap::default())?;
        let mut reducer = AppReducer::new(instance.handle.snapshot());
        let initial = AppPresentation::from_reducer(&reducer);
        assert!(matches!(initial.history.entries, ContentState::Loading));
        assert!(matches!(
            initial.settings.microphones,
            ContentState::Loading
        ));

        let mut snapshot = (*instance.handle.snapshot()).clone();
        snapshot.revision = 1;
        snapshot.history.has_snapshot = true;
        snapshot.audio_devices.has_snapshot = true;
        reducer.reduce(AppMutation::Snapshot(Arc::new(snapshot)));
        let empty = AppPresentation::from_reducer(&reducer);
        assert!(matches!(empty.history.entries, ContentState::Empty { .. }));
        let ContentState::Ready(microphones) = empty.settings.microphones else {
            panic!("expected the system-default microphone option");
        };
        assert_eq!(microphones.len(), 1);
        assert_eq!(microphones[0].id, SYSTEM_DEFAULT_MICROPHONE_ID);
        instance.shutdown().await?;
        Ok(())
    }

    #[tokio::test]
    async fn transcription_test_preserves_model_progress_and_live_audio() -> TestResult {
        let instance = start_runtime(RuntimeBootstrap::default())?;
        let mut snapshot = (*instance.handle.snapshot()).clone();
        snapshot.runtime_capabilities = RuntimeCapabilities {
            audio_capture: true,
            local_transcription: true,
            model_activation: true,
            ..RuntimeCapabilities::default()
        };
        let selected = snapshot.models.selected_model_id.clone();
        snapshot.models.model_states = vec![LocalModelRuntimeState {
            model_id: selected.clone(),
            state: ModelOperationState::Downloading {
                progress: 0.42,
                speed_bps: 100.0,
                eta_secs: 4.0,
            },
        }];
        let mut reducer = AppReducer::new(Arc::new(snapshot.clone()));
        let downloading = AppPresentation::from_reducer(&reducer);
        assert_eq!(
            downloading.transcription_test.phase,
            TranscriptionTestPhase::ModelDownloading
        );
        assert_eq!(downloading.transcription_test.progress, Some(0.42));

        snapshot.revision = 1;
        snapshot.models.installed_model_ids = vec![selected.clone()];
        snapshot.models.active_model_id = Some(selected.clone());
        snapshot.models.model_states = vec![LocalModelRuntimeState {
            model_id: selected,
            state: ModelOperationState::Ready,
        }];
        snapshot.pipeline = PipelineState::Recording;
        reducer.reduce(AppMutation::Snapshot(Arc::new(snapshot)));
        let mut recording = AppPresentation::from_reducer(&reducer);
        let before_audio = recording.clone();
        reducer.reduce(AppMutation::AudioLevel(0.73));
        assert!(recording.refresh_audio_level(&reducer));
        assert_eq!(
            recording.transcription_test.phase,
            TranscriptionTestPhase::Recording
        );
        assert_eq!(recording.transcription_test.audio_level, Some(0.73));
        assert_eq!(recording.revision, before_audio.revision);
        assert_eq!(recording.settings, before_audio.settings);
        assert_eq!(recording.models, before_audio.models);
        assert_eq!(recording.history, before_audio.history);
        assert!(!recording.refresh_audio_level(&reducer));
        instance.shutdown().await?;
        Ok(())
    }
}
