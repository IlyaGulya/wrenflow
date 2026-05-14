//! Audio devices actor — owns the latest audio device inventory snapshot.

use rinf::{DartSignal, RustSignal};
use std::sync::{Arc, Mutex};
use tokio::sync::watch;
use wrenflow_domain::config::{AppConfig, DEFAULT_SELECTED_MICROPHONE_ID};

use crate::signals;

pub type SharedAudioDevicesState = Arc<Mutex<AudioDevicesRuntimeState>>;

#[derive(Clone, Debug)]
pub struct AudioDevicesRuntimeState {
    pub has_snapshot: bool,
    pub devices: Vec<signals::AudioDeviceInfo>,
    pub default_device_name: String,
    pub selected_device_id: String,
}

impl AudioDevicesRuntimeState {
    fn new() -> Self {
        Self {
            has_snapshot: false,
            devices: vec![],
            default_device_name: String::new(),
            selected_device_id: DEFAULT_SELECTED_MICROPHONE_ID.to_string(),
        }
    }

    fn effective_device_id_for(&self, preferred_device_id: &str) -> String {
        if preferred_device_id == DEFAULT_SELECTED_MICROPHONE_ID {
            return DEFAULT_SELECTED_MICROPHONE_ID.to_string();
        }

        if self
            .devices
            .iter()
            .any(|device| device.id == preferred_device_id)
        {
            preferred_device_id.to_string()
        } else {
            DEFAULT_SELECTED_MICROPHONE_ID.to_string()
        }
    }

    fn effective_selected_device_id(&self) -> String {
        self.effective_device_id_for(&self.selected_device_id)
    }
}

pub fn shared_state() -> SharedAudioDevicesState {
    Arc::new(Mutex::new(AudioDevicesRuntimeState::new()))
}

fn send_snapshot(state: &SharedAudioDevicesState) {
    let Ok(guard) = state.lock() else {
        return;
    };

    signals::AudioDevicesSnapshotChanged {
        snapshot: signals::AudioDevicesSnapshot {
            has_snapshot: guard.has_snapshot,
            devices: guard.devices.clone(),
            default_device_name: guard.default_device_name.clone(),
            selected_device_id: guard.selected_device_id.clone(),
            effective_selected_device_id: guard.effective_selected_device_id(),
        },
    }
    .send_signal_to_dart();
}

fn update_state(
    state: &SharedAudioDevicesState,
    update: impl FnOnce(&mut AudioDevicesRuntimeState),
) {
    let Ok(mut guard) = state.lock() else {
        return;
    };
    update(&mut guard);
    drop(guard);
    send_snapshot(state);
}

pub fn effective_device_id_for(
    state: &SharedAudioDevicesState,
    preferred_device_id: &str,
) -> String {
    state
        .lock()
        .map(|guard| guard.effective_device_id_for(preferred_device_id))
        .unwrap_or_else(|_| DEFAULT_SELECTED_MICROPHONE_ID.to_string())
}

pub fn set_selected_device_id(state: &SharedAudioDevicesState, device_id: String) {
    update_state(state, |snapshot| {
        snapshot.selected_device_id = device_id;
    });
}

fn refresh_inventory(state: &SharedAudioDevicesState) {
    let devices = super::audio_actor::AudioActor::list_devices();
    let default_device_name = super::audio_actor::AudioActor::default_device_name();
    update_state(state, |snapshot| {
        snapshot.has_snapshot = true;
        snapshot.devices = devices;
        snapshot.default_device_name = default_device_name;
    });
}

pub async fn run(state: SharedAudioDevicesState, mut config_rx: watch::Receiver<AppConfig>) {
    let request_recv = signals::RequestAudioDevicesSnapshot::get_dart_signal_receiver();

    let initial_selected_device_id = config_rx.borrow().selected_microphone_id.clone();
    set_selected_device_id(&state, initial_selected_device_id);
    refresh_inventory(&state);

    loop {
        tokio::select! {
            Some(_) = request_recv.recv() => {
                refresh_inventory(&state);
            }
            Ok(()) = config_rx.changed() => {
                let selected_device_id = config_rx.borrow().selected_microphone_id.clone();
                set_selected_device_id(&state, selected_device_id);
            }
            else => break,
        }
    }
}
