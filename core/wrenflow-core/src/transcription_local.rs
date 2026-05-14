//! Local transcription engine dispatching to the selected ONNX runtime.

use crate::transcription_whisper::WhisperTranscriptionEngine;
use parakeet_rs::Transcriber;
use std::path::Path;
use thiserror::Error;
use wrenflow_domain::model_management::{ModelInfo, ModelRuntime};

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

enum LocalBackend {
    Parakeet(parakeet_rs::ParakeetTDT),
    Whisper(WhisperTranscriptionEngine),
}

pub struct LocalTranscriptionEngine {
    model_id: String,
    model_display_name: String,
    runtime: ModelRuntime,
    state: ModelState,
    backend: Option<LocalBackend>,
}

impl LocalTranscriptionEngine {
    pub fn new(model: &ModelInfo) -> Self {
        Self {
            model_id: model.id.clone(),
            model_display_name: model.name.clone(),
            runtime: model.runtime,
            state: ModelState::NotLoaded,
            backend: None,
        }
    }

    pub fn state(&self) -> &ModelState {
        &self.state
    }

    pub fn model_id(&self) -> &str {
        &self.model_id
    }

    pub fn model_display_name(&self) -> &str {
        &self.model_display_name
    }

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

        let backend = match self.runtime {
            ModelRuntime::ParakeetOnnx => {
                let model = parakeet_rs::ParakeetTDT::from_pretrained(model_dir, None)
                    .map_err(|e| LocalTranscriptionError::TranscriptionFailed(e.to_string()))?;
                LocalBackend::Parakeet(model)
            }
            ModelRuntime::WhisperOnnx => {
                let engine = WhisperTranscriptionEngine::from_model_dir(model_dir)
                    .map_err(|e| LocalTranscriptionError::TranscriptionFailed(e.to_string()))?;
                LocalBackend::Whisper(engine)
            }
        };

        self.backend = Some(backend);
        self.state = ModelState::Ready;
        if let Some(cb) = on_state_change {
            cb(&self.state);
        }
        log::info!("Local model loaded from {:?}", model_dir);
        Ok(())
    }

    pub fn prewarm(&mut self) -> Result<(), LocalTranscriptionError> {
        let start = std::time::Instant::now();
        match self
            .backend
            .as_mut()
            .ok_or(LocalTranscriptionError::ModelNotLoaded)?
        {
            LocalBackend::Parakeet(model) => {
                let silence = vec![0.0f32; 16_000];
                let _ = model.transcribe_samples(silence, 16_000, 1, None);
            }
            LocalBackend::Whisper(engine) => {
                engine
                    .prewarm()
                    .map_err(|e| LocalTranscriptionError::TranscriptionFailed(e.to_string()))?;
            }
        }
        log::info!("Local model prewarmed in {:?}", start.elapsed());
        Ok(())
    }

    pub fn transcribe(&mut self, samples: &[f32]) -> Result<String, LocalTranscriptionError> {
        if samples.len() < 16_000 {
            return Err(LocalTranscriptionError::AudioTooShort);
        }

        match self
            .backend
            .as_mut()
            .ok_or(LocalTranscriptionError::ModelNotLoaded)?
        {
            LocalBackend::Parakeet(model) => model
                .transcribe_samples(samples.to_vec(), 16_000, 1, None)
                .map(|result| result.text)
                .map_err(|e| LocalTranscriptionError::TranscriptionFailed(e.to_string())),
            LocalBackend::Whisper(engine) => engine
                .transcribe(samples)
                .map_err(|e| LocalTranscriptionError::TranscriptionFailed(e.to_string())),
        }
    }

    pub fn transcribe_file(&mut self, path: &Path) -> Result<String, LocalTranscriptionError> {
        match self
            .backend
            .as_mut()
            .ok_or(LocalTranscriptionError::ModelNotLoaded)?
        {
            LocalBackend::Parakeet(model) => model
                .transcribe_file(path, None)
                .map(|result| result.text)
                .map_err(|e| LocalTranscriptionError::TranscriptionFailed(e.to_string())),
            LocalBackend::Whisper(_) => Err(LocalTranscriptionError::TranscriptionFailed(
                "Whisper file transcription path is not used in Wrenflow".to_string(),
            )),
        }
    }
}
