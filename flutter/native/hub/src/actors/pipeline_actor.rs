//! Pipeline actor — owns the PipelineEngine and routes signals.
//! Manages FSM timeouts and bridges PipelineListener to rinf signals.

use rinf::RustSignal;
use tokio::time::{Duration, Instant};
use wrenflow_domain::config::AppConfig;
use wrenflow_domain::history::HistoryEntry;
use wrenflow_domain::pipeline::{
    PipelineEngine, PipelineListener, PipelineSound, PipelineState, TranscriptionResult,
};

use crate::signals;

const INIT_TIMEOUT: Duration = Duration::from_millis(500);
const INDICATOR_TIMEOUT: Duration = Duration::from_secs(1);
const DISMISS_TIMEOUT: Duration = Duration::from_secs(3);

/// Bridges PipelineListener trait to rinf signals.
struct SignalListener;

impl PipelineListener for SignalListener {
    fn on_state_changed(&self, old: PipelineState, new: PipelineState) {
        signals::PipelineStateChanged {
            old_state: domain_state_to_signal(old),
            new_state: domain_state_to_signal(new),
        }
        .send_signal_to_dart();
    }

    fn on_paste_text(&self, text: String) {
        // Paste via enigo+arboard
        if let Err(e) = super::paste_actor::paste_text(&text) {
            log::error!("paste failed: {e}");
            signals::PipelineError {
                message: format!("Paste failed: {e}"),
            }
            .send_signal_to_dart();
        }
        signals::TranscriptReady {
            transcript: text,
        }
        .send_signal_to_dart();
        signals::PasteComplete.send_signal_to_dart();
    }

    fn on_play_sound(&self, sound: PipelineSound) {
        let sound_type = match sound {
            PipelineSound::RecordingStarted => signals::SoundType::RecordingStarted,
            PipelineSound::RecordingStopped => signals::SoundType::RecordingStopped,
        };
        signals::PlaySound { sound: sound_type }.send_signal_to_dart();
    }

    fn on_error(&self, message: String) {
        signals::PipelineError { message }.send_signal_to_dart();
    }

    fn on_history_entry_added(&self, entry: HistoryEntry) {
        signals::HistoryEntryAdded {
            entry: signals::HistoryEntryData {
                id: entry.id,
                timestamp: entry.timestamp,
                transcript: entry.transcript,
                custom_vocabulary: entry.custom_vocabulary,
                audio_file_name: entry.audio_file_name,
                metrics_json: entry.metrics_json,
            },
        }
        .send_signal_to_dart();
    }
}

pub struct PipelineActor {
    engine: PipelineEngine,
    listener: SignalListener,
    init_deadline: Option<Instant>,
    indicator_deadline: Option<Instant>,
    dismiss_deadline: Option<Instant>,
}

impl PipelineActor {
    pub fn new() -> Self {
        Self {
            engine: PipelineEngine::new(AppConfig::default()),
            listener: SignalListener,
            init_deadline: None,
            indicator_deadline: None,
            dismiss_deadline: None,
        }
    }

    pub fn handle_hotkey_down(&mut self) {
        let started = self.engine.handle_hotkey_down(&self.listener);
        if started {
            self.init_deadline = Some(Instant::now() + INIT_TIMEOUT);
            self.indicator_deadline = None;
            self.dismiss_deadline = None;
        }
    }

    pub fn handle_hotkey_up(&mut self, duration_ms: f64) {
        let transcribing = self.engine.handle_hotkey_up(duration_ms, &self.listener);
        self.init_deadline = None;
        if transcribing {
            self.indicator_deadline = Some(Instant::now() + INDICATOR_TIMEOUT);
            // TODO: trigger actual transcription (freeflow-385)
        }
    }

    pub fn handle_config_update(&mut self, c: signals::UpdateConfig) {
        self.engine.update_config(AppConfig {
            selected_hotkey: c.selected_hotkey,
            selected_microphone_id: c.selected_microphone_id,
            sound_enabled: c.sound_enabled,
            custom_vocabulary: c.custom_vocabulary,
            minimum_recording_duration_ms: c.minimum_recording_duration_ms,
        });
    }

    pub fn on_transcription_complete(&mut self, result: TranscriptionResult) {
        self.engine.on_transcription_complete(result, &self.listener);
        self.indicator_deadline = None;
        self.update_dismiss();
    }

    pub fn is_transcribing(&self) -> bool {
        self.engine.state().is_transcribing()
    }

    pub fn on_first_audio(&mut self) {
        self.engine.on_first_audio(&self.listener);
        self.init_deadline = None;
    }

    /// Check and fire any expired timers. Call after each event.
    pub async fn check_timers(&mut self) {
        let now = Instant::now();

        if let Some(deadline) = self.init_deadline {
            if now >= deadline {
                self.init_deadline = None;
                self.engine.on_init_timeout(&self.listener);
            }
        }

        if let Some(deadline) = self.indicator_deadline {
            if now >= deadline {
                self.indicator_deadline = None;
                self.engine.on_indicator_timeout(&self.listener);
            }
        }

        if let Some(deadline) = self.dismiss_deadline {
            if now >= deadline {
                self.dismiss_deadline = None;
                self.engine.on_dismiss_timeout(&self.listener);
            }
        }
    }

    fn update_dismiss(&mut self) {
        match self.engine.state() {
            PipelineState::Pasting | PipelineState::Error { .. } => {
                if self.dismiss_deadline.is_none() {
                    self.dismiss_deadline = Some(Instant::now() + DISMISS_TIMEOUT);
                }
            }
            _ => {}
        }
    }
}

fn domain_state_to_signal(state: PipelineState) -> signals::PipelineState {
    match state {
        PipelineState::Idle => signals::PipelineState::Idle,
        PipelineState::Starting => signals::PipelineState::Starting,
        PipelineState::Initializing => signals::PipelineState::Initializing,
        PipelineState::Recording => signals::PipelineState::Recording,
        PipelineState::Transcribing { showing_indicator } => {
            signals::PipelineState::Transcribing { showing_indicator }
        }
        PipelineState::Pasting => signals::PipelineState::Pasting,
        PipelineState::Error { message } => signals::PipelineState::Error { message },
    }
}
