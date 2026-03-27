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
    // TODO: rdev::listen crashes on macOS when called from non-main thread
    // (dispatch_assert_queue_fail in TSMGetInputSourceProperty).
    // Need to either run on main thread or use CGEventTap directly.
    // let mut hotkey = HotkeyActor::new("fn");

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

    // Main loop: config updates (hotkey disabled until rdev thread crash is fixed)
    let _transcription_engine = engine_handle.clone();
    let _audio = audio;
    spawn(async move {
        let config_recv = signals::UpdateConfig::get_dart_signal_receiver();

        loop {
            tokio::select! {
                // TODO: re-enable hotkey + audio when rdev thread crash is fixed
                // rdev::listen crashes on macOS from non-main thread
                // (dispatch_assert_queue_fail in TSMGetInputSourceProperty)
                Some(pack) = config_recv.recv() => {
                    pipeline.handle_config_update(pack.message);
                }
                else => break,
            }

            pipeline.check_timers().await;
        }
    });
}
