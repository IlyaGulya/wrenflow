//! Real-time audio level computation.
//!
//! Mirrors the smoothing logic in the Swift `drainRingBuffer` / `computeAudioLevel`
//! methods:
//!   - RMS of the incoming chunk
//!   - Scaled by 10x and clamped to [0, 1]
//!   - Asymmetric exponential smoothing:
//!     rise  (scaled > smoothed): `new = old * 0.3 + scaled * 0.7`
//!     fall  (scaled <= smoothed): `new = old * 0.6 + scaled * 0.4`

/// Stateful audio-level smoother.
///
/// All methods take `&mut self` -- not `&self` -- so there is no need for
/// atomics; the caller is expected to access this from a single thread
/// (the drain / consumer thread).
#[derive(Debug, Clone)]
pub struct AudioLevel {
    /// Current smoothed level in [0.0, 1.0].
    smoothed: f32,
}

impl Default for AudioLevel {
    fn default() -> Self {
        Self { smoothed: 0.0 }
    }
}

impl AudioLevel {
    /// Create a new level meter starting at 0.
    pub fn new() -> Self {
        Self::default()
    }

    /// Feed a chunk of f32 samples and return the updated level in [0.0, 1.0].
    pub fn process(&mut self, samples: &[f32]) -> f32 {
        if samples.is_empty() {
            return self.smoothed;
        }

        let rms = compute_rms(samples);
        let scaled = (rms * 10.0).min(1.0);

        if scaled > self.smoothed {
            self.smoothed = self.smoothed * 0.3 + scaled * 0.7;
        } else {
            self.smoothed = self.smoothed * 0.6 + scaled * 0.4;
        }

        self.smoothed
    }

    /// Reset the smoothed level to zero (e.g., after recording stops).
    pub fn reset(&mut self) {
        self.smoothed = 0.0;
    }

    /// Current smoothed level without feeding new samples.
    pub fn current(&self) -> f32 {
        self.smoothed
    }
}

/// Compute the root-mean-square of a slice of f32 samples.
fn compute_rms(samples: &[f32]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    let sum_sq: f32 = samples.iter().map(|&s| s * s).sum();
    (sum_sq / samples.len() as f32).sqrt()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rms_silence() {
        let samples = vec![0.0f32; 100];
        assert_eq!(compute_rms(&samples), 0.0);
    }

    #[test]
    fn rms_dc() {
        // All samples = 0.5 -> RMS = 0.5
        let samples = vec![0.5f32; 1000];
        let rms = compute_rms(&samples);
        assert!((rms - 0.5).abs() < 1e-5, "expected 0.5, got {rms}");
    }

    #[test]
    fn rms_full_scale_sine() {
        // A full-scale sine wave has RMS = 1/sqrt(2) ~ 0.7071
        let n = 44_100usize;
        let samples: Vec<f32> = (0..n)
            .map(|i| (2.0 * std::f64::consts::PI * 440.0 * i as f64 / 44_100.0).sin() as f32)
            .collect();
        let rms = compute_rms(&samples);
        let expected = 1.0f32 / 2.0f32.sqrt();
        assert!(
            (rms - expected).abs() < 0.001,
            "RMS of sine: expected {expected:.4}, got {rms:.4}"
        );
    }

    #[test]
    fn level_rises_fast_falls_slow() {
        let mut lv = AudioLevel::new();

        // Loud burst: scaled = 1.0 -> rises quickly
        let loud = vec![0.1f32; 1000]; // rms=0.1, scaled=1.0
        let after_loud = lv.process(&loud);
        // After one frame: 0.0 * 0.3 + 1.0 * 0.7 = 0.7
        assert!((after_loud - 0.7).abs() < 0.001, "rise: expected 0.7, got {after_loud}");

        // Silence: scaled = 0.0 -> falls slowly
        let silence = vec![0.0f32; 1000];
        let after_silence = lv.process(&silence);
        // 0.7 * 0.6 + 0.0 * 0.4 = 0.42
        assert!(
            (after_silence - 0.42).abs() < 0.001,
            "fall: expected 0.42, got {after_silence}"
        );
    }

    #[test]
    fn level_clamped_at_one() {
        let mut lv = AudioLevel::new();
        // Very loud signal (rms > 0.1 -> scaled = 1.0)
        let loud = vec![1.0f32; 1000];
        let v = lv.process(&loud);
        assert!(v <= 1.0, "level must not exceed 1.0, got {v}");
    }

    #[test]
    fn reset_returns_to_zero() {
        let mut lv = AudioLevel::new();
        let loud = vec![1.0f32; 100];
        lv.process(&loud);
        assert!(lv.current() > 0.0);
        lv.reset();
        assert_eq!(lv.current(), 0.0);
    }

    #[test]
    fn empty_slice_no_change() {
        let mut lv = AudioLevel::new();
        let loud = vec![0.5f32; 100];
        let v1 = lv.process(&loud);
        let v2 = lv.process(&[]);
        assert_eq!(v1, v2, "empty slice should not change the level");
    }
}
