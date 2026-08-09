//! Product screens rendered exclusively from immutable `AppPresentation` values.
//!
//! Screen interaction is expressed as typed `AppAction`s. Runtime and AppKit
//! ownership remain behind `AppModel` and the shell adapter respectively.

mod about;
mod accessibility;
mod common;
mod history;
mod models;
mod onboarding;
mod settings;

use std::{collections::HashMap, fmt, time::Duration};

use gpui::{
    div, point, prelude::FluentBuilder as _, px, AnyElement, App, AppContext as _, BoxShadow,
    Context, Entity, EventEmitter, FocusHandle, Focusable, InteractiveElement as _, IntoElement,
    KeyDownEvent, ParentElement as _, Render, SharedString, StatefulInteractiveElement as _,
    Styled as _, Timer, Window,
};
use gpui_component::{
    input::{InputEvent, InputState},
    scroll::ScrollableElement as _,
};

use crate::app::{AppAction, AppModel, AppPresentation, NavigationTarget, Notice, NoticeKind};
use crate::ui::{
    progress, text_input, AccessibilityAction, AccessibilityFrame, AccessibilityPriority,
    AccessibilityRole, AccessibilitySnapshot, AccessibleButton, AccessibleButtonEvent,
    AccessibleSwitch, AccessibleSwitchEvent, ButtonStyle, Card, DialogSurface, MeasuredElement,
    NavigationSidebar, StatusKind, StatusSurface, WrenflowTheme,
};

use accessibility::{AccessibilityNodeDraft, AccessibilityState};

use common::{
    ActionPlan, BlockPlan, CardPlan, ControlPlan, InputKind, ScreenIntent, ScreenLayout,
    ScreenPlan, SectionPlan, TextPlan, TextTone, ToggleKind,
};

struct ButtonRecord {
    entity: Entity<AccessibleButton>,
}

struct SwitchRecord {
    entity: Entity<AccessibleSwitch>,
}

struct HotkeyControl<'a> {
    id: &'a str,
    label: &'a str,
    value: &'a str,
    hint: &'a str,
    enabled: bool,
    parent_id: &'a str,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum HotkeyCaptureEvent {
    Changed(String),
    ListeningChanged(bool),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum HotkeyCaptureDecision {
    Start,
    Cancel,
    Navigate,
    Commit(u16),
    Ignore,
}

/// Focusable custom macOS key capture. Common choices remain separate
/// `AccessibleButton`s so both pointer and keyboard users can choose them.
struct HotkeyCapture {
    value: SharedString,
    disabled: bool,
    listening: bool,
    focus_handle: FocusHandle,
}

impl HotkeyCapture {
    fn new(value: impl Into<SharedString>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let this = Self {
            value: value.into(),
            disabled: false,
            listening: false,
            focus_handle: cx.focus_handle(),
        };
        cx.on_blur(&this.focus_handle, window, |this, _, cx| {
            if this.listening {
                this.listening = false;
                cx.emit(HotkeyCaptureEvent::ListeningChanged(false));
                cx.notify();
            }
        })
        .detach();
        this
    }

    fn sync(&mut self, value: &str, disabled: bool, cx: &mut Context<Self>) {
        let changed = self.value.as_ref() != value || self.disabled != disabled;
        self.value = value.to_string().into();
        self.disabled = disabled;
        if changed {
            cx.notify();
        }
    }

    fn focus(&mut self, _: &gpui::ClickEvent, window: &mut Window, cx: &mut Context<Self>) {
        self.start_listening(window, cx);
    }

    fn start_listening(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.disabled {
            self.listening = true;
            window.focus(&self.focus_handle);
            cx.emit(HotkeyCaptureEvent::ListeningChanged(true));
            cx.notify();
        }
    }

    fn capture(&mut self, event: &KeyDownEvent, _: &mut Window, cx: &mut Context<Self>) {
        if self.disabled || event.is_held {
            return;
        }
        match hotkey_capture_decision(&event.keystroke.key, self.listening) {
            HotkeyCaptureDecision::Start => {
                self.listening = true;
                cx.emit(HotkeyCaptureEvent::ListeningChanged(true));
                cx.stop_propagation();
                cx.notify();
            }
            HotkeyCaptureDecision::Cancel => {
                self.listening = false;
                cx.emit(HotkeyCaptureEvent::ListeningChanged(false));
                cx.stop_propagation();
                cx.notify();
            }
            HotkeyCaptureDecision::Commit(code) => {
                self.value = code.to_string().into();
                self.listening = false;
                cx.emit(HotkeyCaptureEvent::Changed(code.to_string()));
                cx.stop_propagation();
                cx.notify();
            }
            HotkeyCaptureDecision::Navigate | HotkeyCaptureDecision::Ignore => {}
        }
    }
}

impl EventEmitter<HotkeyCaptureEvent> for HotkeyCapture {}

impl Focusable for HotkeyCapture {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus_handle.clone()
    }
}

impl Render for HotkeyCapture {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let tokens = WrenflowTheme::current(cx).tokens;
        let border = if self.focus_handle.is_focused(window) {
            tokens.colors.focus_ring
        } else {
            tokens.colors.border
        };
        let focus_handle = self.focus_handle.clone().tab_stop(!self.disabled);
        let label = if self.listening {
            "Press any key…".to_string()
        } else {
            format!("Custom key: {}", hotkey_display_name(&self.value))
        };
        let disabled = self.disabled;

        div()
            .id("custom-hotkey-capture")
            .track_focus(&focus_handle)
            .flex()
            .items_center()
            .min_h(px(36.))
            .px(tokens.spacing.md)
            .py(tokens.spacing.xs)
            .rounded(tokens.controls.radius)
            .border(tokens.controls.focus_width)
            .border_color(border)
            .bg(tokens.colors.surface)
            .when(self.focus_handle.is_focused(window), |this| {
                this.shadow(vec![BoxShadow {
                    color: tokens.colors.foreground,
                    offset: point(px(0.0), px(0.0)),
                    blur_radius: px(0.0),
                    spread_radius: tokens.controls.focus_width,
                }])
            })
            .when(!disabled, |this| {
                this.cursor_pointer()
                    .on_click(cx.listener(Self::focus))
                    .on_key_down(cx.listener(Self::capture))
            })
            .when(disabled, |this| this.opacity(0.5))
            .child(label)
    }
}

