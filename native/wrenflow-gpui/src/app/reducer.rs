use std::collections::BTreeMap;
use std::sync::Arc;

use wrenflow_runtime::{CommandOutcome, RuntimeEvent, RuntimeEventEnvelope, RuntimeSnapshot};

use super::navigation::{NavigationState, NavigationTarget};

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum CommandKey {
    Settings,
    Models,
    History,
    Onboarding,
    AudioDevices,
    Pipeline,
    Application,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum CommandStatus {
    #[default]
    Idle,
    Pending {
        token: u64,
    },
    Succeeded {
        revision: u64,
    },
    Failed {
        message: String,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NoticeKind {
    Information,
    Success,
    Error,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Notice {
    pub kind: NoticeKind,
    pub title: String,
    pub detail: Option<String>,
    pub action_id: Option<String>,
    pub action_label: Option<String>,
}

pub enum AppMutation {
    Snapshot(Arc<RuntimeSnapshot>),
    AudioLevel(f32),
    Event(RuntimeEventEnvelope),
    Navigate(NavigationTarget),
    SelectHistoryEntry(Option<String>),
    CommandStarted {
        key: CommandKey,
        token: u64,
    },
    CommandFinished {
        key: CommandKey,
        token: u64,
        result: Result<CommandOutcome, String>,
    },
    ActionRejected(String),
    ClearNotice,
}

pub struct AppReducer {
    snapshot: Arc<RuntimeSnapshot>,
    navigation: NavigationState,
    command_statuses: BTreeMap<CommandKey, CommandStatus>,
    last_event_sequence: u64,
    last_transcript: Option<String>,
    selected_history_entry_id: Option<String>,
    audio_level: f32,
    notice: Option<Notice>,
    shutting_down: bool,
}

impl AppReducer {
    #[must_use]
    pub fn new(snapshot: Arc<RuntimeSnapshot>) -> Self {
        let shutting_down = matches!(
            &snapshot.session,
            wrenflow_runtime::AppSessionState::ShuttingDown
        );
        Self {
            snapshot,
            navigation: NavigationState::default(),
            command_statuses: BTreeMap::new(),
            last_event_sequence: 0,
            last_transcript: None,
            selected_history_entry_id: None,
            audio_level: 0.0,
            notice: None,
            shutting_down,
        }
    }

    pub fn reduce(&mut self, mutation: AppMutation) -> bool {
        match mutation {
            AppMutation::Snapshot(snapshot) => {
                if snapshot.revision < self.snapshot.revision {
                    return false;
                }
                self.shutting_down = matches!(
                    &snapshot.session,
                    wrenflow_runtime::AppSessionState::ShuttingDown
                );
                if self
                    .selected_history_entry_id
                    .as_ref()
                    .is_some_and(|id| !snapshot.history.entries.iter().any(|entry| &entry.id == id))
                {
                    self.selected_history_entry_id = None;
                }
                self.snapshot = snapshot;
                true
            }
            AppMutation::Event(envelope) => self.reduce_event(envelope),
            AppMutation::AudioLevel(level) => {
                let level = level.clamp(0.0, 1.0);
                if self.audio_level == level {
                    false
                } else {
                    self.audio_level = level;
                    true
                }
            }
            AppMutation::Navigate(target) => {
                let previous = self.navigation;
                self.navigation.request(target);
                previous != self.navigation
            }
            AppMutation::SelectHistoryEntry(id) => {
                let id = id.filter(|id| {
                    self.snapshot
                        .history
                        .entries
                        .iter()
                        .any(|entry| &entry.id == id)
                });
                if self.selected_history_entry_id == id {
                    false
                } else {
                    self.selected_history_entry_id = id;
                    true
                }
            }
            AppMutation::CommandStarted { key, token } => {
                self.command_statuses
                    .insert(key, CommandStatus::Pending { token });
                true
            }
            AppMutation::CommandFinished { key, token, result } => {
                if !matches!(
                    self.command_statuses.get(&key),
                    Some(CommandStatus::Pending { token: pending }) if *pending == token
                ) {
                    return false;
                }
                let status = match result {
                    Ok(outcome) => CommandStatus::Succeeded {
                        revision: outcome.revision(),
                    },
                    Err(message) => {
                        self.notice = Some(error_notice("Could not apply change", &message));
                        CommandStatus::Failed { message }
                    }
                };
                self.command_statuses.insert(key, status);
                true
            }
            AppMutation::ActionRejected(message) => {
                self.notice = Some(error_notice("Invalid action", &message));
                true
            }
            AppMutation::ClearNotice => self.notice.take().is_some(),
        }
    }

    fn reduce_event(&mut self, envelope: RuntimeEventEnvelope) -> bool {
        if envelope.sequence <= self.last_event_sequence {
            return false;
        }
        self.last_event_sequence = envelope.sequence;
        match envelope.event {
            RuntimeEvent::PlaySound(_) | RuntimeEvent::HistoryEntryAdded(_) => {}
            RuntimeEvent::TranscriptReady { transcript } => {
                self.last_transcript = Some(transcript);
            }
            RuntimeEvent::PipelineError { message, action } => {
                self.notice = Some(Notice {
                    kind: NoticeKind::Error,
                    title: "Dictation failed".to_string(),
                    detail: Some(message),
                    action_id: action.as_ref().map(|action| action.id.clone()),
                    action_label: action.map(|action| action.label),
                });
            }
            RuntimeEvent::PasteCompleted => {
                self.notice = Some(Notice {
                    kind: NoticeKind::Success,
                    title: "Pasted".to_string(),
                    detail: None,
                    action_id: None,
                    action_label: None,
                });
            }
            RuntimeEvent::QuitRequested => {
                self.shutting_down = true;
            }
        }
        true
    }

    #[must_use]
    pub fn snapshot(&self) -> &RuntimeSnapshot {
        &self.snapshot
    }

    #[must_use]
    pub const fn navigation(&self) -> NavigationState {
        self.navigation
    }

    #[must_use]
    pub fn command_status(&self, key: CommandKey) -> CommandStatus {
        self.command_statuses.get(&key).cloned().unwrap_or_default()
    }

    #[must_use]
    pub fn notice(&self) -> Option<&Notice> {
        self.notice.as_ref()
    }

    #[must_use]
    pub fn last_transcript(&self) -> Option<&str> {
        self.last_transcript.as_deref()
    }

    #[must_use]
    pub fn selected_history_entry_id(&self) -> Option<&str> {
        self.selected_history_entry_id.as_deref()
    }

    #[must_use]
    pub const fn audio_level(&self) -> f32 {
        self.audio_level
    }

    #[must_use]
    pub const fn shutting_down(&self) -> bool {
        self.shutting_down
    }
}

fn error_notice(title: &str, message: &str) -> Notice {
    Notice {
        kind: NoticeKind::Error,
        title: title.to_string(),
        detail: Some(message.to_string()),
        action_id: None,
        action_label: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wrenflow_runtime::{start_runtime, RuntimeBootstrap};

    type TestResult = Result<(), Box<dyn std::error::Error>>;

    #[tokio::test]
    async fn stale_snapshots_and_command_completions_are_ignored() -> TestResult {
        let instance = start_runtime(RuntimeBootstrap::default())?;
        let mut current = (*instance.handle.snapshot()).clone();
        current.revision = 5;
        let mut reducer = AppReducer::new(Arc::new(current));

        let mut stale = (*instance.handle.snapshot()).clone();
        stale.revision = 4;
        assert!(!reducer.reduce(AppMutation::Snapshot(Arc::new(stale))));

        reducer.reduce(AppMutation::CommandStarted {
            key: CommandKey::Settings,
            token: 2,
        });
        assert!(!reducer.reduce(AppMutation::CommandFinished {
            key: CommandKey::Settings,
            token: 1,
            result: Ok(CommandOutcome::Applied { revision: 6 }),
        }));
        assert_eq!(
            reducer.command_status(CommandKey::Settings),
            CommandStatus::Pending { token: 2 }
        );
        instance.shutdown().await?;
        Ok(())
    }

    #[tokio::test]
    async fn runtime_events_project_transcript_errors_and_quit() -> TestResult {
        let instance = start_runtime(RuntimeBootstrap::default())?;
        let mut reducer = AppReducer::new(instance.handle.snapshot());
        assert!(reducer.reduce(AppMutation::Event(RuntimeEventEnvelope {
            sequence: 1,
            event: RuntimeEvent::TranscriptReady {
                transcript: "hello".to_string(),
            },
        })));
        assert_eq!(reducer.last_transcript(), Some("hello"));
        assert!(!reducer.reduce(AppMutation::Event(RuntimeEventEnvelope {
            sequence: 1,
            event: RuntimeEvent::QuitRequested,
        })));
        assert!(!reducer.shutting_down());
        assert!(reducer.reduce(AppMutation::Event(RuntimeEventEnvelope {
            sequence: 2,
            event: RuntimeEvent::QuitRequested,
        })));
        assert!(reducer.shutting_down());
        instance.shutdown().await?;
        Ok(())
    }
}
