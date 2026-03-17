//! Simple linear-interpolation resampler.
//!
//! Converts mono f32 audio at an arbitrary input sample rate to 16 000 Hz
//! mono f32 -- matching what the Swift `AVAudioConverter` pipeline produces
//! before WAV encoding.
//!
//! Linear interpolation is adequate for speech (not music): Parakeet is
//! trained on 16 kHz data and is insensitive to the mild HF roll-off that
//! linear interpolation introduces when downsampling.

/// Resample `src` from `src_rate` Hz to `dst_rate` Hz (both must be > 0).
///
/// Returns a `Vec<f32>` containing the resampled mono samples.  If
/// `src_rate == dst_rate` the input is returned as-is (cloned).
pub fn resample(src: &[f32], src_rate: u32, dst_rate: u32) -> Vec<f32> {
    assert!(src_rate > 0, "src_rate must be > 0");
    assert!(dst_rate > 0, "dst_rate must be > 0");

    if src.is_empty() {
        return Vec::new();
    }
    if src_rate == dst_rate {
        return src.to_vec();
    }

    let ratio = src_rate as f64 / dst_rate as f64;
    // Number of output frames
    let out_len = ((src.len() as f64) / ratio).ceil() as usize;
    let mut dst = Vec::with_capacity(out_len);

    for i in 0..out_len {
        let src_pos = i as f64 * ratio;
        let idx = src_pos.floor() as usize;
        let frac = (src_pos - idx as f64) as f32;

        let s0 = src[idx];
        let s1 = if idx + 1 < src.len() {
            src[idx + 1]
        } else {
            src[idx] // hold last sample at boundary
        };

        dst.push(s0 + frac * (s1 - s0));
    }

    dst
}

/// Convenience wrapper: resample `src` at `src_rate` to 16 000 Hz.
pub fn resample_to_16khz(src: &[f32], src_rate: u32) -> Vec<f32> {
    resample(src, src_rate, 16_000)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn passthrough_same_rate() {
        let src: Vec<f32> = (0..100).map(|i| i as f32 * 0.01).collect();
        let dst = resample(&src, 16_000, 16_000);
        assert_eq!(dst.len(), src.len());
        for (a, b) in src.iter().zip(dst.iter()) {
            assert!((a - b).abs() < 1e-6, "passthrough mismatch");
        }
    }

    #[test]
    fn empty_input() {
        let dst = resample_to_16khz(&[], 44_100);
        assert!(dst.is_empty());
    }

    #[test]
    fn downsample_44100_to_16000_length() {
        // 1 second of audio at 44.1 kHz -> should produce ~16000 output frames
        let src = vec![0.5f32; 44_100];
        let dst = resample_to_16khz(&src, 44_100);
        // Allow +/-1 frame due to ceiling arithmetic
        assert!(
            (dst.len() as i64 - 16_000_i64).abs() <= 1,
            "expected ~16000 frames, got {}",
            dst.len()
        );
    }

    #[test]
    fn downsample_48000_to_16000_length() {
        let src = vec![0.5f32; 48_000];
        let dst = resample_to_16khz(&src, 48_000);
        assert!(
            (dst.len() as i64 - 16_000_i64).abs() <= 1,
            "expected ~16000 frames, got {}",
            dst.len()
        );
    }

    #[test]
    fn dc_signal_preserved() {
        // DC at 0.5 should remain 0.5 after resampling
        let src = vec![0.5f32; 44_100];
        let dst = resample_to_16khz(&src, 44_100);
        for (i, &v) in dst.iter().enumerate() {
            assert!(
                (v - 0.5f32).abs() < 1e-5,
                "DC not preserved at index {i}: got {v}"
            );
        }
    }

    #[test]
    fn linear_interpolation_midpoint() {
        // Two-sample input: [0.0, 1.0], upsample 1->2 (ratio=0.5)
        // out_len = ceil(2 / 0.5) = 4
        // positions: 0.0->0.0, 0.5->0.5, 1.0->1.0, 1.5->1.0 (hold)
        let src = vec![0.0f32, 1.0f32];
        let dst = resample(&src, 1, 2);
        assert_eq!(dst.len(), 4);
        assert!((dst[0] - 0.0).abs() < 1e-6);
        assert!((dst[1] - 0.5).abs() < 1e-6);
        assert!((dst[2] - 1.0).abs() < 1e-6);
        assert!((dst[3] - 1.0).abs() < 1e-6);
    }

    #[test]
    fn single_sample_input() {
        let src = vec![0.7f32];
        let dst = resample_to_16khz(&src, 44_100);
        // Should produce at least one output sample
        assert!(!dst.is_empty());
        // All values should equal the single input sample (held at boundary)
        for &v in &dst {
            assert!((v - 0.7f32).abs() < 1e-6, "unexpected value: {v}");
        }
    }
}