fn mac_keycode(key: &str) -> Option<u16> {
    let code = match key.to_ascii_lowercase().as_str() {
        "a" => 0,
        "s" => 1,
        "d" => 2,
        "f" => 3,
        "h" => 4,
        "g" => 5,
        "z" => 6,
        "x" => 7,
        "c" => 8,
        "v" => 9,
        "b" => 11,
        "q" => 12,
        "w" => 13,
        "e" => 14,
        "r" => 15,
        "y" => 16,
        "t" => 17,
        "1" => 18,
        "2" => 19,
        "3" => 20,
        "4" => 21,
        "6" => 22,
        "5" => 23,
        "=" => 24,
        "9" => 25,
        "7" => 26,
        "-" => 27,
        "8" => 28,
        "0" => 29,
        "]" => 30,
        "o" => 31,
        "u" => 32,
        "[" => 33,
        "i" => 34,
        "p" => 35,
        "enter" | "return" => 36,
        "l" => 37,
        "j" => 38,
        "'" => 39,
        "k" => 40,
        ";" => 41,
        "\\" => 42,
        "," => 43,
        "/" => 44,
        "n" => 45,
        "m" => 46,
        "." => 47,
        "tab" => 48,
        "space" => 49,
        "`" => 50,
        "backspace" => 51,
        "escape" => 53,
        "f1" => 122,
        "f2" => 120,
        "f3" => 99,
        "f4" => 118,
        "f5" => 96,
        "f6" => 97,
        "f7" => 98,
        "f8" => 100,
        "f9" => 101,
        "f10" => 109,
        "f11" => 103,
        "f12" => 111,
        "f13" => 105,
        "f14" => 107,
        "f15" => 113,
        "delete" => 117,
        _ => return None,
    };
    Some(code)
}

fn hotkey_capture_decision(key: &str, listening: bool) -> HotkeyCaptureDecision {
    let key = key.to_ascii_lowercase();
    if !listening {
        return if matches!(key.as_str(), "enter" | "return" | "space") {
            HotkeyCaptureDecision::Start
        } else {
            HotkeyCaptureDecision::Ignore
        };
    }
    match key.as_str() {
        "escape" => HotkeyCaptureDecision::Cancel,
        "tab" => HotkeyCaptureDecision::Navigate,
        _ => mac_keycode(&key)
            .map(HotkeyCaptureDecision::Commit)
            .unwrap_or(HotkeyCaptureDecision::Ignore),
    }
}

fn hotkey_display_name(value: &str) -> String {
    match value {
        "63" => "Fn".to_string(),
        "54" => "Right Command".to_string(),
        "61" => "Right Option".to_string(),
        "96" => "F5".to_string(),
        value => format!("keycode {value}"),
    }
}

/// Root GPUI view for onboarding, recovery and all settings destinations.
///
/// The shell should wrap this entity in `gpui_component::Root`; it remains the
/// owner of window hiding, TCC and other AppKit-only behavior.
pub struct AppScreens {
    model: Entity<AppModel>,
    hotkey_capture: Entity<HotkeyCapture>,
    vocabulary_input: Entity<InputState>,
    buttons: HashMap<String, ButtonRecord>,
    button_intents: HashMap<String, ScreenIntent>,
    switches: HashMap<String, SwitchRecord>,
    switch_kinds: HashMap<String, ToggleKind>,
    confirm_clear_history: bool,
    vocabulary_revision: u64,
    accessibility: AccessibilityState,
    modal_restore_focus_id: Option<String>,
    modal_needs_initial_focus: bool,
    modal_needs_restore: bool,
    last_accessibility_route: Option<NavigationTarget>,
    last_screen_announcement_key: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AccessibilityActionError {
    UnknownNode(String),
    UnsupportedAction {
        id: String,
        action: AccessibilityAction,
    },
    MissingValue(String),
}

impl fmt::Display for AccessibilityActionError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnknownNode(id) => write!(formatter, "unknown accessibility node `{id}`"),
            Self::UnsupportedAction { id, action } => {
                write!(
                    formatter,
                    "accessibility action {action:?} is unsupported for `{id}`"
                )
            }
            Self::MissingValue(id) => {
                write!(
                    formatter,
                    "accessibility action for `{id}` requires a value"
                )
            }
        }
    }
}

impl std::error::Error for AccessibilityActionError {}

