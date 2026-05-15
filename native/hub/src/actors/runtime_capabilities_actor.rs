//! Runtime capabilities actor — owns the latest Rust runtime capability snapshot.

use rinf::{DartSignal, RustSignal};
use wrenflow_core::audio_capture::AudioCapture;

use crate::platform::{global_hotkey, paste, runtime_probe};
use crate::signals;

fn detect_runtime_capabilities() -> signals::RuntimeCapabilitiesSnapshot {
    let audio_capture = AudioCapture::backend_available();
    let local_transcription = runtime_probe::onnx_runtime_available();
    let model_download = runtime_probe::model_storage_writable() && local_transcription;

    signals::RuntimeCapabilitiesSnapshot {
        global_hotkey: global_hotkey::is_supported(),
        paste_injection: paste::is_supported(),
        local_transcription,
        audio_capture,
        model_download,
        model_activation: local_transcription,
        history_persistence: runtime_probe::history_storage_writable(),
    }
}

pub async fn run() {
    let request_recv = signals::RequestRuntimeCapabilitiesSnapshot::get_dart_signal_receiver();

    signals::RuntimeCapabilitiesSnapshotChanged {
        snapshot: detect_runtime_capabilities(),
    }
    .send_signal_to_dart();

    while request_recv.recv().await.is_some() {
        signals::RuntimeCapabilitiesSnapshotChanged {
            snapshot: detect_runtime_capabilities(),
        }
        .send_signal_to_dart();
    }
}
