use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::Duration;

use tokio::sync::oneshot;
use wrenflow_core::history_store::HistoryStore;
use wrenflow_domain::history::HistoryEntry;

use crate::store::RuntimeStore;
use crate::{HistoryLoadState, RuntimeError, RuntimeEvent};

const HISTORY_LOADING: u8 = 0;
const HISTORY_READY: u8 = 1;
const HISTORY_ERROR: u8 = 2;
const SHUTDOWN_ACK_TIMEOUT: Duration = Duration::from_millis(100);
const HISTORY_COMMAND_CAPACITY: usize = 64;

pub(crate) type HistoryLoader =
    Arc<dyn Fn(&Path) -> Result<(HistoryStore, Vec<HistoryEntry>), String> + Send + Sync + 'static>;

struct HistoryLifecycle {
    availability: AtomicU8,
    shutdown_requested: AtomicBool,
    failure: Mutex<Option<String>>,
    initialization_transition: Mutex<()>,
}

impl HistoryLifecycle {
    fn loading() -> Self {
        Self {
            availability: AtomicU8::new(HISTORY_LOADING),
            shutdown_requested: AtomicBool::new(false),
            failure: Mutex::new(None),
            initialization_transition: Mutex::new(()),
        }
    }

    fn mark_ready(&self) {
        self.availability.store(HISTORY_READY, Ordering::Release);
    }

    fn mark_error(&self, message: String) {
        if let Ok(mut failure) = self.failure.lock() {
            *failure = Some(message);
        }
        self.availability.store(HISTORY_ERROR, Ordering::Release);
    }

    fn request_shutdown(&self) {
        // Linearize shutdown against the one initialization publication. Once
        // this returns, a late loader result can no longer mutate the store.
        let _transition = self.initialization_transition.lock().ok();
        self.shutdown_requested.store(true, Ordering::Release);
    }

    fn is_shutdown_requested(&self) -> bool {
        self.shutdown_requested.load(Ordering::Acquire)
    }

    fn require_insert_queue_open(&self) -> Result<(), RuntimeError> {
        if self.is_shutdown_requested() {
            return Err(RuntimeError::ServiceClosed("history"));
        }
        if self.availability.load(Ordering::Acquire) == HISTORY_ERROR {
            return self.require_ready();
        }
        Ok(())
    }

    fn require_ready(&self) -> Result<(), RuntimeError> {
        let _transition = self.initialization_transition.lock().map_err(|_| {
            history_error("history initialization state is unavailable".to_string())
        })?;
        match self.availability.load(Ordering::Acquire) {
            HISTORY_READY if !self.is_shutdown_requested() => Ok(()),
            HISTORY_ERROR => Err(history_error(
                self.failure
                    .lock()
                    .ok()
                    .and_then(|failure| failure.clone())
                    .unwrap_or_else(|| "history failed to initialize".to_string()),
            )),
            _ if self.is_shutdown_requested() => Err(RuntimeError::ServiceClosed("history")),
            _ => Err(history_error("history is still loading".to_string())),
        }
    }
}

enum HistoryCommand {
    Insert {
        entry: HistoryEntry,
        completion: Option<oneshot::Sender<Result<u64, String>>>,
    },
    Delete {
        id: String,
        completion: oneshot::Sender<Result<u64, String>>,
    },
    Clear {
        completion: oneshot::Sender<Result<u64, String>>,
    },
    Shutdown {
        completion: mpsc::SyncSender<()>,
    },
}

#[derive(Clone)]
pub(crate) struct HistoryHandle {
    commands: mpsc::SyncSender<HistoryCommand>,
    lifecycle: Arc<HistoryLifecycle>,
}

impl HistoryHandle {
    /// Inserts are the only operations accepted while the store is loading.
    /// The worker preserves channel order and applies them after the initial
    /// snapshot, so an early transcription is not exposed as loaded state
    /// before its database is available. Delete and clear fail closed until
    /// the store is Ready, keeping the supervisor responsive to shutdown.
    pub(crate) fn insert(&self, entry: HistoryEntry) -> Result<(), RuntimeError> {
        self.lifecycle.require_insert_queue_open()?;
        self.commands
            .try_send(HistoryCommand::Insert {
                entry,
                completion: None,
            })
            .map_err(history_send_error)
    }

