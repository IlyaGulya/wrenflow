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
use model_actor::SharedTranscriptionEngine;
use pipeline_actor::PipelineActor;
use rinf::{DartSignal, RustSignal};
use tokio::spawn;
use wrenflow_domain::pipeline::TranscriptionResult;

use crate::signals;

pub async fn create_actors() {
    // Shared transcription engine (populated by model_actor, used by pipeline)
    let engine_handle = model_actor::shared_engine();

    let mut pipeline = PipelineActor::new();
    let mut audio = AudioActor::new();
    let mut hotkey = HotkeyActor::new("rightOption");

    // History actor — owns SQLite store on its own thread (Connection is !Send)
    let history_path = history_actor::default_history_path();
    match HistoryActor::new(history_path) {
        Ok(history) => {
            std::thread::spawn(move || {
                history.run_blocking();
            });
        }
        Err(e) => {
            log::error!("Failed to start history actor: {e}");
        }
    }

    // Model download/load actor — shares engine handle
    let model_engine = engine_handle.clone();
    spawn(async move {
        model_actor::run(model_engine).await;
    });

    // Listen for device listing requests
    spawn(async {
        let recv = signals::ListAudioDevices::get_dart_signal_receiver();
        while let Some(_) = recv.recv().await {
            let devices = AudioActor::list_devices();
            signals::AudioDevicesListed { devices }.send_signal_to_dart();
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
                            pipeline.handle_hotkey_up(duration_ms);
                            let transcribing = pipeline.is_transcribing();

                            if transcribing {
                                if let Ok(Some(result)) = recording {
                                    let engine = transcription_engine.clone();
                                    let file_path = result.file_path.clone();
                                    let tx_result = tokio::task::spawn_blocking(move || {
                                        let start = std::time::Instant::now();
                                        let mut guard = engine.lock().ok()?;
                                        let engine_mut = guard.as_mut()?;
                                        match engine_mut.transcribe_file(std::path::Path::new(&file_path)) {
                                            Ok(text) => Some(wrenflow_domain::pipeline::TranscriptionResult {
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
                                            pipeline.on_transcription_complete(result);
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
                    pipeline.handle_config_update(pack.message);
                }
                else => break,
            }

            pipeline.check_timers().await;
        }
    });
}