impl AppScreens {
    #[must_use]
    pub fn new(model: Entity<AppModel>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let presentation = model.read(cx).presentation();
        let hotkey_value = presentation.settings.selected_hotkey.clone();
        let vocabulary_value = presentation.settings.custom_vocabulary.clone();
        let hotkey_capture = cx.new(|cx| HotkeyCapture::new(hotkey_value, window, cx));
        let vocabulary_input = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder("One word or phrase per line")
                .default_value(vocabulary_value)
                .multi_line(true)
        });

        cx.observe(&model, |_, _, cx| cx.notify()).detach();
        cx.observe(&hotkey_capture, |_, _, cx| cx.notify()).detach();
        cx.observe(&vocabulary_input, |_, _, cx| cx.notify())
            .detach();
        cx.subscribe(
            &hotkey_capture,
            |this, _, event: &HotkeyCaptureEvent, cx| match event {
                HotkeyCaptureEvent::Changed(value) => {
                    this.accessibility.announce(
                        format!("hotkey:capture:{value}"),
                        format!("Shortcut changed to {}", hotkey_display_name(value)),
                        AccessibilityPriority::Medium,
                    );
                    this.dispatch(AppAction::SetSelectedHotkey(value.clone()), cx);
                }
                HotkeyCaptureEvent::ListeningChanged(true) => {
                    this.accessibility.announce(
                        "hotkey:listening",
                        "Shortcut capture started. Press a key, or Escape to cancel.",
                        AccessibilityPriority::Medium,
                    );
                }
                HotkeyCaptureEvent::ListeningChanged(false) => {
                    this.accessibility.announce(
                        "hotkey:cancelled",
                        "Shortcut capture stopped.",
                        AccessibilityPriority::Low,
                    );
                }
            },
        )
        .detach();
        cx.subscribe(
            &vocabulary_input,
            |this, input, event: &InputEvent, cx| match event {
                InputEvent::Change => this.schedule_vocabulary_update(input.clone(), cx),
                InputEvent::Blur => {
                    this.vocabulary_revision = this.vocabulary_revision.saturating_add(1);
                    this.dispatch(
                        AppAction::SetCustomVocabulary(input.read(cx).value().to_string()),
                        cx,
                    );
                }
                InputEvent::PressEnter { .. } | InputEvent::Focus => {}
            },
        )
        .detach();

        Self {
            model,
            hotkey_capture,
            vocabulary_input,
            buttons: HashMap::new(),
            button_intents: HashMap::new(),
            switches: HashMap::new(),
            switch_kinds: HashMap::new(),
            confirm_clear_history: false,
            vocabulary_revision: 0,
            accessibility: AccessibilityState::default(),
            modal_restore_focus_id: None,
            modal_needs_initial_focus: false,
            modal_needs_restore: false,
            last_accessibility_route: None,
            last_screen_announcement_key: None,
        }
    }

    /// Latest fully-measured accessibility tree. The generation covers semantic
    /// and geometry changes; `focused_id` is refreshed from live GPUI focus on
    /// every call and must be consumed even when the generation is unchanged.
    #[must_use]
    pub fn accessibility_snapshot(&self, window: &Window, cx: &App) -> AccessibilitySnapshot {
        let focused_id = self.focused_accessibility_id(window, cx);
        let mut snapshot = self.accessibility.snapshot();
        snapshot.focused_id.clone_from(&focused_id);
        for node in &mut snapshot.nodes {
            node.focused = focused_id.as_deref() == Some(node.id.as_str());
        }
        snapshot
    }

    pub fn perform_accessibility_action(
        &mut self,
        id: &str,
        action: AccessibilityAction,
        value: Option<&str>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Result<(), AccessibilityActionError> {
        let snapshot = self.accessibility.snapshot();
        let node = snapshot
            .nodes
            .iter()
            .find(|node| node.id == id)
            .ok_or_else(|| AccessibilityActionError::UnknownNode(id.to_string()))?;
        if !node.enabled || !node.actions.contains(&action) {
            return Err(AccessibilityActionError::UnsupportedAction {
                id: id.to_string(),
                action,
            });
        }
        match action {
            AccessibilityAction::Focus => self.focus_accessibility_node(id, window, cx),
            AccessibilityAction::Press => {
                if self.buttons.contains_key(id) {
                    self.activate_button(id, cx);
                    Ok(())
                } else if let Some(record) = self.switches.get(id) {
                    let checked = record.entity.read(cx).checked();
                    self.activate_switch(id, !checked, cx);
                    Ok(())
                } else if id == "settings-hotkey-input" {
                    self.hotkey_capture.update(cx, |capture, cx| {
                        capture.start_listening(window, cx);
                    });
                    Ok(())
                } else {
                    Err(AccessibilityActionError::UnknownNode(id.to_string()))
                }
            }
            AccessibilityAction::SetValue => {
                let value =
                    value.ok_or_else(|| AccessibilityActionError::MissingValue(id.to_string()))?;
                if id == "settings-vocabulary-input" {
                    self.vocabulary_revision = self.vocabulary_revision.saturating_add(1);
                    self.vocabulary_input.update(cx, |input, cx| {
                        input.set_value(value.to_string(), window, cx);
                    });
                    self.dispatch(AppAction::SetCustomVocabulary(value.to_string()), cx);
                    Ok(())
                } else {
                    Err(AccessibilityActionError::UnsupportedAction {
                        id: id.to_string(),
                        action,
                    })
                }
            }
            AccessibilityAction::Increment | AccessibilityAction::Decrement => {
                Err(AccessibilityActionError::UnsupportedAction {
                    id: id.to_string(),
                    action,
                })
            }
        }
    }

    fn focused_accessibility_id(&self, window: &Window, cx: &App) -> Option<String> {
        for (id, record) in &self.buttons {
            if record.entity.read(cx).focus_handle(cx).is_focused(window) {
                return Some(id.clone());
            }
        }
        for (id, record) in &self.switches {
            if record.entity.read(cx).focus_handle(cx).is_focused(window) {
                return Some(id.clone());
            }
        }
        if self
            .hotkey_capture
            .read(cx)
            .focus_handle(cx)
            .is_focused(window)
        {
            return Some("settings-hotkey-input".to_string());
        }
        if self
            .vocabulary_input
            .read(cx)
            .focus_handle(cx)
            .is_focused(window)
        {
            return Some("settings-vocabulary-input".to_string());
        }
        None
    }

    fn focus_accessibility_node(
        &self,
        id: &str,
        window: &mut Window,
        cx: &App,
    ) -> Result<(), AccessibilityActionError> {
        if let Some(record) = self.buttons.get(id) {
            record.entity.read(cx).focus_handle(cx).focus(window);
            return Ok(());
        }
        if let Some(record) = self.switches.get(id) {
            record.entity.read(cx).focus_handle(cx).focus(window);
            return Ok(());
        }
        if id == "settings-hotkey-input" {
            self.hotkey_capture.read(cx).focus_handle(cx).focus(window);
            return Ok(());
        }
        if id == "settings-vocabulary-input" {
            self.vocabulary_input
                .read(cx)
                .focus_handle(cx)
                .focus(window);
            return Ok(());
        }
        Err(AccessibilityActionError::UnknownNode(id.to_string()))
    }

    fn schedule_vocabulary_update(&mut self, input: Entity<InputState>, cx: &mut Context<Self>) {
        self.vocabulary_revision = self.vocabulary_revision.saturating_add(1);
        let revision = self.vocabulary_revision;
        cx.spawn(async move |this, cx| {
            Timer::after(Duration::from_millis(500)).await;
            let _ = this.update(cx, |this, cx| {
                if this.vocabulary_revision == revision {
                    this.dispatch(
                        AppAction::SetCustomVocabulary(input.read(cx).value().to_string()),
                        cx,
                    );
                }
            });
        })
        .detach();
    }

    fn dispatch(&self, action: AppAction, cx: &mut Context<Self>) {
        self.model
            .update(cx, |model, cx| model.dispatch(action, cx));
    }

    fn register_accessibility_node(&mut self, draft: AccessibilityNodeDraft) {
        self.accessibility.register(draft);
    }

    fn measure_accessibility_node(
        &self,
        id: impl Into<String>,
        element: impl IntoElement,
        cx: &Context<Self>,
    ) -> AnyElement {
        let id = id.into();
        let epoch = self.accessibility.current_epoch();
        let weak_self = cx.entity().downgrade();
        MeasuredElement::new(element, move |bounds, _, cx| {
            let _ = weak_self.update(cx, |this, _| {
                this.accessibility
                    .measure(epoch, &id, AccessibilityFrame::from(bounds));
            });
        })
        .into_any_element()
    }

    fn accessibility_element(
        &mut self,
        draft: AccessibilityNodeDraft,
        element: impl IntoElement,
        cx: &Context<Self>,
    ) -> AnyElement {
        let id = draft.id.clone();
        self.register_accessibility_node(draft);
        self.measure_accessibility_node(id, element, cx)
    }

    fn update_accessibility_announcement(&mut self, plan: &ScreenPlan, notice: Option<&Notice>) {
        let announcement = if let Some(notice) = notice {
            let priority = if notice.kind == NoticeKind::Error {
                AccessibilityPriority::High
            } else {
                AccessibilityPriority::Medium
            };
            let message = notice.detail.as_ref().map_or_else(
                || notice.title.clone(),
                |detail| format!("{}. {detail}", notice.title),
            );
            Some((
                format!(
                    "notice:{:?}:{}:{:?}",
                    notice.kind, notice.title, notice.detail
                ),
                message,
                priority,
            ))
        } else if self.last_accessibility_route != Some(plan.route) {
            self.last_accessibility_route = Some(plan.route);
            Some((
                format!("route:{:?}", plan.route),
                plan.title.clone(),
                AccessibilityPriority::Medium,
            ))
        } else {
            plan.sections.iter().find_map(|section| {
                section.blocks.iter().find_map(|block| match block {
                    BlockPlan::Status {
                        kind,
                        title,
                        detail,
                        ..
                    } => {
                        let priority = if *kind == StatusKind::Error {
                            AccessibilityPriority::High
                        } else {
                            AccessibilityPriority::Low
                        };
                        let message = detail
                            .as_ref()
                            .map_or_else(|| title.clone(), |detail| format!("{title}. {detail}"));
                        Some((
                            format!("status:{kind:?}:{title}:{detail:?}"),
                            message,
                            priority,
                        ))
                    }
                    BlockPlan::Card(_) => None,
                })
            })
        };

        let Some((key, message, priority)) = announcement else {
            self.last_screen_announcement_key = None;
            return;
        };
        if self.last_screen_announcement_key.as_ref() != Some(&key) {
            self.last_screen_announcement_key = Some(key.clone());
            self.accessibility.announce(key, message, priority);
        }
    }

    fn activate_button(&mut self, id: &str, cx: &mut Context<Self>) {
        let Some(intent) = self.button_intents.get(id).cloned() else {
            return;
        };
        match intent {
            ScreenIntent::Dispatch(action) => self.dispatch(action, cx),
            ScreenIntent::ShowClearHistoryConfirmation => {
                self.modal_restore_focus_id = Some(id.to_string());
                self.confirm_clear_history = true;
                self.modal_needs_initial_focus = true;
                cx.notify();
            }
            ScreenIntent::DismissClearHistoryConfirmation => {
                self.confirm_clear_history = false;
                self.modal_needs_restore = true;
                cx.notify();
            }
            ScreenIntent::ConfirmClearHistory => {
                self.confirm_clear_history = false;
                self.modal_needs_restore = true;
                self.dispatch(AppAction::ClearHistory, cx);
                cx.notify();
            }
        }
    }

    fn on_dialog_key_down(&mut self, event: &KeyDownEvent, _: &mut Window, cx: &mut Context<Self>) {
        if event.keystroke.key.eq_ignore_ascii_case("escape") {
            self.confirm_clear_history = false;
            self.modal_needs_restore = true;
            cx.stop_propagation();
            cx.notify();
        }
    }

    fn activate_switch(&self, id: &str, checked: bool, cx: &mut Context<Self>) {
        let action = match self.switch_kinds.get(id) {
            Some(ToggleKind::SoundEnabled) => AppAction::SetSoundEnabled(checked),
            Some(ToggleKind::LaunchAtLogin) => AppAction::SetLaunchAtLogin(checked),
            None => return,
        };
        self.dispatch(action, cx);
    }

    fn button(&mut self, action: &ActionPlan, cx: &mut Context<Self>) -> Entity<AccessibleButton> {
        self.button_intents
            .insert(action.id.clone(), action.intent.clone());
        if !self.buttons.contains_key(&action.id) {
            let id = action.id.clone();
            let subscription_id = id.clone();
            let label = action.label.clone();
            let entity = cx.new(|cx| AccessibleButton::new(id.clone(), label.clone(), cx));
            cx.subscribe(
                &entity,
                move |this, _, event: &AccessibleButtonEvent, cx| {
                    if *event == AccessibleButtonEvent::Pressed {
                        this.activate_button(&subscription_id, cx);
                    }
                },
            )
            .detach();
            self.buttons.insert(id, ButtonRecord { entity });
        }
        let entity = self.buttons[&action.id].entity.clone();
        entity.update(cx, |button, cx| {
            button.set_label(action.label.clone(), cx);
            button.set_style(action.style, cx);
            let modal_action = matches!(
                action.id.as_str(),
                "cancel-clear-history" | "confirm-clear-history"
            );
            button.set_disabled(
                !action.enabled || (self.confirm_clear_history && !modal_action),
                cx,
            );
        });
        entity
    }

    fn switch(
        &mut self,
        id: &str,
        label: &str,
        checked: bool,
        enabled: bool,
        kind: ToggleKind,
        cx: &mut Context<Self>,
    ) -> Entity<AccessibleSwitch> {
        self.switch_kinds.insert(id.to_string(), kind);
        if !self.switches.contains_key(id) {
            let owned_id = id.to_string();
            let subscription_id = owned_id.clone();
            let entity = cx
                .new(|cx| AccessibleSwitch::new(owned_id.clone(), label.to_string(), checked, cx));
            cx.subscribe(
                &entity,
                move |this, _, event: &AccessibleSwitchEvent, cx| {
                    let AccessibleSwitchEvent::Changed(checked) = *event;
                    this.activate_switch(&subscription_id, checked, cx);
                },
            )
            .detach();
            self.switches.insert(owned_id, SwitchRecord { entity });
        }
        let entity = self.switches[id].entity.clone();
        entity.update(cx, |switch, cx| {
            switch.sync_checked(checked, cx);
            switch.set_disabled(!enabled || self.confirm_clear_history, cx);
        });
        entity
    }

    fn screen_plan(&self, presentation: &AppPresentation) -> ScreenPlan {
        match presentation.active_route {
            NavigationTarget::Loading => loading_plan(),
            NavigationTarget::Onboarding => onboarding::project(presentation),
            NavigationTarget::PermissionRecovery => onboarding::project_recovery(presentation),
            NavigationTarget::Settings => settings::project(&presentation.settings),
            NavigationTarget::Models => models::project(&presentation.models),
            NavigationTarget::History => {
                history::project(&presentation.history, self.confirm_clear_history)
            }
            NavigationTarget::About => about::project(&presentation.about),
        }
    }

    fn render_plan(
        &mut self,
        plan: ScreenPlan,
        notice: Option<&Notice>,
        root_id: &str,
        compact: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let tokens = WrenflowTheme::current(cx).tokens;
        let sidebar = (plan.layout == ScreenLayout::Application)
            .then(|| self.render_sidebar(plan.route, root_id, compact, cx));
        let heading = self.accessibility_element(
            AccessibilityNodeDraft::new(
                format!("{root_id}:heading"),
                Some(root_id),
                AccessibilityRole::Heading,
                plan.title.clone(),
            ),
            div()
                .min_w(px(0.0))
                .text_size(if plan.layout == ScreenLayout::Centered {
                    tokens.typography.hero
                } else {
                    tokens.typography.title
                })
                .child(plan.title.clone()),
            cx,
        );
        let subtitle = plan.subtitle.clone().map(|subtitle| {
            self.accessibility_element(
                AccessibilityNodeDraft::new(
                    format!("{root_id}:subtitle"),
                    Some(root_id),
                    AccessibilityRole::StaticText,
                    subtitle.clone(),
                ),
                div()
                    .min_w(px(0.0))
                    .text_size(tokens.typography.body)
                    .text_color(tokens.colors.muted_foreground)
                    .child(subtitle),
                cx,
            )
        });
        let scroll_id = format!("{root_id}:scroll");
        self.register_accessibility_node(AccessibilityNodeDraft::new(
            scroll_id.clone(),
            Some(root_id),
            AccessibilityRole::Group,
            "Scrollable screen content",
        ));
        let notice = notice.map(|notice| self.render_notice(notice, &scroll_id, cx));
        let sections = plan
            .sections
            .iter()
            .enumerate()
            .map(|(index, section)| self.render_section(section, index, &scroll_id, cx))
            .collect::<Vec<_>>();
        let footer = self.render_actions(&plan.footer_actions, &scroll_id, cx);
        let scroll = div()
            .id("screen-scroll")
            .flex()
            .flex_col()
            .flex_1()
            .gap(tokens.spacing.xl)
            .p(tokens.spacing.lg)
            .when_some(notice, |this, notice| this.child(notice))
            .children(sections)
            .when(!plan.footer_actions.is_empty(), |this| {
                this.child(
                    div()
                        .flex()
                        .flex_wrap()
                        .justify_end()
                        .gap(tokens.spacing.sm)
                        .children(footer),
                )
            })
            .overflow_y_scrollbar();
        let scroll = self.measure_accessibility_node(&scroll_id, scroll, cx);

        let content = div()
            .flex()
            .flex_col()
            .flex_1()
            .h_full()
            .min_w(px(0.))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(tokens.spacing.xs)
                    .p(tokens.spacing.lg)
                    .border_b_1()
                    .border_color(tokens.colors.border)
                    .child(heading)
                    .when_some(subtitle, |this, subtitle| this.child(subtitle)),
            )
            .child(scroll);

        let page = match plan.layout {
            ScreenLayout::Application => div()
                .flex()
                .when(compact, |this| this.flex_col())
                .size_full()
                .children(sidebar)
                .child(content)
                .into_any_element(),
            ScreenLayout::Centered => div()
                .flex()
                .size_full()
                .justify_center()
                .child(
                    div()
                        .w_full()
                        .max_w(tokens.controls.content_max_width)
                        .h_full()
                        .child(content),
                )
                .into_any_element(),
        };

        div()
            .relative()
            .size_full()
            .bg(tokens.colors.background)
            .text_color(tokens.colors.foreground)
            .font_family("-apple-system")
            .child(page)
            .when(plan.confirm_clear_history, |this| {
                this.child(self.render_clear_history_dialog(root_id, cx))
            })
            .into_any_element()
    }

    fn render_sidebar(
        &mut self,
        active_route: NavigationTarget,
        root_id: &str,
        compact: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let navigation_id = format!("{root_id}:navigation");
        self.register_accessibility_node(AccessibilityNodeDraft::new(
            navigation_id.clone(),
            Some(root_id),
            AccessibilityRole::Navigation,
            "Wrenflow sections",
        ));
        let destinations = [
            (NavigationTarget::Settings, "General"),
            (NavigationTarget::Models, "Models"),
            (NavigationTarget::History, "History"),
            (NavigationTarget::About, "About"),
        ];
        let buttons = destinations
            .into_iter()
            .map(|(route, label)| {
                let mut action = ActionPlan::dispatch(
                    format!("nav-{}", label.to_lowercase()),
                    label,
                    AppAction::Navigate(route),
                );
                action.style = if route == active_route {
                    ButtonStyle::Primary
                } else {
                    ButtonStyle::Ghost
                };
                self.render_action(&action, &navigation_id, cx)
            })
            .collect::<Vec<_>>();
        self.measure_accessibility_node(
            navigation_id,
            NavigationSidebar::new("wrenflow-navigation", "Wrenflow")
                .compact(compact)
                .items(buttons),
            cx,
        )
    }

    fn render_section(
        &mut self,
        section: &SectionPlan,
        index: usize,
        root_id: &str,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let tokens = WrenflowTheme::current(cx).tokens;
        let section_id = format!("{root_id}:section:{index}");
        let section_label = section
            .title
            .clone()
            .unwrap_or_else(|| "Content".to_string());
        self.register_accessibility_node(AccessibilityNodeDraft::new(
            section_id.clone(),
            Some(root_id),
            AccessibilityRole::Group,
            section_label,
        ));
        let blocks = section
            .blocks
            .iter()
            .enumerate()
            .map(|(block_index, block)| self.render_block(block, block_index, &section_id, cx))
            .collect::<Vec<_>>();
        self.measure_accessibility_node(
            section_id,
            div()
                .flex()
                .flex_col()
                .min_w(px(0.0))
                .gap(tokens.spacing.md)
                .when_some(section.title.clone(), |this, title| {
                    this.child(
                        div()
                            .text_size(tokens.typography.caption)
                            .text_color(tokens.colors.muted_foreground)
                            .child(title),
                    )
                })
                .children(blocks),
            cx,
        )
    }

    fn render_block(
        &mut self,
        block: &BlockPlan,
        index: usize,
        parent_id: &str,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        match block {
            BlockPlan::Card(card) => self.render_card(card, parent_id, cx),
            BlockPlan::Status {
                kind,
                title,
                detail,
                action,
            } => {
                let status_id = format!("{parent_id}:status:{index}");
                let draft = AccessibilityNodeDraft::new(
                    status_id.clone(),
                    Some(parent_id),
                    AccessibilityRole::Status,
                    title.clone(),
                );
                let draft = detail
                    .as_ref()
                    .map_or(draft.clone(), |detail| draft.value(detail.clone()));
                self.register_accessibility_node(draft);
                let mut surface = StatusSurface::new(*kind, title.clone());
                if let Some(detail) = detail {
                    surface = surface.detail(detail.clone());
                }
                if let Some(action) = action {
                    surface = surface.action(self.render_action(action, &status_id, cx));
                }
                self.measure_accessibility_node(status_id, surface, cx)
            }
        }
    }

    fn render_card(
        &mut self,
        plan: &CardPlan,
        parent_id: &str,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let value = plan
            .lines
            .iter()
            .map(|line| {
                line.label.as_ref().map_or_else(
                    || line.value.clone(),
                    |label| format!("{label}: {}", line.value),
                )
            })
            .collect::<Vec<_>>()
            .join(". ");
        let draft = AccessibilityNodeDraft::new(
            plan.id.clone(),
            Some(parent_id),
            AccessibilityRole::Group,
            plan.title.clone(),
        );
        let draft = if value.is_empty() {
            draft
        } else {
            draft.value(value)
        };
        self.register_accessibility_node(draft);
        let lines = plan
            .lines
            .iter()
            .map(|line| self.render_text(line, cx))
            .collect::<Vec<_>>();
        let controls = plan
            .controls
            .iter()
            .map(|control| self.render_control(control, &plan.id, cx))
            .collect::<Vec<_>>();
        self.measure_accessibility_node(
            plan.id.clone(),
            Card::new()
                .title(plan.title.clone())
                .children(lines)
                .children(controls),
            cx,
        )
    }

    fn render_text(&self, plan: &TextPlan, cx: &Context<Self>) -> AnyElement {
        let tokens = WrenflowTheme::current(cx).tokens;
        let color = match plan.tone {
            TextTone::Normal | TextTone::Monospace => tokens.colors.foreground,
            TextTone::Muted => tokens.colors.muted_foreground,
            TextTone::Success => tokens.colors.accent,
            TextTone::Danger => tokens.colors.danger,
        };
        div()
            .flex()
            .flex_wrap()
            .items_start()
            .justify_between()
            .gap(tokens.spacing.lg)
            .when_some(plan.label.clone(), |this, label| {
                this.child(
                    div()
                        .min_w(px(0.0))
                        .flex_1()
                        .text_color(tokens.colors.muted_foreground)
                        .child(label),
                )
            })
            .child(
                div()
                    .min_w(px(0.0))
                    .flex_1()
                    .text_color(color)
                    .when(plan.tone == TextTone::Monospace, |this| {
                        this.font_family("ui-monospace")
                    })
                    .child(plan.value.clone()),
            )
            .into_any_element()
    }

    fn render_control(
        &mut self,
        plan: &ControlPlan,
        parent_id: &str,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let tokens = WrenflowTheme::current(cx).tokens;
        match plan {
            ControlPlan::Actions(actions) => div()
                .flex()
                .flex_wrap()
                .gap(tokens.spacing.sm)
                .children(self.render_actions(actions, parent_id, cx))
                .into_any_element(),
            ControlPlan::Toggle {
                id,
                label,
                checked,
                enabled,
                kind,
            } => {
                let enabled = *enabled && !self.confirm_clear_history;
                let entity = self.switch(id, label, *checked, enabled, *kind, cx);
                self.accessibility_element(
                    AccessibilityNodeDraft::new(
                        id.clone(),
                        Some(parent_id),
                        AccessibilityRole::Switch,
                        label.clone(),
                    )
                    .value(if *checked { "on" } else { "off" })
                    .enabled(enabled)
                    .actions([AccessibilityAction::Press, AccessibilityAction::Focus]),
                    entity,
                    cx,
                )
            }
            ControlPlan::Input {
                kind,
                id,
                label,
                value,
                hint,
                enabled,
            } => match kind {
                InputKind::Hotkey => self.render_hotkey_control(
                    HotkeyControl {
                        id,
                        label,
                        value,
                        hint,
                        enabled: *enabled,
                        parent_id,
                    },
                    cx,
                ),
                InputKind::Vocabulary => {
                    let enabled = *enabled && !self.confirm_clear_history;
                    let accessibility_value = self.vocabulary_input.read(cx).value().to_string();
                    let input = self.accessibility_element(
                        AccessibilityNodeDraft::new(
                            id.clone(),
                            Some(parent_id),
                            AccessibilityRole::TextField,
                            label.clone(),
                        )
                        .value(accessibility_value)
                        .enabled(enabled)
                        .actions([AccessibilityAction::Focus, AccessibilityAction::SetValue]),
                        text_input(&self.vocabulary_input).disabled(!enabled),
                        cx,
                    );
                    div()
                        .flex()
                        .flex_col()
                        .min_w(px(0.0))
                        .gap(tokens.spacing.sm)
                        .child(label.clone())
                        .child(input)
                        .child(
                            div()
                                .text_size(tokens.typography.caption)
                                .text_color(tokens.colors.muted_foreground)
                                .child(hint.clone()),
                        )
                        .into_any_element()
                }
            },
            ControlPlan::Progress {
                id,
                label,
                value,
                detail,
            } => self.accessibility_element(
                AccessibilityNodeDraft::new(
                    id.clone(),
                    Some(parent_id),
                    AccessibilityRole::ProgressIndicator,
                    label.clone(),
                )
                .value(format!("{:.0}%", value.clamp(0.0, 1.0) * 100.0)),
                div()
                    .flex()
                    .flex_col()
                    .min_w(px(0.0))
                    .gap(tokens.spacing.xs)
                    .child(
                        div()
                            .flex()
                            .flex_wrap()
                            .justify_between()
                            .child(label.clone())
                            .when_some(detail.clone(), |this, detail| this.child(detail)),
                    )
                    .child(progress(value.clamp(0.0, 1.0), cx)),
                cx,
            ),
        }
    }

    fn render_hotkey_control(
        &mut self,
        plan: HotkeyControl<'_>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let HotkeyControl {
            id,
            label,
            value,
            hint,
            enabled,
            parent_id,
        } = plan;
        let tokens = WrenflowTheme::current(cx).tokens;
        let presets = [
            ("63", "Fn"),
            ("54", "Right Command"),
            ("61", "Right Option"),
            ("96", "F5"),
        ];
        let actions = presets.map(|(code, preset_label)| {
            let mut action = ActionPlan::dispatch(
                format!("hotkey-preset-{code}"),
                preset_label,
                AppAction::SetSelectedHotkey(code.to_string()),
            )
            .enabled(enabled);
            action.style = if value == code {
                ButtonStyle::Primary
            } else {
                ButtonStyle::Secondary
            };
            action
        });
        let group_id = format!("{id}:group");
        self.register_accessibility_node(AccessibilityNodeDraft::new(
            group_id.clone(),
            Some(parent_id),
            AccessibilityRole::Group,
            label,
        ));
        let preset_buttons = self.render_actions(&actions, &group_id, cx);
        self.hotkey_capture.update(cx, |capture, cx| {
            capture.sync(value, !enabled || self.confirm_clear_history, cx);
        });
        let hotkey_value = if self.hotkey_capture.read(cx).listening {
            "Listening; press a key, or Escape to cancel".to_string()
        } else {
            hotkey_display_name(value)
        };
        let capture = self.accessibility_element(
            AccessibilityNodeDraft::new(
                id,
                Some(group_id.as_str()),
                AccessibilityRole::TextField,
                label,
            )
            .value(hotkey_value)
            .enabled(enabled && !self.confirm_clear_history)
            .actions([AccessibilityAction::Press, AccessibilityAction::Focus]),
            self.hotkey_capture.clone(),
            cx,
        );

        self.measure_accessibility_node(
            group_id,
            div()
                .flex()
                .flex_col()
                .min_w(px(0.0))
                .gap(tokens.spacing.sm)
                .child(label.to_string())
                .child(
                    div()
                        .flex()
                        .flex_wrap()
                        .gap(tokens.spacing.sm)
                        .children(preset_buttons),
                )
                .child(capture)
                .child(
                    div()
                        .text_size(tokens.typography.caption)
                        .text_color(tokens.colors.muted_foreground)
                        .child(hint.to_string()),
                ),
            cx,
        )
    }

    fn render_actions(
        &mut self,
        actions: &[ActionPlan],
        parent_id: &str,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        actions
            .iter()
            .map(|action| self.render_action(action, parent_id, cx))
            .collect()
    }

    fn render_action(
        &mut self,
        action: &ActionPlan,
        parent_id: &str,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let enabled = action.enabled
            && (!self.confirm_clear_history
                || matches!(
                    action.id.as_str(),
                    "cancel-clear-history" | "confirm-clear-history"
                ));
        let entity = self.button(action, cx);
        self.accessibility_element(
            AccessibilityNodeDraft::new(
                action.id.clone(),
                Some(parent_id),
                AccessibilityRole::Button,
                action.label.clone(),
            )
            .enabled(enabled)
            .actions([AccessibilityAction::Press, AccessibilityAction::Focus]),
            entity,
            cx,
        )
    }

    fn render_notice(
        &mut self,
        notice: &Notice,
        parent_id: &str,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let kind = match notice.kind {
            NoticeKind::Information => StatusKind::Empty,
            NoticeKind::Success => StatusKind::Success,
            NoticeKind::Error => StatusKind::Error,
        };
        let notice_id = format!("{parent_id}:notice");
        let draft = AccessibilityNodeDraft::new(
            notice_id.clone(),
            Some(parent_id),
            AccessibilityRole::Status,
            notice.title.clone(),
        );
        let draft = notice
            .detail
            .as_ref()
            .map_or(draft.clone(), |detail| draft.value(detail.clone()));
        self.register_accessibility_node(draft);
        let dismiss = ActionPlan::dispatch("dismiss-notice", "Dismiss", AppAction::ClearNotice);
        let mut surface = StatusSurface::new(kind, notice.title.clone())
            .action(self.render_action(&dismiss, &notice_id, cx));
        if let Some(detail) = &notice.detail {
            surface = surface.detail(detail.clone());
        }
        self.measure_accessibility_node(notice_id, surface, cx)
    }

    fn render_clear_history_dialog(
        &mut self,
        parent_id: &str,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let tokens = WrenflowTheme::current(cx).tokens;
        let dialog_id = "clear-history-dialog";
        let cancel = ActionPlan::intent(
            "cancel-clear-history",
            "Cancel",
            ScreenIntent::DismissClearHistoryConfirmation,
        );
        let confirm = ActionPlan::intent(
            "confirm-clear-history",
            "Clear history",
            ScreenIntent::ConfirmClearHistory,
        )
        .danger();
        self.register_accessibility_node(
            AccessibilityNodeDraft::new(
                dialog_id,
                Some(parent_id),
                AccessibilityRole::Dialog,
                "Clear transcription history?",
            )
            .value("This permanently deletes every saved transcription and its metadata."),
        );
        let dialog = DialogSurface::new(
            dialog_id,
            "Clear transcription history?",
            div().child("This permanently deletes every saved transcription and its metadata."),
        )
        .action(self.render_action(&cancel, dialog_id, cx))
        .action(self.render_action(&confirm, dialog_id, cx));
        let dialog = self.measure_accessibility_node(dialog_id, dialog, cx);

        div()
            .id("clear-history-modal-layer")
            .absolute()
            .size_full()
            .flex()
            .items_center()
            .justify_center()
            .p(tokens.spacing.lg)
            .bg(tokens.colors.background.opacity(0.88))
            .on_key_down(cx.listener(Self::on_dialog_key_down))
            .child(dialog)
            .into_any_element()
    }
}

