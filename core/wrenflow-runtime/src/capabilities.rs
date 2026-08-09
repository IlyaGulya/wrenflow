use wrenflow_core::audio_capture::AudioCapture;
use wrenflow_domain::config::DEFAULT_SELECTED_MICROPHONE_ID;

use crate::platform::{paste_injection_supported, runtime_probe};
use crate::state::{AudioDevicesSnapshot, RuntimeCapabilities};
use crate::store::{RuntimeStore, StoreUpdate};
use crate::RuntimeError;

pub(crate) fn detect_runtime_capabilities() -> RuntimeCapabilities {
    let audio_capture = AudioCapture::backend_available();
    let local_transcription = runtime_probe::onnx_runtime_available();
    let model_download = runtime_probe::model_storage_writable() && local_transcription;

    RuntimeCapabilities {
        // Global input is a shell capability. The runtime only consumes typed
        // HotkeyPressed/HotkeyReleased commands and never installs an event tap.
        global_hotkey: false,
        paste_injection: paste_injection_supported(),
        local_transcription,
        audio_capture,
        model_download,
        model_activation: local_transcription,
        history_persistence: runtime_probe::history_storage_writable(),
    }
}

pub(crate) fn refresh_audio_devices(runtime: &RuntimeStore) -> Result<StoreUpdate, RuntimeError> {
    let devices = AudioCapture::list_input_devices();
    let default_device_name = AudioCapture::default_input_device_name();
    runtime.update(move |snapshot| {
        let selected = snapshot.settings.selected_microphone_id.clone();
        let effective = if selected == DEFAULT_SELECTED_MICROPHONE_ID
            || devices.iter().any(|device| device.id == selected)
        {
            selected.clone()
        } else {
            DEFAULT_SELECTED_MICROPHONE_ID.to_string()
        };
        let next = AudioDevicesSnapshot {
            has_snapshot: true,
            devices,
            default_device_name,
            selected_device_id: selected,
            effective_selected_device_id: effective,
        };
        if snapshot.audio_devices == next {
            false
        } else {
            snapshot.audio_devices = next;
            true
        }
    })
}
