use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, RwLock};

use tokio::sync::{broadcast, watch};

use crate::{RuntimeError, RuntimeEvent, RuntimeEventEnvelope, RuntimeSnapshot};

#[derive(Clone)]
pub(crate) struct RuntimeStore {
    state: Arc<RwLock<RuntimeSnapshot>>,
    snapshots: watch::Sender<Arc<RuntimeSnapshot>>,
    audio_level: watch::Sender<f32>,
    events: broadcast::Sender<RuntimeEventEnvelope>,
    next_event_sequence: Arc<AtomicU64>,
}

impl RuntimeStore {
    pub(crate) fn new(
        initial: RuntimeSnapshot,
        snapshots: watch::Sender<Arc<RuntimeSnapshot>>,
        audio_level: watch::Sender<f32>,
        events: broadcast::Sender<RuntimeEventEnvelope>,
    ) -> Self {
        Self {
            state: Arc::new(RwLock::new(initial)),
            snapshots,
            audio_level,
            events,
            next_event_sequence: Arc::new(AtomicU64::new(1)),
        }
    }

    pub(crate) fn snapshot(&self) -> Arc<RuntimeSnapshot> {
        self.state
            .read()
            .map(|state| Arc::new(state.clone()))
            .unwrap_or_else(|_| self.snapshots.borrow().clone())
    }

    pub(crate) fn subscribe_snapshots(&self) -> watch::Receiver<Arc<RuntimeSnapshot>> {
        self.snapshots.subscribe()
    }

    pub(crate) fn update(
        &self,
        update: impl FnOnce(&mut RuntimeSnapshot) -> bool,
    ) -> Result<StoreUpdate, RuntimeError> {
        let mut state = self
            .state
            .write()
            .map_err(|_| RuntimeError::StateUnavailable)?;
        if !update(&mut state) {
            return Ok(StoreUpdate {
                changed: false,
                revision: state.revision,
            });
        }

        state.revision = state.revision.saturating_add(1);
        let snapshot = Arc::new(state.clone());
        let revision = state.revision;
        drop(state);
        self.snapshots.send_replace(snapshot);
        Ok(StoreUpdate {
            changed: true,
            revision,
        })
    }

    pub(crate) fn emit(&self, event: RuntimeEvent) {
        let sequence = self.next_event_sequence.fetch_add(1, Ordering::Relaxed);
        let _ = self.events.send(RuntimeEventEnvelope { sequence, event });
    }

    pub(crate) fn set_audio_level(&self, level: f32) {
        self.audio_level.send_replace(level.clamp(0.0, 1.0));
    }
}

pub(crate) struct StoreUpdate {
    pub(crate) changed: bool,
    pub(crate) revision: u64,
}
