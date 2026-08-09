use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use arboard::Clipboard;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tokio::time::{Duration, Instant};
use wrenflow_core::audio_capture::{AudioCapture, AudioCaptureListener};
use wrenflow_domain::config::{AppConfig, DEFAULT_SELECTED_MICROPHONE_ID};
use wrenflow_domain::history::HistoryEntry;
use wrenflow_domain::pipeline::{
    PipelineEngine, PipelineListener, PipelineSound, PipelineState, TranscriptionResult,
};

use crate::history::HistoryHandle;
use crate::model::{self, TranscriptionService};
use crate::platform::paste;
use crate::state::TranscriptDisposition;
use crate::store::RuntimeStore;
use crate::{ErrorAction, RuntimeEvent, RuntimeSnapshot};

const INIT_TIMEOUT: Duration = Duration::from_millis(500);
const INDICATOR_TIMEOUT: Duration = Duration::from_secs(1);
const TIMER_TICK: Duration = Duration::from_millis(50);

enum PipelineCommand {
    Shutdown,
}

#[derive(Clone)]
pub(crate) struct PipelineHandle {
    commands: mpsc::Sender<PipelineCommand>,
    hotkey_events: mpsc::UnboundedSender<HotkeyEvent>,
}

impl PipelineHandle {
    pub(crate) async fn shutdown(&self) {
        let _ = self.commands.send(PipelineCommand::Shutdown).await;
    }

    pub(crate) fn hotkey_pressed(&self) -> Result<(), crate::RuntimeError> {
        self.hotkey_events
            .send(HotkeyEvent::KeyDown)
            .map_err(|_| crate::RuntimeError::ServiceClosed("pipeline"))
    }

    pub(crate) fn hotkey_released(&self, duration: Duration) -> Result<(), crate::RuntimeError> {
        self.hotkey_events
            .send(HotkeyEvent::KeyUp {
                duration_ms: duration.as_secs_f64() * 1_000.0,
            })
            .map_err(|_| crate::RuntimeError::ServiceClosed("pipeline"))
    }
}

pub(crate) struct PipelineRuntime {
    pub(crate) handle: PipelineHandle,
    pub(crate) join: JoinHandle<()>,
}

pub(crate) enum HotkeyEvent {
    KeyDown,
    KeyUp { duration_ms: f64 },
}

enum AudioEvent {
    FirstAudio,
    Error(String),
}

struct RuntimeAudioListener {
    store: RuntimeStore,
    events: mpsc::UnboundedSender<AudioEvent>,
    first_audio_sent: AtomicBool,
}

impl AudioCaptureListener for RuntimeAudioListener {
    fn on_audio_level(&self, level: f32) {
        self.store.set_audio_level(level);
    }

    fn on_recording_ready(&self) {
        if !self.first_audio_sent.swap(true, Ordering::Relaxed) {
            let _ = self.events.send(AudioEvent::FirstAudio);
        }
    }

    fn on_error(&self, message: String) {
        let _ = self.events.send(AudioEvent::Error(message));
    }
}

struct RuntimePipelineListener {
    store: RuntimeStore,
    history: Option<HistoryHandle>,
}

impl PipelineListener for RuntimePipelineListener {
    fn on_state_changed(&self, _old: PipelineState, new: PipelineState) {
        let _ = self.store.update(|snapshot| {
            if snapshot.pipeline == new {
                false
            } else {
                snapshot.pipeline = new;
                true
            }
        });
    }

    fn on_transcript_ready(&self, transcript: String) {
        self.store
            .emit(RuntimeEvent::TranscriptReady { transcript });
    }

    fn on_play_sound(&self, sound: PipelineSound) {
        self.store.emit(RuntimeEvent::PlaySound(sound));
    }

    fn on_error(&self, message: String) {
        let action = resolve_model_error_action(&message, &self.store.snapshot());
        self.store
            .emit(RuntimeEvent::PipelineError { message, action });
    }

    fn on_history_entry_added(&self, entry: HistoryEntry) {
        if let Some(history) = &self.history {
            if let Err(error) = history.insert(entry) {
                log::error!("Failed to queue history entry: {error}");
            }
        }
    }
}

struct PipelineController {
    engine: PipelineEngine,
    listener: RuntimePipelineListener,
    init_deadline: Option<Instant>,
    indicator_deadline: Option<Instant>,
}

impl PipelineController {
    fn new(config: AppConfig, store: RuntimeStore, history: Option<HistoryHandle>) -> Self {
        Self {
            engine: PipelineEngine::new(config),
            listener: RuntimePipelineListener { store, history },
            init_deadline: None,
            indicator_deadline: None,
        }
    }

    fn hotkey_down(&mut self) {
        if self.engine.handle_hotkey_down(&self.listener) {
            self.init_deadline = Some(Instant::now() + INIT_TIMEOUT);
            self.indicator_deadline = None;
        }
    }

