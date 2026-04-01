//! Audio capture using cpal.
//!
//! Provides device enumeration, low-latency recording via a ring buffer,
//! background drain thread with resampling to 16 kHz, audio level metering,
//! and WAV file output.

use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{Device, SampleFormat, StreamConfig};

use wrenflow_domain::audio::{
    pad_to_minimum_duration, AudioDeviceInfo, AudioLevel, RecordingMetrics, RecordingResult,
    SpscRingBuffer, TARGET_SAMPLE_RATE,
};
use wrenflow_domain::audio::resampler::resample_to_16khz;

// ---------------------------------------------------------------------------
// Listener trait
// ---------------------------------------------------------------------------

/// Callback interface for recording events.
pub trait AudioCaptureListener: Send + Sync {
    /// Called periodically (~50 Hz) with the current smoothed audio level in [0, 1].
    fn on_audio_level(&self, level: f32);
    /// Called once when the first non-silent audio chunk is detected.
    fn on_recording_ready(&self);
    /// Called when an error occurs during recording.
    fn on_error(&self, message: String);
}

// ---------------------------------------------------------------------------
// Send wrapper for cpal::Stream
// ---------------------------------------------------------------------------

/// Wrapper that makes `cpal::Stream` `Send`.
///
/// `cpal::Stream` on macOS (CoreAudio) is `!Send` because it holds a
/// `PhantomData<*mut ()>` marker.  In practice the stream is created on one
/// thread and dropped on the same (or another) thread while protected by a
/// `Mutex`.  The audio callback itself runs on a dedicated CoreAudio thread
/// regardless. This wrapper is safe because:
///   1. We never concurrently access the inner Stream from multiple threads
///      (Mutex provides exclusion).
///   2. The only operation on the stored Stream is `drop`.
#[allow(dead_code)]
struct SendStream(cpal::Stream);

// SAFETY: see above — the Stream is only dropped behind a Mutex.
unsafe impl Send for SendStream {}

// ---------------------------------------------------------------------------
// Send wrapper for cpal::Device
// ---------------------------------------------------------------------------

/// Same rationale as `SendStream` — `Device` on some backends is `!Send`.
struct SendDevice(Device);

// SAFETY: Device is only used behind a Mutex and never concurrently accessed.
unsafe impl Send for SendDevice {}

// ---------------------------------------------------------------------------
// Internal state shared between the drain thread and the main thread
// ---------------------------------------------------------------------------

struct RecordingState {
    /// Ring buffer — kept alive so the producer (cpal callback) Arc stays valid.
    #[allow(dead_code)]
    ring_buffer: SpscRingBuffer,
    /// Device sample rate (Hz).
    device_sample_rate: u32,
    /// Signal the drain thread to stop.
    stop_flag: Arc<AtomicBool>,
    /// Handle to the drain thread (joined on stop).
    drain_handle: Option<std::thread::JoinHandle<DrainResult>>,
    /// The cpal stream — kept alive while recording.
    _stream: SendStream,
    /// Wall-clock instant when recording started.
    start_time: Instant,
    /// Buffer count (number of cpal callbacks).
    buffer_count: Arc<AtomicU32>,
    /// Max sample amplitude (as f32 bits) seen across all cpal callbacks.
    max_sample_seen: Arc<AtomicU32>,
}

/// Data returned by the drain thread when it finishes.
struct DrainResult {
    /// Accumulated 16 kHz mono samples.
    samples_16k: Vec<f32>,
    /// Wall-clock ms from recording start to first non-silent audio.
    first_audio_ms: Option<f64>,
}

// ---------------------------------------------------------------------------
// Cached warm-up state
// ---------------------------------------------------------------------------

struct WarmUpState {
    device: SendDevice,
    config: StreamConfig,
    sample_rate: u32,
}

// ---------------------------------------------------------------------------
// AudioCapture
// ---------------------------------------------------------------------------

/// Cross-platform audio capture built on cpal.
pub struct AudioCapture {
    /// Active recording (if any).
    recording: Mutex<Option<RecordingState>>,
    /// Cached device + config from warm_up().
    warm_up: Mutex<Option<WarmUpState>>,
}

