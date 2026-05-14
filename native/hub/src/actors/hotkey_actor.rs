//! Hotkey actor — listens for global key events via raw-input (CGEventTap on macOS).
//! No TIS/TSM calls — uses raw virtual keycodes only. Safe on background threads.
//! Target keycode can be changed at runtime via `set_keycode()`.

use std::sync::Arc;
use std::sync::atomic::{AtomicU32, Ordering};
use tokio::sync::mpsc;

use crate::platform::global_hotkey;

#[derive(Debug)]
pub enum HotkeyEvent {
    KeyDown,
    KeyUp { duration_ms: f64 },
}

pub struct HotkeyActor {
    event_rx: mpsc::UnboundedReceiver<HotkeyEvent>,
    target_keycode: Arc<AtomicU32>,
}

impl HotkeyActor {
    pub fn new(keycode: u32) -> Self {
        let target_keycode = Arc::new(AtomicU32::new(keycode));
        let (event_tx, event_rx) = mpsc::unbounded_channel();

        global_hotkey::start_listener(target_keycode.clone(), event_tx);

        log::info!("Hotkey listener started (keycode={keycode})");

        Self {
            event_rx,
            target_keycode,
        }
    }

    /// Change the target keycode at runtime.
    pub fn set_keycode(&self, keycode: u32) {
        let old = self.target_keycode.swap(keycode, Ordering::Relaxed);
        if old != keycode {
            log::info!("Hotkey changed: {old} → {keycode}");
        }
    }

    pub async fn recv(&mut self) -> Option<HotkeyEvent> {
        self.event_rx.recv().await
    }
}

/// Convert saved hotkey values into the current raw virtual keycode format.
pub fn keycode_from_name(name: &str) -> u32 {
    global_hotkey::keycode_from_saved_value(name)
}