    fn hotkey_up(&mut self, duration_ms: f64) {
        let transcribing = self.engine.handle_hotkey_up(duration_ms, &self.listener);
        self.init_deadline = None;
        self.indicator_deadline = transcribing.then(|| Instant::now() + INDICATOR_TIMEOUT);
    }

    fn update_config(&mut self, config: AppConfig) {
        self.engine.update_config(config);
    }

    fn custom_vocabulary(&self) -> String {
        self.engine.custom_vocabulary().to_string()
    }

    fn transcription_complete(&mut self, result: TranscriptionResult) {
        self.engine
            .on_transcription_complete(result, &self.listener);
        self.indicator_deadline = None;
    }

    fn is_transcribing(&self) -> bool {
        self.engine.state().is_transcribing()
    }

    fn first_audio(&mut self) {
        self.engine.on_first_audio(&self.listener);
        self.init_deadline = None;
    }

    fn error(&mut self, message: &str) {
        self.engine.on_pipeline_error(message, &self.listener);
        self.indicator_deadline = None;
    }

    fn check_timers(&mut self) {
        let now = Instant::now();
        if self.init_deadline.is_some_and(|deadline| now >= deadline) {
            self.init_deadline = None;
            self.engine.on_init_timeout(&self.listener);
        }
        if self
            .indicator_deadline
            .is_some_and(|deadline| now >= deadline)
        {
            self.indicator_deadline = None;
            self.engine.on_indicator_timeout(&self.listener);
        }
    }
}

pub(crate) fn start(
    store: RuntimeStore,
    transcription: TranscriptionService,
    history: Option<HistoryHandle>,
) -> PipelineRuntime {
    let (commands, command_rx) = mpsc::channel(2);
    let (hotkey_events, hotkey_rx) = mpsc::unbounded_channel();
    let handle = PipelineHandle {
        commands,
        hotkey_events,
    };
    let join = tokio::spawn(run(command_rx, hotkey_rx, store, transcription, history));
    PipelineRuntime { handle, join }
}

async fn run(
    mut commands: mpsc::Receiver<PipelineCommand>,
    mut hotkey_rx: mpsc::UnboundedReceiver<HotkeyEvent>,
    store: RuntimeStore,
    transcription: TranscriptionService,
    history: Option<HistoryHandle>,
) {
    let audio = AudioCapture::new();
    let (audio_tx, mut audio_rx) = mpsc::unbounded_channel();
    let mut snapshots = store.subscribe_snapshots();
    let mut controller =
        PipelineController::new(store.snapshot().settings.clone(), store.clone(), history);
    let mut timer = tokio::time::interval(TIMER_TICK);

    loop {
        tokio::select! {
            command = commands.recv() => {
                if matches!(command, Some(PipelineCommand::Shutdown) | None) {
                    audio.cleanup();
                    store.set_audio_level(0.0);
                    break;
                }
            }
            event = hotkey_rx.recv() => {
                match event {
                    Some(HotkeyEvent::KeyDown) => {
                        if let Some(message) = model::preflight_error(&store, &transcription) {
                            controller.error(&message);
                            continue;
                        }
                        controller.hotkey_down();
                        let device_id = effective_device_id(&store.snapshot());
                        let selected = (device_id != DEFAULT_SELECTED_MICROPHONE_ID)
                            .then_some(device_id.as_str());
                        let listener = Arc::new(RuntimeAudioListener {
                            store: store.clone(),
                            events: audio_tx.clone(),
                            first_audio_sent: AtomicBool::new(false),
                        });
                        if let Err(error) = audio.start_recording(selected, listener) {
                            controller.error(&format!("Failed to start audio: {error}"));
                        }
                    }
                    Some(HotkeyEvent::KeyUp { duration_ms }) => {
                        let recording = audio.stop_recording();
                        store.set_audio_level(0.0);
                        controller.hotkey_up(duration_ms);
                        if controller.is_transcribing() {
                            match recording {
                                Ok(Some(recording)) => {
                                    save_recording(recording.samples_16k.clone());
                                    let vocabulary = controller.custom_vocabulary();
                                    match transcription.transcribe(recording.samples_16k, vocabulary).await {
                                        Ok(result) => {
                                            let transcript = result.raw_transcript.trim().to_string();
                                            controller.transcription_complete(result);
                                            if !transcript.is_empty()
                                                && store.snapshot().transcript_disposition == TranscriptDisposition::Paste
                                            {
                                                match paste_text(&transcript) {
                                                    Ok(()) => store.emit(RuntimeEvent::PasteCompleted),
                                                    Err(error) => controller.error(&format!("Paste failed: {error}")),
                                                }
                                            }
                                        }
                                        Err(message) => controller.error(&message),
                                    }
                                }
                                Ok(None) => controller.error("Recording did not produce audio"),
                                Err(message) => controller.error(&message),
                            }
                        }
                    }
                    None => break,
                }
            }
            event = audio_rx.recv() => {
                match event {
                    Some(AudioEvent::FirstAudio) => controller.first_audio(),
                    Some(AudioEvent::Error(message)) => controller.error(&message),
                    None => break,
                }
            }
            changed = snapshots.changed() => {
                if changed.is_err() {
                    break;
                }
                let config = snapshots.borrow().settings.clone();
                controller.update_config(config);
            }
            _ = timer.tick() => controller.check_timers(),
        }
    }
}

