//! Audio processing — ring buffer, resampling, WAV encoding, silence padding

pub mod device;
pub mod level;
pub mod recording;
pub mod resampler;
pub mod ring_buffer;
pub mod wav;

pub use device::AudioDeviceInfo;
pub use level::AudioLevel;
pub use recording::{RecordingMetrics, RecordingResult};
pub use resampler::resample_to_16khz;
pub use ring_buffer::SpscRingBuffer;
pub use wav::{encode_wav, WavError};

/// Minimum recording duration in seconds (Parakeet requirement).
pub const MIN_DURATION_SECS: f64 = 1.0;
/// Target output sample rate for transcription.
pub const TARGET_SAMPLE_RATE: u32 = 16_000;
const DEFAULT_TRIM_WINDOW_MS: u32 = 20;
const DEFAULT_TRIM_PADDING_MS: u32 = 120;
const DEFAULT_TRIM_RMS_THRESHOLD: f32 = 0.0025;

/// Pad a slice of 16kHz mono f32 samples with trailing silence to reach
/// at least `min_secs` of audio. Returns the padded Vec (or the original
/// samples unchanged if already long enough).
pub fn pad_to_minimum_duration(samples: &[f32], sample_rate: u32, min_secs: f64) -> Vec<f32> {
    let min_frames = (sample_rate as f64 * min_secs).ceil() as usize;
    if samples.len() >= min_frames {
        return samples.to_vec();
    }
    let mut out = Vec::with_capacity(min_frames);
    out.extend_from_slice(samples);
    out.resize(min_frames, 0.0f32);
    out
}

/// Trim leading and trailing silence using windowed RMS with safety padding.
///
/// Returns an empty vector when no speech-like window crosses `rms_threshold`.
pub fn trim_silence_with_rms_padding(
    samples: &[f32],
    sample_rate: u32,
    window_ms: u32,
    padding_ms: u32,
    rms_threshold: f32,
) -> Vec<f32> {
    if samples.is_empty() || sample_rate == 0 {
        return Vec::new();
    }

    let window = ((sample_rate as u64 * window_ms.max(1) as u64) / 1000)
        .max(1)
        .min(usize::MAX as u64) as usize;
    let padding = ((sample_rate as u64 * padding_ms as u64) / 1000).min(usize::MAX as u64) as usize;

    let mut first_non_silent_start = None;
    let mut last_non_silent_end = None;

    for start in (0..samples.len()).step_by(window) {
        let end = (start + window).min(samples.len());
        if rms(&samples[start..end]) >= rms_threshold {
            first_non_silent_start.get_or_insert(start);
            last_non_silent_end = Some(end);
        }
    }

    let (first_non_silent_start, last_non_silent_end) =
        match (first_non_silent_start, last_non_silent_end) {
            (Some(start), Some(end)) => (start, end),
            _ => return Vec::new(),
        };

    let trim_start = first_non_silent_start.saturating_sub(padding);
    let trim_end = (last_non_silent_end + padding).min(samples.len());
    samples[trim_start..trim_end].to_vec()
}

/// Conservative trim path used before local Whisper inference.
///
/// This removes obvious leading/trailing silence, including the artificial
/// trailing pad we add for other models, while preserving a small safety margin.
pub fn trim_for_whisper_dictation(samples: &[f32], sample_rate: u32) -> Vec<f32> {
    trim_silence_with_rms_padding(
        samples,
        sample_rate,
        DEFAULT_TRIM_WINDOW_MS,
        DEFAULT_TRIM_PADDING_MS,
        DEFAULT_TRIM_RMS_THRESHOLD,
    )
}

fn rms(samples: &[f32]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }

    let sum_sq: f32 = samples.iter().map(|sample| sample * sample).sum();
    (sum_sq / samples.len() as f32).sqrt()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pad_short_recording_to_one_second() {
        // 0.5 seconds at 16 kHz -> 8000 samples
        let samples = vec![0.5f32; 8_000];
        let padded = pad_to_minimum_duration(&samples, 16_000, 1.0);
        assert_eq!(padded.len(), 16_000);
        // Original samples preserved
        for (i, &v) in padded[..8_000].iter().enumerate() {
            assert_eq!(v, 0.5f32, "original sample {i} changed");
        }
        // Padding is silence
        for (i, &v) in padded[8_000..].iter().enumerate() {
            assert_eq!(v, 0.0f32, "padding sample {i} is not zero");
        }
    }

    #[test]
    fn no_pad_when_already_long_enough() {
        let samples = vec![0.3f32; 16_000];
        let result = pad_to_minimum_duration(&samples, 16_000, 1.0);
        assert_eq!(result.len(), 16_000);
    }

    #[test]
    fn no_pad_when_longer_than_minimum() {
        let samples = vec![0.1f32; 32_000];
        let result = pad_to_minimum_duration(&samples, 16_000, 1.0);
        assert_eq!(result.len(), 32_000);
    }

    #[test]
    fn pad_empty_recording() {
        let result = pad_to_minimum_duration(&[], 16_000, 1.0);
        assert_eq!(result.len(), 16_000);
        assert!(result.iter().all(|&v| v == 0.0));
    }

    #[test]
    fn pad_uses_given_sample_rate() {
        // 0.5 s at 44.1 kHz
        let samples = vec![0.0f32; 22_050];
        let result = pad_to_minimum_duration(&samples, 44_100, 1.0);
        assert_eq!(result.len(), 44_100);
    }

    #[test]
    fn trim_silence_drops_leading_and_trailing_padding() {
        let leading = vec![0.0f32; 4_000];
        let speech = vec![0.05f32; 8_000];
        let trailing = vec![0.0f32; 12_000];
        let mut samples = Vec::new();
        samples.extend_from_slice(&leading);
        samples.extend_from_slice(&speech);
        samples.extend_from_slice(&trailing);

        let trimmed = trim_for_whisper_dictation(&samples, 16_000);

        assert!(trimmed.len() < samples.len());
        assert!(trimmed.len() > speech.len());
        assert!(trimmed.iter().any(|sample| sample.abs() >= 0.05f32));
    }

    #[test]
    fn trim_silence_returns_empty_for_silence_only() {
        let samples = vec![0.0f32; 16_000];
        let trimmed = trim_for_whisper_dictation(&samples, 16_000);
        assert!(trimmed.is_empty());
    }

    #[test]
    fn trim_silence_keeps_short_burst_with_padding() {
        let mut samples = vec![0.0f32; 16_000];
        for sample in &mut samples[7_800..8_200] {
            *sample = 0.08f32;
        }

        let trimmed = trim_for_whisper_dictation(&samples, 16_000);

        assert!(!trimmed.is_empty());
        assert!(trimmed.len() < samples.len());
        assert!(trimmed.len() >= 3_000);
    }
}
