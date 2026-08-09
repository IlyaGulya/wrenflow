//! Local Whisper transcription via direct ONNX Runtime sessions.
//!
//! This stays ONNX-first:
//! - audio is preprocessed locally into Whisper log-mel features
//! - encoder runs once
//! - decoder runs once for the prompt
//! - decoder-with-past runs token-by-token with KV-cache reuse

use ndarray::{Array2, Axis};
use ort::ep::{self, ExecutionProviderDispatch};
use ort::session::{builder::GraphOptimizationLevel, Session, SessionInputValue};
use ort::value::{DynValue, Tensor, TensorRef};
use realfft::num_complex::Complex32;
use realfft::RealFftPlanner;
use serde::Deserialize;
use std::collections::{HashMap, HashSet};
use std::f32::consts::PI;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use thiserror::Error;
use tokenizers::Tokenizer;

#[derive(Debug, Clone, Copy)]
enum SessionRole {
    Encoder,
    Decoder,
    DecoderWithPast,
}

#[derive(Debug, Error)]
pub enum WhisperTranscriptionError {
    #[error("Invalid Whisper model bundle: {0}")]
    InvalidModel(String),
    #[error("Failed to load Whisper config: {0}")]
    Config(String),
    #[error("Failed to initialize ONNX Runtime: {0}")]
    Ort(String),
    #[error("Failed to tokenize/decode text: {0}")]
    Tokenizer(String),
    #[error("Whisper preprocessing failed: {0}")]
    Audio(String),
    #[error("Whisper inference failed: {0}")]
    Inference(String),
}

#[derive(Debug, Deserialize)]
struct WhisperConfig {
    decoder_start_token_id: u32,
    eos_token_id: u32,
}

#[derive(Debug, Deserialize)]
struct WhisperGenerationConfig {
    begin_suppress_tokens: Vec<u32>,
    suppress_tokens: Vec<u32>,
    no_timestamps_token_id: u32,
    lang_to_id: HashMap<String, u32>,
    task_to_id: HashMap<String, u32>,
}

#[derive(Debug, Clone, Deserialize)]
struct WhisperPreprocessorConfig {
    sampling_rate: u32,
    feature_size: usize,
    hop_length: usize,
    n_fft: usize,
    n_samples: usize,
    nb_max_frames: usize,
}

struct WhisperFeatureExtractor {
    config: WhisperPreprocessorConfig,
    window: Vec<f32>,
    mel_filterbank: Array2<f32>,
    fft: Arc<dyn realfft::RealToComplex<f32>>,
    fft_input: Vec<f32>,
    fft_output: Vec<Complex32>,
    fft_scratch: Vec<Complex32>,
}

impl WhisperFeatureExtractor {
    fn new(config: &WhisperPreprocessorConfig) -> Self {
        let mut planner = RealFftPlanner::<f32>::new();
        let fft = planner.plan_fft_forward(config.n_fft);
        Self {
            config: config.clone(),
            window: periodic_hann_window(config.n_fft),
            mel_filterbank: create_mel_filterbank(
                config.n_fft,
                config.feature_size,
                config.sampling_rate as usize,
            ),
            fft_input: fft.make_input_vec(),
            fft_output: fft.make_output_vec(),
            fft_scratch: fft.make_scratch_vec(),
            fft,
        }
    }

    fn extract(&mut self, samples: &[f32]) -> Result<Array2<f32>, WhisperTranscriptionError> {
        if self.config.sampling_rate != 16_000 {
            return Err(WhisperTranscriptionError::Config(format!(
                "Unsupported Whisper sampling rate {}",
                self.config.sampling_rate
            )));
        }

        let audio = trim_to_max_samples(samples, self.config.n_samples);
        let spectrogram = self.stft_power_spectrogram(&audio)?;
        let mel_spectrogram = self.mel_filterbank.dot(&spectrogram);

        let mut log_spec = mel_spectrogram.mapv(|x| x.max(1e-10).log10());
        let max_value = log_spec.iter().copied().fold(f32::NEG_INFINITY, f32::max);
        let clamp_floor = max_value - 8.0;
        log_spec.mapv_inplace(|x| x.max(clamp_floor));
        log_spec.mapv_inplace(|x| (x + 4.0) / 4.0);
        let normalized_floor = (clamp_floor + 4.0) / 4.0;

        let current_frames = log_spec.shape()[1];
        if current_frames >= self.config.nb_max_frames {
            return Ok(log_spec
                .slice(ndarray::s![.., 0..self.config.nb_max_frames])
                .to_owned());
        }

        let mut padded = Array2::<f32>::from_elem(
            (self.config.feature_size, self.config.nb_max_frames),
            normalized_floor,
        );
        padded
            .slice_mut(ndarray::s![.., 0..current_frames])
            .assign(&log_spec);
        Ok(padded)
    }

    fn stft_power_spectrogram(
        &mut self,
        audio: &[f32],
    ) -> Result<Array2<f32>, WhisperTranscriptionError> {
        if audio.is_empty() {
            return Err(WhisperTranscriptionError::Audio(
                "Cannot compute spectrogram for empty audio".to_string(),
            ));
        }

        let padded = reflect_pad(audio, self.config.n_fft / 2);
        let frames = (padded.len().saturating_sub(self.config.n_fft)) / self.config.hop_length + 1;
        let freq_bins = self.config.n_fft / 2 + 1;
        let mut spectrogram = Array2::<f32>::zeros((freq_bins, frames.saturating_sub(1)));

        for frame_idx in 0..frames.saturating_sub(1) {
            let start = frame_idx * self.config.hop_length;
            self.fft_input.fill(0.0);
            for i in 0..self.config.n_fft {
                self.fft_input[i] = padded[start + i] * self.window[i];
            }

            self.fft
                .process_with_scratch(
                    &mut self.fft_input,
                    &mut self.fft_output,
                    &mut self.fft_scratch,
                )
                .map_err(|e| WhisperTranscriptionError::Audio(format!("FFT failed: {e}")))?;

            for (bin_idx, bin) in self.fft_output.iter().enumerate() {
                spectrogram[[bin_idx, frame_idx]] = bin.norm_sqr();
            }
        }

        Ok(spectrogram)
    }
}

struct LanguageDetectionResult {
    language_token_id: u32,
    no_speech_probability: f32,
}

struct WhisperStageTimings {
    feature_ms: f64,
    encoder_ms: f64,
    detect_ms: f64,
    prompt_ms: f64,
    decode_ms: f64,
    total_ms: f64,
    token_count: usize,
}