fn effective_device_id(snapshot: &RuntimeSnapshot) -> String {
    snapshot.audio_devices.effective_selected_device_id.clone()
}

fn resolve_model_error_action(message: &str, snapshot: &RuntimeSnapshot) -> Option<ErrorAction> {
    let selected = snapshot
        .models
        .models
        .iter()
        .find(|model| model.id == snapshot.models.selected_model_id)?;
    let message = message.to_ascii_lowercase();
    let model_related = message.contains("settings -> models")
        || message.contains("local model")
        || message.contains(&selected.display_name.to_ascii_lowercase());
    if !model_related {
        return None;
    }

    let installed = snapshot
        .models
        .installed_model_ids
        .iter()
        .any(|model_id| model_id == &selected.id);
    let active = snapshot.models.active_model_id.as_deref() == Some(selected.id.as_str());
    if installed && !active {
        Some(ErrorAction {
            id: "activate_selected_model".to_string(),
            label: "Activate now".to_string(),
        })
    } else {
        Some(ErrorAction {
            id: "open_models".to_string(),
            label: "Open Models".to_string(),
        })
    }
}

fn save_recording(samples: Vec<f32>) {
    tokio::task::spawn_blocking(move || {
        let directory = recordings_dir();
        if let Err(error) = std::fs::create_dir_all(&directory) {
            log::error!("Failed to create recordings dir: {error}");
            return;
        }
        let millis = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis();
        let path = directory.join(format!("recording_{millis}.ogg"));
        match std::fs::File::create(&path) {
            Ok(mut file) => {
                if let Err(error) =
                    wrenflow_core::opus_encoder::encode_ogg_opus(&mut file, &samples)
                {
                    log::error!("Opus encode error: {error}");
                }
            }
            Err(error) => log::error!("Opus file create error: {error}"),
        }
    });
}

fn paste_text(text: &str) -> Result<(), String> {
    let mut clipboard = Clipboard::new().map_err(|error| format!("clipboard error: {error}"))?;
    clipboard
        .set_text(text)
        .map_err(|error| format!("clipboard set error: {error}"))?;
    std::thread::sleep(Duration::from_millis(50));
    paste::simulate_paste_shortcut()
}

fn recordings_dir() -> PathBuf {
    dirs::data_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("Wrenflow/recordings")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn typed_hotkey_events_reach_the_pipeline_without_a_native_listener() {
        let (commands, _command_rx) = mpsc::channel(1);
        let (hotkey_events, mut hotkey_rx) = mpsc::unbounded_channel();
        let handle = PipelineHandle {
            commands,
            hotkey_events,
        };

        assert!(handle.hotkey_pressed().is_ok());
        assert!(matches!(hotkey_rx.recv().await, Some(HotkeyEvent::KeyDown)));

        assert!(handle.hotkey_released(Duration::from_millis(275)).is_ok());
        let Some(HotkeyEvent::KeyUp { duration_ms }) = hotkey_rx.recv().await else {
            panic!("expected a typed hotkey release");
        };
        assert!((duration_ms - 275.0).abs() < f64::EPSILON);
    }

    #[test]
    fn default_microphone_maps_to_backend_default() {
        let mut snapshot = crate::supervisor::initial_snapshot(&crate::RuntimeBootstrap::default());
        snapshot.audio_devices.effective_selected_device_id =
            DEFAULT_SELECTED_MICROPHONE_ID.to_string();
        assert_eq!(
            effective_device_id(&snapshot),
            DEFAULT_SELECTED_MICROPHONE_ID
        );
    }

    #[test]
    fn model_errors_offer_activation_only_for_an_installed_inactive_selection() {
        let mut snapshot = crate::supervisor::initial_snapshot(&crate::RuntimeBootstrap::default());
        let selected = snapshot.models.selected_model_id.clone();
        snapshot.models.installed_model_ids.push(selected);

        assert_eq!(
            resolve_model_error_action(
                "The active model is unavailable. Open Settings -> Models and activate a model again.",
                &snapshot,
            ),
            Some(ErrorAction {
                id: "activate_selected_model".to_string(),
                label: "Activate now".to_string(),
            })
        );
    }

    #[test]
    fn unavailable_or_unrelated_model_errors_route_without_false_actions() {
        let snapshot = crate::supervisor::initial_snapshot(&crate::RuntimeBootstrap::default());
        assert_eq!(
            resolve_model_error_action("Local model files are missing", &snapshot),
            Some(ErrorAction {
                id: "open_models".to_string(),
                label: "Open Models".to_string(),
            })
        );
        assert_eq!(resolve_model_error_action("Paste failed", &snapshot), None);
    }
}
