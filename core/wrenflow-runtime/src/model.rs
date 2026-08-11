use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;
use wrenflow_core::model_downloader;
use wrenflow_core::model_management::{
    all_local_model_catalog_entries, all_local_models, local_model_by_id, DownloadProgress,
    LocalModelCatalogEntry, LocalModelState, ModelDownloadListener,
};
use wrenflow_core::transcription_local::LocalTranscriptionEngine;
use wrenflow_core::ConfigStore;
use wrenflow_domain::config::AppConfig;
use wrenflow_domain::pipeline::TranscriptionResult;

use crate::state::{LocalModelRuntimeState, ModelInventoryState, ModelOperationState};
use crate::store::RuntimeStore;
use crate::{RuntimeError, RuntimeEvent};

enum ModelCommand {
    ActivateSelected,
    Cancel,
    Shutdown,
}

#[derive(Clone)]
pub(crate) struct ModelHandle {
    commands: mpsc::Sender<ModelCommand>,
    transcription: TranscriptionService,
}

impl ModelHandle {
    pub(crate) async fn activate_selected(&self) -> Result<(), RuntimeError> {
        self.commands
            .send(ModelCommand::ActivateSelected)
            .await
            .map_err(|_| RuntimeError::ServiceClosed("models"))
    }

    pub(crate) async fn cancel(&self) -> Result<(), RuntimeError> {
        self.commands
            .send(ModelCommand::Cancel)
            .await
            .map_err(|_| RuntimeError::ServiceClosed("models"))
    }

    pub(crate) async fn shutdown(&self) {
        let _ = self.commands.send(ModelCommand::Shutdown).await;
    }

    pub(crate) fn transcription(&self) -> TranscriptionService {
        self.transcription.clone()
    }
}

pub(crate) struct ModelRuntime {
    pub(crate) handle: ModelHandle,
    pub(crate) join: JoinHandle<()>,
}

#[derive(Clone)]
struct ModelInventoryProbe {
    operation: Arc<dyn Fn() -> Vec<String> + Send + Sync>,
    in_flight: Arc<AtomicBool>,
}

impl ModelInventoryProbe {
    fn new(operation: impl Fn() -> Vec<String> + Send + Sync + 'static) -> Self {
        Self {
            operation: Arc::new(operation),
            in_flight: Arc::new(AtomicBool::new(false)),
        }
    }

    fn start(&self) -> Result<oneshot::Receiver<Vec<String>>, RuntimeError> {
        self.in_flight
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .map_err(|_| RuntimeError::ServiceFailed {
                service: "models",
                message: "model inventory verification is already running".to_string(),
            })?;
        let operation = Arc::clone(&self.operation);
        let in_flight = Arc::clone(&self.in_flight);
        let (sender, receiver) = oneshot::channel();
        std::thread::Builder::new()
            .name("wrenflow-model-inventory-probe".to_string())
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
                    service: "models",
                    message: "model inventory verification could not start".to_string(),
                }
            })?;
        Ok(receiver)
    }
}

const MODEL_INVENTORY_TIMEOUT: Duration = Duration::from_secs(30);

async fn verified_inventory(
    probe: &ModelInventoryProbe,
    timeout: Duration,
) -> Result<Vec<String>, RuntimeError> {
    let receiver = probe.start()?;
    tokio::time::timeout(timeout, receiver)
        .await
        .map_err(|_| RuntimeError::ServiceFailed {
            service: "models",
            message: "model inventory verification timed out".to_string(),
        })?
        .map_err(|_| RuntimeError::ServiceFailed {
            service: "models",
            message: "model inventory verification failed".to_string(),
        })
}

/// The only owner-facing interface to a loaded inference engine.
///
/// Neither UI adapter receives the engine mutex itself; inference is always a
/// complete operation with stable metadata captured under the same lock.
#[derive(Clone, Default)]
pub(crate) struct TranscriptionService {
    engine: Arc<Mutex<Option<LocalTranscriptionEngine>>>,
}

impl TranscriptionService {
    pub(crate) fn is_ready(&self) -> bool {
        self.engine
            .lock()
            .map(|engine| engine.is_some())
            .unwrap_or(false)
    }

