//! Pipeline state machine and engine.
//!
//! The Rust core owns the pipeline state and orchestrates transitions.
//! Platform-specific side effects (overlay, sounds, timers) are delegated
//! to a `PipelineListener` trait implemented by the native layer.

use crate::config::AppConfig;
use crate::history::HistoryEntry;
use crate::metrics::PipelineMetrics;
use std::time::Instant;

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
pub enum PipelineState {
    Idle,
    Starting,
    Initializing,
    Recording,
    Transcribing { showing_indicator: bool },
    Pasting,
    Error { message: String },
}

impl PipelineState {
    pub fn is_recording(&self) -> bool {
        matches!(self, Self::Starting | Self::Initializing | Self::Recording)
    }

    pub fn is_transcribing(&self) -> bool {
        matches!(self, Self::Transcribing { .. })
    }

    pub fn can_start_recording(&self) -> bool {
        matches!(self, Self::Idle | Self::Pasting | Self::Error { .. })
    }

    pub fn status_text(&self) -> &str {
        match self {
            Self::Idle => "Ready",
            Self::Starting | Self::Initializing => "Starting...",
            Self::Recording => "Recording...",
            Self::Transcribing { .. } => "Transcribing...",
            Self::Pasting => "Copied to clipboard!",
            Self::Error { .. } => "Error",
        }
    }

    pub fn name(&self) -> &str {
        match self {
            Self::Idle => "idle",
            Self::Starting => "starting",
            Self::Initializing => "initializing",
            Self::Recording => "recording",
            Self::Transcribing { .. } => "transcribing",
            Self::Pasting => "pasting",
            Self::Error { .. } => "error",
        }
    }
}

// ---------------------------------------------------------------------------
// Listener — implemented by native platform layer
// ---------------------------------------------------------------------------

/// Callback interface for platform-specific side effects.
/// The native layer (Swift/Kotlin/C++) implements this trait.
pub trait PipelineListener: Send + Sync {
    /// Called on every state transition.
    fn on_state_changed(&self, old: PipelineState, new: PipelineState);

    /// Called when the final transcript is ready to be pasted.
    fn on_paste_text(&self, text: String);

    /// Called to play a sound effect.
    fn on_play_sound(&self, sound: PipelineSound);

    /// Called when pipeline encounters an error.
    fn on_error(&self, message: String);

    /// Called when a pipeline run is recorded to history.
    fn on_history_entry_added(&self, entry: HistoryEntry);
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum PipelineSound {
    RecordingStarted, // "Tink" on macOS
    RecordingStopped, // "Pop" on macOS
}

// ---------------------------------------------------------------------------
// Transcription result — passed from native audio capture through Rust
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct TranscriptionResult {
    pub raw_transcript: String,
    pub duration_ms: f64,
    pub provider: String,
}

// ---------------------------------------------------------------------------
// Pipeline Engine
// ---------------------------------------------------------------------------

pub struct PipelineEngine {
    state: PipelineState,
    config: AppConfig,
    metrics: PipelineMetrics,
    pipeline_start: Option<Instant>,
    recording_duration_ms: f64,
}

impl PipelineEngine {
    pub fn new(config: AppConfig) -> Self {
        Self {
            state: PipelineState::Idle,
            config,
            metrics: PipelineMetrics::new(),
            pipeline_start: None,
            recording_duration_ms: 0.0,
        }
    }

    pub fn state(&self) -> &PipelineState {
        &self.state
    }

    pub fn update_config(&mut self, config: AppConfig) {
        self.config = config;
    }

    /// Transition to a new state, notifying the listener.
    pub fn transition(&mut self, new_state: PipelineState, listener: &dyn PipelineListener) {
        let old = self.state.clone();
        log::info!("pipeline: {} → {}", old.name(), new_state.name());
        self.state = new_state.clone();
        listener.on_state_changed(old, new_state);
    }

    /// Called when hotkey is pressed — start recording if possible.
    pub fn handle_hotkey_down(&mut self, listener: &dyn PipelineListener) -> bool {
        if !self.state.can_start_recording() {
            return false;
        }
        if self.state != PipelineState::Idle {
            self.transition(PipelineState::Idle, listener);
        }
        self.metrics = PipelineMetrics::new();
        self.pipeline_start = Some(Instant::now());
        self.transition(PipelineState::Starting, listener);
        true
    }

    /// Called when first real audio buffer arrives.
    pub fn on_first_audio(&mut self, listener: &dyn PipelineListener) {
        if matches!(self.state, PipelineState::Starting | PipelineState::Initializing) {
            self.transition(PipelineState::Recording, listener);
            if self.config.sound_enabled {
                listener.on_play_sound(PipelineSound::RecordingStarted);
            }
        }
    }