impl WhisperStageTimings {
    fn log_if_enabled(&self, phase: &str) {
        if std::env::var_os("WRENFLOW_WHISPER_TRACE_TIMINGS").is_none() {
            return;
        }

        log::info!(
            "Whisper {phase}: feature={:.1}ms encoder={:.1}ms detect={:.1}ms prompt={:.1}ms decode={:.1}ms total={:.1}ms tokens={}",
            self.feature_ms,
            self.encoder_ms,
            self.detect_ms,
            self.prompt_ms,
            self.decode_ms,
            self.total_ms,
            self.token_count,
        );
    }
}

struct DecoderCache {
    static_tensors: HashMap<String, DynValue>,
    dynamic_tensors: HashMap<String, DynValue>,
    cache_position: DynValue,
}

impl DecoderCache {
    fn from_prompt_outputs(
        outputs: HashMap<String, DynValue>,
        prompt_len: usize,
    ) -> Result<Self, WhisperTranscriptionError> {
        let mut static_tensors = HashMap::new();
        let mut dynamic_tensors = HashMap::new();

        for (name, value) in outputs {
            if name.contains(".encoder.") {
                static_tensors.insert(name, value);
            } else {
                dynamic_tensors.insert(name, value);
            }
        }

        Ok(Self {
            static_tensors,
            dynamic_tensors,
            cache_position: owned_i64_tensor(&[prompt_len as i64])?,
        })
    }

    fn get(&self, name: &str) -> Option<&DynValue> {
        match name {
            "cache_position" => Some(&self.cache_position),
            _ => self
                .dynamic_tensors
                .get(name)
                .or_else(|| self.static_tensors.get(name)),
        }
    }

    fn apply_decoder_outputs(
        &mut self,
        outputs: HashMap<String, DynValue>,
    ) -> Result<(), WhisperTranscriptionError> {
        self.dynamic_tensors = outputs;
        self.cache_position = advanced_cache_position(Some(&self.cache_position))?;
        Ok(())
    }
}

pub struct WhisperTranscriptionEngine {
    config: WhisperConfig,
    generation_config: WhisperGenerationConfig,
    preprocessor_config: WhisperPreprocessorConfig,
    tokenizer: Tokenizer,
    feature_extractor: WhisperFeatureExtractor,
    encoder_session: Session,
    decoder_session: Session,
    decoder_with_past_session: Session,
    suppressed_tokens: HashSet<u32>,
    begin_suppressed_tokens: HashSet<u32>,
    language_token_ids: Vec<u32>,
    no_speech_token_id: u32,
    transcribe_token_id: u32,
    profiling_enabled: bool,
    profiling_finished: bool,
}

impl WhisperTranscriptionEngine {
    pub fn from_model_dir(model_dir: &Path) -> Result<Self, WhisperTranscriptionError> {
        let config = read_json::<WhisperConfig>(&model_dir.join("config.json"))?;
        let generation_config =
            read_json::<WhisperGenerationConfig>(&model_dir.join("generation_config.json"))?;
        let preprocessor_config =
            read_json::<WhisperPreprocessorConfig>(&model_dir.join("preprocessor_config.json"))?;
        let tokenizer = Tokenizer::from_file(model_dir.join("tokenizer.json"))
            .map_err(|e| WhisperTranscriptionError::Tokenizer(e.to_string()))?;
        let feature_extractor = WhisperFeatureExtractor::new(&preprocessor_config);

        let transcribe_token_id = generation_config
            .task_to_id
            .get("transcribe")
            .copied()
            .ok_or_else(|| {
                WhisperTranscriptionError::Config(
                    "generation_config.json is missing task_to_id.transcribe".to_string(),
                )
            })?;
        let no_speech_token_id = generation_config.no_timestamps_token_id.saturating_sub(1);

        let encoder_session = create_session(
            &model_dir.join("onnx/encoder_model_int8.onnx"),
            SessionRole::Encoder,
        )?;
        let decoder_session = create_session(
            &model_dir.join("onnx/decoder_model_int8.onnx"),
            SessionRole::Decoder,
        )?;
        let decoder_with_past_session = create_session(
            &model_dir.join("onnx/decoder_with_past_model_int8.onnx"),
            SessionRole::DecoderWithPast,
        )?;
        let suppressed_tokens = generation_config.suppress_tokens.iter().copied().collect();
        let begin_suppressed_tokens = generation_config
            .begin_suppress_tokens
            .iter()
            .copied()
            .collect();
        let language_token_ids = generation_config.lang_to_id.values().copied().collect();

        Ok(Self {
            config,
            generation_config,
            preprocessor_config,
            tokenizer,
            feature_extractor,
            encoder_session,
            decoder_session,
            decoder_with_past_session,
            suppressed_tokens,
            begin_suppressed_tokens,
            language_token_ids,
            no_speech_token_id,
            transcribe_token_id,
            profiling_enabled: whisper_ort_profiling_dir().is_some(),
            profiling_finished: false,
        })
    }

    pub fn prewarm(&mut self) -> Result<(), WhisperTranscriptionError> {
        let total_started = std::time::Instant::now();
        let silence = vec![0.0f32; self.preprocessor_config.sampling_rate as usize];
        let feature_started = std::time::Instant::now();
        let features = self.feature_extractor.extract(&silence)?;
        let feature_ms = feature_started.elapsed().as_secs_f64() * 1000.0;
        let encoder_started = std::time::Instant::now();
        let encoder_hidden_states = self.run_encoder(&features)?;
        let encoder_ms = encoder_started.elapsed().as_secs_f64() * 1000.0;
        let detect_started = std::time::Instant::now();
        let detection = self.detect_language(&encoder_hidden_states)?;
        let detect_ms = detect_started.elapsed().as_secs_f64() * 1000.0;

        let language_token_id = self
            .forced_language_token_id()?
            .unwrap_or(detection.language_token_id);
        let prompt = [
            self.config.decoder_start_token_id,
            language_token_id,
            self.transcribe_token_id,
            self.generation_config.no_timestamps_token_id,
        ];
        let prompt_started = std::time::Instant::now();
        let (logits, mut cache) = self.run_decoder_prompt(&encoder_hidden_states, &prompt)?;
        let prompt_ms = prompt_started.elapsed().as_secs_f64() * 1000.0;
        let next_token = select_token_from_logits(
            &logits,
            &self.suppressed_tokens,
            Some(&self.begin_suppressed_tokens),
            self.generation_config
                .no_timestamps_token_id
                .saturating_add(1),
        )?;
        let decode_started = std::time::Instant::now();
        let _ = self.run_decoder_with_past(&encoder_hidden_states, &mut cache, next_token)?;
        let decode_ms = decode_started.elapsed().as_secs_f64() * 1000.0;
        WhisperStageTimings {
            feature_ms,
            encoder_ms,
            detect_ms,
            prompt_ms,
            decode_ms,
            total_ms: total_started.elapsed().as_secs_f64() * 1000.0,
            token_count: 1,
        }
        .log_if_enabled("prewarm");
        Ok(())
    }

