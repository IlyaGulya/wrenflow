//! Local Whisper transcription via direct ONNX Runtime sessions.
//!
//! This stays ONNX-first:
//! - audio is preprocessed locally into Whisper log-mel features
//! - encoder runs once
//! - decoder runs once for the prompt
//! - decoder-with-past runs token-by-token with KV-cache reuse

use ndarray::{Array2, Axis};
use ort::session::{builder::GraphOptimizationLevel, Session, SessionInputValue};
use ort::value::{DynValue, TensorRef};
use realfft::RealFftPlanner;
use serde::Deserialize;
use std::collections::{HashMap, HashSet};
use std::f32::consts::PI;
use std::path::Path;
use thiserror::Error;
use tokenizers::Tokenizer;

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

#[derive(Debug, Deserialize)]
struct WhisperPreprocessorConfig {
    sampling_rate: u32,
    feature_size: usize,
    hop_length: usize,
    n_fft: usize,
    n_samples: usize,
    nb_max_frames: usize,
}

struct LanguageDetectionResult {
    language_token_id: u32,
    no_speech_probability: f32,
}

pub struct WhisperTranscriptionEngine {
    config: WhisperConfig,
    generation_config: WhisperGenerationConfig,
    preprocessor_config: WhisperPreprocessorConfig,
    tokenizer: Tokenizer,
    encoder_session: Session,
    decoder_session: Session,
    decoder_with_past_session: Session,
    suppressed_tokens: HashSet<u32>,
    begin_suppressed_tokens: HashSet<u32>,
    language_token_ids: Vec<u32>,
    no_speech_token_id: u32,
    transcribe_token_id: u32,
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

        let encoder_session = create_session(&model_dir.join("onnx/encoder_model_int8.onnx"))?;
        let decoder_session = create_session(&model_dir.join("onnx/decoder_model_int8.onnx"))?;
        let decoder_with_past_session =
            create_session(&model_dir.join("onnx/decoder_with_past_model_int8.onnx"))?;
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
            encoder_session,
            decoder_session,
            decoder_with_past_session,
            suppressed_tokens,
            begin_suppressed_tokens,
            language_token_ids,
            no_speech_token_id,
            transcribe_token_id,
        })
    }

    pub fn prewarm(&mut self) -> Result<(), WhisperTranscriptionError> {
        let silence = vec![0.0f32; self.preprocessor_config.sampling_rate as usize];
        let features = extract_log_mel_features(&silence, &self.preprocessor_config)?;
        let encoder_hidden_states = self.run_encoder(&features)?;
        let detection = self.detect_language(&encoder_hidden_states)?;

        let prompt = [
            self.config.decoder_start_token_id,
            detection.language_token_id,
            self.transcribe_token_id,
            self.generation_config.no_timestamps_token_id,
        ];
        let _ = self.run_decoder_prompt(&encoder_hidden_states, &prompt)?;
        Ok(())
    }

    pub fn transcribe(&mut self, samples: &[f32]) -> Result<String, WhisperTranscriptionError> {
        let features = extract_log_mel_features(samples, &self.preprocessor_config)?;
        let encoder_hidden_states = self.run_encoder(&features)?;
        let detection = self.detect_language(&encoder_hidden_states)?;
        if detection.no_speech_probability >= 0.6 {
            return Ok(String::new());
        }

        let prompt = vec![
            self.config.decoder_start_token_id,
            detection.language_token_id,
            self.transcribe_token_id,
            self.generation_config.no_timestamps_token_id,
        ];
        let (mut logits, mut cache) = self.run_decoder_prompt(&encoder_hidden_states, &prompt)?;

        let mut generated_tokens = Vec::new();
        let max_steps = 448usize.saturating_sub(prompt.len());
        let timestamp_begin = self
            .generation_config
            .no_timestamps_token_id
            .saturating_add(1);

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
            let (next_logits, next_cache) =
                self.run_decoder_with_past(&encoder_hidden_states, &cache, next_token)?;
            logits = next_logits;
            cache = next_cache;
        }

        self.tokenizer
            .decode(&generated_tokens, true)
            .map(|text| text.trim().to_string())
            .map_err(|e| WhisperTranscriptionError::Tokenizer(e.to_string()))
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
    ) -> Result<(DynValue, HashMap<String, DynValue>), WhisperTranscriptionError> {
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
        let (logits, cache) = split_outputs(&outputs)?;

        Ok((logits, cache))
    }

    fn run_decoder_with_past(
        &mut self,
        encoder_hidden_states: &DynValue,
        cache: &HashMap<String, DynValue>,
        next_token: u32,
    ) -> Result<(DynValue, HashMap<String, DynValue>), WhisperTranscriptionError> {
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

        let mut next_cache = HashMap::with_capacity(cache.len());
        for (name, value) in cache {
            next_cache.insert(
                name.clone(),
                value.view().try_upgrade().map_err(|_| {
                    WhisperTranscriptionError::Inference(
                        "Failed to retain decoder cache between steps".to_string(),
                    )
                })?,
            );
        }
        next_cache.extend(new_present_cache);

        Ok((logits, next_cache))
    }
}