    pub(crate) async fn transcribe(
        &self,
        samples: Vec<f32>,
        custom_vocabulary: String,
    ) -> Result<TranscriptionResult, String> {
        let engine = self.engine.clone();
        tokio::task::spawn_blocking(move || {
            let started = Instant::now();
            let mut guard = engine.lock().map_err(|_| unavailable_model_message())?;
            let active = guard.as_mut().ok_or_else(unavailable_model_message)?;
            let model_id = active.model_id().to_string();
            let model_name = active.model_display_name().to_string();
            let raw_transcript = active
                .transcribe(&samples, Some(&custom_vocabulary))
                .map_err(|error| error.user_message())?;
            Ok(TranscriptionResult {
                raw_transcript,
                duration_ms: started.elapsed().as_secs_f64() * 1_000.0,
                provider: "local".to_string(),
                model_id,
                model_name,
            })
        })
        .await
        .map_err(|error| format!("Transcription task failed: {error}"))?
    }
}

pub(crate) fn start(store: RuntimeStore, settings_store: Option<Arc<ConfigStore>>) -> ModelRuntime {
    start_with_inventory_probe(
        store,
        settings_store,
        ModelInventoryProbe::new(installed_model_ids),
        MODEL_INVENTORY_TIMEOUT,
    )
}

fn start_with_inventory_probe(
    store: RuntimeStore,
    settings_store: Option<Arc<ConfigStore>>,
    inventory_probe: ModelInventoryProbe,
    inventory_timeout: Duration,
) -> ModelRuntime {
    let (commands, receiver) = mpsc::channel(8);
    let transcription = TranscriptionService::default();

    let worker_transcription = transcription.clone();
    let join = tokio::spawn(async move {
        run(
            receiver,
            store,
            settings_store,
            worker_transcription,
            inventory_probe,
            inventory_timeout,
        )
        .await;
    });
    ModelRuntime {
        handle: ModelHandle {
            commands,
            transcription,
        },
        join,
    }
}

