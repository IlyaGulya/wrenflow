pub fn simulate_paste_shortcut() -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        use core_graphics::event::{CGEvent, CGEventFlags, CGKeyCode};
        use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};

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
        Ok(())
    }

    #[cfg(not(target_os = "macos"))]
    {
        use enigo::{Direction, Enigo, Key, Keyboard, Settings};

        let mut enigo =
            Enigo::new(&Settings::default()).map_err(|e| format!("enigo error: {e}"))?;
        enigo
            .key(Key::Control, Direction::Press)
            .map_err(|e| format!("key error: {e}"))?;
        enigo
            .key(Key::Unicode('v'), Direction::Click)
            .map_err(|e| format!("key error: {e}"))?;
        enigo
            .key(Key::Control, Direction::Release)
            .map_err(|e| format!("key error: {e}"))?;
        Ok(())
    }
}
