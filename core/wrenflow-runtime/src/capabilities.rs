use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use tokio::sync::oneshot;
use wrenflow_core::audio_capture::AudioCapture;
use wrenflow_domain::audio::device::AudioDeviceInfo;
use wrenflow_domain::config::DEFAULT_SELECTED_MICROPHONE_ID;

use crate::platform::{paste_injection_supported, runtime_probe};
use crate::state::{AudioDevicesSnapshot, RuntimeCapabilities};
use crate::store::{RuntimeStore, StoreUpdate};
use crate::RuntimeError;

#[derive(Debug)]
pub(crate) struct AudioDeviceInventory {
    pub(crate) devices: Vec<AudioDeviceInfo>,
    pub(crate) default_device_name: String,
}

#[derive(Clone)]
pub(crate) struct AudioDeviceProbe {
    operation: Arc<dyn Fn() -> AudioDeviceInventory + Send + Sync>,
    in_flight: Arc<AtomicBool>,
}

impl AudioDeviceProbe {
    pub(crate) fn new(
        operation: impl Fn() -> AudioDeviceInventory + Send + Sync + 'static,
    ) -> Self {
        Self {
            operation: Arc::new(operation),
            in_flight: Arc::new(AtomicBool::new(false)),
        }
    }

    fn start(&self) -> Result<oneshot::Receiver<AudioDeviceInventory>, RuntimeError> {
        self.in_flight
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .map_err(|_| RuntimeError::ServiceFailed {
                service: "audio_devices",
                message: "audio device probe is already running".to_string(),
            })?;
        let operation = Arc::clone(&self.operation);
        let in_flight = Arc::clone(&self.in_flight);
        let (sender, receiver) = oneshot::channel();
        std::thread::Builder::new()
            .name("wrenflow-audio-device-probe".to_string())
            .spawn(move || {
                struct ResetInFlight(Arc<AtomicBool>);

                impl Drop for ResetInFlight {
                    fn drop(&mut self) {
                        self.0.store(false, Ordering::Release);
                    }
                }

                let _reset = ResetInFlight(in_flight);
                let _ = sender.send(operation());
            })
            .map_err(|_| {
                self.in_flight.store(false, Ordering::Release);
                RuntimeError::ServiceFailed {
                    service: "audio_devices",
                    message: "audio device probe task could not start".to_string(),
                }
            })?;
        Ok(receiver)
    }
}

const AUDIO_DEVICE_PROBE_TIMEOUT: Duration = Duration::from_secs(5);

pub(crate) fn production_audio_device_probe() -> AudioDeviceProbe {
    AudioDeviceProbe::new(|| AudioDeviceInventory {
        devices: AudioCapture::list_input_devices(),
        default_device_name: AudioCapture::default_input_device_name(),
    })
}

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

pub(crate) async fn refresh_audio_devices(
    runtime: &RuntimeStore,
    probe: &AudioDeviceProbe,
) -> Result<StoreUpdate, RuntimeError> {
    refresh_audio_devices_with_timeout(runtime, probe, AUDIO_DEVICE_PROBE_TIMEOUT).await
}

async fn refresh_audio_devices_with_timeout(
    runtime: &RuntimeStore,
    probe: &AudioDeviceProbe,
    timeout: Duration,
) -> Result<StoreUpdate, RuntimeError> {
    let receiver = probe.start()?;
    let AudioDeviceInventory {
        devices,
        default_device_name,
    } = tokio::time::timeout(timeout, receiver)
        .await
        .map_err(|_| RuntimeError::ServiceFailed {
            service: "audio_devices",
            message: "audio device probe timed out".to_string(),
        })?
        .map_err(|_| RuntimeError::ServiceFailed {
            service: "audio_devices",
            message: "audio device probe task failed".to_string(),
        })?;
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    use tokio::sync::{broadcast, watch};

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn stuck_probe_times_out_closed_and_remains_single_flight() {
        let snapshot = crate::supervisor::initial_snapshot(&crate::RuntimeBootstrap::default());
        let (snapshot_tx, _) = watch::channel(Arc::new(snapshot.clone()));
        let (audio_tx, _) = watch::channel(0.0);
        let (event_tx, _) = broadcast::channel(1);
        let store = RuntimeStore::new(snapshot, snapshot_tx, audio_tx, event_tx);
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let release_rx = Arc::new(std::sync::Mutex::new(release_rx));
        let probe = AudioDeviceProbe::new(move || {
            entered_tx.send(()).unwrap();
            release_rx.lock().unwrap().recv().unwrap();
            AudioDeviceInventory {
                devices: Vec::new(),
                default_device_name: String::new(),
            }
        });

        let first_store = store.clone();
        let first_probe = probe.clone();
        let first = tokio::spawn(async move {
            refresh_audio_devices_with_timeout(
                &first_store,
                &first_probe,
                Duration::from_millis(25),
            )
            .await
        });
        entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(matches!(
            first.await.unwrap(),
            Err(RuntimeError::ServiceFailed {
                service: "audio_devices",
                ref message,
            }) if message == "audio device probe timed out"
        ));
        assert!(!store.snapshot().audio_devices.has_snapshot);
        assert!(matches!(
            refresh_audio_devices_with_timeout(&store, &probe, Duration::from_millis(25)).await,
            Err(RuntimeError::ServiceFailed {
                service: "audio_devices",
                ref message,
            }) if message == "audio device probe is already running"
        ));

        release_tx.send(()).unwrap();
    }
}
