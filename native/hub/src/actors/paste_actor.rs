//! Paste actor — copies text to clipboard and simulates Cmd+V via CGEvent.
//! Uses CGEvent directly instead of enigo to avoid TSM main-thread requirement.

use arboard::Clipboard;

use crate::platform::paste;

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

    paste::simulate_paste_shortcut()
}