    pub(crate) async fn insert_acknowledged(
        &self,
        entry: HistoryEntry,
    ) -> Result<u64, RuntimeError> {
        self.lifecycle.require_ready()?;
        let (completion, result) = oneshot::channel();
        self.commands
            .try_send(HistoryCommand::Insert {
                entry,
                completion: Some(completion),
            })
            .map_err(history_send_error)?;
        result
            .await
            .map_err(|_| RuntimeError::ServiceClosed("history"))?
            .map_err(history_error)
    }

    pub(crate) async fn delete(&self, id: String) -> Result<u64, RuntimeError> {
        self.lifecycle.require_ready()?;
        let (completion, result) = oneshot::channel();
        self.commands
            .try_send(HistoryCommand::Delete { id, completion })
            .map_err(history_send_error)?;
        result
            .await
            .map_err(|_| RuntimeError::ServiceClosed("history"))?
            .map_err(history_error)
    }

    pub(crate) async fn clear(&self) -> Result<u64, RuntimeError> {
        self.lifecycle.require_ready()?;
        let (completion, result) = oneshot::channel();
        self.commands
            .try_send(HistoryCommand::Clear { completion })
            .map_err(history_send_error)?;
        result
            .await
            .map_err(|_| RuntimeError::ServiceClosed("history"))?
            .map_err(history_error)
    }

    pub(crate) fn shutdown(&self) {
        self.lifecycle.request_shutdown();
        let (completion, acknowledgement) = mpsc::sync_channel(1);
        if self
            .commands
            .try_send(HistoryCommand::Shutdown { completion })
            .is_ok()
        {
            let _ = acknowledgement.recv_timeout(SHUTDOWN_ACK_TIMEOUT);
        }
    }
}

pub(crate) struct HistoryRuntime {
    pub(crate) handle: HistoryHandle,
    pub(crate) join: std::thread::JoinHandle<()>,
}

pub(crate) fn start(path: PathBuf, runtime: RuntimeStore) -> Result<HistoryRuntime, RuntimeError> {
    start_with_loader(path, runtime, Arc::new(load_history))
}

pub(crate) fn start_with_loader(
    path: PathBuf,
    runtime: RuntimeStore,
    loader: HistoryLoader,
) -> Result<HistoryRuntime, RuntimeError> {
    let (commands, receiver) = mpsc::sync_channel(HISTORY_COMMAND_CAPACITY);
    let lifecycle = Arc::new(HistoryLifecycle::loading());
    let worker_lifecycle = lifecycle.clone();
    let join = std::thread::Builder::new()
        .name("wrenflow-history".to_string())
        .spawn(move || initialize_and_run(path, loader, receiver, runtime, worker_lifecycle))
        .map_err(|error| RuntimeError::ServiceFailed {
            service: "history",
            message: error.to_string(),
        })?;

    Ok(HistoryRuntime {
        handle: HistoryHandle {
            commands,
            lifecycle,
        },
        join,
    })
}

fn load_history(path: &Path) -> Result<(HistoryStore, Vec<HistoryEntry>), String> {
    let store = HistoryStore::open(path).map_err(|error| {
        format!(
            "{error}. The original database was not overwritten; inspect the quarantine and use the explicit GPUI data reset flow if recovery is not required"
        )
    })?;
    let entries = store.load_all().map_err(|error| error.to_string())?;
    Ok((store, entries))
}

