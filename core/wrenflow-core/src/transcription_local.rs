//! Local Parakeet TDT transcription via parakeet-rs (ONNX Runtime).
//!
//! Uses the `parakeet-rs` crate which wraps NVIDIA's Parakeet TDT model
//! with ONNX Runtime inference. Cross-platform (macOS, Android, Windows, Linux).

use parakeet_rs::Transcriber;
use std::path::Path;
use thiserror::Error;

// Re-export the domain ModelState type
pub use wrenflow_domain::transcription::local::ModelState;

#[derive(Debug, Error)]
pub enum LocalTranscriptionError {
    #[error("Model not loaded")]
    ModelNotLoaded,
    #[error("Transcription failed: {0}")]
    TranscriptionFailed(String),
    #[error("Audio too short (minimum 1 second required)")]
    AudioTooShort,
}

/// Local transcription engine using parakeet-rs.
pub struct LocalTranscriptionEngine {
    state: ModelState,
    model: Option<parakeet_rs::Parakeet>,
}

impl LocalTranscriptionEngine {
    pub fn new() -> Self {
        Self {
            state: ModelState::NotLoaded,
            model: None,
        }
    }

    pub fn state(&self) -> &ModelState {
        &self.state
    }

    /// Initialize: load model from directory.
    pub fn initialize(
        &mut self,
        model_dir: &Path,
        on_state_change: Option<&dyn Fn(&ModelState)>,
    ) -> Result<(), LocalTranscriptionError> {
        if self.state.is_ready() || self.state.is_loading() {
            return Ok(());
        }

        self.state = ModelState::Compiling;
        if let Some(cb) = on_state_change {
            cb(&self.state);
        }

        match parakeet_rs::Parakeet::from_pretrained(model_dir, None) {
            Ok(model) => {
                self.model = Some(model);
                self.state = ModelState::Ready;
                if let Some(cb) = on_state_change {
                    cb(&self.state);
                }
                log::info!("Parakeet model loaded from {:?}", model_dir);
                Ok(())
            }
            Err(e) => {
                let msg = format!("Failed to load model: {e}");
                self.state = ModelState::Error(msg.clone());
                if let Some(cb) = on_state_change {
                    cb(&self.state);
                }
                Err(LocalTranscriptionError::TranscriptionFailed(msg))
            }
        }
    }

    /// Transcribe 16kHz mono f32 audio samples to text.
    pub fn transcribe(&mut self, samples: &[f32]) -> Result<String, LocalTranscriptionError> {
        let model = self.model.as_mut()
            .ok_or(LocalTranscriptionError::ModelNotLoaded)?;

        if samples.len() < 16000 {
            return Err(LocalTranscriptionError::AudioTooShort);
        }

        let result = model
            .transcribe_samples(samples.to_vec(), 16000, 1, None)
            .map_err(|e| LocalTranscriptionError::TranscriptionFailed(e.to_string()))?;

        Ok(result.text)
    }

    /// Transcribe from a WAV file path.
    pub fn transcribe_file(&mut self, path: &Path) -> Result<String, LocalTranscriptionError> {
        let model = self.model.as_mut()
            .ok_or(LocalTranscriptionError::ModelNotLoaded)?;

        let result = model
            .transcribe_file(path, None)
            .map_err(|e| LocalTranscriptionError::TranscriptionFailed(e.to_string()))?;

        Ok(result.text)
    }
}

impl Default for LocalTranscriptionEngine {
    fn default() -> Self {
        Self::new()
    }
}
