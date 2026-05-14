//! Settings actor — owns persisted application settings and their Rust snapshot.

use rinf::{DartSignal, RustSignal};
use std::sync::{Arc, Mutex};
use tokio::sync::watch;
use wrenflow_core::ConfigStore;
use wrenflow_domain::config::AppConfig;

use crate::signals;

const APP_NAME: &str = "Wrenflow";

pub type SharedSettingsState = Arc<Mutex<AppConfig>>;

#[derive(Clone)]
pub struct SettingsRuntime {
    state: SharedSettingsState,
    tx: watch::Sender<AppConfig>,
}

fn config_to_snapshot(config: &AppConfig) -> signals::SettingsSnapshot {
    signals::SettingsSnapshot {
        selected_local_model_id: config.selected_local_model_id.clone(),
        selected_hotkey: config.selected_hotkey.clone(),
        selected_microphone_id: config.selected_microphone_id.clone(),
        sound_enabled: config.sound_enabled,
        custom_vocabulary: config.custom_vocabulary.clone(),
        minimum_recording_duration_ms: config.minimum_recording_duration_ms,
        has_completed_setup: config.has_completed_setup,
    }
}

fn snapshot_to_config(snapshot: &signals::SettingsSnapshot) -> AppConfig {
    AppConfig {
        minimum_recording_duration_ms: snapshot.minimum_recording_duration_ms,
        custom_vocabulary: snapshot.custom_vocabulary.clone(),
        selected_hotkey: snapshot.selected_hotkey.clone(),
        selected_microphone_id: snapshot.selected_microphone_id.clone(),
        selected_local_model_id: snapshot.selected_local_model_id.clone(),
        sound_enabled: snapshot.sound_enabled,
        has_completed_setup: snapshot.has_completed_setup,
    }
}

fn send_snapshot(snapshot: &signals::SettingsSnapshot) {
    signals::SettingsSnapshotChanged {
        snapshot: snapshot.clone(),
    }
    .send_signal_to_dart();
}

pub fn load_initial_config() -> AppConfig {
    ConfigStore::default_for(APP_NAME).load_or_default()
}

pub fn shared_runtime(initial_config: AppConfig) -> SettingsRuntime {
    let (tx, _rx) = watch::channel(initial_config.clone());
    SettingsRuntime {
        state: Arc::new(Mutex::new(initial_config)),
        tx,
    }
}

pub fn current_config(runtime: &SettingsRuntime) -> AppConfig {
    runtime
        .state
        .lock()
        .map(|guard| guard.clone())
        .unwrap_or_else(|_| runtime.tx.borrow().clone())
}

pub fn subscribe(runtime: &SettingsRuntime) -> watch::Receiver<AppConfig> {
    runtime.tx.subscribe()
}

fn update_runtime(runtime: &SettingsRuntime, update: impl FnOnce(&mut AppConfig)) -> AppConfig {
    let next = if let Ok(mut guard) = runtime.state.lock() {
        update(&mut guard);
        guard.clone()
    } else {
        let mut fallback = runtime.tx.borrow().clone();
        update(&mut fallback);
        fallback
    };
    let _ = runtime.tx.send(next.clone());
    next
}

pub async fn run(runtime: SettingsRuntime) {
    let store = ConfigStore::default_for(APP_NAME);
    let request_recv = signals::RequestSettingsSnapshot::get_dart_signal_receiver();
    let select_model_recv = signals::SelectLocalModel::get_dart_signal_receiver();
    let hotkey_recv = signals::SetSelectedHotkey::get_dart_signal_receiver();
    let microphone_recv = signals::SetSelectedMicrophoneId::get_dart_signal_receiver();
    let sound_recv = signals::SetSoundEnabled::get_dart_signal_receiver();
    let vocabulary_recv = signals::SetCustomVocabulary::get_dart_signal_receiver();
    let min_duration_recv = signals::SetMinimumRecordingDurationMs::get_dart_signal_receiver();
    let setup_recv = signals::SetHasCompletedSetup::get_dart_signal_receiver();

    let mut snapshot = config_to_snapshot(&current_config(&runtime));
    send_snapshot(&snapshot);

    let persist = |snapshot: &signals::SettingsSnapshot| {
        let config = snapshot_to_config(snapshot);
        if let Err(error) = store.save(&config) {
            log::error!("Failed to persist settings snapshot: {error}");
        }
    };

    loop {
        tokio::select! {
            Some(_) = request_recv.recv() => {
                send_snapshot(&snapshot);
            }
            Some(pack) = select_model_recv.recv() => {
                let next = update_runtime(&runtime, |config| {
                    config.selected_local_model_id = pack.message.model_id;
                });
                snapshot = config_to_snapshot(&next);
                persist(&snapshot);
                send_snapshot(&snapshot);
            }
            Some(pack) = hotkey_recv.recv() => {
                let next = update_runtime(&runtime, |config| {
                    config.selected_hotkey = pack.message.selected_hotkey;
                });
                snapshot = config_to_snapshot(&next);
                persist(&snapshot);
                send_snapshot(&snapshot);
            }
            Some(pack) = microphone_recv.recv() => {
                let next = update_runtime(&runtime, |config| {
                    config.selected_microphone_id = pack.message.selected_microphone_id;
                });
                snapshot = config_to_snapshot(&next);
                persist(&snapshot);
                send_snapshot(&snapshot);
            }
            Some(pack) = sound_recv.recv() => {
                let next = update_runtime(&runtime, |config| {
                    config.sound_enabled = pack.message.sound_enabled;
                });
                snapshot = config_to_snapshot(&next);
                persist(&snapshot);
                send_snapshot(&snapshot);
            }
            Some(pack) = vocabulary_recv.recv() => {
                let next = update_runtime(&runtime, |config| {
                    config.custom_vocabulary = pack.message.custom_vocabulary;
                });
                snapshot = config_to_snapshot(&next);
                persist(&snapshot);
                send_snapshot(&snapshot);
            }
            Some(pack) = min_duration_recv.recv() => {
                let next = update_runtime(&runtime, |config| {
                    config.minimum_recording_duration_ms = pack.message.minimum_recording_duration_ms;
                });
                snapshot = config_to_snapshot(&next);
                persist(&snapshot);
                send_snapshot(&snapshot);
            }
            Some(pack) = setup_recv.recv() => {
                let next = update_runtime(&runtime, |config| {
                    config.has_completed_setup = pack.message.has_completed_setup;
                });
                snapshot = config_to_snapshot(&next);
                persist(&snapshot);
                send_snapshot(&snapshot);
            }
            else => break,
        }
    }
}
