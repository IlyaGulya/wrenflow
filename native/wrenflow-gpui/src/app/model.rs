use std::time::Duration;

use gpui::{Context, Task};
use tokio::runtime::Handle as AsyncRuntimeHandle;
use tokio::sync::mpsc;
use tokio::time::MissedTickBehavior;
use wrenflow_runtime::{
    diagnostics::{
        emit_diagnostic, DiagnosticCategory, DiagnosticCode, DiagnosticEvent, DiagnosticLevel,
    },
    CommandOutcome, RuntimeHandle,
};

use super::{
    effect, AppAction, AppMutation, AppPresentation, AppReducer, CommandKey, NavigationTarget,
    ShellRequest, ShellRequestReceiver,
};

/// GPUI does not need the shell overlay's 50 Hz sample rate. The AppKit overlay
/// subscribes directly to the runtime, while the settings waveform renders at
/// a frame-capped rate that is comfortably above human-visible meter latency.
const AUDIO_PRESENTATION_INTERVAL: Duration = Duration::from_millis(33);

#[derive(Default)]
struct PendingAudioLevel(Option<f32>);

impl PendingAudioLevel {
    fn observe(&mut self, level: f32) {
        self.0 = Some(level);
    }

    fn take_latest(&mut self) -> Option<f32> {
        self.0.take()
    }
}

struct CommandCompletion {
    key: CommandKey,
    token: u64,
    result: Result<CommandOutcome, String>,
}

struct CommandRequest {
    key: CommandKey,
    token: u64,
    command: wrenflow_runtime::RuntimeCommand,
}

#[derive(Clone)]
struct CommandDispatcher {
    requests: mpsc::UnboundedSender<CommandRequest>,
}

impl CommandDispatcher {
    fn dispatch(
        &self,
        key: CommandKey,
        token: u64,
        command: wrenflow_runtime::RuntimeCommand,
    ) -> Result<(), String> {
        self.requests
            .send(CommandRequest {
                key,
                token,
                command,
            })
            .map_err(|_| "the runtime command queue is unavailable".to_string())
    }
}

/// GPUI-owned application entity.
///
/// Tokio tasks only perform runtime IO. Snapshot, event and command-completion
/// receivers hand immutable messages back through GPUI's `AsyncApp`, and all
/// UI-visible mutation happens inside this entity.
pub struct AppModel {
    reducer: AppReducer,
    presentation: AppPresentation,
    dispatcher: CommandDispatcher,
    next_command_token: u64,
    shell_requests: effect::ShellRequestSender,
    shell_request_receiver: Option<ShellRequestReceiver>,
    performance_runtime: RuntimeHandle,
    async_runtime: AsyncRuntimeHandle,
    _subscriptions: Vec<Task<()>>,
}

impl AppModel {
    #[must_use]
    pub fn new(
        runtime: RuntimeHandle,
        async_runtime: AsyncRuntimeHandle,
        cx: &mut Context<Self>,
    ) -> Self {
        let reducer = AppReducer::new(runtime.snapshot());
        let presentation = AppPresentation::from_reducer(&reducer);
        let (completion_tx, completion_rx) = mpsc::unbounded_channel();
        let (request_tx, request_rx) = mpsc::unbounded_channel();
        let (shell_requests, shell_request_receiver) = effect::channel();
        let dispatcher = CommandDispatcher {
            requests: request_tx,
        };
        spawn_command_worker(
            async_runtime.clone(),
            runtime.clone(),
            request_rx,
            completion_tx,
        );
        let audio_levels = spawn_audio_level_sampler(async_runtime.clone(), runtime.clone());
        let subscriptions = vec![
            subscribe_snapshots(runtime.clone(), cx),
            subscribe_audio_level(audio_levels, cx),
            subscribe_events(runtime.clone(), cx),
            subscribe_completions(completion_rx, cx),
        ];

        Self {
            reducer,
            presentation,
            dispatcher,
            next_command_token: 1,
            shell_requests,
            shell_request_receiver: Some(shell_request_receiver),
            performance_runtime: runtime,
            async_runtime,
            _subscriptions: subscriptions,
        }
    }

    #[must_use]
    pub const fn presentation(&self) -> &AppPresentation {
        &self.presentation
    }