async fn run(
    mut commands: mpsc::Receiver<ModelCommand>,
    store: RuntimeStore,
    settings_store: Option<Arc<ConfigStore>>,
    transcription: TranscriptionService,
    inventory_probe: ModelInventoryProbe,
    inventory_timeout: Duration,
) {
    let cancel = Arc::new(AtomicBool::new(false));
    let mut inventory_task = Some(tokio::spawn(async move {
        verified_inventory(&inventory_probe, inventory_timeout).await
    }));
    let mut active_request = None;
    let mut task = None;
    let mut pending = None;

    loop {
        tokio::select! {
            command = commands.recv() => {
                match command {
                    Some(ModelCommand::ActivateSelected) => {
                        let selected = store.snapshot().models.selected_model_id.clone();
                        if inventory_task.is_some() {
                            pending = Some(selected);
                            continue;
                        }
                        match decide_initialize_request(task.is_some(), active_request.as_deref(), &selected) {
                            InitializeRequestDecision::StartNow => {
                                cancel.store(false, Ordering::Relaxed);
                                active_request = Some(selected.clone());
                                task = Some(spawn_activation(
                                    selected,
                                    true,
                                    cancel.clone(),
                                    transcription.clone(),
                                    store.clone(),
                                    settings_store.clone(),
                                ));
                            }
                            InitializeRequestDecision::Ignore => {}
                            InitializeRequestDecision::CancelCurrentAndQueue => {
                                pending = Some(selected);
                                cancel.store(true, Ordering::Relaxed);
                            }
                        }
                    }
                    Some(ModelCommand::Cancel) => {
                        pending = None;
                        cancel.store(true, Ordering::Relaxed);
                    }
                    Some(ModelCommand::Shutdown) | None => {
                        cancel.store(true, Ordering::Relaxed);
                        if let Some(inventory_task) = inventory_task.take() {
                            inventory_task.abort();
                        }
                        if let Some(task) = task.take() {
                            let _ = task.await;
                        }
                        break;
                    }
                }
            }
            result = async {
                match inventory_task.as_mut() {
                    Some(task) => Some(task.await),
                    None => None,
                }
            }, if inventory_task.is_some() => {
                inventory_task = None;
                match result {
                    Some(Ok(Ok(installed))) => {
                        publish_inventory(&store, installed.clone());
                        if task.is_none() {
                            let next = pending
                                .take()
                                .map(|model_id| (model_id, true))
                                .or_else(|| {
                                    let startup = store.snapshot().settings.clone();
                                    resolve_startup_active_model_id_with(&startup, &installed)
                                        .map(|model_id| (model_id, false))
                                });
                            if let Some((model_id, allow_download)) = next {
                                active_request = Some(model_id.clone());
                                task = Some(spawn_activation(
                                    model_id,
                                    allow_download,
                                    cancel.clone(),
                                    transcription.clone(),
                                    store.clone(),
                                    settings_store.clone(),
                                ));
                            }
                        }
                    }
                    Some(Ok(Err(error))) => {
                        pending = None;
                        publish_inventory_error(&store);
                        log::error!("Model inventory verification failed: {error}");
                        crate::diagnostics::emit_diagnostic(crate::diagnostics::DiagnosticEvent::new(
                            crate::diagnostics::DiagnosticCategory::Models,
                            crate::diagnostics::DiagnosticLevel::Error,
                            crate::diagnostics::DiagnosticCode::ModelInventoryRefreshFailed,
                        ));
                    }
                    Some(Err(error)) => {
                        pending = None;
                        publish_inventory_error(&store);
                        log::error!("Model inventory task failed: {error}");
                        crate::diagnostics::emit_diagnostic(crate::diagnostics::DiagnosticEvent::new(
                            crate::diagnostics::DiagnosticCategory::Models,
                            crate::diagnostics::DiagnosticLevel::Error,
                            crate::diagnostics::DiagnosticCode::ModelInventoryRefreshFailed,
                        ));
                    }
                    None => {}
                }
            }
            result = async {
                match task.as_mut() {
                    Some(task) => Some(task.await),
                    None => None,
                }
            }, if task.is_some() => {
                task = None;
                active_request = None;
                if let Some(Err(error)) = result {
                    log::error!("Model activation task failed: {error}");
                }
                if let Some(model_id) = pending.take() {
                    cancel.store(false, Ordering::Relaxed);
                    active_request = Some(model_id.clone());
                    task = Some(spawn_activation(
                        model_id,
                        true,
                        cancel.clone(),
                        transcription.clone(),
                        store.clone(),
                        settings_store.clone(),
                    ));
                }
            }
        }
    }
}

fn spawn_activation(
    model_id: String,
    allow_download: bool,
    cancel: Arc<AtomicBool>,
    transcription: TranscriptionService,
    store: RuntimeStore,
    settings_store: Option<Arc<ConfigStore>>,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        activate(
            model_id,
            allow_download,
            cancel,
            transcription,
            store,
            settings_store,
        )
        .await;
    })
}

