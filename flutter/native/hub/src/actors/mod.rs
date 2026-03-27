//! Actor system for Wrenflow hub.

pub mod audio_actor;
mod pipeline_actor;

use audio_actor::{AudioActor, AudioEvent};
use pipeline_actor::PipelineActor;
use rinf::{DartSignal, RustSignal};
use tokio::spawn;
use wrenflow_domain::pipeline::TranscriptionResult;

use crate::signals;

pub async fn create_actors() {
    let mut pipeline = PipelineActor::new();
    let mut audio = AudioActor::new();

    // Listen for device listing requests
    spawn(async {
        let recv = signals::ListAudioDevices::get_dart_signal_receiver();
        while let Some(_) = recv.recv().await {
            let devices = AudioActor::list_devices();
            signals::AudioDevicesListed { devices }.send_signal_to_dart();
        }
    });

    // Main loop: pipeline + audio events
    // For now pipeline runs its own select loop.
    // Audio events will be integrated when transcription is wired.
    spawn(async move {
        pipeline.run().await;
    });
}