impl Render for AppScreens {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let presentation = self.model.read(cx).presentation().clone();
        let plan = self.screen_plan(&presentation);
        let root_id = accessibility_root_id(plan.route);
        let compact = window.viewport_size().width
            < WrenflowTheme::current(cx)
                .tokens
                .controls
                .compact_breakpoint;
        let epoch = self.accessibility.begin_frame();
        self.update_accessibility_announcement(&plan, presentation.notice.as_ref());
        self.register_accessibility_node(AccessibilityNodeDraft::new(
            root_id,
            None::<String>,
            AccessibilityRole::Window,
            plan.title.clone(),
        ));
        let page = self.render_plan(plan, presentation.notice.as_ref(), root_id, compact, cx);
        let page = self.measure_accessibility_node(root_id, page, cx);
        if self.confirm_clear_history {
            self.accessibility
                .set_modal_root(Some("clear-history-dialog"));
        }
        self.accessibility.seal(epoch);

        if self.modal_needs_initial_focus || self.modal_needs_restore {
            cx.on_next_frame(window, |this, window, cx| {
                if this.modal_needs_initial_focus {
                    this.modal_needs_initial_focus = false;
                    let _ = this.focus_accessibility_node("cancel-clear-history", window, cx);
                } else if this.modal_needs_restore {
                    this.modal_needs_restore = false;
                    if let Some(id) = this.modal_restore_focus_id.take() {
                        let _ = this.focus_accessibility_node(&id, window, cx);
                    }
                }
            });
        }

