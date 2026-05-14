//! Model actor — manages local model download, loading, and lifecycle.
//! Stores the loaded engine in a shared Arc<Mutex> for pipeline to use.

use rinf::{DartSignal, RustSignal};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;
use wrenflow_core::model_downloader;
use wrenflow_core::model_management::{
    DownloadProgress, LocalModelState, ModelDownloadListener, all_local_models, local_model_by_id,
};
use wrenflow_core::transcription_local::LocalTranscriptionEngine;

use crate::signals;

/// Shared transcription engine — None until model is loaded.
pub type SharedTranscriptionEngine = Arc<Mutex<Option<LocalTranscriptionEngine>>>;

/// Create the shared engine handle.
pub fn shared_engine() -> SharedTranscriptionEngine {
    Arc::new(Mutex::new(None))
}

struct SignalDownloadListener {
    model_id: String,
    last_signal: Mutex<Instant>,
}

impl SignalDownloadListener {
    fn new(model_id: String) -> Self {
        Self {
            model_id,
            last_signal: Mutex::new(Instant::now()),
        }
    }
}

impl ModelDownloadListener for SignalDownloadListener {
    fn on_progress(&self, progress: DownloadProgress) {
        let now = Instant::now();
        let should_send = {
            let Ok(mut last) = self.last_signal.lock() else {
                return;
            };
            if now.duration_since(*last).as_millis() >= 50 {
                *last = now;
                true
            } else {
                false
            }
        };
        if !should_send {
            return;
        }

        let fraction = progress.fraction().unwrap_or(0.0);
        send_model_state(
            signals::ModelState::Downloading {
                progress: fraction,
                speed_bps: 0.0,
                eta_secs: 0.0,
            },
            Some(self.model_id.as_str()),
        );
    }

    fn on_state_changed(&self, state: LocalModelState) {
        let signal_state = match &state {
            LocalModelState::NotDownloaded => signals::ModelState::NotDownloaded,
            LocalModelState::Downloading(p) => signals::ModelState::Downloading {
                progress: p.fraction().unwrap_or(0.0),
                speed_bps: 0.0,
                eta_secs: 0.0,
            },
            LocalModelState::Loading => signals::ModelState::Loading,
            LocalModelState::Ready => signals::ModelState::Ready,
            LocalModelState::Error(msg) => signals::ModelState::Error {
                message: msg.clone(),
            },
        };
        send_model_state(signal_state, Some(self.model_id.as_str()));
    }
}

fn send_model_state(state: signals::ModelState, model_id: Option<&str>) {
    signals::ModelStateChanged {
        state,
        model_id: model_id.map(ToString::to_string),
    }
    .send_signal_to_dart();
}

fn model_dir_for(model_id: &str) -> Option<PathBuf> {
    let base = dirs::data_local_dir().unwrap_or_else(|| PathBuf::from("."));
    let model = local_model_by_id(model_id)?;
    Some(
        base.join("wrenflow")
            .join("models")
            .join(model.directory_name),
    )
}

fn installed_model_ids() -> Vec<String> {
    all_local_models()
        .into_iter()
        .filter_map(|model| {
            let dir = model_dir_for(&model.id)?;
            if model_downloader::is_model_present(&model, &dir) {
                Some(model.id)
            } else {
                None
            }
        })
        .collect()
}

fn send_models_status(selected_model_id: &str, active_model_id: Option<&str>) {
    signals::LocalModelsStatusChanged {
        selected_model_id: selected_model_id.to_string(),
        active_model_id: active_model_id.map(ToString::to_string),
        installed_model_ids: installed_model_ids(),
    }
    .send_signal_to_dart();
}

/// Run the model actor. Stores loaded engine in `engine_handle`.
pub async fn run(engine_handle: SharedTranscriptionEngine) {
    let init_recv = signals::InitializeLocalModel::get_dart_signal_receiver();
    let status_recv = signals::RequestLocalModelsStatus::get_dart_signal_receiver();
    let select_recv = signals::SelectLocalModel::get_dart_signal_receiver();
    let cancel_recv = signals::CancelModelDownload::get_dart_signal_receiver();
    let cancel_flag: Arc<AtomicBool> = Arc::new(AtomicBool::new(false));
    let current_model_id = Arc::new(Mutex::new(String::from("parakeet-tdt-0.6b-v3-onnx")));
    let active_model_id: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));

    send_models_status("parakeet-tdt-0.6b-v3-onnx", None);

    loop {
        tokio::select! {
            Some(_) = init_recv.recv() => {
                cancel_flag.store(false, Ordering::Relaxed);
                let selected_model_id = current_model_id
                    .lock()
                    .map(|guard| guard.clone())
                    .unwrap_or_else(|_| String::from("parakeet-tdt-0.6b-v3-onnx"));
                handle_initialize(
                    selected_model_id,
                    cancel_flag.clone(),
                    engine_handle.clone(),
                    active_model_id.clone(),
                ).await;
            }
            Some(_) = status_recv.recv() => {
                let selected_model_id = current_model_id
                    .lock()
                    .map(|guard| guard.clone())
                    .unwrap_or_else(|_| String::from("parakeet-tdt-0.6b-v3-onnx"));
                let active = active_model_id.lock().ok().and_then(|guard| guard.clone());
                send_models_status(&selected_model_id, active.as_deref());
            }
            Some(pack) = select_recv.recv() => {
                let model_id = pack.message.model_id;
                log::info!("Selected local model: {model_id}");
                let selected_model_id = if let Ok(mut guard) = current_model_id.lock() {
                    *guard = model_id;
                    guard.clone()
                } else {
                    String::from("parakeet-tdt-0.6b-v3-onnx")
                };
                let active = active_model_id.lock().ok().and_then(|guard| guard.clone());
                send_models_status(&selected_model_id, active.as_deref());
            }
            Some(_) = cancel_recv.recv() => {
                log::info!("Model download cancel requested");
                cancel_flag.store(true, Ordering::Relaxed);
            }
            else => break,
        }
    }
}