    /// Called when 0.5s elapses in Starting state without audio.
    pub fn on_init_timeout(&mut self, listener: &dyn PipelineListener) {
        if self.state == PipelineState::Starting {
            self.transition(PipelineState::Initializing, listener);
        }
    }

    /// Called when hotkey is released — stop recording, begin transcription.
    pub fn handle_hotkey_up(&mut self, recording_duration_ms: f64, listener: &dyn PipelineListener) -> bool {
        if !self.state.is_recording() {
            return false;
        }

        self.recording_duration_ms = recording_duration_ms;
        self.metrics.set_double("recording.durationMs", recording_duration_ms);

        // Check minimum duration
        if recording_duration_ms < self.config.minimum_recording_duration_ms {
            log::info!("recording too short ({:.0}ms < {:.0}ms)",
                recording_duration_ms, self.config.minimum_recording_duration_ms);
            self.transition(PipelineState::Idle, listener);
            return false;
        }

        self.transition(PipelineState::Transcribing { showing_indicator: false }, listener);
        if self.config.sound_enabled {
            listener.on_play_sound(PipelineSound::RecordingStopped);
        }
        true
    }

    /// Called after delayed indicator timeout (1s) during transcribing.
    pub fn on_indicator_timeout(&mut self, listener: &dyn PipelineListener) {
        if matches!(self.state, PipelineState::Transcribing { showing_indicator: false }) {
            self.transition(PipelineState::Transcribing { showing_indicator: true }, listener);
        }
    }

    /// Called when transcription completes — move to pasting.
    pub fn on_transcription_complete(
        &mut self,
        result: TranscriptionResult,
        listener: &dyn PipelineListener,
    ) {
        self.metrics.set_double("transcription.durationMs", result.duration_ms);
        self.metrics.set_string("transcription.provider", result.provider);

        let transcript = result.raw_transcript.trim().to_string();
        self.finish_pipeline(transcript, listener);
    }

    /// Called when pipeline encounters an error at any stage.
    pub fn on_pipeline_error(&mut self, message: &str, listener: &dyn PipelineListener) {
        self.metrics.set_string("pipeline.outcome", "error".to_string());
        listener.on_error(message.to_string());
        self.transition(PipelineState::Error { message: message.to_string() }, listener);
    }

    /// Called after error/pasting auto-dismiss timeout (3s).
    pub fn on_dismiss_timeout(&mut self, listener: &dyn PipelineListener) {
        if matches!(self.state, PipelineState::Pasting | PipelineState::Error { .. }) {
            self.transition(PipelineState::Idle, listener);
        }
    }

    fn finish_pipeline(
        &mut self,
        transcript: String,
        listener: &dyn PipelineListener,
    ) {
        if let Some(start) = self.pipeline_start {
            let total_ms = start.elapsed().as_secs_f64() * 1000.0;
            self.metrics.set_double("pipeline.totalMs", total_ms);
        }

        if transcript.is_empty() {
            log::info!("transcript empty — dismissing");
            self.metrics.set_string("pipeline.outcome", "empty".to_string());
            self.transition(PipelineState::Idle, listener);
        } else {
            self.metrics.set_string("pipeline.outcome", "pasted".to_string());
            listener.on_paste_text(transcript.clone());
            self.transition(PipelineState::Pasting, listener);
        }

        let entry = HistoryEntry {
            id: uuid_v4(),
            timestamp: unix_timestamp(),
            transcript: transcript.clone(),
            custom_vocabulary: self.config.custom_vocabulary.clone(),
            audio_file_name: None,
            metrics_json: self.metrics.to_json(),
        };
        listener.on_history_entry_added(entry);

        self.pipeline_start = None;
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn uuid_v4() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
    // Simple pseudo-UUID from timestamp + random-ish bits
    format!(
        "{:08x}-{:04x}-4{:03x}-{:04x}-{:012x}",
        (now.as_secs() & 0xFFFFFFFF) as u32,
        (now.subsec_nanos() >> 16) & 0xFFFF,
        now.subsec_nanos() & 0xFFF,
        0x8000 | (now.subsec_micros() & 0x3FFF),
        now.as_nanos() & 0xFFFFFFFFFFFF,
    )
}

fn unix_timestamp() -> f64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    #[derive(Default)]
    struct MockListener {
        transitions: Mutex<Vec<(String, String)>>,
        pasted: Mutex<Vec<String>>,
        sounds: Mutex<Vec<PipelineSound>>,
        errors: Mutex<Vec<String>>,
        history: Mutex<Vec<HistoryEntry>>,
    }