// AudioCapture is Send+Sync because all fields are behind Mutex,
// and the non-Send cpal types are wrapped in Send newtypes.
// SAFETY: see SendStream / SendDevice docs above.
unsafe impl Send for AudioCapture {}
unsafe impl Sync for AudioCapture {}

impl Default for AudioCapture {
    fn default() -> Self {
        Self {
            recording: Mutex::new(None),
            warm_up: Mutex::new(None),
        }
    }
}

impl AudioCapture {
    /// Create a new AudioCapture (no resources allocated yet).
    pub fn new() -> Self {
        Self::default()
    }

    /// Enumerate available audio input devices.
    pub fn list_input_devices() -> Vec<AudioDeviceInfo> {
        let host = cpal::default_host();
        let devices = match host.input_devices() {
            Ok(d) => d,
            Err(_) => return Vec::new(),
        };
        devices
            .filter_map(|dev| {
                let name = dev.name().ok()?;
                // Use name as id on platforms where cpal doesn't expose a stable id.
                Some(AudioDeviceInfo {
                    id: name.clone(),
                    name,
                })
            })
            .collect()
    }

    /// Get the name of the current system default input device.
    pub fn default_input_device_name() -> String {
        let host = cpal::default_host();
        host.default_input_device()
            .and_then(|d| d.name().ok())
            .unwrap_or_default()
    }

    /// Pre-resolve the device and stream config so that `start_recording` is fast.
    /// Returns `Ok(())` on success, or an error string.
    pub fn warm_up(&self, device_id: Option<&str>) -> Result<(), String> {
        let (device, config, sample_rate) = resolve_device_and_config(device_id)?;
        let mut guard = self.warm_up.lock().unwrap();
        *guard = Some(WarmUpState {
            device: SendDevice(device),
            config,
            sample_rate,
        });
        Ok(())
    }

    /// Start recording. The `listener` receives audio-level and readiness callbacks.
    pub fn start_recording(
        &self,
        device_id: Option<&str>,
        listener: Arc<dyn AudioCaptureListener>,
    ) -> Result<(), String> {
        // Ensure we're not already recording.
        {
            let guard = self.recording.lock().unwrap();
            if guard.is_some() {
                return Err("Already recording".into());
            }
        }

        // Use warm-up cache if available and device_id matches, otherwise resolve now.
        let (device, config, sample_rate) = {
            let mut warm = self.warm_up.lock().unwrap();
            if let Some(ws) = warm.take() {
                // If caller didn't specify a device, or specified one matching the cached name,
                // reuse the warm-up state.
                let cached_name = ws.device.0.name().unwrap_or_default();
                let matches = match device_id {
                    None => true,
                    Some(id) => id == cached_name,
                };
                if matches {
                    (ws.device.0, ws.config, ws.sample_rate)
                } else {
                    resolve_device_and_config(device_id)?
                }
            } else {
                resolve_device_and_config(device_id)?
            }
        };

        let ring_buffer = SpscRingBuffer::new(131_072); // ~3 s at 44.1 kHz
        let rb_producer = ring_buffer.clone();
        let channels = config.channels as usize;
        let buffer_count = Arc::new(AtomicU32::new(0));
        let buffer_count_cb = buffer_count.clone();

        // Error listener for cpal stream error callback
        let err_listener = listener.clone();

        log::info!("[audio] build_input_stream: device={}, rate={}, channels={}, format={:?}",
            device.name().unwrap_or_default(), sample_rate, channels, config.sample_rate);

        let first_cb_logged = Arc::new(AtomicBool::new(false));
        let first_cb_logged_cb = first_cb_logged.clone();
        let max_sample_seen = Arc::new(std::sync::atomic::AtomicU32::new(0));
        let max_sample_cb = max_sample_seen.clone();

        let stream = device
            .build_input_stream(
                &config,
                move |data: &[f32], _info: &cpal::InputCallbackInfo| {
                    buffer_count_cb.fetch_add(1, Ordering::Relaxed);

                    // Log first callback + track max amplitude
                    if !first_cb_logged_cb.swap(true, Ordering::Relaxed) {
                        let max = data.iter().map(|s| s.abs()).fold(0.0f32, f32::max);
                        log::info!("[audio] first callback: {} samples, max_amp={:.6}", data.len(), max);
                    }
                    let max = data.iter().map(|s| s.abs()).fold(0.0f32, f32::max);
                    let bits = max.to_bits();
                    let prev = max_sample_cb.load(Ordering::Relaxed);
                    if bits > prev {
                        max_sample_cb.store(bits, Ordering::Relaxed);
                    }

                    if channels == 1 {
                        rb_producer.write(data);
                    } else {
                        // Mix to mono
                        let frame_count = data.len() / channels;
                        // Use a small stack buffer to avoid allocation in RT callback
                        let mut mono = [0.0f32; 1024];
                        let mut offset = 0;
                        while offset < frame_count {
                            let chunk = (frame_count - offset).min(1024);
                            for (i, mono_sample) in mono[..chunk].iter_mut().enumerate() {
                                let frame_start = (offset + i) * channels;
                                let mut sum = 0.0f32;
                                for ch in 0..channels {
                                    sum += data[frame_start + ch];
                                }
                                *mono_sample = sum / channels as f32;
                            }
                            rb_producer.write(&mono[..chunk]);
                            offset += chunk;
                        }
                    }
                },
                move |err| {
                    err_listener.on_error(format!("cpal stream error: {err}"));
                },
                None, // no timeout
            )
            .map_err(|e| format!("Failed to build input stream: {e}"))?;

        stream.play().map_err(|e| format!("Failed to start stream: {e}"))?;
        log::info!("[audio] stream.play() OK");

        let stop_flag = Arc::new(AtomicBool::new(false));
        let stop_flag_drain = stop_flag.clone();
        let rb_consumer = ring_buffer.clone();
        let drain_listener = listener.clone();
        let start_time = Instant::now();
        let drain_start = start_time;

        let drain_handle = std::thread::Builder::new()
            .name("audio-drain".into())
            .spawn(move || {
                drain_loop(
                    rb_consumer,
                    sample_rate,
                    stop_flag_drain,
                    drain_listener,
                    drain_start,
                )
            })
            .map_err(|e| format!("Failed to spawn drain thread: {e}"))?;

        let mut guard = self.recording.lock().unwrap();
        *guard = Some(RecordingState {
            ring_buffer,
            device_sample_rate: sample_rate,
            stop_flag,
            drain_handle: Some(drain_handle),
            _stream: SendStream(stream),
            start_time,
            buffer_count,
            max_sample_seen,
        });

        Ok(())
    }

