use raw_input::{Core, Event, Listen};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::time::Instant;
use tokio::sync::mpsc;
use wrenflow_domain::config::default_selected_hotkey_keycode;

use crate::actors::hotkey_actor::HotkeyEvent;

pub const fn is_supported() -> bool {
    cfg!(target_os = "macos")
}

pub fn start_listener(
    target_keycode: Arc<AtomicU32>,
    event_tx: mpsc::UnboundedSender<HotkeyEvent>,
) {
    let is_pressed = Arc::new(AtomicBool::new(false));
    let press_time = Arc::new(std::sync::Mutex::new(None::<Instant>));

    std::thread::Builder::new()
        .name("raw-input-core".into())
        .spawn(|| {
            if let Err(e) = Core::start() {
                log::error!("raw-input Core::start failed: {e:?}");
            }
        })
        .ok();

    std::thread::sleep(std::time::Duration::from_millis(100));

    Listen::keyboard(true);
    Listen::mouse_move(false);
    Listen::mouse_button(false);
    Listen::mouse_wheel(false);
    Listen::start();

    let pressed = is_pressed;
    let time = press_time;

    Listen::subscribe(move |event| {
        let target = target_keycode.load(Ordering::Relaxed);
        match event {
            Event::KeyDown { code, .. } => {
                if code == Some(target) && !pressed.swap(true, Ordering::Relaxed) {
                    *time.lock().unwrap_or_else(|e| e.into_inner()) = Some(Instant::now());
                    let _ = event_tx.send(HotkeyEvent::KeyDown);
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
                    let _ = event_tx.send(HotkeyEvent::KeyUp { duration_ms });
                }
            }
            _ => {}
        }
    });
}

/// Convert legacy saved values into the current raw virtual keycode format.
pub fn keycode_from_saved_value(value: &str) -> u32 {
    match value {
        "fn" | "fnKey" => 63,
        "rightOption" => 61,
        "f5" => 96,
        _ => value
            .parse::<u32>()
            .unwrap_or_else(|_| default_selected_hotkey_keycode()),
    }
}