fn initialize_and_run(
    path: PathBuf,
    loader: HistoryLoader,
    receiver: mpsc::Receiver<HistoryCommand>,
    runtime: RuntimeStore,
    lifecycle: Arc<HistoryLifecycle>,
) {
    let loaded = loader(&path);
    let initialized_store = {
        let Ok(_transition) = lifecycle.initialization_transition.lock() else {
            lifecycle.mark_error("history initialization state is unavailable".to_string());
            reject_pending(&receiver, "history initialization state is unavailable");
            return;
        };
        if lifecycle.is_shutdown_requested() {
            reject_pending(
                &receiver,
                "history shut down before initialization completed",
            );
            return;
        }

        match loaded {
            Ok((store, initial_entries)) => {
                let published = runtime.update(|snapshot| {
                    snapshot.history.load_state = HistoryLoadState::Ready;
                    snapshot.history.has_snapshot = true;
                    snapshot.history.entries = initial_entries;
                    true
                });
                match published {
                    Ok(_) => {
                        // Ready commands take this transition lock, so they
                        // cannot observe the publication half-complete.
                        lifecycle.mark_ready();
                        Some(store)
                    }
                    Err(error) => {
                        let message = error.to_string();
                        lifecycle.mark_error(message.clone());
                        reject_pending(&receiver, &message);
                        None
                    }
                }
            }
            Err(message) => {
                log::error!("Current GPUI history recovery required: {message}");
                lifecycle.mark_error(message.clone());
                let update_message = message.clone();
                let _ = runtime.update(|snapshot| {
                    snapshot.history.load_state = HistoryLoadState::Error {
                        message: update_message,
                    };
                    snapshot.history.has_snapshot = false;
                    snapshot.history.entries.clear();
                    true
                });
                runtime.emit(RuntimeEvent::PipelineError {
                    message: format!("Failed to load history: {message}"),
                    action: None,
                });
                reject_pending(&receiver, &message);
                None
            }
        }
    };

    if let Some(store) = initialized_store {
        run(store, receiver, runtime, &lifecycle);
    }
}

fn run(
    mut store: HistoryStore,
    receiver: mpsc::Receiver<HistoryCommand>,
    runtime: RuntimeStore,
    lifecycle: &HistoryLifecycle,
) {
    while let Ok(command) = receiver.recv() {
        if lifecycle.is_shutdown_requested() {
            reject_command(command, "history is shutting down");
            reject_pending(&receiver, "history is shutting down");
            break;
        }
        match command {
            HistoryCommand::Insert { entry, completion } => {
                let result = insert(&mut store, &runtime, lifecycle, entry);
                if let Some(completion) = completion {
                    let _ = completion.send(result);
                }
            }
            HistoryCommand::Delete { id, completion } => {
                let result = delete(&mut store, &runtime, lifecycle, &id);
                let _ = completion.send(result);
            }
            HistoryCommand::Clear { completion } => {
                let result = clear(&mut store, &runtime, lifecycle);
                let _ = completion.send(result);
            }
            HistoryCommand::Shutdown { completion } => {
                let _ = completion.send(());
                break;
            }
        }
    }
}

fn reject_pending(receiver: &mpsc::Receiver<HistoryCommand>, message: &str) {
    while let Ok(command) = receiver.try_recv() {
        reject_command(command, message);
    }
}

fn reject_command(command: HistoryCommand, message: &str) {
    let failure = || Err(message.to_string());
    match command {
        HistoryCommand::Insert {
            completion: Some(completion),
            ..
        } => {
            let _ = completion.send(failure());
        }
        HistoryCommand::Delete { completion, .. } | HistoryCommand::Clear { completion } => {
            let _ = completion.send(failure());
        }
        HistoryCommand::Shutdown { completion } => {
            let _ = completion.send(());
        }
        HistoryCommand::Insert {
            completion: None, ..
        } => {}
    }
}

fn insert(
    store: &mut HistoryStore,
    runtime: &RuntimeStore,
    lifecycle: &HistoryLifecycle,
    entry: HistoryEntry,
) -> Result<u64, String> {
    if let Err(error) = store.insert(&entry) {
        runtime.emit(RuntimeEvent::PipelineError {
            message: format!("Failed to persist history: {error}"),
            action: None,
        });
        return Err(error.to_string());
    }
    if let Err(error) = store.trim(50) {
        log::error!("Failed to trim history: {error}");
        return Err(error.to_string());
    }
    let _transition = lifecycle
        .initialization_transition
        .lock()
        .map_err(|_| "history initialization state is unavailable".to_string())?;
    if lifecycle.is_shutdown_requested() {
        return Err("history is shutting down".to_string());
    }
    let event_entry = entry.clone();
    let update = runtime
        .update(|snapshot| {
            debug_assert!(matches!(
                &snapshot.history.load_state,
                HistoryLoadState::Ready
            ));
            snapshot.history.has_snapshot = true;
            snapshot
                .history
                .entries
                .retain(|existing| existing.id != entry.id);
            snapshot.history.entries.insert(0, entry);
            snapshot.history.entries.truncate(50);
            true
        })
        .map_err(|error| error.to_string())?;
    runtime.emit(RuntimeEvent::HistoryEntryAdded(event_entry));
    Ok(update.revision)
}

