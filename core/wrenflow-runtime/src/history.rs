use std::path::PathBuf;
use std::sync::mpsc;

use tokio::sync::oneshot;
use wrenflow_core::history_store::HistoryStore;
use wrenflow_domain::history::HistoryEntry;

use crate::store::RuntimeStore;
use crate::{RuntimeError, RuntimeEvent};

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
    Shutdown,
}

#[derive(Clone)]
pub(crate) struct HistoryHandle {
    commands: mpsc::Sender<HistoryCommand>,
}

impl HistoryHandle {
    pub(crate) fn insert(&self, entry: HistoryEntry) -> Result<(), RuntimeError> {
        self.commands
            .send(HistoryCommand::Insert {
                entry,
                completion: None,
            })
            .map_err(|_| RuntimeError::ServiceClosed("history"))
    }

    pub(crate) async fn insert_acknowledged(
        &self,
        entry: HistoryEntry,
    ) -> Result<u64, RuntimeError> {
        let (completion, result) = oneshot::channel();
        self.commands
            .send(HistoryCommand::Insert {
                entry,
                completion: Some(completion),
            })
            .map_err(|_| RuntimeError::ServiceClosed("history"))?;
        result
            .await
            .map_err(|_| RuntimeError::ServiceClosed("history"))?
            .map_err(history_error)
    }

    pub(crate) async fn delete(&self, id: String) -> Result<u64, RuntimeError> {
        let (completion, result) = oneshot::channel();
        self.commands
            .send(HistoryCommand::Delete { id, completion })
            .map_err(|_| RuntimeError::ServiceClosed("history"))?;
        result
            .await
            .map_err(|_| RuntimeError::ServiceClosed("history"))?
            .map_err(history_error)
    }

    pub(crate) async fn clear(&self) -> Result<u64, RuntimeError> {
        let (completion, result) = oneshot::channel();
        self.commands
            .send(HistoryCommand::Clear { completion })
            .map_err(|_| RuntimeError::ServiceClosed("history"))?;
        result
            .await
            .map_err(|_| RuntimeError::ServiceClosed("history"))?
            .map_err(history_error)
    }

    pub(crate) fn shutdown(&self) {
        let _ = self.commands.send(HistoryCommand::Shutdown);
    }
}

pub(crate) struct HistoryRuntime {
    pub(crate) handle: HistoryHandle,
    pub(crate) join: std::thread::JoinHandle<()>,
}

pub(crate) fn start(path: PathBuf, runtime: RuntimeStore) -> Result<HistoryRuntime, RuntimeError> {
    let store = HistoryStore::open(&path).map_err(|error| {
        let message = format!(
            "{error}. The original database was not overwritten; inspect the quarantine and use the explicit GPUI data reset flow if recovery is not required"
        );
        log::error!("Current GPUI history recovery required: {message}");
        RuntimeError::ServiceFailed {
            service: "history",
            message,
        }
    })?;
    let initial_entries = store
        .load_all()
        .map_err(|error| RuntimeError::ServiceFailed {
            service: "history",
            message: error.to_string(),
        })?;
    runtime.update(|snapshot| {
        snapshot.history.has_snapshot = true;
        snapshot.history.entries = initial_entries;
        true
    })?;

    let (commands, receiver) = mpsc::channel();
    let join = std::thread::Builder::new()
        .name("wrenflow-history".to_string())
        .spawn(move || run(store, receiver, runtime))
        .map_err(|error| RuntimeError::ServiceFailed {
            service: "history",
            message: error.to_string(),
        })?;

    Ok(HistoryRuntime {
        handle: HistoryHandle { commands },
        join,
    })
}

fn run(mut store: HistoryStore, receiver: mpsc::Receiver<HistoryCommand>, runtime: RuntimeStore) {
    while let Ok(command) = receiver.recv() {
        match command {
            HistoryCommand::Insert { entry, completion } => {
                let result = insert(&mut store, &runtime, entry);
                if let Some(completion) = completion {
                    let _ = completion.send(result);
                }
            }
            HistoryCommand::Delete { id, completion } => {
                let result = delete(&mut store, &runtime, &id);
                let _ = completion.send(result);
            }
            HistoryCommand::Clear { completion } => {
                let result = clear(&mut store, &runtime);
                let _ = completion.send(result);
            }
            HistoryCommand::Shutdown => break,
        }
    }
}

fn insert(
    store: &mut HistoryStore,
    runtime: &RuntimeStore,
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
    let event_entry = entry.clone();
    let update = runtime
        .update(|snapshot| {
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

fn delete(store: &mut HistoryStore, runtime: &RuntimeStore, id: &str) -> Result<u64, String> {
    store.delete(id).map_err(|error| error.to_string())?;
    let update = runtime
        .update(|snapshot| {
            let old_len = snapshot.history.entries.len();
            snapshot.history.entries.retain(|entry| entry.id != id);
            snapshot.history.has_snapshot = true;
            snapshot.history.entries.len() != old_len
        })
        .map_err(|error| error.to_string())?;
    Ok(update.revision)
}

fn clear(store: &mut HistoryStore, runtime: &RuntimeStore) -> Result<u64, String> {
    store.clear_all().map_err(|error| error.to_string())?;
    let update = runtime
        .update(|snapshot| {
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
