/// Metrics from a completed recording.
#[derive(Debug, Clone)]
pub struct RecordingMetrics {
    pub duration_ms: f64,
    pub file_size_bytes: u64,
    pub device_sample_rate: u32,
    pub buffer_count: u32,
    pub first_audio_ms: Option<f64>,
}

/// Result of a completed recording.
#[derive(Debug, Clone)]
pub struct RecordingResult {
    /// Resampled 16kHz mono f32 samples, ready for transcription.
    pub samples_16k: Vec<f32>,
    /// Path to WAV file (written in parallel for history/debugging).
    pub file_path: String,
    pub metrics: RecordingMetrics,
}