async fn activate(
    model_id: String,
    allow_download: bool,
    cancel: Arc<AtomicBool>,
    transcription: TranscriptionService,
    store: RuntimeStore,
    settings_store: Option<Arc<ConfigStore>>,
) {
    let Some(model) = local_model_by_id(&model_id) else {
        set_state(
            &store,
            &model_id,
            error_state(format!("Unknown local model '{model_id}'")),
        );
        return;
    };
    let catalog = all_local_model_catalog_entries()
        .into_iter()
        .find(|entry| entry.id == model_id);
    let Some(catalog) = catalog else {
        set_state(
            &store,
            &model_id,
            error_state(format!(
                "Local model '{model_id}' is missing from the catalog"
            )),
        );
        return;
    };
    let Some(directory) = model_dir_for(&model_id) else {
        set_state(
            &store,
            &model_id,
            error_state(format!("Local model '{model_id}' is not wired yet")),
        );
        return;
    };

    if !catalog.supports_current_runtime {
        set_state(
            &store,
            &model_id,
            error_state(format!(
                "{} is not supported by the current runtime",
                catalog.display_name
            )),
        );
        return;
    }
    if !crate::platform::runtime_probe::onnx_runtime_available() {
        set_state(
            &store,
            &model_id,
            error_state("Local ONNX runtime is unavailable in the current build".to_string()),
        );
        return;
    }
    let model_present = model_downloader::is_model_present(&model, &directory);
    if !model_present && !crate::platform::runtime_probe::model_storage_writable() {
        set_state(
            &store,
            &model_id,
            error_state("Local model storage is not writable".to_string()),
        );
        return;
    }
    if cancel.load(Ordering::Relaxed) {
        remove_state(&store, &model_id);
        return;
    }

    if !model_present {
        if !allow_download {
            remove_state(&store, &model_id);
            return;
        }
        set_state(
            &store,
            &model_id,
            ModelOperationState::Downloading {
                progress: 0.0,
                speed_bps: 0.0,
                eta_secs: 0.0,
            },
        );
        let listener = Arc::new(RuntimeDownloadListener::new(
            model_id.clone(),
            store.clone(),
        ));
        match model_downloader::download_model(&model, &directory, listener, cancel.clone()).await {
            Ok(_) => {}
            Err(message) if message == "Cancelled" => {
                remove_state(&store, &model_id);
                return;
            }
            Err(message) => {
                set_state(&store, &model_id, error_state(message));
                return;
            }
        }
    }
    publish_verified_model(&store, &model_id);

    set_state(&store, &model_id, ModelOperationState::Loading);
    let engine = transcription.engine.clone();
    let task_model_id = model_id.clone();
    let task_store = store.clone();
    let task_cancel = cancel.clone();
    let load = tokio::task::spawn_blocking(
        move || -> Result<bool, wrenflow_core::transcription_local::LocalTranscriptionError> {
            if task_cancel.load(Ordering::Relaxed) {
                return Ok(false);
            }
            let mut next = LocalTranscriptionEngine::new(&model);
            next.initialize(
                &directory,
                Some(&|state| match state {
                    wrenflow_core::transcription_local::ModelState::Compiling => {
                        set_state(&task_store, &task_model_id, ModelOperationState::Loading);
                    }
                    wrenflow_core::transcription_local::ModelState::Ready => {
                        set_state(&task_store, &task_model_id, ModelOperationState::Warming);
                    }
                    wrenflow_core::transcription_local::ModelState::Error(message) => {
                        set_state(&task_store, &task_model_id, error_state(message.clone()));
                    }
                    _ => {}
                }),
            )?;
            if task_cancel.load(Ordering::Relaxed) {
                return Ok(false);
            }
            set_state(&task_store, &task_model_id, ModelOperationState::Warming);
            let _ = next.prewarm();
            if task_cancel.load(Ordering::Relaxed) {
                return Ok(false);
            }
            let mut guard = engine.lock().map_err(|_| {
                wrenflow_core::transcription_local::LocalTranscriptionError::ModelNotLoaded
            })?;
            *guard = Some(next);
            Ok(true)
        },
    )
    .await;

    match load {
        Ok(Ok(true)) => {
            let _ = store.update(|snapshot| {
                snapshot.models.active_model_id = Some(model_id.clone());
                upsert_state(snapshot, &model_id, ModelOperationState::Ready);
                snapshot.settings.last_active_model_id = Some(model_id.clone());
                true
            });
            if let Some(settings_store) = settings_store {
                let settings = store.snapshot().settings.clone();
                if let Err(error) = settings_store.save(&settings) {
                    store.emit(RuntimeEvent::PipelineError {
                        message: format!("Failed to persist active model: {error}"),
                        action: None,
                    });
                }
            }
        }
        Ok(Ok(false)) => remove_state(&store, &model_id),
        Ok(Err(error)) => set_state(&store, &model_id, error_state(error.to_string())),
        Err(error) => set_state(
            &store,
            &model_id,
            error_state(format!("Internal error: {error}")),
        ),
    }
}

struct RuntimeDownloadListener {
    model_id: String,
    store: RuntimeStore,
    started_at: Instant,
    previous: Mutex<(Instant, u64, f64)>,
}

