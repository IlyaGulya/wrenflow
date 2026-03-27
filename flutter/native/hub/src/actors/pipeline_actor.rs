//! Pipeline actor — owns the PipelineEngine and routes signals.
//! Manages FSM timeouts and bridges PipelineListener to rinf signals.

use rinf::{DartSignal, RustSignal};
use std::pin::Pin;
use tokio::select;
use tokio::time::{Duration, Sleep, sleep};
use wrenflow_domain::config::AppConfig;
use wrenflow_domain::history::HistoryEntry;
use wrenflow_domain::pipeline::{
    PipelineEngine, PipelineListener, PipelineSound, PipelineState, TranscriptionResult,
};

use crate::signals;

// Timeout durations matching the Swift app
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
        // TODO: Use enigo+arboard to paste (freeflow-71y)
        signals::TranscriptReady { transcript: text }.send_signal_to_dart();
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
    // Optional timers — None when inactive
    init_timer: Option<Pin<Box<Sleep>>>,
    indicator_timer: Option<Pin<Box<Sleep>>>,
    dismiss_timer: Option<Pin<Box<Sleep>>>,
}

impl PipelineActor {
    pub fn new() -> Self {
        Self {
            engine: PipelineEngine::new(AppConfig::default()),
            listener: SignalListener,
            init_timer: None,
            indicator_timer: None,
            dismiss_timer: None,
        }
    }

    pub async fn run(&mut self) {
        let start_recv = signals::StartRecording::get_dart_signal_receiver();
        let stop_recv = signals::StopRecording::get_dart_signal_receiver();
        let config_recv = signals::UpdateConfig::get_dart_signal_receiver();

        loop {
            select! {
                Some(_pack) = start_recv.recv() => {
                    let started = self.engine.handle_hotkey_down(&self.listener);
                    if started {
                        // Schedule init timeout (0.5s → show initializing spinner)
                        self.init_timer = Some(Box::pin(sleep(INIT_TIMEOUT)));
                        self.indicator_timer = None;
                        self.dismiss_timer = None;
                    }
                }

                Some(pack) = stop_recv.recv() => {
                    let transcribing = self.engine.handle_hotkey_up(
                        pack.message.duration_ms, &self.listener
                    );
                    self.init_timer = None;
                    if transcribing {
                        // Schedule indicator timeout (1s → show transcribing indicator)
                        self.indicator_timer = Some(Box::pin(sleep(INDICATOR_TIMEOUT)));

                        // TODO (freeflow-385): Actually transcribe audio here.
                        // For now, simulate with a placeholder to complete the FSM flow.
                        // The real implementation will call Groq API or Parakeet.
                    }
                }

                Some(pack) = config_recv.recv() => {
                    let c = pack.message;
                    self.engine.update_config(AppConfig {
                        api_key: c.api_key,
                        api_base_url: c.api_base_url,
                        selected_hotkey: c.selected_hotkey,
                        selected_microphone_id: c.selected_microphone_id,
                        sound_enabled: c.sound_enabled,
                        custom_vocabulary: c.custom_vocabulary,
                        transcription_provider: c.transcription_provider,
                        transcription_model: c.transcription_model,
                        minimum_recording_duration_ms: c.minimum_recording_duration_ms,
                    });
                }

                // Timer fires: init timeout
                () = async { self.init_timer.as_mut().expect("timer").as_mut().await },
                    if self.init_timer.is_some() => {
                    self.init_timer = None;
                    self.engine.on_init_timeout(&self.listener);
                }

                // Timer fires: indicator timeout
                () = async { self.indicator_timer.as_mut().expect("timer").as_mut().await },
                    if self.indicator_timer.is_some() => {
                    self.indicator_timer = None;
                    self.engine.on_indicator_timeout(&self.listener);
                }

                // Timer fires: dismiss timeout
                () = async { self.dismiss_timer.as_mut().expect("timer").as_mut().await },
                    if self.dismiss_timer.is_some() => {
                    self.dismiss_timer = None;
                    self.engine.on_dismiss_timeout(&self.listener);
                }

                else => break,
            }

            // After any event, check if we should schedule a dismiss timer
            self.update_dismiss_timer();
        }
    }

    /// Schedule dismiss timer when entering Pasting or Error state.
    fn update_dismiss_timer(&mut self) {
        match self.engine.state() {
            PipelineState::Pasting | PipelineState::Error { .. } => {
                if self.dismiss_timer.is_none() {
                    self.dismiss_timer = Some(Box::pin(sleep(DISMISS_TIMEOUT)));
                }
            }
            _ => {}
        }
    }

    /// Called when transcription completes (will be triggered by audio/transcription actors).
    pub fn on_transcription_complete(&mut self, result: TranscriptionResult) {
        self.engine
            .on_transcription_complete(result, &self.listener);
        self.indicator_timer = None;
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
