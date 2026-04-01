//! Paste actor — copies text to clipboard and simulates Cmd+V via CGEvent.
//! Uses CGEvent directly instead of enigo to avoid TSM main-thread requirement.

use arboard::Clipboard;

/// Paste text into the frontmost application.
/// 1. Set clipboard content via arboard
/// 2. Simulate Cmd+V via CGEvent (safe from any thread)
pub fn paste_text(text: &str) -> Result<(), String> {
    // Set clipboard
    let mut clipboard = Clipboard::new().map_err(|e| format!("clipboard error: {e}"))?;
    clipboard
        .set_text(text)
        .map_err(|e| format!("clipboard set error: {e}"))?;

    // Small delay to let clipboard settle
    std::thread::sleep(std::time::Duration::from_millis(50));

    // Simulate Cmd+V via CGEvent (no TSM dependency, works cross-process)
    #[cfg(target_os = "macos")]
    {
        use core_graphics::event::{CGEvent, CGEventFlags, CGKeyCode};
        use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};

        // 'v' = keycode 9 on macOS
        const V_KEYCODE: CGKeyCode = 9;

        let source = CGEventSource::new(CGEventSourceStateID::HIDSystemState)
            .map_err(|_| "Failed to create CGEventSource")?;

        let key_down = CGEvent::new_keyboard_event(source.clone(), V_KEYCODE, true)
            .map_err(|_| "Failed to create key down event")?;
        key_down.set_flags(CGEventFlags::CGEventFlagCommand);

        let key_up = CGEvent::new_keyboard_event(source, V_KEYCODE, false)
            .map_err(|_| "Failed to create key up event")?;
        key_up.set_flags(CGEventFlags::CGEventFlagCommand);

        key_down.post(core_graphics::event::CGEventTapLocation::Session);
        key_up.post(core_graphics::event::CGEventTapLocation::Session);
    }

    #[cfg(not(target_os = "macos"))]
    {
        use enigo::{Enigo, Keyboard, Key, Settings, Direction};
        let mut enigo = Enigo::new(&Settings::default()).map_err(|e| format!("enigo error: {e}"))?;
        enigo.key(Key::Control, Direction::Press).map_err(|e| format!("key error: {e}"))?;
        enigo.key(Key::Unicode('v'), Direction::Click).map_err(|e| format!("key error: {e}"))?;
        enigo.key(Key::Control, Direction::Release).map_err(|e| format!("key error: {e}"))?;
    }

    Ok(())
}