    impl PipelineListener for MockListener {
        fn on_state_changed(&self, old: PipelineState, new: PipelineState) {
            self.transitions.lock().unwrap().push((old.name().to_string(), new.name().to_string()));
        }
        fn on_paste_text(&self, text: String) {
            self.pasted.lock().unwrap().push(text);
        }
        fn on_play_sound(&self, sound: PipelineSound) {
            self.sounds.lock().unwrap().push(sound);
        }
        fn on_error(&self, message: String) {
            self.errors.lock().unwrap().push(message);
        }
        fn on_history_entry_added(&self, entry: HistoryEntry) {
            self.history.lock().unwrap().push(entry);
        }
    }

    fn make_engine() -> (PipelineEngine, Arc<MockListener>) {
        let config = AppConfig::default();
        let listener = Arc::new(MockListener::default());
        (PipelineEngine::new(config), listener)
    }

    #[test]
    fn basic_flow() {
        let (mut engine, listener) = make_engine();
        assert_eq!(engine.state(), &PipelineState::Idle);

        // Start recording
        assert!(engine.handle_hotkey_down(&*listener));
        assert_eq!(engine.state(), &PipelineState::Starting);

        // First audio
        engine.on_first_audio(&*listener);
        assert_eq!(engine.state(), &PipelineState::Recording);

        // Stop recording (500ms)
        assert!(engine.handle_hotkey_up(500.0, &*listener));
        assert!(engine.state().is_transcribing());

        // Transcription completes
        engine.on_transcription_complete(
            TranscriptionResult {
                raw_transcript: "hello world".to_string(),
                duration_ms: 200.0,
                provider: "local".to_string(),
            },
            &*listener,
        );
        assert_eq!(engine.state(), &PipelineState::Pasting);

        // Check paste happened
        let pasted = listener.pasted.lock().unwrap();
        assert_eq!(pasted[0], "hello world");

        // Check history recorded
        let history = listener.history.lock().unwrap();
        assert_eq!(history.len(), 1);
        assert_eq!(history[0].transcript, "hello world");
    }

    #[test]
    fn short_recording_dismissed() {
        let (mut engine, listener) = make_engine();
        engine.handle_hotkey_down(&*listener);
        engine.on_first_audio(&*listener);

        // Too short (100ms < 200ms default)
        assert!(!engine.handle_hotkey_up(100.0, &*listener));
        assert_eq!(engine.state(), &PipelineState::Idle);
    }

    #[test]
    fn empty_transcript_goes_to_idle() {
        let (mut engine, listener) = make_engine();
        engine.handle_hotkey_down(&*listener);
        engine.on_first_audio(&*listener);
        engine.handle_hotkey_up(500.0, &*listener);

        engine.on_transcription_complete(
            TranscriptionResult {
                raw_transcript: "  ".to_string(),
                duration_ms: 200.0,
                provider: "local".to_string(),
            },
            &*listener,
        );
        assert_eq!(engine.state(), &PipelineState::Idle);
        assert!(listener.pasted.lock().unwrap().is_empty());
    }

    #[test]
    fn cannot_start_during_transcription() {
        let (mut engine, listener) = make_engine();
        engine.handle_hotkey_down(&*listener);
        engine.on_first_audio(&*listener);
        engine.handle_hotkey_up(500.0, &*listener);

        // Try to start again during transcription
        assert!(!engine.handle_hotkey_down(&*listener));
    }

    #[test]
    fn indicator_timeout_promotes_state() {
        let (mut engine, listener) = make_engine();
        engine.handle_hotkey_down(&*listener);
        engine.on_first_audio(&*listener);
        engine.handle_hotkey_up(500.0, &*listener);

        assert_eq!(engine.state(), &PipelineState::Transcribing { showing_indicator: false });
        engine.on_indicator_timeout(&*listener);
        assert_eq!(engine.state(), &PipelineState::Transcribing { showing_indicator: true });
    }

    #[test]
    fn error_recovery() {
        let (mut engine, listener) = make_engine();
        engine.handle_hotkey_down(&*listener);
        engine.on_first_audio(&*listener);
        engine.handle_hotkey_up(500.0, &*listener);

        engine.on_pipeline_error("test error", &*listener);
        assert!(matches!(engine.state(), PipelineState::Error { .. }));

        // Can start again from error state
        assert!(engine.handle_hotkey_down(&*listener));
    }

    #[test]
    fn init_timeout_promotes_to_initializing() {
        let (mut engine, listener) = make_engine();
        engine.handle_hotkey_down(&*listener);
        assert_eq!(engine.state(), &PipelineState::Starting);

        engine.on_init_timeout(&*listener);
        assert_eq!(engine.state(), &PipelineState::Initializing);
    }
}
