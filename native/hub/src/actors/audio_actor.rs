//! Audio actor — manages audio capture and sends level updates to Dart.

use rinf::RustSignal;
use std::sync::Arc;
use tokio::sync::mpsc;
use wrenflow_core::audio_capture::{AudioCapture, AudioCaptureListener};
use wrenflow_domain::audio::RecordingResult;

use crate::signals;

/// Events sent from AudioActor to PipelineActor.
pub enum AudioEvent {
    FirstAudio,
    RecordingComplete(RecordingResult),
    Error(String),
}

/// Listener that sends audio level updates to Dart and events to pipeline.
struct HubAudioListener {
    event_tx: mpsc::UnboundedSender<AudioEvent>,
    first_audio_sent: std::sync::atomic::AtomicBool,
}

impl AudioCaptureListener for HubAudioListener {
    fn on_audio_level(&self, level: f32) {
        signals::AudioLevelUpdate { level }.send_signal_to_dart();
    }

    fn on_recording_ready(&self) {
        if !self.first_audio_sent.swap(true, std::sync::atomic::Ordering::Relaxed) {
            let _ = self.event_tx.send(AudioEvent::FirstAudio);
        }
    }

    fn on_error(&self, message: String) {
        let _ = self.event_tx.send(AudioEvent::Error(message));
    }
}

pub struct AudioActor {
    capture: AudioCapture,
    event_tx: mpsc::UnboundedSender<AudioEvent>,
    event_rx: mpsc::UnboundedReceiver<AudioEvent>,
}

impl AudioActor {
    pub fn new() -> Self {
        let (event_tx, event_rx) = mpsc::unbounded_channel();
        Self {
            capture: AudioCapture::new(),
            event_tx,
            event_rx,
        }
    }

    /// Start recording from the specified device.
    pub fn start(&self, device_id: &str) -> Result<(), String> {
        let listener = Arc::new(HubAudioListener {
            event_tx: self.event_tx.clone(),
            first_audio_sent: std::sync::atomic::AtomicBool::new(false),
        });

        let dev = if device_id.is_empty() || device_id == "default" {
            None
        } else {
            Some(device_id)
        };

        self.capture.start_recording(dev, listener)
    }

    /// Stop recording and return the result.
    pub fn stop(&self) -> Result<Option<RecordingResult>, String> {
        self.capture.stop_recording()
    }

    /// Receive the next audio event (non-blocking via mpsc).
    pub async fn recv_event(&mut self) -> Option<AudioEvent> {
        self.event_rx.recv().await
    }

    /// List available input devices.
    pub fn list_devices() -> Vec<signals::AudioDeviceInfo> {
        AudioCapture::list_input_devices()
            .into_iter()
            .map(|d| signals::AudioDeviceInfo {
                id: d.id,
                name: d.name,
            })
            .collect()
    }

    /// Get the name of the current system default input device.
    pub fn default_device_name() -> String {
        AudioCapture::default_input_device_name()
    }
}