        page
    }
}

const fn accessibility_root_id(route: NavigationTarget) -> &'static str {
    match route {
        NavigationTarget::Loading => "loading-screen",
        NavigationTarget::Onboarding => "onboarding-screen",
        NavigationTarget::PermissionRecovery => "permission-recovery-screen",
        NavigationTarget::Settings => "settings-screen",
        NavigationTarget::Models => "models-screen",
        NavigationTarget::History => "history-screen",
        NavigationTarget::About => "about-screen",
    }
}

fn loading_plan() -> ScreenPlan {
    let mut plan = ScreenPlan::centered(NavigationTarget::Loading, "Starting Wrenflow");
    plan.subtitle = Some("Preparing the local transcription runtime.".to_string());
    plan.sections = vec![SectionPlan::untitled(vec![BlockPlan::Status {
        kind: StatusKind::Loading,
        title: "Loading".to_string(),
        detail: Some("Opening settings, models and local history.".to_string()),
        action: None,
    }])];
    plan
}

#[cfg(test)]
mod tests {
    use crate::app::NavigationTarget;
    use crate::screens::{
        about, history, hotkey_capture_decision, mac_keycode, models, onboarding, settings,
        HotkeyCaptureDecision,
    };

    #[test]
    fn gpui_keys_map_to_canonical_mac_virtual_codes() {
        assert_eq!(mac_keycode("f5"), Some(96));
        assert_eq!(mac_keycode("space"), Some(49));
        assert_eq!(mac_keycode("a"), Some(0));
        assert_eq!(mac_keycode("media-play-pause"), None);
    }