async fn handle_initialize(
    selected_model_id: String,
    cancel_flag: Arc<AtomicBool>,
    engine_handle: SharedTranscriptionEngine,
    active_model_id: Arc<Mutex<Option<String>>>,
) {
    log::info!("handle_initialize called for {selected_model_id}");
    let Some(model) = local_model_by_id(&selected_model_id) else {
        send_model_state(
            signals::ModelState::Error {
                message: format!("Unknown local model '{selected_model_id}'"),
            },
            Some(&selected_model_id),
        );
        return;
    };
    let Some(dir) = model_dir_for(&selected_model_id) else {
        send_model_state(
            signals::ModelState::Error {
                message: format!("Local model '{selected_model_id}' is not wired yet"),
            },
            Some(&selected_model_id),
        );
        return;
    };
    log::info!(
        "Model dir: {:?}, present: {}",
        dir,
        model_downloader::is_model_present(&model, &dir)
    );

    // 1. Download if needed
    if !model_downloader::is_model_present(&model, &dir) {
        send_model_state(
            signals::ModelState::Downloading {
                progress: 0.0,
                speed_bps: 0.0,
                eta_secs: 0.0,
            },
            Some(&selected_model_id),
        );

        let listener = Arc::new(SignalDownloadListener::new(selected_model_id.clone()));
        match model_downloader::download_model(&model, &dir, listener, cancel_flag).await {
            Ok(_) => log::info!("Model download complete"),
            Err(e) if e == "Cancelled" => {
                send_model_state(signals::ModelState::NotDownloaded, Some(&selected_model_id));
                let active = active_model_id.lock().ok().and_then(|guard| guard.clone());
                send_models_status(&selected_model_id, active.as_deref());
                return;
            }
            Err(e) => {
                send_model_state(
                    signals::ModelState::Error { message: e },
                    Some(&selected_model_id),
                );
                let active = active_model_id.lock().ok().and_then(|guard| guard.clone());
                send_models_status(&selected_model_id, active.as_deref());
                return;
            }
        }
    }

    // 2. Load model (blocking)
    send_model_state(signals::ModelState::Loading, Some(&selected_model_id));

    let load_dir = dir.clone();
    let handle = engine_handle.clone();
    let model_for_engine = model.clone();
    let selected_model_id_for_task = selected_model_id.clone();
    log::info!("Starting model load (spawn_blocking)...");
    let load_result = tokio::task::spawn_blocking(move || {
        log::info!("spawn_blocking: creating LocalTranscriptionEngine");
        let mut engine = LocalTranscriptionEngine::new(&model_for_engine);
        log::info!("spawn_blocking: calling engine.initialize()");
        engine.initialize(
            &load_dir,
            Some(&|state| {
                let signal_state = match state {
                    wrenflow_core::transcription_local::ModelState::Compiling => {
                        log::info!("Model state: Compiling (ONNX execution plan)");
                        signals::ModelState::Loading
                    }
                    wrenflow_core::transcription_local::ModelState::Ready => {
                        log::info!("Model state: Loaded (proceeding to warmup)");
                        signals::ModelState::Warming
                    }
                    wrenflow_core::transcription_local::ModelState::Error(msg) => {
                        log::error!("Model state: Error({msg})");
                        signals::ModelState::Error {
                            message: msg.clone(),
                        }
                    }
                    _ => return,
                };
                send_model_state(signal_state, Some(&selected_model_id_for_task));
            }),
        )?;
        log::info!("spawn_blocking: engine.initialize() done, warming up...");

        // Prewarm: run dummy inference to compile ONNX graph ahead of first real use
        send_model_state(
            signals::ModelState::Warming,
            Some(&selected_model_id_for_task),
        );
        engine.prewarm().ok();

        // Store in shared handle
        if let Ok(mut guard) = handle.lock() {
            *guard = Some(engine);
        }
        Ok::<(), wrenflow_core::transcription_local::LocalTranscriptionError>(())
    })
    .await;

    match load_result {
        Ok(Ok(())) => {
            log::info!("Local transcription model ready");
            if let Ok(mut guard) = active_model_id.lock() {
                *guard = Some(selected_model_id.clone());
            }
            send_model_state(signals::ModelState::Ready, Some(&selected_model_id));
            send_models_status(&selected_model_id, Some(&selected_model_id));
        }
        Ok(Err(e)) => {
            log::error!("Model load failed: {e}");
            send_model_state(
                signals::ModelState::Error {
                    message: e.to_string(),
                },
                Some(&selected_model_id),
            );
            let active = active_model_id.lock().ok().and_then(|guard| guard.clone());
            send_models_status(&selected_model_id, active.as_deref());
        }
        Err(e) => {
            log::error!("Model load task panicked: {e}");
            send_model_state(
                signals::ModelState::Error {
                    message: format!("Internal error: {e}"),
                },
                Some(&selected_model_id),
            );
            let active = active_model_id.lock().ok().and_then(|guard| guard.clone());
            send_models_status(&selected_model_id, active.as_deref());
        }
    }
}