fn delete(
    store: &mut HistoryStore,
    runtime: &RuntimeStore,
    lifecycle: &HistoryLifecycle,
    id: &str,
) -> Result<u64, String> {
    store.delete(id).map_err(|error| error.to_string())?;
    let _transition = lifecycle
        .initialization_transition
        .lock()
        .map_err(|_| "history initialization state is unavailable".to_string())?;
    if lifecycle.is_shutdown_requested() {
        return Err("history is shutting down".to_string());
    }
    let update = runtime
        .update(|snapshot| {
            debug_assert!(matches!(
                &snapshot.history.load_state,
                HistoryLoadState::Ready
            ));
            let old_len = snapshot.history.entries.len();
            snapshot.history.entries.retain(|entry| entry.id != id);
            snapshot.history.has_snapshot = true;
            snapshot.history.entries.len() != old_len
        })
        .map_err(|error| error.to_string())?;
    Ok(update.revision)
}

fn clear(
    store: &mut HistoryStore,
    runtime: &RuntimeStore,
    lifecycle: &HistoryLifecycle,
) -> Result<u64, String> {
    store.clear_all().map_err(|error| error.to_string())?;
    let _transition = lifecycle
        .initialization_transition
        .lock()
        .map_err(|_| "history initialization state is unavailable".to_string())?;
    if lifecycle.is_shutdown_requested() {
        return Err("history is shutting down".to_string());
    }
    let update = runtime
        .update(|snapshot| {
            debug_assert!(matches!(
                &snapshot.history.load_state,
                HistoryLoadState::Ready
            ));
            let changed = !snapshot.history.entries.is_empty() || !snapshot.history.has_snapshot;
            snapshot.history.has_snapshot = true;
            snapshot.history.entries.clear();
            changed
        })
        .map_err(|error| error.to_string())?;
    Ok(update.revision)
}

fn history_error(message: String) -> RuntimeError {
    RuntimeError::ServiceFailed {
        service: "history",
        message,
    }
}