    /// Stop recording and produce a WAV file.
    /// Returns `None` if not currently recording.
    pub fn stop_recording(&self) -> Result<Option<RecordingResult>, String> {
        let state = {
            let mut guard = self.recording.lock().unwrap();
            guard.take()
        };

        let state = match state {
            Some(s) => s,
            None => return Ok(None),
        };

        let duration_ms = state.start_time.elapsed().as_secs_f64() * 1000.0;

        let max_bits = state.max_sample_seen.load(Ordering::Relaxed);
        let max_amp = f32::from_bits(max_bits);
        log::info!("[audio] stop: buffers={}, max_cpal_amplitude={:.6}, duration={:.0}ms",
            state.buffer_count.load(Ordering::Relaxed), max_amp, duration_ms);

        // Signal drain thread to stop
        state.stop_flag.store(true, Ordering::Release);

        // Drop the stream to stop audio callbacks
        drop(state._stream);

        // Join drain thread
        let drain_result = match state.drain_handle {
            Some(handle) => handle
                .join()
                .map_err(|_| "Drain thread panicked".to_string())?,
            None => return Err("No drain thread handle".into()),
        };

        // Pad to minimum duration
        let padded = pad_to_minimum_duration(
            &drain_result.samples_16k,
            TARGET_SAMPLE_RATE,
            wrenflow_domain::audio::MIN_DURATION_SECS,
        );

        Ok(Some(RecordingResult {
            samples_16k: padded,
            file_path: String::new(),
            metrics: RecordingMetrics {
                duration_ms,
                file_size_bytes: 0,
                device_sample_rate: state.device_sample_rate,
                buffer_count: state.buffer_count.load(Ordering::Relaxed),
                first_audio_ms: drain_result.first_audio_ms,
            },
        }))
    }