    pub fn transcribe(
        &mut self,
        samples: &[f32],
        custom_vocabulary: Option<&str>,
    ) -> Result<String, WhisperTranscriptionError> {
        let total_started = std::time::Instant::now();
        let feature_started = std::time::Instant::now();
        let features = self.feature_extractor.extract(samples)?;
        let feature_ms = feature_started.elapsed().as_secs_f64() * 1000.0;
        let encoder_started = std::time::Instant::now();
        let encoder_hidden_states = self.run_encoder(&features)?;
        let encoder_ms = encoder_started.elapsed().as_secs_f64() * 1000.0;
        let detect_started = std::time::Instant::now();
        let detection = self.detect_language(&encoder_hidden_states)?;
        let detect_ms = detect_started.elapsed().as_secs_f64() * 1000.0;
        if detection.no_speech_probability >= 0.6 {
            WhisperStageTimings {
                feature_ms,
                encoder_ms,
                detect_ms,
                prompt_ms: 0.0,
                decode_ms: 0.0,
                total_ms: total_started.elapsed().as_secs_f64() * 1000.0,
                token_count: 0,
            }
            .log_if_enabled("transcribe");
            self.finish_profiling_if_enabled();
            return Ok(String::new());
        }

        let language_token_id = self
            .forced_language_token_id()?
            .unwrap_or(detection.language_token_id);
        let mut prompt = vec![
            self.config.decoder_start_token_id,
            language_token_id,
            self.transcribe_token_id,
            self.generation_config.no_timestamps_token_id,
        ];
        prompt.extend(self.custom_vocabulary_prompt_tokens(custom_vocabulary)?);
        let prompt_started = std::time::Instant::now();
        let (mut logits, mut cache) = self.run_decoder_prompt(&encoder_hidden_states, &prompt)?;
        let prompt_ms = prompt_started.elapsed().as_secs_f64() * 1000.0;

        let mut generated_tokens = Vec::new();
        let max_steps = 448usize.saturating_sub(prompt.len());
        let timestamp_begin = self
            .generation_config
            .no_timestamps_token_id
            .saturating_add(1);
        let decode_started = std::time::Instant::now();

        for step in 0..max_steps {
            let next_token = select_token_from_logits(
                &logits,
                &self.suppressed_tokens,
                if step == 0 {
                    Some(&self.begin_suppressed_tokens)
                } else {
                    None
                },
                timestamp_begin,
            )?;

            if next_token == self.config.eos_token_id {
                break;
            }

            generated_tokens.push(next_token);
            logits = self.run_decoder_with_past(&encoder_hidden_states, &mut cache, next_token)?;
        }
        let decode_ms = decode_started.elapsed().as_secs_f64() * 1000.0;

        let text = self
            .tokenizer
            .decode(&generated_tokens, true)
            .map_err(|e| WhisperTranscriptionError::Tokenizer(e.to_string()))?;
        WhisperStageTimings {
            feature_ms,
            encoder_ms,
            detect_ms,
            prompt_ms,
            decode_ms,
            total_ms: total_started.elapsed().as_secs_f64() * 1000.0,
            token_count: generated_tokens.len(),
        }
        .log_if_enabled("transcribe");
        self.finish_profiling_if_enabled();
        Ok(text.trim().to_string())
    }

    fn finish_profiling_if_enabled(&mut self) {
        if !self.profiling_enabled || self.profiling_finished {
            return;
        }

        self.profiling_finished = true;
        for (role, session) in [
            ("encoder", &mut self.encoder_session),
            ("decoder", &mut self.decoder_session),
            ("decoder_with_past", &mut self.decoder_with_past_session),
        ] {
            match session.end_profiling() {
                Ok(path) => log::info!("Whisper ORT profile ({role}) saved to {path}"),
                Err(error) => {
                    log::warn!("Failed to finalize Whisper ORT profile ({role}): {error}")
                }
            }
        }
    }

    fn forced_language_token_id(&self) -> Result<Option<u32>, WhisperTranscriptionError> {
        let Some(raw) = std::env::var_os("WRENFLOW_WHISPER_FORCE_LANGUAGE") else {
            return Ok(None);
        };

        let raw = raw.to_string_lossy();
        let normalized = if raw.starts_with("<|") && raw.ends_with("|>") {
            raw.to_string()
        } else {
            format!("<|{}|>", raw.trim().to_ascii_lowercase())
        };

        self.generation_config
            .lang_to_id
            .get(&normalized)
            .copied()
            .ok_or_else(|| {
                WhisperTranscriptionError::Config(format!(
                    "Unsupported WRENFLOW_WHISPER_FORCE_LANGUAGE={raw:?}"
                ))
            })
            .map(Some)
    }

    fn custom_vocabulary_prompt_tokens(
        &self,
        custom_vocabulary: Option<&str>,
    ) -> Result<Vec<u32>, WhisperTranscriptionError> {
        let prompt_enabled = std::env::var_os("WRENFLOW_WHISPER_ENABLE_INITIAL_PROMPT").is_some();
        if !prompt_enabled {
            return Ok(Vec::new());
        }

        let custom_vocabulary = custom_vocabulary
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToOwned::to_owned)
            .or_else(|| {
                std::env::var("WRENFLOW_WHISPER_CUSTOM_VOCAB")
                    .ok()
                    .map(|value| value.trim().to_string())
                    .filter(|value| !value.is_empty())
            });

        let Some(custom_vocabulary) = custom_vocabulary else {
            return Ok(Vec::new());
        };

        let normalized = custom_vocabulary
            .lines()
            .flat_map(|line| line.split([',', ';']))
            .map(str::trim)
            .filter(|term| !term.is_empty())
            .take(4)
            .collect::<Vec<_>>()
            .join(", ");