fn history_send_error(error: mpsc::TrySendError<HistoryCommand>) -> RuntimeError {
    match error {
        mpsc::TrySendError::Full(_) => history_error("history command queue is full".to_string()),
        mpsc::TrySendError::Disconnected(_) => RuntimeError::ServiceClosed("history"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};
    use tokio::sync::{broadcast, watch};

    fn test_store() -> RuntimeStore {
        let snapshot = crate::supervisor::initial_snapshot(&crate::RuntimeBootstrap::default());
        let (snapshot_tx, _) = watch::channel(Arc::new(snapshot.clone()));
        let (audio_level_tx, _) = watch::channel(0.0_f32);
        let (event_tx, _) = broadcast::channel(16);
        RuntimeStore::new(snapshot, snapshot_tx, audio_level_tx, event_tx)
    }

    fn entry(id: &str, timestamp: f64) -> HistoryEntry {
        HistoryEntry {
            id: id.to_string(),
            timestamp,
            transcript: format!("transcript-{id}"),
            custom_vocabulary: String::new(),
            audio_file_name: None,
            metrics_json: "{}".to_string(),
        }
    }

    async fn wait_for_history(
        store: &RuntimeStore,
        predicate: impl Fn(&crate::HistorySnapshot) -> bool,
    ) {
        let mut snapshots = store.subscribe_snapshots();
        tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                if predicate(&snapshots.borrow().history) {
                    break;
                }
                snapshots.changed().await.unwrap();
            }
        })
        .await
        .expect("history state did not converge");
    }

    #[tokio::test]
    async fn corrupt_database_publishes_error_without_false_ready_empty() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("history.sqlite");
        std::fs::write(&path, b"not a sqlite database").unwrap();
        let store = test_store();

        let history = start(path.clone(), store.clone()).unwrap();
        wait_for_history(&store, |history| {
            matches!(&history.load_state, HistoryLoadState::Error { .. })
        })
        .await;

        let snapshot = store.snapshot();
        assert!(matches!(
            &snapshot.history.load_state,
            HistoryLoadState::Error { message }
                if message.contains("quarantined") && message.contains("explicit GPUI data reset")
        ));
        assert!(!snapshot.history.has_snapshot);
        assert!(snapshot.history.entries.is_empty());
        assert!(!path.exists());
        assert!(std::fs::read_dir(dir.path()).unwrap().any(|entry| {
            entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with("history.sqlite.corrupt-")
        }));

        history.handle.shutdown();
        history.join.join().unwrap();
    }

    #[tokio::test]
    async fn inserts_queued_during_loading_keep_fifo_order_and_mutations_fail_closed() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("history.sqlite");
        let store = test_store();
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let release_rx = Mutex::new(release_rx);
        let loader: HistoryLoader = Arc::new(move |path| {
            entered_tx.send(()).unwrap();
            release_rx.lock().unwrap().recv().unwrap();
            load_history(path)
        });
        let history = start_with_loader(path.clone(), store.clone(), loader).unwrap();
        entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        history.handle.insert(entry("first", 1.0)).unwrap();
        history.handle.insert(entry("second", 2.0)).unwrap();
        let acknowledged_started = Instant::now();
        assert!(matches!(
            history.handle.insert_acknowledged(entry("ack", 3.0)).await,
            Err(RuntimeError::ServiceFailed {
                service: "history",
                message,
            }) if message == "history is still loading"
        ));
        assert!(acknowledged_started.elapsed() < Duration::from_millis(100));
        assert!(matches!(
            history.handle.clear().await,
            Err(RuntimeError::ServiceFailed {
                service: "history",
                message,
            }) if message == "history is still loading"
        ));
        assert!(matches!(
            &store.snapshot().history.load_state,
            HistoryLoadState::Loading
        ));

        release_tx.send(()).unwrap();
        wait_for_history(&store, |history| history.entries.len() == 2).await;
        assert_eq!(
            store
                .snapshot()
                .history
                .entries
                .iter()
                .map(|entry| entry.id.as_str())
                .collect::<Vec<_>>(),
            ["second", "first"]
        );

        history.handle.shutdown();
        history.join.join().unwrap();
        assert_eq!(
            HistoryStore::open(&path)
                .unwrap()
                .load_all()
                .unwrap()
                .iter()
                .map(|entry| entry.id.as_str())
                .collect::<Vec<_>>(),
            ["second", "first"]
        );
    }

    #[test]
    fn loading_insert_queue_is_bounded_and_fails_closed() {
        let dir = tempfile::tempdir().unwrap();
        let store = test_store();
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let release_rx = Mutex::new(release_rx);
        let loader: HistoryLoader = Arc::new(move |_| {
            entered_tx.send(()).unwrap();
            release_rx.lock().unwrap().recv().unwrap();
            Ok((HistoryStore::open_in_memory().unwrap(), Vec::new()))
        });
        let history = start_with_loader(dir.path().join("history.sqlite"), store, loader).unwrap();
        entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        for index in 0..HISTORY_COMMAND_CAPACITY {
            history
                .handle
                .insert(entry(&format!("queued-{index}"), index as f64))
                .unwrap();
        }
        assert!(matches!(
            history.handle.insert(entry("overflow", 100.0)),
            Err(RuntimeError::ServiceFailed {
                service: "history",
                message,
            }) if message == "history command queue is full"
        ));

        let started = Instant::now();
        history.handle.shutdown();
        assert!(started.elapsed() < Duration::from_millis(250));
        release_tx.send(()).unwrap();
        history.join.join().unwrap();
    }

    #[test]
    fn late_loader_result_is_ignored_after_bounded_shutdown() {
        let dir = tempfile::tempdir().unwrap();
        let store = test_store();
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let release_rx = Mutex::new(release_rx);
        let loader: HistoryLoader = Arc::new(move |_| {
            entered_tx.send(()).unwrap();
            release_rx.lock().unwrap().recv().unwrap();
            Ok((HistoryStore::open_in_memory().unwrap(), Vec::new()))
        });
        let history =
            start_with_loader(dir.path().join("history.sqlite"), store.clone(), loader).unwrap();
        entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        let started = Instant::now();
        history.handle.shutdown();
        assert!(
            started.elapsed() < Duration::from_millis(250),
            "history shutdown waited for the blocked loader"
        );
        release_tx.send(()).unwrap();
        history.join.join().unwrap();

        let snapshot = store.snapshot();
        assert_eq!(snapshot.revision, 0);
        assert!(matches!(
            &snapshot.history.load_state,
            HistoryLoadState::Loading
        ));
        assert!(!snapshot.history.has_snapshot);
        assert!(snapshot.history.entries.is_empty());
    }
}
