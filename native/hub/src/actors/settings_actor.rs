//! Settings actor — owns persisted application settings and their Rust snapshot.

use rinf::{DartSignal, RustSignal};
use wrenflow_core::ConfigStore;
use wrenflow_domain::config::AppConfig;

use crate::signals;

const APP_NAME: &str = "Wrenflow";

fn config_to_snapshot(config: &AppConfig) -> signals::SettingsSnapshot {
    signals::SettingsSnapshot {
        selected_local_model_id: config.selected_local_model_id.clone(),
        api_key: config.api_key.clone(),
        api_base_url: config.api_base_url.clone(),
        selected_hotkey: config.selected_hotkey.clone(),
        selected_microphone_id: config.selected_microphone_id.clone(),
        sound_enabled: config.sound_enabled,
        custom_vocabulary: config.custom_vocabulary.clone(),
        transcription_provider: config.transcription_provider.clone(),
        transcription_model: config.transcription_model.clone(),
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
        api_key: snapshot.api_key.clone(),
        api_base_url: snapshot.api_base_url.clone(),
        transcription_provider: snapshot.transcription_provider.clone(),
        transcription_model: snapshot.transcription_model.clone(),
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

pub async fn run(initial_config: AppConfig) {
    let store = ConfigStore::default_for(APP_NAME);
    let request_recv = signals::RequestSettingsSnapshot::get_dart_signal_receiver();
    let update_recv = signals::UpdateSettingsSnapshot::get_dart_signal_receiver();

    let mut snapshot = config_to_snapshot(&initial_config);
    send_snapshot(&snapshot);

    loop {
        tokio::select! {
            Some(_) = request_recv.recv() => {
                send_snapshot(&snapshot);
            }
            Some(pack) = update_recv.recv() => {
                snapshot = pack.message.snapshot;
                let config = snapshot_to_config(&snapshot);
                if let Err(error) = store.save(&config) {
                    log::error!("Failed to persist settings snapshot: {error}");
                }
                send_snapshot(&snapshot);
            }
            else => break,
        }
    }
}
