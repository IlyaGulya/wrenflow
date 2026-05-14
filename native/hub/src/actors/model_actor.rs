//! Model actor — manages local model download, loading, and lifecycle.
//! Stores the loaded engine in a shared Arc<Mutex> for pipeline to use.

use rinf::{DartSignal, RustSignal};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;
use wrenflow_core::model_downloader;
use wrenflow_core::model_management::{
    DownloadProgress, LocalModelState, ModelDownloadListener, all_local_model_catalog_entries,
    all_local_models, local_model_by_id,
};
use wrenflow_core::transcription_local::LocalTranscriptionEngine;

use crate::signals;

/// Shared transcription engine — None until model is loaded.
pub type SharedTranscriptionEngine = Arc<Mutex<Option<LocalTranscriptionEngine>>>;

/// Create the shared engine handle.
pub fn shared_engine() -> SharedTranscriptionEngine {
    Arc::new(Mutex::new(None))
}

type SharedLocalModelsSnapshot = Arc<Mutex<LocalModelsRuntimeState>>;

#[derive(Clone, Debug)]
struct LocalModelsRuntimeState {
    selected_model_id: String,
    active_model_id: Option<String>,
    model_states: HashMap<String, signals::ModelState>,
}

impl LocalModelsRuntimeState {
    fn new(default_model_id: &str) -> Self {
        Self {
            selected_model_id: default_model_id.to_string(),
            active_model_id: None,
            model_states: HashMap::new(),
        }
    }
}

struct SignalDownloadListener {
    model_id: String,
    snapshot: SharedLocalModelsSnapshot,
    last_signal: Mutex<Instant>,
}

