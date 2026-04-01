//! Model actor — manages local Parakeet model download, loading, and lifecycle.
//! Stores the loaded engine in a shared Arc<Mutex> for pipeline to use.

use rinf::{DartSignal, RustSignal};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;
use wrenflow_core::model_downloader;
use wrenflow_core::model_management::{
    default_parakeet_model, DownloadProgress, LocalModelState, ModelDownloadListener,
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
    last_signal: Mutex<Instant>,
}

impl SignalDownloadListener {
    fn new() -> Self {
        Self {
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
        signals::ModelStateChanged {
            state: signals::ModelState::Downloading {
                progress: fraction,
                speed_bps: 0.0,
                eta_secs: 0.0,
            },
        }
        .send_signal_to_dart();
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
        signals::ModelStateChanged {
            state: signal_state,
        }
        .send_signal_to_dart();
    }
}

fn model_dir() -> PathBuf {
    let base = dirs::data_local_dir().unwrap_or_else(|| PathBuf::from("."));
    base.join("wrenflow").join("models").join("parakeet-tdt")
}

/// Run the model actor. Stores loaded engine in `engine_handle`.
pub async fn run(engine_handle: SharedTranscriptionEngine) {
    let init_recv = signals::InitializeLocalModel::get_dart_signal_receiver();
    let cancel_recv = signals::CancelModelDownload::get_dart_signal_receiver();
    let cancel_flag: Arc<AtomicBool> = Arc::new(AtomicBool::new(false));

    loop {
        tokio::select! {
            Some(_) = init_recv.recv() => {
                cancel_flag.store(false, Ordering::Relaxed);
                handle_initialize(cancel_flag.clone(), engine_handle.clone()).await;
            }
            Some(_) = cancel_recv.recv() => {
                log::info!("Model download cancel requested");
                cancel_flag.store(true, Ordering::Relaxed);
            }
            else => break,
        }
    }
}

async fn handle_initialize(cancel_flag: Arc<AtomicBool>, engine_handle: SharedTranscriptionEngine) {
    log::info!("handle_initialize called");
    let model = default_parakeet_model();
    let dir = model_dir();
    log::info!("Model dir: {:?}, present: {}", dir, model_downloader::is_model_present(&model, &dir));

    // 1. Download if needed
    if !model_downloader::is_model_present(&model, &dir) {
        signals::ModelStateChanged {
            state: signals::ModelState::Downloading {
                progress: 0.0,
                speed_bps: 0.0,
                eta_secs: 0.0,
            },
        }
        .send_signal_to_dart();

        let listener = Arc::new(SignalDownloadListener::new());
        match model_downloader::download_model(&model, &dir, listener, cancel_flag).await {
            Ok(_) => log::info!("Model download complete"),
            Err(e) if e == "Cancelled" => {
                signals::ModelStateChanged {
                    state: signals::ModelState::NotDownloaded,
                }
                .send_signal_to_dart();
                return;
            }
            Err(e) => {
                signals::ModelStateChanged {
                    state: signals::ModelState::Error { message: e },
                }
                .send_signal_to_dart();
                return;
            }
        }
    }

    // 2. Load model (blocking)
    signals::ModelStateChanged {
        state: signals::ModelState::Loading,
    }
    .send_signal_to_dart();

    let load_dir = dir.clone();
    let handle = engine_handle.clone();
    log::info!("Starting model load (spawn_blocking)...");
    let load_result = tokio::task::spawn_blocking(move || {
        log::info!("spawn_blocking: creating LocalTranscriptionEngine");
        let mut engine = LocalTranscriptionEngine::new();
        log::info!("spawn_blocking: calling engine.initialize()");
        engine.initialize(&load_dir, Some(&|state| {
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
                    signals::ModelState::Error { message: msg.clone() }
                }
                _ => return,
            };
            signals::ModelStateChanged { state: signal_state }.send_signal_to_dart();
        }))?;
        log::info!("spawn_blocking: engine.initialize() done, warming up...");

        // Prewarm: run dummy inference to compile ONNX graph ahead of first real use
        signals::ModelStateChanged {
            state: signals::ModelState::Warming,
        }.send_signal_to_dart();
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
            signals::ModelStateChanged {
                state: signals::ModelState::Ready,
            }
            .send_signal_to_dart();
        }
        Ok(Err(e)) => {
            log::error!("Model load failed: {e}");
            signals::ModelStateChanged {
                state: signals::ModelState::Error {
                    message: e.to_string(),
                },
            }
            .send_signal_to_dart();
        }
        Err(e) => {
            log::error!("Model load task panicked: {e}");
            signals::ModelStateChanged {
                state: signals::ModelState::Error {
                    message: format!("Internal error: {e}"),
                },
            }
            .send_signal_to_dart();
        }
    }
}
