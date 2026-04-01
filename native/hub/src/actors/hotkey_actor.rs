//! Hotkey actor — listens for global key events via raw-input (CGEventTap on macOS).
//! No TIS/TSM calls — uses raw virtual keycodes only. Safe on background threads.
//! Target keycode can be changed at runtime via `set_keycode()`.

use raw_input::{Core, Event, Listen};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;
use std::time::Instant;
use tokio::sync::mpsc;

/// Default keycode: Right Option (61 on macOS).
const DEFAULT_KEYCODE: u32 = 61;

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

        let is_pressed = Arc::new(AtomicBool::new(false));
        let press_time = Arc::new(std::sync::Mutex::new(None::<Instant>));

        // Start raw-input core on a background thread
        std::thread::Builder::new()
            .name("raw-input-core".into())
            .spawn(|| {
                if let Err(e) = Core::start() {
                    log::error!("raw-input Core::start failed: {e:?}");
                }
            })
            .ok();

        // Give core a moment to initialize
        std::thread::sleep(std::time::Duration::from_millis(100));

        // Start keyboard listening
        Listen::keyboard(true);
        Listen::mouse_move(false);
        Listen::mouse_button(false);
        Listen::mouse_wheel(false);
        Listen::start();

        let kc = target_keycode.clone();
        let pressed = is_pressed;
        let time = press_time;
        let tx = event_tx;

        Listen::subscribe(move |event| {
            let target = kc.load(Ordering::Relaxed);
            match event {
                Event::KeyDown { code, .. } => {
                    if code == Some(target) && !pressed.swap(true, Ordering::Relaxed) {
                        *time.lock().unwrap_or_else(|e| e.into_inner()) = Some(Instant::now());
                        let _ = tx.send(HotkeyEvent::KeyDown);
                    }
                }
                Event::KeyUp { code, .. } => {
                    if code == Some(target) && pressed.swap(false, Ordering::Relaxed) {
                        let duration_ms = time
                            .lock()
                            .unwrap_or_else(|e| e.into_inner())
                            .take()
                            .map(|t| t.elapsed().as_secs_f64() * 1000.0)
                            .unwrap_or(0.0);
                        let _ = tx.send(HotkeyEvent::KeyUp { duration_ms });
                    }
                }
                _ => {}
            }
        });

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

/// Convert legacy hotkey name to keycode (for backward compatibility with saved prefs).
pub fn keycode_from_name(name: &str) -> u32 {
    match name {
        "fn" | "fnKey" => 63,
        "rightOption" => 61,
        "f5" => 96,
        _ => {
            // Try parsing as numeric keycode
            name.parse::<u32>().unwrap_or(DEFAULT_KEYCODE)
        }
    }
}