impl RuntimeDownloadListener {
    fn new(model_id: String, store: RuntimeStore) -> Self {
        let now = Instant::now();
        Self {
            model_id,
            store,
            started_at: now,
            previous: Mutex::new((now, 0, 0.0)),
        }
    }
}

impl ModelDownloadListener for RuntimeDownloadListener {
    fn on_progress(&self, progress: DownloadProgress) {
        let now = Instant::now();
        let Ok(mut previous) = self.previous.lock() else {
            return;
        };
        let elapsed = now.duration_since(previous.0);
        if elapsed.as_millis() < 50 {
            return;
        }
        let delta = progress.bytes_downloaded.saturating_sub(previous.1) as f64;
        let instant = delta / elapsed.as_secs_f64().max(f64::EPSILON);
        let smoothed = if previous.2 <= 0.0 {
            instant
        } else {
            previous.2 * 0.8 + instant * 0.2
        };
        *previous = (now, progress.bytes_downloaded, smoothed);
        drop(previous);

        let average = progress.bytes_downloaded as f64
            / self.started_at.elapsed().as_secs_f64().max(f64::EPSILON);
        let speed_bps = if self.started_at.elapsed().as_secs_f64() >= 1.0 {
            (smoothed + average) / 2.0
        } else {
            smoothed
        };
        let eta_secs = progress
            .total_bytes
            .filter(|total| *total > progress.bytes_downloaded && speed_bps > 1.0)
            .map(|total| (total - progress.bytes_downloaded) as f64 / speed_bps)
            .unwrap_or(0.0);
        set_state(
            &self.store,
            &self.model_id,
            ModelOperationState::Downloading {
                progress: progress.fraction().unwrap_or(0.0),
                speed_bps,
                eta_secs,
            },
        );
    }

    fn on_state_changed(&self, state: LocalModelState) {
        let next = match state {
            LocalModelState::NotDownloaded => ModelOperationState::NotDownloaded,
            LocalModelState::Downloading(progress) => ModelOperationState::Downloading {
                progress: progress.fraction().unwrap_or(0.0),
                speed_bps: 0.0,
                eta_secs: 0.0,
            },
            LocalModelState::Loading => ModelOperationState::Loading,
            LocalModelState::Ready => ModelOperationState::Ready,
            LocalModelState::Error(message) => error_state(message),
        };
        set_state(&self.store, &self.model_id, next);
    }
}

fn publish_inventory(store: &RuntimeStore, installed: Vec<String>) {
    let _ = store.update(|snapshot| {
        if snapshot.models.installed_model_ids == installed
            && snapshot.models.inventory_state == ModelInventoryState::Ready
        {
            false
        } else {
            snapshot.models.installed_model_ids = installed;
            snapshot.models.inventory_state = ModelInventoryState::Ready;
            true
        }
    });
}

fn publish_verified_model(store: &RuntimeStore, model_id: &str) {
    let _ = store.update(|snapshot| {
        if snapshot
            .models
            .installed_model_ids
            .iter()
            .any(|installed| installed == model_id)
        {
            false
        } else {
            snapshot
                .models
                .installed_model_ids
                .push(model_id.to_string());
            true
        }
    });
}

fn publish_inventory_error(store: &RuntimeStore) {
    let _ = store.update(|snapshot| {
        if snapshot.models.inventory_state == ModelInventoryState::Error {
            false
        } else {
            snapshot.models.installed_model_ids.clear();
            snapshot.models.inventory_state = ModelInventoryState::Error;
            true
        }
    });
}

fn upsert_state(snapshot: &mut crate::RuntimeSnapshot, model_id: &str, state: ModelOperationState) {
    if let Some(existing) = snapshot
        .models
        .model_states
        .iter_mut()
        .find(|existing| existing.model_id == model_id)
    {
        existing.state = state;
    } else {
        snapshot.models.model_states.push(LocalModelRuntimeState {
            model_id: model_id.to_string(),
            state,
        });
    }
}

fn set_state(store: &RuntimeStore, model_id: &str, state: ModelOperationState) {
    let _ = store.update(|snapshot| {
        upsert_state(snapshot, model_id, state);
        true
    });
}