        if normalized.is_empty() {
            return Ok(Vec::new());
        }

        let encoding = self
            .tokenizer
            .encode(normalized, false)
            .map_err(|e| WhisperTranscriptionError::Tokenizer(e.to_string()))?;

        Ok(encoding.get_ids().iter().copied().take(16).collect())
    }

    fn run_encoder(
        &mut self,
        features: &Array2<f32>,
    ) -> Result<DynValue, WhisperTranscriptionError> {
        let input_features = TensorRef::from_array_view(features.view().insert_axis(Axis(0)))
            .map_err(|e| WhisperTranscriptionError::Ort(e.to_string()))?;

        let mut inputs: Vec<(String, SessionInputValue<'_>)> = Vec::new();
        for input in self.encoder_session.inputs() {
            match input.name() {
                "input_features" => {
                    inputs.push((input.name().to_string(), input_features.view().into()))
                }
                other => {
                    return Err(WhisperTranscriptionError::InvalidModel(format!(
                        "Unexpected encoder input '{other}'"
                    )));
                }
            }
        }

        let mut outputs = self
            .encoder_session
            .run(inputs)
            .map_err(|e| WhisperTranscriptionError::Inference(e.to_string()))?;

        if let Some(value) = outputs.remove("last_hidden_state") {
            return Ok(value);
        }

        outputs
            .into_iter()
            .next()
            .map(|(_, value)| value)
            .ok_or_else(|| {
                WhisperTranscriptionError::InvalidModel("Encoder produced no outputs".to_string())
            })
    }

    fn detect_language(
        &mut self,
        encoder_hidden_states: &DynValue,
    ) -> Result<LanguageDetectionResult, WhisperTranscriptionError> {
        let decoder_input_ids = ndarray::arr2(&[[self.config.decoder_start_token_id as i64]]);
        let input_ids = TensorRef::from_array_view(decoder_input_ids.view())
            .map_err(|e| WhisperTranscriptionError::Ort(e.to_string()))?;

        let mut inputs: Vec<(String, SessionInputValue<'_>)> = Vec::new();
        for input in self.decoder_session.inputs() {
            match input.name() {
                "input_ids" => inputs.push((input.name().to_string(), input_ids.view().into())),
                "encoder_hidden_states" => inputs.push((
                    input.name().to_string(),
                    encoder_hidden_states.view().into(),
                )),
                other => {
                    return Err(WhisperTranscriptionError::InvalidModel(format!(
                        "Unexpected decoder input '{other}' during language detection"
                    )));
                }
            }
        }

        let outputs = self
            .decoder_session
            .run(inputs)
            .map_err(|e| WhisperTranscriptionError::Inference(e.to_string()))?;
        let logits = outputs.get("logits").ok_or_else(|| {
            WhisperTranscriptionError::InvalidModel(
                "Decoder did not return logits during language detection".to_string(),
            )
        })?;

        let logits = logits
            .try_extract_array::<f32>()
            .map_err(|e| WhisperTranscriptionError::Inference(e.to_string()))?;
        if logits.ndim() != 3 || logits.shape()[0] != 1 || logits.shape()[1] == 0 {
            return Err(WhisperTranscriptionError::InvalidModel(format!(
                "Unexpected logits shape for language detection: {:?}",
                logits.shape()
            )));
        }

        let time_index = logits.shape()[1] - 1;
        let batch_logits = logits.index_axis(Axis(0), 0);
        let last_token_logits = batch_logits.index_axis(Axis(0), time_index);

        let no_speech_probability =
            softmax_probability(&last_token_logits, self.no_speech_token_id as usize);
        let mut best: Option<(u32, f32)> = None;
        for language_token_id in &self.language_token_ids {
            let idx = *language_token_id as usize;
            if idx >= last_token_logits.len() {
                continue;
            }
            let score = last_token_logits[idx];
            match best {
                Some((_, best_score)) if score <= best_score => {}
                _ => best = Some((*language_token_id, score)),
            }
        }

        let language_token_id = best.map(|(token, _)| token).ok_or_else(|| {
            WhisperTranscriptionError::InvalidModel(
                "No valid language tokens found in generation_config.json".to_string(),
            )
        })?;

        Ok(LanguageDetectionResult {
            language_token_id,
            no_speech_probability,
        })
    }

    fn run_decoder_prompt(
        &mut self,
        encoder_hidden_states: &DynValue,
        prompt: &[u32],
    ) -> Result<(DynValue, DecoderCache), WhisperTranscriptionError> {
        let prompt_ids = Array2::from_shape_vec(
            (1, prompt.len()),
            prompt.iter().map(|token| i64::from(*token)).collect(),
        )
        .map_err(|e| WhisperTranscriptionError::Inference(e.to_string()))?;
        let input_ids = TensorRef::from_array_view(prompt_ids.view())
            .map_err(|e| WhisperTranscriptionError::Ort(e.to_string()))?;

        let mut inputs: Vec<(String, SessionInputValue<'_>)> = Vec::new();
        for input in self.decoder_session.inputs() {
            match input.name() {
                "input_ids" => inputs.push((input.name().to_string(), input_ids.view().into())),
                "encoder_hidden_states" => inputs.push((
                    input.name().to_string(),
                    encoder_hidden_states.view().into(),
                )),
                other => {
                    return Err(WhisperTranscriptionError::InvalidModel(format!(
                        "Unexpected decoder input '{other}'"
                    )));
                }
            }
        }

        let outputs = self
            .decoder_session
            .run(inputs)
            .map_err(|e| WhisperTranscriptionError::Inference(e.to_string()))?;
        let (logits, cache_outputs) = split_outputs(&outputs)?;
        Ok((
            logits,
            DecoderCache::from_prompt_outputs(cache_outputs, prompt.len())?,
        ))
    }

    fn run_decoder_with_past(
        &mut self,
        encoder_hidden_states: &DynValue,
        cache: &mut DecoderCache,
        next_token: u32,
    ) -> Result<DynValue, WhisperTranscriptionError> {
        let next_input_ids = ndarray::arr2(&[[i64::from(next_token)]]);
        let input_ids = TensorRef::from_array_view(next_input_ids.view())
            .map_err(|e| WhisperTranscriptionError::Ort(e.to_string()))?;

        let mut inputs: Vec<(String, SessionInputValue<'_>)> = Vec::new();
        for input in self.decoder_with_past_session.inputs() {
            if input.name() == "input_ids" {
                inputs.push((input.name().to_string(), input_ids.view().into()));
                continue;
            }

            if input.name() == "encoder_hidden_states" {
                inputs.push((
                    input.name().to_string(),
                    encoder_hidden_states.view().into(),
                ));
                continue;
            }

            if input.name() == "cache_position" {
                let cache_position = cache.get("cache_position").ok_or_else(|| {
                    WhisperTranscriptionError::InvalidModel(
                        "Missing cache position tensor for decoder step".to_string(),
                    )
                })?;
                inputs.push((input.name().to_string(), cache_position.view().into()));
                continue;
            }

            let cached_value = cache.get(input.name()).ok_or_else(|| {
                WhisperTranscriptionError::InvalidModel(format!(
                    "Missing cache tensor for decoder input '{}'",
                    input.name()
                ))
            })?;
            inputs.push((input.name().to_string(), cached_value.view().into()));
        }

        let outputs = self
            .decoder_with_past_session
            .run(inputs)
            .map_err(|e| WhisperTranscriptionError::Inference(e.to_string()))?;
        let (logits, new_present_cache) = split_outputs(&outputs)?;
        cache.apply_decoder_outputs(new_present_cache)?;
        Ok(logits)
    }
}

fn create_session(
    model_path: &Path,
    role: SessionRole,
) -> Result<Session, WhisperTranscriptionError> {
    let threads = whisper_ort_threads(role);
    let optimization_level = whisper_ort_optimization_level(role);

    let builder = Session::builder().map_err(|e| WhisperTranscriptionError::Ort(e.to_string()))?;
    #[cfg(target_vendor = "apple")]
    let builder = builder
        .with_execution_providers(coreml_execution_providers(model_path))
        .map_err(|e| WhisperTranscriptionError::Ort(e.to_string()))?;
    let builder = builder
        .with_optimization_level(optimization_level)
        .map_err(|e| WhisperTranscriptionError::Ort(e.to_string()))?;
    let builder = builder
        .with_intra_threads(threads)
        .map_err(|e| WhisperTranscriptionError::Ort(e.to_string()))?;
    let builder = builder
        .with_inter_threads(whisper_ort_inter_threads())
        .map_err(|e| WhisperTranscriptionError::Ort(e.to_string()))?;
    let builder = builder
        .with_parallel_execution(whisper_ort_parallel_execution())
        .map_err(|e| WhisperTranscriptionError::Ort(e.to_string()))?;
    let builder = builder
        .with_memory_pattern(whisper_ort_memory_pattern_enabled())
        .map_err(|e| WhisperTranscriptionError::Ort(e.to_string()))?;
    let mut builder = if let Some(profile_path) = whisper_ort_profile_path(model_path, role) {
        builder
            .with_profiling(profile_path)
            .map_err(|e| WhisperTranscriptionError::Ort(e.to_string()))?
    } else {
        builder
    };

    builder
        .commit_from_file(model_path)
        .map_err(|e| WhisperTranscriptionError::Ort(e.to_string()))
}

fn whisper_ort_optimization_level(role: SessionRole) -> GraphOptimizationLevel {
    let role_specific_env = match role {
        SessionRole::Encoder => "WRENFLOW_WHISPER_ENCODER_ORT_OPT_LEVEL",
        SessionRole::Decoder => "WRENFLOW_WHISPER_DECODER_ORT_OPT_LEVEL",
        SessionRole::DecoderWithPast => "WRENFLOW_WHISPER_DECODER_WITH_PAST_ORT_OPT_LEVEL",
    };

    let configured = std::env::var(role_specific_env)
        .ok()
        .or_else(|| std::env::var("WRENFLOW_WHISPER_ORT_OPT_LEVEL").ok());

    match configured
        .map(|value| value.to_ascii_lowercase())
        .as_deref()
    {
        Some("basic") | Some("1") => GraphOptimizationLevel::Level1,
        Some("extended") | Some("2") => GraphOptimizationLevel::Level2,
        Some("disable") | Some("disabled") | Some("0") => GraphOptimizationLevel::Disable,
        _ => GraphOptimizationLevel::All,
    }
}

fn whisper_ort_threads(role: SessionRole) -> usize {
    let role_specific_env = match role {
        SessionRole::Encoder => "WRENFLOW_WHISPER_ENCODER_ORT_THREADS",
        SessionRole::Decoder => "WRENFLOW_WHISPER_DECODER_ORT_THREADS",
        SessionRole::DecoderWithPast => "WRENFLOW_WHISPER_DECODER_WITH_PAST_ORT_THREADS",
    };

    if let Some(value) = std::env::var_os(role_specific_env) {
        if let Ok(parsed) = value.to_string_lossy().parse::<usize>() {
            return parsed.max(1);
        }
    }

    if let Some(value) = std::env::var_os("WRENFLOW_WHISPER_ORT_THREADS") {
        if let Ok(parsed) = value.to_string_lossy().parse::<usize>() {
            return parsed.max(1);
        }
    }

    std::thread::available_parallelism()
        .map(|parallelism| parallelism.get().min(8))
        .unwrap_or(1)
}

fn whisper_ort_inter_threads() -> usize {
    std::env::var("WRENFLOW_WHISPER_INTER_ORT_THREADS")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .map(|threads| threads.max(1))
        .unwrap_or(1)
}

fn whisper_ort_parallel_execution() -> bool {
    matches!(
        std::env::var("WRENFLOW_WHISPER_PARALLEL_EXECUTION")
            .ok()
            .as_deref()
            .map(str::to_ascii_lowercase)
            .as_deref(),
        Some("1") | Some("true") | Some("yes") | Some("on")
    )
}

fn whisper_ort_memory_pattern_enabled() -> bool {
    !matches!(
        std::env::var("WRENFLOW_WHISPER_DISABLE_MEMORY_PATTERN")
            .ok()
            .as_deref()
            .map(str::to_ascii_lowercase)
            .as_deref(),
        Some("1") | Some("true") | Some("yes") | Some("on")
    )
}

fn whisper_ort_profiling_dir() -> Option<PathBuf> {
    let raw = std::env::var_os("WRENFLOW_WHISPER_ORT_PROFILE_DIR")?;
    let dir = PathBuf::from(raw);
    std::fs::create_dir_all(&dir).ok()?;
    Some(dir)
}

fn whisper_ort_profile_path(model_path: &Path, role: SessionRole) -> Option<PathBuf> {
    let dir = whisper_ort_profiling_dir()?;
    let stem = model_path.file_stem()?.to_string_lossy();
    let role = match role {
        SessionRole::Encoder => "encoder",
        SessionRole::Decoder => "decoder",
        SessionRole::DecoderWithPast => "decoder_with_past",
    };
    Some(dir.join(format!("{role}-{stem}.json")))
}

#[cfg(target_vendor = "apple")]
fn coreml_execution_providers(model_path: &Path) -> Vec<ExecutionProviderDispatch> {
    if std::env::var_os("WRENFLOW_WHISPER_ENABLE_COREML_EP").is_none() {
        return vec![];
    }

    let mut provider = ep::CoreML::default()
        .with_model_format(ep::coreml::ModelFormat::MLProgram)
        .with_compute_units(ep::coreml::ComputeUnits::CPUAndNeuralEngine)
        .with_specialization_strategy(ep::coreml::SpecializationStrategy::FastPrediction);

    if let Some(cache_dir) = coreml_model_cache_dir(model_path) {
        provider = provider.with_model_cache_dir(cache_dir.to_string_lossy().to_string());
    }

    vec![provider.build()]
}

#[cfg(target_vendor = "apple")]
fn coreml_model_cache_dir(model_path: &Path) -> Option<std::path::PathBuf> {
    let cache_dir = model_path.parent()?.join(".ort-coreml-cache");
    std::fs::create_dir_all(&cache_dir).ok()?;
    Some(cache_dir)
}

fn read_json<T: for<'de> Deserialize<'de>>(path: &Path) -> Result<T, WhisperTranscriptionError> {
    let contents = std::fs::read_to_string(path)
        .map_err(|e| WhisperTranscriptionError::Config(format!("{}: {e}", path.display())))?;
    serde_json::from_str::<T>(&contents)
        .map_err(|e| WhisperTranscriptionError::Config(format!("{}: {e}", path.display())))
}

fn split_outputs(
    outputs: &ort::session::SessionOutputs<'_>,
) -> Result<(DynValue, HashMap<String, DynValue>), WhisperTranscriptionError> {
    let mut logits = None;
    let mut cache = HashMap::new();

    for key in outputs.keys() {
        let value = outputs.get(key).ok_or_else(|| {
            WhisperTranscriptionError::InvalidModel(format!("Missing output value for key '{key}'"))
        })?;
        let value = value.view().try_upgrade().map_err(|_| {
            WhisperTranscriptionError::Inference(format!("Failed to retain output tensor '{key}'"))
        })?;

        if key == "logits" {
            logits = Some(value);
        } else {
            cache.insert(normalize_cache_name(key), value);
        }
    }

    let logits = logits.ok_or_else(|| {
        WhisperTranscriptionError::InvalidModel("Decoder pass did not return logits".to_string())
    })?;

    Ok((logits, cache))
}

fn owned_i64_tensor(values: &[i64]) -> Result<DynValue, WhisperTranscriptionError> {
    let tensor =
        Tensor::<i64>::from_array((vec![values.len()], values.to_vec().into_boxed_slice()))
            .map_err(|e| WhisperTranscriptionError::Ort(e.to_string()))?;
    Ok(tensor.into_dyn())
}

fn read_i64_tensor_scalar(value: &DynValue) -> Result<i64, WhisperTranscriptionError> {
    let array = value
        .try_extract_array::<i64>()
        .map_err(|e| WhisperTranscriptionError::Inference(e.to_string()))?;
    array
        .iter()
        .next()
        .copied()
        .ok_or_else(|| WhisperTranscriptionError::InvalidModel("Empty i64 tensor".to_string()))
}

fn advanced_cache_position(
    current: Option<&DynValue>,
) -> Result<DynValue, WhisperTranscriptionError> {
    let current = current.ok_or_else(|| {
        WhisperTranscriptionError::InvalidModel("Missing cache_position state".to_string())
    })?;
    let next = read_i64_tensor_scalar(current)? + 1;
    owned_i64_tensor(&[next])
}

fn normalize_cache_name(name: &str) -> String {
    if let Some(rest) = name.strip_prefix("present.") {
        format!("past_key_values.{rest}")
    } else {
        name.to_string()
    }
}

fn softmax_probability<D: ndarray::Dimension>(
    logits: &ndarray::ArrayBase<ndarray::ViewRepr<&f32>, D>,
    index: usize,
) -> f32 {
    if index >= logits.len() {
        return 0.0;
    }

    let max_logit = logits.iter().copied().fold(f32::NEG_INFINITY, f32::max);
    let denominator = logits
        .iter()
        .map(|logit| (*logit - max_logit).exp())
        .sum::<f32>();

    if denominator <= 0.0 {
        0.0
    } else {
        let target_logit = logits
            .iter()
            .nth(index)
            .copied()
            .unwrap_or(f32::NEG_INFINITY);
        (target_logit - max_logit).exp() / denominator
    }
}

fn select_token_from_logits(
    logits: &DynValue,
    suppressed_tokens: &HashSet<u32>,
    extra_suppressed_tokens: Option<&HashSet<u32>>,
    timestamp_begin: u32,
) -> Result<u32, WhisperTranscriptionError> {
    let logits = logits
        .try_extract_array::<f32>()
        .map_err(|e| WhisperTranscriptionError::Inference(e.to_string()))?;
    if logits.ndim() != 3 || logits.shape()[0] != 1 || logits.shape()[1] == 0 {
        return Err(WhisperTranscriptionError::InvalidModel(format!(
            "Unexpected logits shape: {:?}",
            logits.shape()
        )));
    }

    let time_index = logits.shape()[1] - 1;
    let batch_logits = logits.index_axis(Axis(0), 0);
    let last_token_logits = batch_logits.index_axis(Axis(0), time_index);

    let mut best: Option<(u32, f32)> = None;
    for (token_idx, score) in last_token_logits.iter().enumerate() {
        let token_id = token_idx as u32;
        if token_id >= timestamp_begin
            || suppressed_tokens.contains(&token_id)
            || extra_suppressed_tokens.is_some_and(|tokens| tokens.contains(&token_id))
        {
            continue;
        }

        match best {
            Some((_, best_score)) if *score <= best_score => {}
            _ => best = Some((token_id, *score)),
        }
    }

    best.map(|(token_id, _)| token_id).ok_or_else(|| {
        WhisperTranscriptionError::Inference(
            "Decoder logits did not contain any valid next token".to_string(),
        )
    })
}

fn trim_to_max_samples(samples: &[f32], target_len: usize) -> Vec<f32> {
    if samples.len() > target_len {
        samples[..target_len].to_vec()
    } else {
        samples.to_vec()
    }
}

fn reflect_pad(input: &[f32], pad: usize) -> Vec<f32> {
    let mut padded = Vec::with_capacity(input.len() + pad * 2);
    for idx in 0..pad {
        padded.push(input[reflect_index(-(pad as isize) + idx as isize, input.len())]);
    }
    padded.extend_from_slice(input);
    for idx in 0..pad {
        padded.push(input[reflect_index(input.len() as isize + idx as isize, input.len())]);
    }
    padded
}

fn reflect_index(mut idx: isize, len: usize) -> usize {
    let len = len as isize;
    while idx < 0 || idx >= len {
        if idx < 0 {
            idx = -idx;
        }
        if idx >= len {
            idx = 2 * len - idx - 2;
        }
    }
    idx as usize
}

fn periodic_hann_window(window_length: usize) -> Vec<f32> {
    (0..window_length)
        .map(|i| 0.5 - 0.5 * ((2.0 * PI * i as f32) / window_length as f32).cos())
        .collect()
}

const F_SP: f64 = 200.0 / 3.0;
const MIN_LOG_HZ: f64 = 1000.0;
const MIN_LOG_MEL: f64 = MIN_LOG_HZ / F_SP;
const LOG_STEP: f64 = 0.068_751_777_420_949_12;

fn hz_to_mel_slaney(hz: f64) -> f64 {
    if hz < MIN_LOG_HZ {
        hz / F_SP
    } else {
        MIN_LOG_MEL + (hz / MIN_LOG_HZ).ln() / LOG_STEP
    }
}

fn mel_to_hz_slaney(mel: f64) -> f64 {
    if mel < MIN_LOG_MEL {
        mel * F_SP
    } else {
        MIN_LOG_HZ * ((mel - MIN_LOG_MEL) * LOG_STEP).exp()
    }
}

fn create_mel_filterbank(n_fft: usize, n_mels: usize, sample_rate: usize) -> Array2<f32> {
    let freq_bins = n_fft / 2 + 1;
    let mut filterbank = Array2::<f32>::zeros((n_mels, freq_bins));
    let fmax = sample_rate as f64 / 2.0;
    let mel_min = hz_to_mel_slaney(0.0);
    let mel_max = hz_to_mel_slaney(fmax);

    let mel_points: Vec<f64> = (0..=n_mels + 1)
        .map(|i| mel_to_hz_slaney(mel_min + (mel_max - mel_min) * i as f64 / (n_mels + 1) as f64))
        .collect();
    let fft_freqs: Vec<f64> = (0..freq_bins)
        .map(|i| i as f64 * sample_rate as f64 / n_fft as f64)
        .collect();
    let fdiff: Vec<f64> = mel_points.windows(2).map(|w| w[1] - w[0]).collect();

    for mel_idx in 0..n_mels {
        for (bin_idx, &freq) in fft_freqs.iter().enumerate() {
            let lower = (freq - mel_points[mel_idx]) / fdiff[mel_idx];
            let upper = (mel_points[mel_idx + 2] - freq) / fdiff[mel_idx + 1];
            filterbank[[mel_idx, bin_idx]] = lower.min(upper).max(0.0) as f32;
        }
    }

    for mel_idx in 0..n_mels {
        let enorm = 2.0 / (mel_points[mel_idx + 2] - mel_points[mel_idx]);
        for bin_idx in 0..freq_bins {
            filterbank[[mel_idx, bin_idx]] *= enorm as f32;
        }
    }

    filterbank
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model_downloader;
    use std::path::PathBuf;
    use std::process::Command;
    use std::sync::atomic::AtomicBool;
    use std::sync::Arc;
    use std::time::Instant;
    use tempfile::tempdir;
    use tokio::runtime::Builder;
    use wrenflow_domain::model_management::{
        DownloadProgress, LocalModelState, ModelDownloadListener, ModelInfo, ModelRuntime,
    };

    struct NoopListener;

    impl ModelDownloadListener for NoopListener {
        fn on_progress(&self, _progress: DownloadProgress) {}

        fn on_state_changed(&self, _state: LocalModelState) {}
    }

    fn tiny_whisper_model() -> ModelInfo {
        ModelInfo {
            id: "whisper-tiny-onnx".to_string(),
            name: "Whisper Tiny".to_string(),
            repo_id: "onnx-community/whisper-tiny-ONNX".to_string(),
            directory_name: "whisper-tiny".to_string(),
            expected_files: vec![
                "config.json".to_string(),
                "generation_config.json".to_string(),
                "preprocessor_config.json".to_string(),
                "tokenizer.json".to_string(),
                "tokenizer_config.json".to_string(),
                "special_tokens_map.json".to_string(),
                "added_tokens.json".to_string(),
                "merges.txt".to_string(),
                "normalizer.json".to_string(),
                "vocab.json".to_string(),
                "onnx/encoder_model_int8.onnx".to_string(),
                "onnx/decoder_model_int8.onnx".to_string(),
                "onnx/decoder_with_past_model_int8.onnx".to_string(),
            ],
            generated_files: vec![],
            runtime: ModelRuntime::WhisperOnnx,
        }
    }

    fn repo_root() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../..")
            .canonicalize()
            .expect("resolve repo root")
    }

    #[test]
    fn cache_position_advances_between_decoder_steps() {
        let start = owned_i64_tensor(&[4]).expect("create cache position tensor");
        let next = advanced_cache_position(Some(&start)).expect("advance cache position");
        assert_eq!(
            read_i64_tensor_scalar(&next).expect("read advanced cache position"),
            5
        );
    }

    #[test]
    fn decoder_cache_keeps_static_encoder_tensors() {
        let mut cache = DecoderCache::from_prompt_outputs(
            HashMap::from([
                (
                    "past_key_values.0.encoder.key".to_string(),
                    owned_i64_tensor(&[1]).expect("encoder tensor"),
                ),
                (
                    "past_key_values.0.decoder.key".to_string(),
                    owned_i64_tensor(&[2]).expect("decoder tensor"),
                ),
            ]),
            4,
        )
        .expect("create decoder cache");

        cache
            .apply_decoder_outputs(HashMap::from([(
                "past_key_values.0.decoder.key".to_string(),
                owned_i64_tensor(&[3]).expect("updated decoder tensor"),
            )]))
            .expect("update decoder cache");

        assert_eq!(
            read_i64_tensor_scalar(
                cache
                    .get("past_key_values.0.encoder.key")
                    .expect("static encoder tensor"),
            )
            .expect("read encoder tensor"),
            1
        );
        assert_eq!(
            read_i64_tensor_scalar(
                cache
                    .get("past_key_values.0.decoder.key")
                    .expect("dynamic decoder tensor"),
            )
            .expect("read decoder tensor"),
            3
        );
        assert_eq!(
            read_i64_tensor_scalar(cache.get("cache_position").expect("cache position"))
                .expect("read cache position"),
            5
        );
    }

    #[test]
    fn short_audio_preprocessing_no_longer_expands_to_full_window() {
        let one_second = vec![0.0f32; 16_000];
        let trimmed = trim_to_max_samples(&one_second, 480_000);
        assert_eq!(trimmed.len(), one_second.len());

        let overlong = vec![0.0f32; 500_000];
        let trimmed = trim_to_max_samples(&overlong, 480_000);
        assert_eq!(trimmed.len(), 480_000);
    }

    #[test]
    #[cfg(target_os = "macos")]
    #[ignore = "manual smoke test; downloads a real model and loads local ONNX Runtime"]
    fn whisper_tiny_smoke_transcribes_silence() {
        let ort_dylib = repo_root().join("vendor/onnxruntime/lib/libonnxruntime.dylib");
        assert!(
            ort_dylib.exists(),
            "missing ONNX Runtime dylib at {}",
            ort_dylib.display()
        );
        let _ = ort::init_from(&ort_dylib)
            .expect("load ONNX Runtime")
            .commit();

        let temp_dir = tempdir().expect("temp dir");
        let runtime = Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("tokio runtime");

        runtime.block_on(async {
            model_downloader::download_model(
                &tiny_whisper_model(),
                temp_dir.path(),
                Arc::new(NoopListener),
                Arc::new(AtomicBool::new(false)),
            )
            .await
            .expect("download tiny whisper");
        });

        let mut engine =
            WhisperTranscriptionEngine::from_model_dir(temp_dir.path()).expect("load engine");
        engine.prewarm().expect("prewarm tiny whisper");
        let text = engine
            .transcribe(&vec![0.0f32; 16_000], None)
            .expect("transcribe silence");

        println!("whisper tiny silence transcript: {text:?}");
    }

    #[test]
    #[cfg(target_os = "macos")]
    #[ignore = "manual diagnostic for timing the locally installed Whisper ONNX bundle"]
    fn debug_local_whisper_stage_timings() {
        let ort_dylib = repo_root().join("vendor/onnxruntime/lib/libonnxruntime.dylib");
        let _ = ort::init_from(&ort_dylib)
            .expect("load ONNX Runtime")
            .commit();

        let home = PathBuf::from(std::env::var("HOME").expect("HOME"));
        let model_dir =
            home.join("Library/Application Support/Wrenflow/models/whisper-large-v3-turbo");
        let recording = home
            .join("Library/Application Support/Wrenflow/recordings/recording_1778849124906.ogg");

        let decoded = Command::new("ffmpeg")
            .args([
                "-v",
                "error",
                "-i",
                recording.to_str().expect("utf8 path"),
                "-f",
                "f32le",
                "-ac",
                "1",
                "-ar",
                "16000",
                "pipe:1",
            ])
            .output()
            .expect("run ffmpeg");
        assert!(
            decoded.status.success(),
            "ffmpeg failed: {:?}",
            decoded.status
        );
        let samples: Vec<f32> = decoded
            .stdout
            .chunks_exact(std::mem::size_of::<f32>())
            .map(|chunk| f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]))
            .collect();

        let mut engine =
            WhisperTranscriptionEngine::from_model_dir(&model_dir).expect("load whisper engine");

        let started = Instant::now();
        let features = engine
            .feature_extractor
            .extract(&samples)
            .expect("extract features");
        let feature_elapsed = started.elapsed();

        let started = Instant::now();
        let encoder_hidden_states = engine.run_encoder(&features).expect("run encoder");
        let encoder_elapsed = started.elapsed();

        let started = Instant::now();
        let detection = engine
            .detect_language(&encoder_hidden_states)
            .expect("detect language");
        let detect_elapsed = started.elapsed();

        let prompt = vec![
            engine.config.decoder_start_token_id,
            detection.language_token_id,
            engine.transcribe_token_id,
            engine.generation_config.no_timestamps_token_id,
        ];

        let started = Instant::now();
        let (mut logits, mut cache) = engine
            .run_decoder_prompt(&encoder_hidden_states, &prompt)
            .expect("run prompt decoder");
        let prompt_elapsed = started.elapsed();

        let timestamp_begin = engine
            .generation_config
            .no_timestamps_token_id
            .saturating_add(1);
        let mut generated_tokens = Vec::new();
        let mut decode_time = std::time::Duration::ZERO;

        for step in 0..448usize.saturating_sub(prompt.len()) {
            let next_token = select_token_from_logits(
                &logits,
                &engine.suppressed_tokens,
                if step == 0 {
                    Some(&engine.begin_suppressed_tokens)
                } else {
                    None
                },
                timestamp_begin,
            )
            .expect("select next token");

            if next_token == engine.config.eos_token_id {
                break;
            }

            generated_tokens.push(next_token);
            let started = Instant::now();
            logits = engine
                .run_decoder_with_past(&encoder_hidden_states, &mut cache, next_token)
                .expect("run decoder with past");
            decode_time += started.elapsed();
        }

        let transcript = engine
            .tokenizer
            .decode(&generated_tokens, true)
            .expect("decode tokens");

        eprintln!(
            "whisper diagnostic => frames={}, no_speech={:.3}, feature={:?}, encoder={:?}, detect={:?}, prompt={:?}, decode={:?}, tokens={}, total={:?}",
            features.shape()[1],
            detection.no_speech_probability,
            feature_elapsed,
            encoder_elapsed,
            detect_elapsed,
            prompt_elapsed,
            decode_time,
            generated_tokens.len(),
            feature_elapsed + encoder_elapsed + detect_elapsed + prompt_elapsed + decode_time
        );
        eprintln!("whisper diagnostic transcript => {}", transcript.trim());
    }
}
