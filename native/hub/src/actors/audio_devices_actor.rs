//! Audio devices actor — owns the latest audio device inventory snapshot.

use rinf::{DartSignal, RustSignal};
use std::sync::{Arc, Mutex};
use tokio::sync::watch;
use wrenflow_domain::config::AppConfig;

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
            selected_device_id: "default".to_string(),
        }
    }

    fn effective_selected_device_id(&self) -> String {
        if self.selected_device_id == "default" {
            return "default".to_string();
        }

        if self
            .devices
            .iter()
            .any(|device| device.id == self.selected_device_id)
        {
            self.selected_device_id.clone()
        } else {
            "default".to_string()
        }
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

pub fn current_selected_device_id(state: &SharedAudioDevicesState) -> String {
    state
        .lock()
        .map(|guard| guard.effective_selected_device_id())
        .unwrap_or_else(|_| "default".to_string())
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
