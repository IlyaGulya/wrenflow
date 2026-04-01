//! Actor system for Wrenflow hub.

pub mod audio_actor;
pub mod history_actor;
pub mod hotkey_actor;
pub mod model_actor;
pub mod paste_actor;
mod pipeline_actor;

use audio_actor::{AudioActor, AudioEvent};
use history_actor::HistoryActor;
use hotkey_actor::HotkeyActor;
use pipeline_actor::PipelineActor;
use rinf::{DartSignal, RustSignal};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use tokio::spawn;
use wrenflow_domain::pipeline::TranscriptionResult;

use crate::signals;

/// Whether to paste after transcription. Set by Dart via SetTranscriptAction.
/// true = paste, false = display only.
static SHOULD_PASTE: AtomicBool = AtomicBool::new(false);

pub async fn create_actors() {
    let engine_handle = model_actor::shared_engine();

    let mut audio = AudioActor::new();
    let mut hotkey = HotkeyActor::new(hotkey_actor::keycode_from_name("rightOption"));

    // History actor
    let history_path = history_actor::default_history_path();
    let history_insert_tx = match HistoryActor::new(history_path) {
        Ok((history, tx)) => {
            std::thread::spawn(move || {
                history.run_blocking();
            });
            Some(tx)
        }
        Err(e) => {
            log::error!("Failed to start history actor: {e}");
            None
        }
    };

    let mut pipeline = PipelineActor::new(history_insert_tx);

    // Model actor
    let model_engine = engine_handle.clone();
    spawn(async move {
        model_actor::run(model_engine).await;
    });

    // Device listing (on-demand from Dart — tray click, settings open).
    spawn(async {
        let recv = signals::ListAudioDevices::get_dart_signal_receiver();
        while recv.recv().await.is_some() {
            let devices = AudioActor::list_devices();
            let default_name = AudioActor::default_device_name();
            signals::AudioDevicesListed { devices, default_device_name: default_name }.send_signal_to_dart();
        }
    });

    // TranscriptAction listener
    spawn(async {
        let recv = signals::SetTranscriptAction::get_dart_signal_receiver();
        while let Some(pack) = recv.recv().await {
            let should_paste = pack.message.action == "paste";
            SHOULD_PASTE.store(should_paste, Ordering::Relaxed);
            log::info!("Transcript action set to: {}", pack.message.action);
        }
    });

    // Main loop: hotkey + audio events drive the pipeline
    let transcription_engine = engine_handle.clone();
    spawn(async move {
        let config_recv = signals::UpdateConfig::get_dart_signal_receiver();

        loop {
            tokio::select! {
                Some(event) = hotkey.recv() => {
                    match event {
                        hotkey_actor::HotkeyEvent::KeyDown => {
                            log::info!("Hotkey DOWN");
                            pipeline.handle_hotkey_down();
                            if let Err(e) = audio.start("default") {
                                log::error!("Failed to start audio: {e}");
                            }
                        }
                        hotkey_actor::HotkeyEvent::KeyUp { duration_ms } => {
                            log::info!("Hotkey UP ({duration_ms:.0}ms)");
                            let recording = audio.stop();
                            match &recording {
                                Ok(Some(r)) => {
                                    log::info!("audio.stop(): file={}, duration={:.0}ms, buffers={}, first_audio={:?}, size={}",
                                        r.file_path, r.metrics.duration_ms, r.metrics.buffer_count,
                                        r.metrics.first_audio_ms, r.metrics.file_size_bytes);
                                }
                                Ok(None) => log::warn!("audio.stop() = Ok(None) — was not recording"),
                                Err(e) => log::error!("audio.stop() error: {e}"),
                            }
                            pipeline.handle_hotkey_up(duration_ms);
                            let transcribing = pipeline.is_transcribing();
                            log::info!("transcribing={transcribing}");

                            if transcribing
                                && let Ok(Some(result)) = recording
                            {
                                    log::info!("Recording: {}ms, {} samples",
                                        result.metrics.duration_ms,
                                        result.samples_16k.len());

                                    // Save OGG/Opus recording in parallel (persistent storage).
                                    let opus_samples = result.samples_16k.clone();
                                    tokio::task::spawn_blocking(move || {
                                        let recordings_dir = recordings_dir();
                                        if let Err(e) = std::fs::create_dir_all(&recordings_dir) {
                                            log::error!("Failed to create recordings dir: {e}");
                                            return;
                                        }
                                        let filename = format!(
                                            "recording_{}.ogg",
                                            std::time::SystemTime::now()
                                                .duration_since(std::time::UNIX_EPOCH)
                                                .unwrap_or_default()
                                                .as_millis()
                                        );
                                        let path = recordings_dir.join(&filename);
                                        match std::fs::File::create(&path) {
                                            Ok(mut f) => {
                                                if let Err(e) = wrenflow_core::opus_encoder::encode_ogg_opus(&mut f, &opus_samples) {
                                                    log::error!("Opus encode error: {e}");
                                                } else {
                                                    log::info!("Opus saved: {}", path.display());
                                                }
                                            }
                                            Err(e) => log::error!("Opus file create error: {e}"),
                                        }
                                    });

                                    // Transcribe from memory buffer (parallel with WAV write).
                                    let engine = transcription_engine.clone();
                                    let samples = result.samples_16k;
                                    let tx_result = tokio::task::spawn_blocking(move || {
                                        let start = std::time::Instant::now();
                                        let mut guard = engine.lock().ok()?;
                                        let engine_mut = guard.as_mut()?;
                                        match engine_mut.transcribe(&samples) {
                                            Ok(text) => Some(TranscriptionResult {
                                                raw_transcript: text,
                                                duration_ms: start.elapsed().as_secs_f64() * 1000.0,
                                                provider: "local".to_string(),
                                            }),
                                            Err(e) => {
                                                log::error!("Transcription failed: {e}");
                                                None
                                            }
                                        }
                                    }).await;

                                    match tx_result {
                                        Ok(Some(result)) => {
                                            let transcript = result.raw_transcript.trim().to_string();
                                            pipeline.on_transcription_complete(result);

                                            // Paste only if Dart configured it.
                                            if !transcript.is_empty() && SHOULD_PASTE.load(Ordering::Relaxed) {
                                                if let Err(e) = paste_actor::paste_text(&transcript) {
                                                    log::error!("paste failed: {e}");
                                                }
                                                signals::PasteComplete.send_signal_to_dart();
                                            }
                                        }
                                        Ok(None) => {
                                            log::warn!("Transcription returned None (model not loaded?)");
                                            pipeline.on_error("Model not loaded. Download the model first.");
                                        }
                                        Err(e) => {
                                            log::error!("Transcription task failed: {e}");
                                            pipeline.on_error(&format!("Transcription failed: {e}"));
                                        }
                                    }
                                }
                            }

                    }

                }
                Some(event) = audio.recv_event() => {
                    match event {
                        AudioEvent::FirstAudio => {
                            pipeline.on_first_audio();
                        }
                        AudioEvent::Error(msg) => {
                            log::error!("Audio error: {msg}");
                        }
                        AudioEvent::RecordingComplete(_) => {}
                    }
                }
                Some(pack) = config_recv.recv() => {
                    let kc = hotkey_actor::keycode_from_name(&pack.message.selected_hotkey);
                    hotkey.set_keycode(kc);
                    pipeline.handle_config_update(pack.message);
                }
                // Wake up to check init/indicator timers during active recording.
                _ = tokio::time::sleep(std::time::Duration::from_secs(1)) => {}
                else => break,
            }

            pipeline.check_timers().await;
        }
    });
}

/// Persistent directory for audio recordings.
fn recordings_dir() -> PathBuf {
    dirs::data_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("Wrenflow/recordings")
}