    pub fn dispatch(&mut self, action: AppAction, cx: &mut Context<Self>) {
        match action {
            AppAction::Navigate(target) => {
                self.apply(AppMutation::Navigate(target), cx);
            }
            AppAction::ClearNotice => {
                self.apply(AppMutation::ClearNotice, cx);
            }
            AppAction::OpenHistoryEntry(id) => {
                self.apply(AppMutation::SelectHistoryEntry(Some(id)), cx);
            }
            AppAction::CloseHistoryEntry => {
                self.apply(AppMutation::SelectHistoryEntry(None), cx);
            }
            AppAction::RequestMicrophonePermission => {
                self.request_shell(ShellRequest::RequestMicrophonePermission, cx);
            }
            AppAction::RequestAccessibilityPermission => {
                self.request_shell(ShellRequest::RequestAccessibilityPermission, cx);
            }
            AppAction::OpenMicrophoneSettings => {
                self.request_shell(ShellRequest::OpenMicrophoneSettings, cx);
            }
            AppAction::OpenAccessibilitySettings => {
                self.request_shell(ShellRequest::OpenAccessibilitySettings, cx);
            }
            AppAction::SetLaunchAtLogin(enabled) => {
                self.request_shell(ShellRequest::SetLaunchAtLogin(enabled), cx);
            }
            AppAction::CheckForUpdates => {
                self.request_shell(
                    ShellRequest::CheckForUpdates(wrenflow_runtime::update::UpdateChannel::Stable),
                    cx,
                );
            }
            AppAction::CheckForBetaUpdates => {
                self.request_shell(
                    ShellRequest::CheckForUpdates(wrenflow_runtime::update::UpdateChannel::Beta),
                    cx,
                );
            }
            AppAction::DownloadAvailableUpdate => {
                self.request_shell(ShellRequest::DownloadAvailableUpdate, cx);
            }
            AppAction::InstallReadyUpdate => {
                self.request_shell(ShellRequest::InstallReadyUpdate, cx);
            }
            AppAction::ExportSupportBundle => {
                self.request_shell(ShellRequest::ExportSupportBundle, cx);
            }
            AppAction::ResetCurrentData => {
                self.request_shell(ShellRequest::ResetCurrentData, cx);
            }
            action => match action.runtime_command() {
                Ok(Some((key, command))) => {
                    let token = self.next_token();
                    self.apply(AppMutation::CommandStarted { key, token }, cx);
                    if let Err(message) = self.dispatcher.dispatch(key, token, command) {
                        self.apply(
                            AppMutation::CommandFinished {
                                key,
                                token,
                                result: Err(message),
                            },
                            cx,
                        );
                    }
                }
                Ok(None) => {}
                Err(error) => {
                    self.apply(AppMutation::ActionRejected(error.to_string()), cx);
                }
            },
        }
    }

    pub fn navigate(&mut self, target: NavigationTarget, cx: &mut Context<Self>) {
        self.dispatch(AppAction::Navigate(target), cx);
    }

    /// The shell takes this receiver exactly once and performs requests on its
    /// AppKit owner. Screens never receive a shell handle.
    pub fn take_shell_requests(&mut self) -> Option<ShellRequestReceiver> {
        self.shell_request_receiver.take()
    }

    /// Start the opaque signed-app performance workload. No `AppAction` or
    /// screen receives this request type, and every terminal result enters the
    /// ordinary typed quit path so runtime cleanup remains production-identical.
    pub fn start_performance_self_test(
        &self,
        request: wrenflow_runtime::performance::PerformanceSelfTestRequest,
    ) {
        let runtime = self.performance_runtime.clone();
        self.async_runtime.spawn(async move {
            let _ = runtime.run_performance_self_test(request).await;
            let _ = runtime
                .request(wrenflow_runtime::RuntimeCommand::RequestQuit)
                .await;
        });
    }

    fn request_shell(&mut self, request: ShellRequest, cx: &mut Context<Self>) {
        if self.shell_requests.send(request).is_err() {
            self.apply(
                AppMutation::ActionRejected("the macOS shell is unavailable".to_string()),
                cx,
            );
        }
    }

    fn next_token(&mut self) -> u64 {
        let token = self.next_command_token;
        self.next_command_token = self.next_command_token.saturating_add(1);
        token
    }

    fn apply(&mut self, mutation: AppMutation, cx: &mut Context<Self>) {
        let audio_level_only = matches!(mutation, AppMutation::AudioLevel(_));
        if self.reducer.reduce(mutation) {
            let presentation_changed = if audio_level_only {
                self.presentation.refresh_audio_level(&self.reducer)
            } else {
                self.presentation = AppPresentation::from_reducer(&self.reducer);
                true
            };
            if presentation_changed {
                cx.notify();
            }
        }
    }
}

fn spawn_audio_level_sampler(
    async_runtime: AsyncRuntimeHandle,
    runtime: RuntimeHandle,
) -> mpsc::UnboundedReceiver<f32> {
    let mut source = runtime.subscribe_audio_level();
    let (frames, receiver) = mpsc::unbounded_channel();
    drop(async_runtime.spawn(async move {
        let mut interval = tokio::time::interval(AUDIO_PRESENTATION_INTERVAL);
        interval.set_missed_tick_behavior(MissedTickBehavior::Skip);
        // Tokio intervals tick immediately once. Consume that tick so every
        // emitted frame is separated by the configured presentation interval.
        interval.tick().await;
        let mut pending = PendingAudioLevel::default();

        loop {
            tokio::select! {
                changed = source.changed() => {
                    if changed.is_err() {
                        break;
                    }
                    pending.observe(*source.borrow_and_update());
                }
                _ = interval.tick() => {
                    if let Some(level) = pending.take_latest() {
                        if frames.send(level).is_err() {
                            break;
                        }
                    }
                }
            }
        }
    }));
    receiver
}