fn remove_state(store: &RuntimeStore, model_id: &str) {
    let _ = store.update(|snapshot| {
        let old_len = snapshot.models.model_states.len();
        snapshot
            .models
            .model_states
            .retain(|state| state.model_id != model_id);
        snapshot.models.model_states.len() != old_len
    });
}

fn error_state(message: String) -> ModelOperationState {
    ModelOperationState::Error { message }
}

pub(crate) fn model_dir_for(model_id: &str) -> Option<PathBuf> {
    let model = local_model_by_id(model_id)?;
    Some(
        crate::data_paths::current_data_paths()
            .models
            .join(model.directory_name),
    )
}

fn installed_model_ids() -> Vec<String> {
    all_local_models()
        .into_iter()
        .filter_map(|model| {
            let directory = model_dir_for(&model.id)?;
            model_downloader::is_model_present(&model, &directory).then_some(model.id)
        })
        .collect()
}

fn resolve_startup_active_model_id_with(
    config: &AppConfig,
    installed_ids: &[String],
) -> Option<String> {
    if installed_ids
        .iter()
        .any(|installed| installed == &config.selected_local_model_id)
    {
        return Some(config.selected_local_model_id.clone());
    }
    if let Some(last_active) = &config.last_active_model_id {
        if installed_ids
            .iter()
            .any(|installed| installed == last_active)
        {
            return Some(last_active.clone());
        }
    }
    installed_ids.first().cloned()
}

#[derive(Debug, PartialEq, Eq)]
enum InitializeRequestDecision {
    StartNow,
    Ignore,
    CancelCurrentAndQueue,
}

fn decide_initialize_request(
    task_running: bool,
    current_model_id: Option<&str>,
    selected_model_id: &str,
) -> InitializeRequestDecision {
    if !task_running {
        InitializeRequestDecision::StartNow
    } else if current_model_id == Some(selected_model_id) {
        InitializeRequestDecision::Ignore
    } else {
        InitializeRequestDecision::CancelCurrentAndQueue
    }
}

pub(crate) fn preflight_error_for_state(
    catalog: &LocalModelCatalogEntry,
    is_installed: bool,
) -> Option<String> {
    if !catalog.is_available {
        Some(format!(
            "{} is not shipped in this build yet. Open Settings -> Models and choose another model.",
            catalog.display_name
        ))
    } else if !catalog.supports_current_runtime {
        Some(format!(
            "{} is not supported by the current runtime. Open Settings -> Models and choose another model.",
            catalog.display_name
        ))
    } else if is_installed {
        Some(format!(
            "{} is selected but not active yet. Open Settings -> Models and activate it first.",
            catalog.display_name
        ))
    } else {
        Some(format!(
            "{} is not downloaded yet. Open Settings -> Models to download it, or choose another model.",
            catalog.display_name
        ))
    }
}

pub(crate) fn preflight_error(
    store: &RuntimeStore,
    service: &TranscriptionService,
) -> Option<String> {
    if service.is_ready() {
        return None;
    }
    let snapshot = store.snapshot();
    match snapshot.models.inventory_state {
        ModelInventoryState::Loading => {
            return Some(
                "Local model verification is still in progress. Try recording again shortly."
                    .to_string(),
            );
        }
        ModelInventoryState::Error => {
            return Some(
                "Local model verification failed. Quit and reopen Wrenflow to retry verified model discovery."
                    .to_string(),
            );
        }
        ModelInventoryState::Ready => {}
    }
    let selected = snapshot.models.selected_model_id.clone();
    let catalog = all_local_model_catalog_entries()
        .into_iter()
        .find(|entry| entry.id == selected);
    let Some(catalog) = catalog else {
        return Some(
            "No local model is selected. Open Settings -> Models and choose one.".to_string(),
        );
    };
    let installed = snapshot
        .models
        .installed_model_ids
        .iter()
        .any(|model_id| model_id == &selected);
    preflight_error_for_state(&catalog, installed)
}

