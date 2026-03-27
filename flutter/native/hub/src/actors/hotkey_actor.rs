//! Hotkey actor — listens for global key events via raw-input (CGEventTap on macOS).
//! No TIS/TSM calls — uses raw virtual keycodes only. Safe on background threads.

use raw_input::{Core, Event, Listen};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Instant;
use tokio::sync::mpsc;

/// macOS virtual keycodes for supported hotkeys.
const KEYCODE_FN: u32 = 63;
const KEYCODE_RIGHT_OPTION: u32 = 61;
const KEYCODE_F5: u32 = 96;

#[derive(Debug)]
pub enum HotkeyEvent {
    KeyDown,
    KeyUp { duration_ms: f64 },
}

pub struct HotkeyActor {
    event_rx: mpsc::UnboundedReceiver<HotkeyEvent>,
}

impl HotkeyActor {
    pub fn new(hotkey_name: &str) -> Self {
        let target_keycode = keycode_from_name(hotkey_name);
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

        let pressed = is_pressed;
        let time = press_time;
        let tx = event_tx;

        Listen::subscribe(move |event| {
            match event {
                Event::KeyDown { code, .. } => {
                    if code == Some(target_keycode) && !pressed.swap(true, Ordering::Relaxed) {
                        *time.lock().unwrap_or_else(|e| e.into_inner()) = Some(Instant::now());
                        let _ = tx.send(HotkeyEvent::KeyDown);
                    }
                }
                Event::KeyUp { code, .. } => {
                    if code == Some(target_keycode) && pressed.swap(false, Ordering::Relaxed) {
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

        log::info!("Hotkey listener started (keycode={target_keycode})");

        Self { event_rx }
    }

    pub async fn recv(&mut self) -> Option<HotkeyEvent> {
        self.event_rx.recv().await
    }
}

fn keycode_from_name(name: &str) -> u32 {
    match name {
        "fn" | "fnKey" => KEYCODE_FN,
        "rightOption" => KEYCODE_RIGHT_OPTION,
        "f5" => KEYCODE_F5,
        _ => KEYCODE_FN,
    }
}
