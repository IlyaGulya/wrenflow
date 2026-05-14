//! Runtime capabilities actor — owns the latest Rust runtime capability snapshot.

use rinf::{DartSignal, RustSignal};

use crate::platform::{global_hotkey, paste};
use crate::signals;

fn detect_runtime_capabilities() -> signals::RuntimeCapabilitiesSnapshot {
    let local_transcription = cfg!(target_os = "macos");
    let audio_capture = cfg!(target_os = "macos");

    signals::RuntimeCapabilitiesSnapshot {
        global_hotkey: global_hotkey::is_supported(),
        paste_injection: paste::is_supported(),
        local_transcription,
        audio_capture,
        model_download: local_transcription,
        model_activation: local_transcription,
        history_persistence: true,
    }
}

pub async fn run() {
    let snapshot = detect_runtime_capabilities();
    let request_recv = signals::RequestRuntimeCapabilitiesSnapshot::get_dart_signal_receiver();

    signals::RuntimeCapabilitiesSnapshotChanged { snapshot: snapshot.clone() }.send_signal_to_dart();

    while request_recv.recv().await.is_some() {
        signals::RuntimeCapabilitiesSnapshotChanged { snapshot: snapshot.clone() }
            .send_signal_to_dart();
    }
}