fn unavailable_model_message() -> String {
    "The active model is unavailable. Open Settings -> Models and activate a model again."
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::sync::{broadcast, watch};

    fn test_store() -> RuntimeStore {
        test_store_with_selected(&AppConfig::default().selected_local_model_id)
    }

    fn test_store_with_selected(selected_model_id: &str) -> RuntimeStore {
        let snapshot = crate::supervisor::initial_snapshot(&crate::RuntimeBootstrap {
            initial_config: AppConfig {
                selected_local_model_id: selected_model_id.to_string(),
                ..AppConfig::default()
            },
            ..crate::RuntimeBootstrap::default()
        });
        let (snapshot_tx, _) = watch::channel(Arc::new(snapshot.clone()));
        let (audio_tx, _) = watch::channel(0.0);
        let (event_tx, _) = broadcast::channel(1);
        RuntimeStore::new(snapshot, snapshot_tx, audio_tx, event_tx)
    }

    #[test]
    fn startup_fallback_order_is_selected_then_last_active_then_any() {
        let config = AppConfig {
            selected_local_model_id: "selected".to_string(),
            last_active_model_id: Some("last".to_string()),
            ..AppConfig::default()
        };

        assert_eq!(
            resolve_startup_active_model_id_with(
                &config,
                &[
                    "any".to_string(),
                    "last".to_string(),
                    "selected".to_string()
                ]
            )
            .as_deref(),
            Some("selected")
        );
        assert_eq!(
            resolve_startup_active_model_id_with(&config, &["any".to_string(), "last".to_string()])
                .as_deref(),
            Some("last")
        );
        assert_eq!(
            resolve_startup_active_model_id_with(&config, &["any".to_string()]).as_deref(),
            Some("any")
        );
    }

    #[test]
    fn activation_requests_are_coalesced_and_latest_different_model_is_queued() {
        assert_eq!(
            decide_initialize_request(false, None, "selected"),
            InitializeRequestDecision::StartNow
        );
        assert_eq!(
            decide_initialize_request(true, Some("selected"), "selected"),
            InitializeRequestDecision::Ignore
        );
        assert_eq!(
            decide_initialize_request(true, Some("active"), "selected"),
            InitializeRequestDecision::CancelCurrentAndQueue
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn verified_model_inventory_does_not_block_runtime_startup() {
        let store = test_store();
        let (entered_tx, entered_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let release_rx = Arc::new(Mutex::new(release_rx));
        let probe = ModelInventoryProbe::new(move || {
            entered_tx.send(()).unwrap();
            release_rx.lock().unwrap().recv().unwrap();
            Vec::new()
        });

        let started = Instant::now();
        let runtime =
            start_with_inventory_probe(store.clone(), None, probe, Duration::from_secs(30));
        assert!(started.elapsed() < Duration::from_millis(100));
        entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(store.snapshot().models.installed_model_ids.is_empty());
        assert_eq!(
            store.snapshot().models.inventory_state,
            ModelInventoryState::Loading
        );

        release_tx.send(()).unwrap();
        tokio::time::timeout(Duration::from_secs(1), async {
            loop {
                if store.snapshot().models.inventory_state == ModelInventoryState::Ready {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();
        runtime.handle.shutdown().await;
        tokio::time::timeout(Duration::from_secs(1), runtime.join)
            .await
            .unwrap()
            .unwrap();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn stuck_model_inventory_is_bounded_single_flight_and_shutdown_safe() {
        let store = test_store();
        let (entered_tx, entered_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let release_rx = Arc::new(Mutex::new(release_rx));
        let probe = ModelInventoryProbe::new(move || {
            entered_tx.send(()).unwrap();
            release_rx.lock().unwrap().recv().unwrap();
            Vec::new()
        });
        let runtime = start_with_inventory_probe(
            store.clone(),
            None,
            probe.clone(),
            Duration::from_millis(25),
        );
        entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        assert!(matches!(
            verified_inventory(&probe, Duration::from_millis(25)).await,
            Err(RuntimeError::ServiceFailed {
                service: "models",
                ref message,
            }) if message == "model inventory verification is already running"
        ));
        assert!(store.snapshot().models.installed_model_ids.is_empty());

        runtime.handle.shutdown().await;
        tokio::time::timeout(Duration::from_millis(250), runtime.join)
            .await
            .unwrap()
            .unwrap();
        release_tx.send(()).unwrap();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn model_inventory_timeout_stays_closed_until_probe_returns() {
        let (entered_tx, entered_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let release_rx = Arc::new(Mutex::new(release_rx));
        let probe = ModelInventoryProbe::new(move || {
            entered_tx.send(()).unwrap();
            release_rx.lock().unwrap().recv().unwrap();
            vec!["verified-model".to_string()]
        });
        let first_probe = probe.clone();
        let first = tokio::spawn(async move {
            verified_inventory(&first_probe, Duration::from_millis(25)).await
        });
        entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        assert!(matches!(
            first.await.unwrap(),
            Err(RuntimeError::ServiceFailed {
                service: "models",
                ref message,
            }) if message == "model inventory verification timed out"
        ));
        assert!(matches!(
            verified_inventory(&probe, Duration::from_millis(25)).await,
            Err(RuntimeError::ServiceFailed {
                service: "models",
                ref message,
            }) if message == "model inventory verification is already running"
        ));
        release_tx.send(()).unwrap();
        tokio::time::timeout(Duration::from_secs(1), async {
            while probe.in_flight.load(Ordering::Acquire) {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();
        let second_probe = probe.clone();
        let second =
            tokio::spawn(
                async move { verified_inventory(&second_probe, Duration::from_secs(1)).await },
            );
        entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        release_tx.send(()).unwrap();
        assert!(second.await.unwrap().is_ok());
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn early_activation_waits_for_verified_inventory() {
        let store = test_store_with_selected("test-model");
        let (entered_tx, entered_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let release_rx = Arc::new(Mutex::new(release_rx));
        let probe = ModelInventoryProbe::new(move || {
            entered_tx.send(()).unwrap();
            release_rx.lock().unwrap().recv().unwrap();
            Vec::new()
        });
        let runtime =
            start_with_inventory_probe(store.clone(), None, probe, Duration::from_secs(30));
        entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        runtime.handle.activate_selected().await.unwrap();
        tokio::time::sleep(Duration::from_millis(25)).await;
        assert!(store.snapshot().models.model_states.is_empty());
        assert_eq!(
            store.snapshot().models.inventory_state,
            ModelInventoryState::Loading
        );

        release_tx.send(()).unwrap();
        tokio::time::timeout(Duration::from_secs(1), async {
            loop {
                if !store.snapshot().models.model_states.is_empty() {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();
        assert_eq!(
            store.snapshot().models.inventory_state,
            ModelInventoryState::Ready
        );
        runtime.handle.shutdown().await;
        tokio::time::timeout(Duration::from_secs(1), runtime.join)
            .await
            .unwrap()
            .unwrap();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn panicked_inventory_probe_is_fail_closed_and_actor_stays_responsive() {
        let store = test_store();
        let runtime = start_with_inventory_probe(
            store.clone(),
            None,
            ModelInventoryProbe::new(|| panic!("injected inventory failure")),
            Duration::from_secs(1),
        );
        tokio::time::timeout(Duration::from_secs(1), async {
            loop {
                if store.snapshot().models.inventory_state == ModelInventoryState::Error {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap();
        assert!(store.snapshot().models.installed_model_ids.is_empty());

        runtime.handle.shutdown().await;
        tokio::time::timeout(Duration::from_millis(250), runtime.join)
            .await
            .unwrap()
            .unwrap();
    }

    #[test]
    fn transcription_preflight_reports_inventory_loading_and_recovery_truthfully() {
        let store = test_store();
        let service = TranscriptionService::default();
        assert_eq!(
            preflight_error(&store, &service).as_deref(),
            Some("Local model verification is still in progress. Try recording again shortly.")
        );
        publish_inventory_error(&store);
        assert_eq!(
            preflight_error(&store, &service).as_deref(),
            Some(
                "Local model verification failed. Quit and reopen Wrenflow to retry verified model discovery."
            )
        );
    }
}