    /// Release any cached resources (warm-up state, etc.).
    pub fn cleanup(&self) {
        let _ = self.warm_up.lock().unwrap().take();
        // If still recording, stop it (best-effort).
        let _ = self.stop_recording();
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Resolve device and build a stream config requesting 128-frame buffers.
fn resolve_device_and_config(
    device_id: Option<&str>,
) -> Result<(Device, StreamConfig, u32), String> {
    let host = cpal::default_host();

    let device = match device_id {
        Some(id) => {
            let devices = host
                .input_devices()
                .map_err(|e| format!("Failed to enumerate input devices: {e}"))?;
            let mut found = None;
            for dev in devices {
                if let Ok(name) = dev.name() {
                    if name == id {
                        found = Some(dev);
                        break;
                    }
                }
            }
            found.ok_or_else(|| format!("Input device not found: {id}"))?
        }
        None => host
            .default_input_device()
            .ok_or_else(|| "No default input device".to_string())?,
    };

    let supported = device
        .default_input_config()
        .map_err(|e| format!("No supported input config: {e}"))?;

    let sample_rate = supported.sample_rate().0;

    // Use default buffer size — Fixed(128) causes silent zeros on some interfaces
    let config = StreamConfig {
        channels: supported.channels(),
        sample_rate: supported.sample_rate(),
        buffer_size: cpal::BufferSize::Default,
    };

    // Verify the sample format is f32 (cpal stream callback expects it)
    if supported.sample_format() != SampleFormat::F32 {
        // cpal will do the conversion for us when we specify f32 in build_input_stream,
        // but log for awareness.
        log::info!(
            "Device sample format is {:?}, cpal will convert to f32",
            supported.sample_format()
        );
    }

    Ok((device, config, sample_rate))
}

/// The drain thread: reads from the ring buffer, computes audio level,
/// resamples to 16 kHz, and accumulates samples.
fn drain_loop(
    ring_buffer: SpscRingBuffer,
    device_sample_rate: u32,
    stop_flag: Arc<AtomicBool>,
    listener: Arc<dyn AudioCaptureListener>,
    start_time: Instant,
) -> DrainResult {
    let mut audio_level = AudioLevel::new();
    let mut accumulated_native = Vec::<f32>::new();
    let mut first_audio_ms: Option<f64> = None;
    let mut tick_counter: u32 = 0;

    // Silence threshold: RMS of raw samples > 0.001
    const SILENCE_THRESHOLD: f32 = 0.001;

    let mut read_buf = vec![0.0f32; 4096];

    loop {
        let n = ring_buffer.read(&mut read_buf);
        if n > 0 {
            let chunk = &read_buf[..n];
            accumulated_native.extend_from_slice(chunk);

            // Compute audio level
            let level = audio_level.process(chunk);

            // Throttle on_audio_level to every other tick (~50 Hz when drain runs at ~100 Hz)
            tick_counter += 1;
            if tick_counter.is_multiple_of(2) {
                listener.on_audio_level(level);
            }

            // Detect first non-silent audio
            if first_audio_ms.is_none() {
                let rms = compute_rms(chunk);
                if rms > SILENCE_THRESHOLD {
                    first_audio_ms = Some(start_time.elapsed().as_secs_f64() * 1000.0);
                    listener.on_recording_ready();
                }
            }
        }

        if stop_flag.load(Ordering::Acquire) {
            // Final drain: read any remaining samples
            loop {
                let n = ring_buffer.read(&mut read_buf);
                if n == 0 {
                    break;
                }
                accumulated_native.extend_from_slice(&read_buf[..n]);
            }
            break;
        }

        std::thread::sleep(std::time::Duration::from_millis(10));
    }

    let native_max = accumulated_native.iter().map(|s| s.abs()).fold(0.0f32, f32::max);
    log::info!("[audio] drain done: {} native samples, max_amp={:.6}, first_audio={:?}",
        accumulated_native.len(), native_max, first_audio_ms);

    // Resample accumulated audio to 16 kHz
    let samples_16k = resample_to_16khz(&accumulated_native, device_sample_rate);

    log::info!("[audio] resampled: {} → {} samples (16kHz)", accumulated_native.len(), samples_16k.len());

    DrainResult {
        samples_16k,
        first_audio_ms,
    }
}

/// Compute RMS of a sample slice.
fn compute_rms(samples: &[f32]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    let sum_sq: f32 = samples.iter().map(|&s| s * s).sum();
    (sum_sq / samples.len() as f32).sqrt()
}