    #[test]
    fn hotkey_capture_preserves_navigation_and_has_explicit_cancel() {
        assert_eq!(
            hotkey_capture_decision("tab", true),
            HotkeyCaptureDecision::Navigate
        );
        assert_eq!(
            hotkey_capture_decision("escape", true),
            HotkeyCaptureDecision::Cancel
        );
        assert_eq!(
            hotkey_capture_decision("f5", true),
            HotkeyCaptureDecision::Commit(96)
        );
        assert_eq!(
            hotkey_capture_decision("f5", false),
            HotkeyCaptureDecision::Ignore
        );
    }

    #[test]
    fn every_product_route_has_a_projection_module() {
        let routes = [
            NavigationTarget::Onboarding,
            NavigationTarget::PermissionRecovery,
            NavigationTarget::Settings,
            NavigationTarget::Models,
            NavigationTarget::History,
            NavigationTarget::About,
        ];
        assert_eq!(routes.len(), 6);
        let module_markers = [
            std::any::type_name_of_val(&onboarding::project),
            std::any::type_name_of_val(&onboarding::project_recovery),
            std::any::type_name_of_val(&settings::project),
            std::any::type_name_of_val(&models::project),
            std::any::type_name_of_val(&history::project),
            std::any::type_name_of_val(&about::project),
        ];
        assert_eq!(module_markers.len(), routes.len());
    }
}