impl SignalDownloadListener {
    fn new(model_id: String, snapshot: SharedLocalModelsSnapshot) -> Self {
        Self {
            model_id,
            snapshot,
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
        set_model_state(
            &self.snapshot,
            &self.model_id,
            signals::ModelState::Downloading {
                progress: fraction,
                speed_bps: 0.0,
                eta_secs: 0.0,
            },
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
        set_model_state(&self.snapshot, &self.model_id, signal_state);
    }
}

fn local_model_catalog_items() -> Vec<signals::LocalModelCatalogItem> {
    all_local_model_catalog_entries()
        .into_iter()
        .map(|model| signals::LocalModelCatalogItem {
            id: model.id,
            display_name: model.display_name,
            subtitle: model.subtitle,
            download_label: model.download_label,
            family: model.family,
            runtime_label: model.runtime_label,
            is_recommended: model.is_recommended,
            is_available: model.is_available,
            supports_current_runtime: model.supports_current_runtime,
        })
        .collect()
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

fn send_models_snapshot(snapshot: &SharedLocalModelsSnapshot) {
    let Ok(guard) = snapshot.lock() else {
        return;
    };

    let selected_model_id = guard.selected_model_id.clone();
    let active_model_id = guard.active_model_id.clone();
    let model_states = guard
        .model_states
        .iter()
        .map(|(model_id, state)| signals::LocalModelRuntimeState {
            model_id: model_id.clone(),
            state: state.clone(),
        })
        .collect();
    drop(guard);

    signals::LocalModelsSnapshotChanged {
        models: local_model_catalog_items(),
        selected_model_id,
        active_model_id,
        installed_model_ids: installed_model_ids(),
        model_states,
    }
    .send_signal_to_dart();
}

fn update_models_snapshot(
    snapshot: &SharedLocalModelsSnapshot,
    update: impl FnOnce(&mut LocalModelsRuntimeState),
) {
    let Ok(mut guard) = snapshot.lock() else {
        return;
    };
    update(&mut guard);
    drop(guard);
    send_models_snapshot(snapshot);
}

fn set_model_state(
    snapshot: &SharedLocalModelsSnapshot,
    model_id: &str,
    state: signals::ModelState,
) {
    update_models_snapshot(snapshot, |runtime| {
        runtime.model_states.insert(model_id.to_string(), state);
    });
}

/// Run the model actor. Stores loaded engine in `engine_handle`.
pub async fn run(engine_handle: SharedTranscriptionEngine) {
    let init_recv = signals::InitializeLocalModel::get_dart_signal_receiver();
    let snapshot_recv = signals::RequestLocalModelsSnapshot::get_dart_signal_receiver();
    let select_recv = signals::SelectLocalModel::get_dart_signal_receiver();
    let cancel_recv = signals::CancelModelDownload::get_dart_signal_receiver();
    let cancel_flag: Arc<AtomicBool> = Arc::new(AtomicBool::new(false));
    let snapshot: SharedLocalModelsSnapshot = Arc::new(Mutex::new(LocalModelsRuntimeState::new(
        "parakeet-tdt-0.6b-v3-onnx",
    )));

    send_models_snapshot(&snapshot);

    loop {
        tokio::select! {
            Some(_) = init_recv.recv() => {
                cancel_flag.store(false, Ordering::Relaxed);
                let selected_model_id = snapshot
                    .lock()
                    .map(|guard| guard.selected_model_id.clone())
                    .unwrap_or_else(|_| String::from("parakeet-tdt-0.6b-v3-onnx"));
                handle_initialize(
                    selected_model_id,
                    cancel_flag.clone(),
                    engine_handle.clone(),
                    snapshot.clone(),
                ).await;
            }
            Some(_) = snapshot_recv.recv() => {
                send_models_snapshot(&snapshot);
            }
            Some(pack) = select_recv.recv() => {
                let model_id = pack.message.model_id;
                log::info!("Selected local model: {model_id}");
                update_models_snapshot(&snapshot, |runtime| {
                    runtime.selected_model_id = model_id;
                });
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
    snapshot: SharedLocalModelsSnapshot,
) {
    log::info!("handle_initialize called for {selected_model_id}");
    let Some(model) = local_model_by_id(&selected_model_id) else {
        set_model_state(
            &snapshot,
            &selected_model_id,
            signals::ModelState::Error {
                message: format!("Unknown local model '{selected_model_id}'"),
            },
        );
        return;
    };
    let Some(dir) = model_dir_for(&selected_model_id) else {
        set_model_state(
            &snapshot,
            &selected_model_id,
            signals::ModelState::Error {
                message: format!("Local model '{selected_model_id}' is not wired yet"),
            },
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
        set_model_state(
            &snapshot,
            &selected_model_id,
            signals::ModelState::Downloading {
                progress: 0.0,
                speed_bps: 0.0,
                eta_secs: 0.0,
            },
        );

        let listener = Arc::new(SignalDownloadListener::new(
            selected_model_id.clone(),
            snapshot.clone(),
        ));
        match model_downloader::download_model(&model, &dir, listener, cancel_flag).await {
            Ok(_) => log::info!("Model download complete"),
            Err(e) if e == "Cancelled" => {
                update_models_snapshot(&snapshot, |runtime| {
                    runtime.model_states.remove(&selected_model_id);
                });
                return;
            }
            Err(e) => {
                set_model_state(
                    &snapshot,
                    &selected_model_id,
                    signals::ModelState::Error { message: e },
                );
                return;
            }
        }
    }

    // 2. Load model (blocking)
    set_model_state(&snapshot, &selected_model_id, signals::ModelState::Loading);

    let load_dir = dir.clone();
    let handle = engine_handle.clone();
    let model_for_engine = model.clone();
    let selected_model_id_for_task = selected_model_id.clone();
    let snapshot_for_task = snapshot.clone();
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
                set_model_state(
                    &snapshot_for_task,
                    &selected_model_id_for_task,
                    signal_state,
                );
            }),
        )?;
        log::info!("spawn_blocking: engine.initialize() done, warming up...");

        // Prewarm: run dummy inference to compile ONNX graph ahead of first real use
        set_model_state(
            &snapshot_for_task,
            &selected_model_id_for_task,
            signals::ModelState::Warming,
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
            update_models_snapshot(&snapshot, |runtime| {
                runtime.active_model_id = Some(selected_model_id.clone());
                runtime
                    .model_states
                    .insert(selected_model_id.clone(), signals::ModelState::Ready);
            });
        }
        Ok(Err(e)) => {
            log::error!("Model load failed: {e}");
            set_model_state(
                &snapshot,
                &selected_model_id,
                signals::ModelState::Error {
                    message: e.to_string(),
                },
            );
        }
        Err(e) => {
            log::error!("Model load task panicked: {e}");
            set_model_state(
                &snapshot,
                &selected_model_id,
                signals::ModelState::Error {
                    message: format!("Internal error: {e}"),
                },
            );
        }
    }
}