fn create_session(model_path: &Path) -> Result<Session, WhisperTranscriptionError> {
    let threads = std::thread::available_parallelism()
        .map(|parallelism| parallelism.get())
        .unwrap_or(1);

    let builder = Session::builder().map_err(|e| WhisperTranscriptionError::Ort(e.to_string()))?;
    let builder = builder
        .with_optimization_level(GraphOptimizationLevel::All)
        .map_err(|e| WhisperTranscriptionError::Ort(e.to_string()))?;
    let builder = builder
        .with_intra_threads(threads)
        .map_err(|e| WhisperTranscriptionError::Ort(e.to_string()))?;
    let builder = builder
        .with_inter_threads(1)
        .map_err(|e| WhisperTranscriptionError::Ort(e.to_string()))?;
    let builder = builder
        .with_parallel_execution(false)
        .map_err(|e| WhisperTranscriptionError::Ort(e.to_string()))?;
    let mut builder = builder
        .with_memory_pattern(true)
        .map_err(|e| WhisperTranscriptionError::Ort(e.to_string()))?;

    builder
        .commit_from_file(model_path)
        .map_err(|e| WhisperTranscriptionError::Ort(e.to_string()))
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

fn extract_log_mel_features(
    samples: &[f32],
    config: &WhisperPreprocessorConfig,
) -> Result<Array2<f32>, WhisperTranscriptionError> {
    if config.sampling_rate != 16_000 {
        return Err(WhisperTranscriptionError::Config(format!(
            "Unsupported Whisper sampling rate {}",
            config.sampling_rate
        )));
    }

    let audio = pad_or_trim(samples, config.n_samples);
    let spectrogram = stft_power_spectrogram(&audio, config.n_fft, config.hop_length)?;
    let mel_filterbank = create_mel_filterbank(
        config.n_fft,
        config.feature_size,
        config.sampling_rate as usize,
    );
    let mel_spectrogram = mel_filterbank.dot(&spectrogram);

    let mut log_spec = mel_spectrogram.mapv(|x| x.max(1e-10).log10());
    let max_value = log_spec.iter().copied().fold(f32::NEG_INFINITY, f32::max);
    let clamp_floor = max_value - 8.0;
    log_spec.mapv_inplace(|x| x.max(clamp_floor));
    log_spec.mapv_inplace(|x| (x + 4.0) / 4.0);

    let frames = config.nb_max_frames.min(log_spec.shape()[1]);
    Ok(log_spec.slice(ndarray::s![.., 0..frames]).to_owned())
}

fn pad_or_trim(samples: &[f32], target_len: usize) -> Vec<f32> {
    let mut result = if samples.len() > target_len {
        samples[..target_len].to_vec()
    } else {
        samples.to_vec()
    };

    if result.len() < target_len {
        result.resize(target_len, 0.0);
    }

    result
}

fn stft_power_spectrogram(
    audio: &[f32],
    n_fft: usize,
    hop_length: usize,
) -> Result<Array2<f32>, WhisperTranscriptionError> {
    if audio.is_empty() {
        return Err(WhisperTranscriptionError::Audio(
            "Cannot compute spectrogram for empty audio".to_string(),
        ));
    }

    let padded = reflect_pad(audio, n_fft / 2);
    let window = periodic_hann_window(n_fft);
    let frames = (padded.len().saturating_sub(n_fft)) / hop_length + 1;
    let freq_bins = n_fft / 2 + 1;
    let mut spectrogram = Array2::<f32>::zeros((freq_bins, frames.saturating_sub(1)));

    let mut planner = RealFftPlanner::<f32>::new();
    let fft = planner.plan_fft_forward(n_fft);
    let mut input = vec![0.0f32; n_fft];
    let mut output = fft.make_output_vec();
    let mut scratch = fft.make_scratch_vec();

    for frame_idx in 0..frames.saturating_sub(1) {
        let start = frame_idx * hop_length;
        input.fill(0.0);
        for i in 0..n_fft {
            input[i] = padded[start + i] * window[i];
        }

        fft.process_with_scratch(&mut input, &mut output, &mut scratch)
            .map_err(|e| WhisperTranscriptionError::Audio(format!("FFT failed: {e}")))?;

        for (bin_idx, bin) in output.iter().enumerate() {
            spectrogram[[bin_idx, frame_idx]] = bin.norm_sqr();
        }
    }

    Ok(spectrogram)
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
    use std::sync::atomic::AtomicBool;
    use std::sync::Arc;
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
            .transcribe(&vec![0.0f32; 16_000])
            .expect("transcribe silence");

        println!("whisper tiny silence transcript: {text:?}");
    }
}