fn spawn_command_worker(
    async_runtime: AsyncRuntimeHandle,
    runtime: RuntimeHandle,
    mut requests: mpsc::UnboundedReceiver<CommandRequest>,
    completions: mpsc::UnboundedSender<CommandCompletion>,
) {
    drop(async_runtime.spawn(async move {
        // A single consumer preserves UI dispatch order. This matters for
        // high-frequency text edits, whose persistence must never race an
        // older value past a newer one.
        while let Some(request) = requests.recv().await {
            let result = runtime
                .request(request.command)
                .await
                .map_err(|error| error.to_string());
            if completions
                .send(CommandCompletion {
                    key: request.key,
                    token: request.token,
                    result,
                })
                .is_err()
            {
                break;
            }
        }
    }));
}

fn subscribe_audio_level(
    mut levels: mpsc::UnboundedReceiver<f32>,
    cx: &Context<AppModel>,
) -> Task<()> {
    cx.spawn(async move |model, cx| {
        while let Some(level) = levels.recv().await {
            if model
                .update(cx, |model, cx| {
                    model.apply(AppMutation::AudioLevel(level), cx);
                })
                .is_err()
            {
                break;
            }
        }
    })
}

fn subscribe_snapshots(runtime: RuntimeHandle, cx: &Context<AppModel>) -> Task<()> {
    let mut snapshots = runtime.subscribe_snapshots();
    cx.spawn(async move |model, cx| {
        while snapshots.changed().await.is_ok() {
            let snapshot = snapshots.borrow_and_update().clone();
            if model
                .update(cx, |model, cx| {
                    model.apply(AppMutation::Snapshot(snapshot), cx);
                })
                .is_err()
            {
                break;
            }
        }
    })
}

fn subscribe_events(runtime: RuntimeHandle, cx: &Context<AppModel>) -> Task<()> {
    let mut events = runtime.subscribe_events();
    cx.spawn(async move |model, cx| loop {
        match events.recv().await {
            Ok(event) => {
                if model
                    .update(cx, |model, cx| {
                        model.apply(AppMutation::Event(event), cx);
                    })
                    .is_err()
                {
                    break;
                }
            }
            Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {
                emit_diagnostic(DiagnosticEvent::new(
                    DiagnosticCategory::Bridge,
                    DiagnosticLevel::Error,
                    DiagnosticCode::AppModelLagged,
                ));
            }
            Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
        }
    })
}

fn subscribe_completions(
    mut completions: mpsc::UnboundedReceiver<CommandCompletion>,
    cx: &Context<AppModel>,
) -> Task<()> {
    cx.spawn(async move |model, cx| {
        while let Some(completion) = completions.recv().await {
            if model
                .update(cx, |model, cx| {
                    model.apply(
                        AppMutation::CommandFinished {
                            key: completion.key,
                            token: completion.token,
                            result: completion.result,
                        },
                        cx,
                    );
                })
                .is_err()
            {
                break;
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use wrenflow_runtime::{start_runtime, RuntimeBootstrap, RuntimeCommand, SettingsPatch};

    type TestResult = Result<(), Box<dyn std::error::Error>>;

    #[tokio::test(flavor = "multi_thread")]
    async fn command_worker_preserves_high_frequency_setting_order() -> TestResult {
        let instance = start_runtime(RuntimeBootstrap::default())?;
        let (request_tx, request_rx) = mpsc::unbounded_channel();
        let (completion_tx, mut completion_rx) = mpsc::unbounded_channel();
        spawn_command_worker(
            AsyncRuntimeHandle::current(),
            instance.handle.clone(),
            request_rx,
            completion_tx,
        );
        let dispatcher = CommandDispatcher {
            requests: request_tx,
        };

        dispatcher.dispatch(
            CommandKey::Settings,
            1,
            RuntimeCommand::UpdateSettings(SettingsPatch::CustomVocabulary("first".to_string())),
        )?;
        dispatcher.dispatch(
            CommandKey::Settings,
            2,
            RuntimeCommand::UpdateSettings(SettingsPatch::CustomVocabulary("second".to_string())),
        )?;

        assert_eq!(completion_rx.recv().await.map(|item| item.token), Some(1));
        assert_eq!(completion_rx.recv().await.map(|item| item.token), Some(2));
        assert_eq!(
            instance.handle.snapshot().settings.custom_vocabulary,
            "second"
        );
        drop(dispatcher);
        instance.shutdown().await?;
        Ok(())
    }

    #[test]
    fn fifty_source_updates_coalesce_to_one_latest_presentation_frame() {
        let mut pending = PendingAudioLevel::default();
        for sample in 1..=50 {
            pending.observe(sample as f32 / 50.0);
        }

        assert_eq!(pending.take_latest(), Some(1.0));
        assert_eq!(pending.take_latest(), None);
        assert!(AUDIO_PRESENTATION_INTERVAL >= Duration::from_millis(33));
    }
}
