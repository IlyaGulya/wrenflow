use std::ffi::{c_char, CStr, CString};
use std::fmt;
use std::path::Path;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;
use wrenflow_runtime::ThemePreference;

static EVENT_SENDER: OnceLock<Mutex<Option<mpsc::UnboundedSender<ShellEvent>>>> = OnceLock::new();

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ShellEvent {
    OpenSettings,
    OpenHistory,
    OpenAbout,
    SelectMicrophone(String),
    QuitRequested,
    OverlayAction(String),
    PermissionsChanged(PermissionObservation),
    LaunchAtLoginChanged(LaunchAtLoginObservation),
    MainWindowHidden,
    HotkeyPressed,
    HotkeyReleased(Duration),
    AccessibilityAction(AccessibilityActionRequest),
    AccessibilityPreferencesChanged(AccessibilityPreferencesObservation),
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AccessibilityActionRequest {
    pub id: String,
    pub action: String,
    pub value: Option<String>,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AccessibilityPreferencesObservation {
    pub increase_contrast: bool,
    pub differentiate_without_color: bool,
    pub reduce_motion: bool,
    pub reduce_transparency: bool,
    pub text_scale_percent: u16,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct PermissionObservation {
    pub microphone: PermissionValue,
    pub accessibility: PermissionValue,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum PermissionValue {
    Unknown,
    Granted,
    Denied,
    Restricted,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct LaunchAtLoginObservation {
    pub is_available: bool,
    pub enabled: bool,
    pub is_loading: bool,
    pub unavailable_reason: Option<String>,
    pub error_message: Option<String>,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TrayPresentation {
    pub version: String,
    pub status: String,
    pub launch_at_login: bool,
    pub microphones: Vec<TrayMicrophone>,
    pub selected_microphone_id: String,
    pub selected_hotkey: u16,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct TrayMicrophone {
    pub id: String,
    pub name: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OverlayPhase {
    Initializing = 0,
    Recording = 1,
    Transcribing = 2,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WindowLayout {
    Compact = 0,
    Settings = 1,
}

#[derive(Clone, Copy)]
pub struct MacShell;

#[derive(Debug)]
pub struct ShellError(String);

impl fmt::Display for ShellError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for ShellError {}

impl MacShell {
    pub fn prepare_process() {
        // SAFETY: the process entry point calls this on the main thread before
        // GPUI constructs NSApplication; no borrowed values cross the boundary.
        unsafe { wrenflow_shell_prepare_process() };
    }

    pub fn claim_single_instance() -> bool {
        // SAFETY: this synchronous AppKit query has no borrowed arguments and
        // runs before any runtime IO is started.
        unsafe { wrenflow_shell_claim_single_instance() == 0 }
    }

    pub fn install(
        window_title: &str,
        version: &str,
    ) -> Result<(Self, mpsc::UnboundedReceiver<ShellEvent>), ShellError> {
        let title = c_string(window_title, "window title")?;
        let version = c_string(version, "version")?;
        let (sender, receiver) = mpsc::unbounded_channel();
        let sender_slot = EVENT_SENDER.get_or_init(|| Mutex::new(None));
        let mut slot = sender_slot
            .lock()
            .map_err(|_| ShellError("native shell event sender lock is poisoned".into()))?;
        *slot = Some(sender);
        drop(slot);

        // SAFETY: the function pointer has static lifetime and Swift stores it
        // only until synchronous shutdown.
        unsafe { wrenflow_shell_set_diagnostic_callback(Some(native_diagnostic_callback)) };
        // SAFETY: both pointers are valid for the duration of this synchronous
        // call and the callback is a C-compatible function pointer.
        let result = unsafe {
            wrenflow_shell_install(title.as_ptr(), version.as_ptr(), native_event_callback)
        };
        if result != 0 {
            // SAFETY: clear the callback before returning a failed shell.
            unsafe { wrenflow_shell_set_diagnostic_callback(None) };
            clear_event_sender();
            return Err(ShellError(format!(
                "native shell install failed with status {result}"
            )));
        }
        Ok((Self, receiver))
    }

    pub fn shutdown(self) {
        // SAFETY: the linked Swift function accepts no arguments and runs its
        // AppKit cleanup synchronously on the main thread.
        unsafe { wrenflow_shell_shutdown() };
        // SAFETY: Swift has completed shutdown and will issue no callbacks.
        unsafe { wrenflow_shell_set_diagnostic_callback(None) };
        clear_event_sender();
    }

    pub fn show_main_window(self) -> Result<(), ShellError> {
        // SAFETY: no arguments cross the FFI boundary; Swift returns a closed
        // status only after verifying AppKit accepted the regular policy.
        let result = unsafe { wrenflow_shell_show_main_window() };
        status_result(result, "show main window")
    }

    pub fn hide_main_window(self) -> Result<(), ShellError> {
        // SAFETY: no arguments cross the FFI boundary; Swift returns a closed
        // status only after verifying AppKit accepted the accessory policy.
        let result = unsafe { wrenflow_shell_hide_main_window() };
        status_result(result, "hide main window")
    }

    pub fn ensure_accessory_policy(self) -> Result<(), ShellError> {
        // SAFETY: no arguments cross the FFI boundary; Swift synchronously
        // applies and verifies the accessory activation policy on main.
        let result = unsafe { wrenflow_shell_ensure_accessory_policy() };
        status_result(result, "ensure accessory policy")
    }

    pub fn apply_window_layout(self, layout: WindowLayout) -> Result<(), ShellError> {
        // SAFETY: the layout discriminants are shared with the Swift enum.
        let result = unsafe { wrenflow_shell_apply_window_layout(layout as i32) };
        status_result(result, "apply window layout")
    }

    pub fn apply_theme_preference(self, preference: ThemePreference) -> Result<(), ShellError> {
        let preference = match preference {
            ThemePreference::System => 0,
            ThemePreference::Light => 1,
            ThemePreference::Dark => 2,
        };
        // SAFETY: the closed integer discriminants are decoded by Swift on
        // the main thread and do not borrow across the FFI boundary.
        let result = unsafe { wrenflow_shell_apply_theme_preference(preference) };
        status_result(result, "apply app-local theme preference")
    }

    pub fn update_tray(self, presentation: &TrayPresentation) -> Result<(), ShellError> {
        let json = serde_json::to_string(presentation)
            .map_err(|error| ShellError(format!("could not serialize tray state: {error}")))?;
        let json = c_string(&json, "tray JSON")?;
        // SAFETY: the pointer is valid during this synchronous call.
        let result = unsafe { wrenflow_shell_update_tray(json.as_ptr()) };
        status_result(result, "update tray")
    }

    pub fn update_accessibility<T: Serialize>(self, snapshot: &T) -> Result<(), ShellError> {
        let json = serde_json::to_string(snapshot).map_err(|error| {
            ShellError(format!("could not serialize accessibility tree: {error}"))
        })?;
        let json = c_string(&json, "accessibility JSON")?;
        // SAFETY: the pointer is valid during this synchronous call. Swift
        // decodes and retains its own accessibility element snapshot.
        let result = unsafe { wrenflow_shell_update_accessibility(json.as_ptr()) };
        status_result(result, "update accessibility tree")
    }

    /// Start the post-event-tap typed-callback performance driver. The paths
    /// are exposed only by an already validated two-gate performance request.
    pub fn start_performance_interaction(
        self,
        ready_path: &Path,
        report_path: &Path,
    ) -> Result<(), ShellError> {
        let ready_path = ready_path
            .to_str()
            .ok_or_else(|| ShellError("performance ready path is not UTF-8".into()))?;
        let report_path = report_path
            .to_str()
            .ok_or_else(|| ShellError("performance report path is not UTF-8".into()))?;
        let ready_path = c_string(ready_path, "performance ready path")?;
        let report_path = c_string(report_path, "performance report path")?;
        // SAFETY: Swift copies both absolute paths during this synchronous
        // call; their originating request was validated before runtime start.
        let result = unsafe {
            wrenflow_shell_start_performance_interaction(ready_path.as_ptr(), report_path.as_ptr())
        };
        status_result(result, "start performance interaction")
    }

    pub fn observe_performance_paste_dispatch(self) {
        // SAFETY: the runtime event is projected on the GPUI main thread and
        // the gated Swift observer copies no borrowed data.
        unsafe { wrenflow_shell_observe_performance_paste_dispatch() };
    }

    pub fn accessibility_node_count(self) -> i32 {
        // SAFETY: the linked Swift getter has no arguments or borrowed result.
        unsafe { wrenflow_shell_accessibility_node_count() }
    }

    pub fn request_microphone(self) {
        // SAFETY: no arguments cross the FFI boundary.
        unsafe { wrenflow_shell_request_microphone() };
    }

    pub fn request_accessibility(self) {
        // SAFETY: no arguments cross the FFI boundary.
        unsafe { wrenflow_shell_request_accessibility() };
    }

    pub fn open_microphone_settings(self) {
        // SAFETY: zero is the documented microphone discriminator.
        unsafe { wrenflow_shell_open_permission_settings(0) };
    }

    pub fn open_accessibility_settings(self) {
        // SAFETY: one is the documented accessibility discriminator.
        unsafe { wrenflow_shell_open_permission_settings(1) };
    }

    // Stable shell API consumed by the upcoming production settings screens.
    #[allow(dead_code)]
    pub fn set_launch_at_login(self, enabled: bool) {
        // SAFETY: Rust and Swift use the C ABI boolean representation here.
        let _ = unsafe { wrenflow_shell_set_launch_at_login(enabled) };
    }

    pub fn show_overlay(self, phase: OverlayPhase, audio_level: f32) {
        // SAFETY: the phase discriminants are shared with the Swift boundary.
        unsafe { wrenflow_shell_show_overlay(phase as i32, audio_level) };
    }

    pub fn update_overlay_audio(self, audio_level: f32) {
        // SAFETY: f32 has the same C ABI representation as Swift Float.
        unsafe { wrenflow_shell_update_overlay_audio(audio_level) };
    }

    pub fn hide_overlay(self) {
        // SAFETY: no arguments cross the FFI boundary.
        unsafe { wrenflow_shell_hide_overlay() };
    }

    pub fn show_error(
        self,
        message: &str,
        action_label: Option<&str>,
        action_id: Option<&str>,
    ) -> Result<(), ShellError> {
        let message = c_string(message, "error message")?;
        let action_label = optional_c_string(action_label, "error action label")?;
        let action_id = optional_c_string(action_id, "error action id")?;
        // SAFETY: all non-null pointers remain valid for this synchronous call.
        let result = unsafe {
            wrenflow_shell_show_error(
                message.as_ptr(),
                optional_pointer(action_label.as_ref()),
                optional_pointer(action_id.as_ref()),
            )
        };
        status_result(result, "show error")
    }

    pub fn terminate(self) {
        // SAFETY: no arguments cross the FFI boundary.
        unsafe { wrenflow_shell_terminate() };
    }
}

fn status_result(status: i32, operation: &str) -> Result<(), ShellError> {
    if status == 0 {
        Ok(())
    } else {
        Err(ShellError(format!(
            "native shell could not {operation}: status {status}"
        )))
    }
}

fn c_string(value: &str, context: &str) -> Result<CString, ShellError> {
    CString::new(value).map_err(|_| ShellError(format!("{context} contains an interior NUL byte")))
}

fn optional_c_string(value: Option<&str>, context: &str) -> Result<Option<CString>, ShellError> {
    value.map(|value| c_string(value, context)).transpose()
}

fn optional_pointer(value: Option<&CString>) -> *const c_char {
    value.map_or(std::ptr::null(), |value| value.as_ptr())
}

fn clear_event_sender() {
    if let Some(sender) = EVENT_SENDER.get() {
        if let Ok(mut slot) = sender.lock() {
            *slot = None;
        }
    }
}

extern "C" fn native_diagnostic_callback(code: u8) {
    wrenflow_runtime::diagnostics::wrenflow_diagnostics_report_shell_failure(code);
}

extern "C" fn native_event_callback(code: i32, payload: *const c_char) {
    let payload = if payload.is_null() {
        None
    } else {
        // SAFETY: Swift guarantees a valid, NUL-terminated pointer for the
        // duration of the callback. Copy before returning across the boundary.
        Some(
            unsafe { CStr::from_ptr(payload) }
                .to_string_lossy()
                .into_owned(),
        )
    };
    let Some(event) = decode_event(code, payload.as_deref()) else {
        return;
    };
    if let Some(sender) = EVENT_SENDER.get() {
        if let Ok(slot) = sender.lock() {
            if let Some(sender) = slot.as_ref() {
                let _ = sender.send(event);
            }
        }
    }
}

fn decode_event(code: i32, payload: Option<&str>) -> Option<ShellEvent> {
    match code {
        1 => Some(ShellEvent::OpenSettings),
        2 => Some(ShellEvent::OpenHistory),
        3 => Some(ShellEvent::OpenAbout),
        4 => payload.map(|value| ShellEvent::SelectMicrophone(value.into())),
        6 => Some(ShellEvent::QuitRequested),
        7 => payload.map(|value| ShellEvent::OverlayAction(value.into())),
        8 => payload
            .and_then(|value| serde_json::from_str(value).ok())
            .map(ShellEvent::PermissionsChanged),
        9 => payload
            .and_then(|value| serde_json::from_str(value).ok())
            .map(ShellEvent::LaunchAtLoginChanged),
        10 => Some(ShellEvent::MainWindowHidden),
        12 => Some(ShellEvent::HotkeyPressed),
        13 => payload
            .and_then(|value| value.parse::<f64>().ok())
            .filter(|milliseconds| milliseconds.is_finite() && *milliseconds >= 0.0)
            .map(|milliseconds| {
                ShellEvent::HotkeyReleased(Duration::from_secs_f64(milliseconds / 1_000.0))
            }),
        14 => payload
            .and_then(|value| serde_json::from_str(value).ok())
            .map(ShellEvent::AccessibilityAction),
        15 => payload
            .and_then(|value| serde_json::from_str(value).ok())
            .map(ShellEvent::AccessibilityPreferencesChanged),
        _ => None,
    }
}

#[allow(dead_code)]
unsafe extern "C" {
    fn wrenflow_shell_prepare_process();
    fn wrenflow_shell_claim_single_instance() -> i32;
    fn wrenflow_shell_set_diagnostic_callback(callback: Option<extern "C" fn(u8)>);
    fn wrenflow_shell_install(
        title: *const c_char,
        version: *const c_char,
        callback: extern "C" fn(i32, *const c_char),
    ) -> i32;
    fn wrenflow_shell_shutdown();
    fn wrenflow_shell_show_main_window() -> i32;
    fn wrenflow_shell_hide_main_window() -> i32;
    fn wrenflow_shell_ensure_accessory_policy() -> i32;
    fn wrenflow_shell_apply_window_layout(layout: i32) -> i32;
    fn wrenflow_shell_apply_theme_preference(preference: i32) -> i32;
    fn wrenflow_shell_update_tray(json: *const c_char) -> i32;
    fn wrenflow_shell_update_accessibility(json: *const c_char) -> i32;
    fn wrenflow_shell_start_performance_interaction(
        ready_path: *const c_char,
        report_path: *const c_char,
    ) -> i32;
    fn wrenflow_shell_observe_performance_paste_dispatch();
    fn wrenflow_shell_accessibility_node_count() -> i32;
    fn wrenflow_accessibility_validate_snapshot(json: *const c_char) -> i32;
    fn wrenflow_shell_request_microphone();
    fn wrenflow_shell_request_accessibility();
    fn wrenflow_shell_open_permission_settings(kind: i32);
    fn wrenflow_shell_set_launch_at_login(enabled: bool) -> i32;
    fn wrenflow_shell_show_overlay(phase: i32, audio_level: f32);
    fn wrenflow_shell_update_overlay_audio(audio_level: f32);
    fn wrenflow_shell_hide_overlay();
    fn wrenflow_shell_show_error(
        message: *const c_char,
        action_label: *const c_char,
        action_id: *const c_char,
    ) -> i32;
    fn wrenflow_shell_permission_confirmation_transition(
        remaining: i32,
        previous_all_granted: i32,
        current_all_granted: i32,
        force: i32,
        detect_loss_transition: i32,
    ) -> i32;
    fn wrenflow_shell_terminate();
}

#[cfg(test)]
mod tests {
    use super::{
        decode_event, wrenflow_shell_permission_confirmation_transition,
        AccessibilityActionRequest, AccessibilityPreferencesObservation, LaunchAtLoginObservation,
        PermissionObservation, PermissionValue, ShellEvent,
    };
    use std::ffi::CString;

    #[test]
    fn permission_confirmation_budget_survives_intervening_refreshes() {
        // A changed granted -> denied observation is the first emitted loss.
        let mut emitted_losses = 1;
        // SAFETY: the Swift function is a pure fixed-width numeric transition
        // compiled into the shell dylib linked by this test target.
        let mut remaining =
            unsafe { wrenflow_shell_permission_confirmation_transition(0, 1, 0, 0, 1) };
        assert_eq!(remaining, 2);

        // App activation and menu-open refreshes query again, but unchanged
        // deduplicated payloads neither emit nor consume a confirmation.
        remaining =
            unsafe { wrenflow_shell_permission_confirmation_transition(remaining, 0, 0, 0, 1) };
        assert_eq!(remaining, 2);

        remaining =
            unsafe { wrenflow_shell_permission_confirmation_transition(remaining, 0, 0, 1, 0) };
        emitted_losses += 1;
        assert_eq!(remaining, 1);
        remaining =
            unsafe { wrenflow_shell_permission_confirmation_transition(remaining, 0, 0, 0, 1) };
        assert_eq!(remaining, 1);
        remaining =
            unsafe { wrenflow_shell_permission_confirmation_transition(remaining, 0, 0, 1, 0) };
        emitted_losses += 1;
        assert_eq!(remaining, 0);
        assert_eq!(emitted_losses, 3);

        // A granted observation cancels an in-flight confirmation burst.
        let granted = unsafe { wrenflow_shell_permission_confirmation_transition(2, 0, 1, 0, 1) };
        assert_eq!(granted, 0);
    }

    #[test]
    fn decodes_permission_event() {
        assert_eq!(
            decode_event(
                8,
                Some(r#"{"microphone":"granted","accessibility":"denied"}"#)
            ),
            Some(ShellEvent::PermissionsChanged(PermissionObservation {
                microphone: PermissionValue::Granted,
                accessibility: PermissionValue::Denied,
            }))
        );
    }

    #[test]
    fn decodes_launch_at_login_event() {
        assert_eq!(
            decode_event(
                9,
                Some(
                    r#"{"isAvailable":true,"enabled":false,"isLoading":false,"unavailableReason":null,"errorMessage":null}"#
                )
            ),
            Some(ShellEvent::LaunchAtLoginChanged(LaunchAtLoginObservation {
                is_available: true,
                enabled: false,
                is_loading: false,
                unavailable_reason: None,
                error_message: None,
            }))
        );
    }

    #[test]
    fn rejects_unknown_or_malformed_events() {
        assert_eq!(decode_event(99, None), None);
        assert_eq!(decode_event(8, Some("not-json")), None);
        assert_eq!(decode_event(4, None), None);
        assert_eq!(decode_event(13, Some("nan")), None);
    }

    #[test]
    fn decodes_hotkey_duration_in_milliseconds() {
        assert_eq!(decode_event(12, None), Some(ShellEvent::HotkeyPressed));
        assert_eq!(
            decode_event(13, Some("312.5")),
            Some(ShellEvent::HotkeyReleased(
                std::time::Duration::from_micros(312_500)
            ))
        );
    }

    #[test]
    fn decodes_accessibility_action_event() {
        assert_eq!(
            decode_event(14, Some(r#"{"id":"save","action":"press","value":null}"#)),
            Some(ShellEvent::AccessibilityAction(
                AccessibilityActionRequest {
                    id: "save".into(),
                    action: "press".into(),
                    value: None,
                }
            ))
        );
        assert_eq!(decode_event(14, Some("{}")), None);
    }

    #[test]
    fn decodes_live_accessibility_display_preferences() {
        assert_eq!(
            decode_event(
                15,
                Some(
                    r#"{"increaseContrast":true,"differentiateWithoutColor":true,"reduceMotion":true,"reduceTransparency":true,"textScalePercent":150}"#
                )
            ),
            Some(ShellEvent::AccessibilityPreferencesChanged(
                AccessibilityPreferencesObservation {
                    increase_contrast: true,
                    differentiate_without_color: true,
                    reduce_motion: true,
                    reduce_transparency: true,
                    text_scale_percent: 150,
                }
            ))
        );
    }

    #[test]
    fn swift_bridge_validates_schema_and_rejects_zero_sized_geometry() {
        let valid = CString::new(
            r#"{"generation":1,"coordinateSpace":"windowContentTopLeft","nodes":[{"id":"save","parentID":null,"role":"button","label":"Save","value":null,"enabled":true,"focused":true,"actions":["press","focus"],"frame":{"x":10.0,"y":10.0,"width":80.0,"height":32.0},"order":0}],"focusedID":"save","announcement":{"serial":1,"message":"Ready","priority":"medium"}}"#,
        )
        .unwrap_or_else(|error| panic!("test accessibility JSON must be a C string: {error}"));
        // SAFETY: this passes a valid, NUL-terminated string to a pure Swift
        // decoder that does not retain the pointer.
        assert_eq!(
            unsafe { super::wrenflow_accessibility_validate_snapshot(valid.as_ptr()) },
            0
        );

        let invalid = CString::new(
            r#"{"generation":2,"coordinateSpace":"windowContentTopLeft","nodes":[{"id":"save","parentID":null,"role":"button","label":"Save","value":null,"enabled":true,"focused":false,"actions":["press"],"frame":{"x":10.0,"y":10.0,"width":0.0,"height":32.0},"order":0}],"focusedID":null,"announcement":null}"#,
        )
        .unwrap_or_else(|error| panic!("test accessibility JSON must be a C string: {error}"));
        // SAFETY: same pure synchronous validation boundary as above.
        assert_ne!(
            unsafe { super::wrenflow_accessibility_validate_snapshot(invalid.as_ptr()) },
            0
        );
    }
}
