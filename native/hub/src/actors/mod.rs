//! Actor system for Wrenflow hub.

pub mod app_session_actor;
pub mod audio_actor;
pub mod audio_devices_actor;
pub mod history_actor;
pub mod hotkey_actor;
pub mod launch_at_login_actor;
pub mod model_actor;
pub mod paste_actor;
pub mod permissions_actor;
mod pipeline_actor;
pub mod settings_actor;
pub mod shell_capabilities_actor;
mod snapshot_mirror;
pub mod updates_actor;

use audio_actor::{AudioActor, AudioEvent};
use history_actor::HistoryActor;
use hotkey_actor::HotkeyActor;
use pipeline_actor::PipelineActor;
use rinf::{DartSignal, RustSignal};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use tokio::spawn;
use wrenflow_domain::config::AppConfig;
use wrenflow_domain::pipeline::TranscriptionResult;

use crate::signals;

/// Whether to paste after transcription. Set by Dart via SetTranscriptAction.
/// true = paste, false = display only.
static SHOULD_PASTE: AtomicBool = AtomicBool::new(false);

struct RuntimeGraph {
    startup_config: AppConfig,
    settings_runtime: settings_actor::SettingsRuntime,
    engine_handle: model_actor::SharedTranscriptionEngine,
    audio_devices_state: audio_devices_actor::SharedAudioDevicesState,
}

impl RuntimeGraph {
    fn new() -> Self {
        let settings_runtime =
            settings_actor::shared_runtime(settings_actor::load_initial_config());
        let startup_config = settings_actor::current_config(&settings_runtime);

        Self {
            startup_config,
            settings_runtime,
            engine_handle: model_actor::shared_engine(),
            audio_devices_state: audio_devices_actor::shared_state(),
        }
    }
}

pub async fn create_actors() {
    let runtime = RuntimeGraph::new();
    let history_insert_tx = spawn_history_actor();

    spawn_settings_actor(runtime.settings_runtime.clone());
    spawn_model_actor(&runtime);
    spawn_permissions_actor();
    spawn_app_session_actor(&runtime);
    spawn_audio_devices_actor(&runtime);
    spawn_updates_actor();
    spawn_shell_capabilities_actor();
    spawn_launch_at_login_actor();
    spawn_transcript_action_listener();
    spawn_pipeline_loop(runtime, history_insert_tx);
}

fn spawn_history_actor() -> Option<history_actor::HistoryInsertSender> {
    let history_path = history_actor::default_history_path();
    match HistoryActor::new(history_path) {
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
    }
}

fn spawn_settings_actor(settings_runtime: settings_actor::SettingsRuntime) {
    spawn(async move {
        settings_actor::run(settings_runtime).await;
    });
}

fn spawn_model_actor(runtime: &RuntimeGraph) {
    let model_engine = runtime.engine_handle.clone();
    let model_config_rx = settings_actor::subscribe(&runtime.settings_runtime);
    spawn(async move {
        model_actor::run(model_engine, model_config_rx).await;
    });
}

fn spawn_permissions_actor() {
    spawn(async {
        permissions_actor::run().await;
    });
}

fn spawn_app_session_actor(runtime: &RuntimeGraph) {
    let app_session_config_rx = settings_actor::subscribe(&runtime.settings_runtime);
    spawn(async move {
        app_session_actor::run(app_session_config_rx).await;
    });
}

fn spawn_audio_devices_actor(runtime: &RuntimeGraph) {
    let audio_devices_state = runtime.audio_devices_state.clone();
    let audio_devices_config_rx = settings_actor::subscribe(&runtime.settings_runtime);
    spawn(async move {
        audio_devices_actor::run(audio_devices_state, audio_devices_config_rx).await;
    });
}

fn spawn_updates_actor() {
    spawn(async {
        updates_actor::run().await;
    });
}

fn spawn_shell_capabilities_actor() {
    spawn(async {
        shell_capabilities_actor::run().await;
    });
}

fn spawn_launch_at_login_actor() {
    spawn(async {
        launch_at_login_actor::run().await;
    });
}

fn spawn_transcript_action_listener() {
    spawn(async {
        let recv = signals::SetTranscriptAction::get_dart_signal_receiver();
        while let Some(pack) = recv.recv().await {
            let should_paste = pack.message.action == "paste";
            SHOULD_PASTE.store(should_paste, Ordering::Relaxed);
            log::info!("Transcript action set to: {}", pack.message.action);
        }
    });
}

fn spawn_pipeline_loop(
    runtime: RuntimeGraph,
    history_insert_tx: Option<history_actor::HistoryInsertSender>,
) {
    let mut audio = AudioActor::new();
    let mut hotkey = HotkeyActor::new(hotkey_actor::keycode_from_name(
        &runtime.startup_config.selected_hotkey,
    ));
    let mut pipeline = PipelineActor::new(history_insert_tx, runtime.startup_config.clone());
    let transcription_engine = runtime.engine_handle.clone();
    let audio_devices_state = runtime.audio_devices_state.clone();
    let settings_runtime = runtime.settings_runtime.clone();
    let mut config_rx = settings_actor::subscribe(&runtime.settings_runtime);

    spawn(async move {
        loop {
            tokio::select! {
                Some(event) = hotkey.recv() => {
                    match event {
                        hotkey_actor::HotkeyEvent::KeyDown => {
                            log::info!("Hotkey DOWN");
                            pipeline.handle_hotkey_down();
                            let preferred_device_id = settings_actor::current_config(&settings_runtime)
                                .selected_microphone_id;
                            let device_id = audio_devices_actor::effective_device_id_for(
                                &audio_devices_state,
                                &preferred_device_id,
                            );
                            if let Err(e) = audio.start(&device_id) {
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
                                        let model_id = engine_mut.model_id().to_string();
                                        let model_name = engine_mut.model_display_name().to_string();
                                        match engine_mut.transcribe(&samples) {
                                            Ok(text) => Some(TranscriptionResult {
                                                raw_transcript: text,
                                                duration_ms: start.elapsed().as_secs_f64() * 1000.0,
                                                provider: "local".to_string(),
                                                model_id,
                                                model_name,
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
                Ok(()) = config_rx.changed() => {
                    let current_config = config_rx.borrow().clone();
                    let kc = hotkey_actor::keycode_from_name(&current_config.selected_hotkey);
                    hotkey.set_keycode(kc);
                    pipeline.handle_config_update(current_config.clone());
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
