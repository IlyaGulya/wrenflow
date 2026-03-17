//! Audio processing — ring buffer, resampling, WAV encoding, silence padding

pub mod ring_buffer;
pub mod resampler;
pub mod wav;
pub mod level;

pub use ring_buffer::SpscRingBuffer;
pub use resampler::resample_to_16khz;
pub use wav::{encode_wav, WavError};
pub use level::AudioLevel;

/// Minimum recording duration in seconds (Parakeet requirement).
pub const MIN_DURATION_SECS: f64 = 1.0;
/// Target output sample rate for transcription.
pub const TARGET_SAMPLE_RATE: u32 = 16_000;

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
}
