use gpui::{
    actions, div, prelude::FluentBuilder as _, px, svg, AnyElement, App, Context, Entity,
    EventEmitter, FocusHandle, Focusable, FontWeight, InteractiveElement as _, IntoElement,
    KeyBinding, ParentElement, Render, RenderOnce, SharedString, StatefulInteractiveElement as _,
    Styled as _, Window,
};
use gpui_component::{
    input::{Input, InputState},
    progress::Progress,
    select::{Select, SelectDelegate, SelectState},
    spinner::Spinner,
};

use super::{ControlSemantics, SemanticRole, WrenflowTheme};

const BUTTON_KEY_CONTEXT: &str = "WrenflowButton";
const SWITCH_KEY_CONTEXT: &str = "WrenflowSwitch";

actions!(wrenflow_controls, [PressButton, ActivateSwitch]);

pub fn init_control_keybindings(cx: &mut App) {
    cx.bind_keys([
        KeyBinding::new("space", PressButton, Some(BUTTON_KEY_CONTEXT)),
        KeyBinding::new("enter", PressButton, Some(BUTTON_KEY_CONTEXT)),
        KeyBinding::new("space", ActivateSwitch, Some(SWITCH_KEY_CONTEXT)),
        KeyBinding::new("enter", ActivateSwitch, Some(SWITCH_KEY_CONTEXT)),
    ]);
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ButtonStyle {
    #[default]
    Primary,
    Secondary,
    Danger,
    Ghost,
    Selected,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AccessibleButtonEvent {
    Pressed,
}

/// Keyboard-operable Wrenflow button. This replaces gpui-component's button for
/// critical paths because the upstream 0.5.1 button is a tab stop but does not
/// bind Space or Enter to activation.
pub struct AccessibleButton {
    id: SharedString,
    label: SharedString,
    style: ButtonStyle,
    disabled: bool,
    focus_handle: FocusHandle,
}

impl AccessibleButton {
    pub fn new(
        id: impl Into<SharedString>,
        label: impl Into<SharedString>,
        cx: &mut Context<Self>,
    ) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
            style: ButtonStyle::Primary,
            disabled: false,
            focus_handle: cx.focus_handle(),
        }
    }

    pub fn set_style(&mut self, style: ButtonStyle, cx: &mut Context<Self>) {
        if self.style != style {
            self.style = style;
            cx.notify();
        }
    }

    pub fn set_label(&mut self, label: impl Into<SharedString>, cx: &mut Context<Self>) {
        let label = label.into();
        if self.label != label {
            self.label = label;
            cx.notify();
        }
    }

    pub fn set_disabled(&mut self, disabled: bool, cx: &mut Context<Self>) {
        if self.disabled != disabled {
            self.disabled = disabled;
            cx.notify();
        }
    }

    pub fn semantics(&self) -> ControlSemantics {
        ControlSemantics {
            id: self.id.to_string(),
            role: SemanticRole::Button,
            label: self.label.to_string(),
            enabled: !self.disabled,
            checked: None,
            value: None,
        }
    }

    fn press(&mut self, cx: &mut Context<Self>) {
        if !self.disabled {
            cx.emit(AccessibleButtonEvent::Pressed);
        }
    }

    fn on_press(&mut self, _: &PressButton, _: &mut Window, cx: &mut Context<Self>) {
        self.press(cx);
    }
}

impl EventEmitter<AccessibleButtonEvent> for AccessibleButton {}

impl Focusable for AccessibleButton {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus_handle.clone()
    }
}

impl Render for AccessibleButton {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let tokens = WrenflowTheme::current(cx).tokens;
        let focused = self.focus_handle.is_focused(window);
        let (background, foreground, border) = match self.style {
            ButtonStyle::Primary => (
                tokens.colors.foreground,
                tokens.colors.surface,
                tokens.colors.foreground,
            ),
            ButtonStyle::Secondary => (
                tokens.colors.button_surface,
                tokens.colors.foreground,
                tokens.colors.border,
            ),
            ButtonStyle::Danger => (
                tokens.colors.surface.opacity(0.0),
                tokens.colors.danger,
                tokens.colors.surface.opacity(0.0),
            ),
            ButtonStyle::Ghost => (
                tokens.colors.surface.opacity(0.0),
                tokens.colors.muted_foreground,
                tokens.colors.surface.opacity(0.0),
            ),
            ButtonStyle::Selected => (
                tokens.colors.selected_surface,
                tokens.colors.foreground,
                tokens.colors.surface.opacity(0.0),
            ),
        };
        let navigation_icon = navigation_icon(self.id.as_ref());
        let action_icon = history_action_icon(self.id.as_ref(), self.label.as_ref());
        let is_navigation = navigation_icon.is_some();
        let is_icon_only = action_icon.is_some();
        let is_hotkey_preset = self.id.starts_with("hotkey-preset-");
        let is_microphone = self.id.starts_with("select-microphone-");
        let show_focus_ring = focused && !(is_navigation && self.style == ButtonStyle::Selected);
        let border = if show_focus_ring {
            tokens.colors.focus_ring
        } else {
            border
        };
        let focus_handle = self.focus_handle.clone().tab_stop(!self.disabled);
        let disabled = self.disabled;

        div()
            .id(self.id.clone())
            .key_context(BUTTON_KEY_CONTEXT)
            .track_focus(&focus_handle)
            .flex()
            .items_center()
            .justify_center()
            .when(is_navigation, |this| {
                this.w_full()
                    .justify_start()
                    .gap(tokens.spacing.sm)
                    .px(px(10.))
            })
            .when(is_icon_only, |this| {
                this.size(px(20.))
                    .min_h(px(20.))
                    .p_0()
                    .border_color(tokens.colors.surface.opacity(0.0))
                    .bg(tokens.colors.surface.opacity(0.0))
            })
            .min_h(px(26.))
            .px(tokens.spacing.lg)
            .py(px(5.))
            .rounded(tokens.controls.button_radius)
            .border(if show_focus_ring {
                tokens.controls.focus_width
            } else {
                tokens.controls.border_width
            })
            .border_color(border)
            .bg(background)
            .when(is_hotkey_preset, |this| {
                this.w_full()
                    .justify_start()
                    .gap(tokens.spacing.md)
                    .min_h(px(28.))
                    .px(px(10.))
                    .py(px(3.))
                    .rounded(px(7.))
                    .border_color(tokens.colors.surface.opacity(0.0))
                    .bg(if self.style == ButtonStyle::Selected {
                        tokens.colors.subtle_surface
                    } else {
                        tokens.colors.surface.opacity(0.0)
                    })
            })
            .when(is_microphone, |this| {
                this.w_full()
                    .justify_start()
                    .gap(tokens.spacing.md)
                    .min_h(px(28.))
                    .px(px(10.))
                    .py(px(3.))
                    .rounded(px(7.))
                    .border_color(tokens.colors.surface.opacity(0.0))
                    .bg(if self.style == ButtonStyle::Selected {
                        tokens.colors.subtle_surface
                    } else {
                        tokens.colors.surface.opacity(0.0)
                    })
            })
            .text_size(tokens.typography.body)
            .text_color(foreground)
            .when(!disabled, |this| {
                this.cursor_pointer()
                    .on_action(cx.listener(Self::on_press))
                    .on_click(cx.listener(|this, _, _, cx| this.press(cx)))
            })
            .when(disabled, |this| this.opacity(0.5))
            .when_some(navigation_icon, |this, icon| {
                this.child(svg().path(icon).size(px(11.)).text_color(
                    if self.style == ButtonStyle::Selected {
                        tokens.colors.foreground
                    } else {
                        tokens.colors.tertiary_foreground
                    },
                ))
            })
            .when_some(action_icon, |this, icon| {
                this.child(
                    svg()
                        .path(icon)
                        .size(px(12.))
                        .text_color(tokens.colors.tertiary_foreground),
                )
            })
            .when(is_hotkey_preset, |this| {
                this.child(if self.style == ButtonStyle::Selected {
                    svg()
                        .path("icons/circle-check.svg")
                        .size(px(13.))
                        .text_color(tokens.colors.foreground)
                        .into_any_element()
                } else {
                    div()
                        .size(px(13.))
                        .rounded(px(13.))
                        .border(tokens.controls.border_width)
                        .border_color(tokens.colors.tertiary_foreground)
                        .into_any_element()
                })
            })
            .when(is_microphone, |this| {
                this.child(if self.style == ButtonStyle::Selected {
                    svg()
                        .path("icons/circle-check.svg")
                        .size(px(13.))
                        .text_color(tokens.colors.foreground)
                        .into_any_element()
                } else {
                    div()
                        .size(px(13.))
                        .rounded(px(13.))
                        .border(tokens.controls.border_width)
                        .border_color(tokens.colors.tertiary_foreground)
                        .into_any_element()
                })
            })
            .when(!is_icon_only, |this| this.child(self.label.clone()))
    }
}

fn navigation_icon(id: &str) -> Option<&'static str> {
    match id {
        "nav-general" => Some("icons/settings.svg"),
        "nav-models" => Some("icons/bot.svg"),
        "nav-history" => Some("icons/calendar.svg"),
        "nav-about" => Some("icons/info.svg"),
        _ => None,
    }
}

fn history_action_icon(id: &str, label: &str) -> Option<&'static str> {
    if id.starts_with("delete-history-") {
        Some("icons/close.svg")
    } else if id.starts_with("toggle-history-") {
        Some(if label == "Hide details" {
            "icons/chevron-up.svg"
        } else {
            "icons/chevron-down.svg"
        })
    } else {
        None
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AccessibleSwitchEvent {
    Changed(bool),
}

/// Focusable, keyboard-operable replacement for gpui-component's pointer-only
/// switch. It retains a platform-neutral semantic snapshot for the future
/// NSAccessibility bridge.
pub struct AccessibleSwitch {
    id: SharedString,
    label: SharedString,
    checked: bool,
    disabled: bool,
    focus_handle: FocusHandle,
}

impl AccessibleSwitch {
    pub fn new(
        id: impl Into<SharedString>,
        label: impl Into<SharedString>,
        checked: bool,
        cx: &mut Context<Self>,
    ) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
            checked,
            disabled: false,
            focus_handle: cx.focus_handle(),
        }
    }

    pub fn checked(&self) -> bool {
        self.checked
    }

    pub fn set_checked(&mut self, checked: bool, cx: &mut Context<Self>) {
        if self.checked != checked {
            self.checked = checked;
            cx.emit(AccessibleSwitchEvent::Changed(checked));
            cx.notify();
        }
    }

    /// Synchronize externally-owned state without emitting a user-change event.
    pub fn sync_checked(&mut self, checked: bool, cx: &mut Context<Self>) {
        if self.checked != checked {
            self.checked = checked;
            cx.notify();
        }
    }

    pub fn set_disabled(&mut self, disabled: bool, cx: &mut Context<Self>) {
        if self.disabled != disabled {
            self.disabled = disabled;
            cx.notify();
        }
    }

    pub fn semantics(&self) -> ControlSemantics {
        ControlSemantics {
            id: self.id.to_string(),
            role: SemanticRole::Switch,
            label: self.label.to_string(),
            enabled: !self.disabled,
            checked: Some(self.checked),
            value: Some(if self.checked { "on" } else { "off" }.into()),
        }
    }

    fn activate(&mut self, cx: &mut Context<Self>) {
        if !self.disabled {
            self.set_checked(!self.checked, cx);
        }
    }

    fn on_activate(&mut self, _: &ActivateSwitch, _: &mut Window, cx: &mut Context<Self>) {
        self.activate(cx);
    }
}

impl EventEmitter<AccessibleSwitchEvent> for AccessibleSwitch {}

impl Focusable for AccessibleSwitch {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus_handle.clone()
    }
}

impl Render for AccessibleSwitch {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let tokens = WrenflowTheme::current(cx).tokens;
        let focused = self.focus_handle.is_focused(window);
        let track_color = if self.checked {
            tokens.colors.accent
        } else {
            tokens.colors.control_inactive
        };
        let border_color = if focused {
            tokens.colors.focus_ring
        } else {
            tokens.colors.surface.opacity(0.0)
        };
        let focus_handle = self.focus_handle.clone().tab_stop(!self.disabled);
        let disabled = self.disabled;

        div()
            .id(self.id.clone())
            .key_context(SWITCH_KEY_CONTEXT)
            .track_focus(&focus_handle)
            .flex()
            .items_center()
            .justify_between()
            .w_full()
            .min_h(tokens.controls.switch_height)
            .gap(tokens.spacing.lg)
            .rounded(tokens.controls.button_radius)
            .border(if focused {
                tokens.controls.focus_width
            } else {
                tokens.controls.border_width
            })
            .border_color(border_color)
            .text_size(tokens.typography.body)
            .text_color(tokens.colors.foreground)
            .when(!disabled, |this| {
                this.cursor_pointer()
                    .on_action(cx.listener(Self::on_activate))
                    .on_click(cx.listener(|this, _, _, cx| this.activate(cx)))
            })
            .when(disabled, |this| this.opacity(0.5))
            .child(self.label.clone())
            .child(
                div()
                    .flex()
                    .items_center()
                    .when(self.checked, |this| this.justify_end())
                    .w(tokens.controls.switch_width)
                    .h(tokens.controls.switch_height)
                    .p(px(2.))
                    .rounded(tokens.controls.switch_height)
                    .bg(track_color)
                    .child(
                        div()
                            .size(tokens.controls.switch_thumb)
                            .rounded(tokens.controls.switch_thumb)
                            .bg(tokens.colors.surface),
                    ),
            )
    }
}

pub fn text_input(state: &Entity<InputState>) -> Input {
    Input::new(state).w_full()
}

pub fn text_input_semantics(
    id: impl Into<String>,
    label: impl Into<String>,
    enabled: bool,
    value: impl Into<String>,
) -> ControlSemantics {
    ControlSemantics {
        id: id.into(),
        role: SemanticRole::TextField,
        label: label.into(),
        enabled,
        checked: None,
        value: Some(value.into()),
    }
}

pub fn select<D>(state: &Entity<SelectState<D>>) -> Select<D>
where
    D: SelectDelegate + 'static,
{
    Select::new(state).w_full()
}

pub fn select_semantics(
    id: impl Into<String>,
    label: impl Into<String>,
    enabled: bool,
    selected_label: impl Into<String>,
) -> ControlSemantics {
    ControlSemantics {
        id: id.into(),
        role: SemanticRole::ListBox,
        label: label.into(),
        enabled,
        checked: None,
        value: Some(selected_label.into()),
    }
}

pub fn progress(value: f32, cx: &App) -> Progress {
    Progress::new()
        .value(value)
        .bg(WrenflowTheme::current(cx).tokens.colors.accent)
}

pub fn progress_semantics(
    id: impl Into<String>,
    label: impl Into<String>,
    value: f32,
) -> ControlSemantics {
    ControlSemantics {
        id: id.into(),
        role: SemanticRole::ProgressIndicator,
        label: label.into(),
        enabled: true,
        checked: None,
        value: Some(format!("{:.0}%", value.clamp(0.0, 1.0) * 100.0)),
    }
}

#[derive(IntoElement)]
pub struct Card {
    title: Option<SharedString>,
    title_badge: Option<SharedString>,
    title_inside: bool,
    title_visible: bool,
    dense: bool,
    inline: bool,
    selection: Option<bool>,
    children: Vec<AnyElement>,
}

impl Default for Card {
    fn default() -> Self {
        Self::new()
    }
}

impl Card {
    pub fn new() -> Self {
        Self {
            title: None,
            title_badge: None,
            title_inside: false,
            title_visible: true,
            dense: false,
            inline: false,
            selection: None,
            children: Vec::new(),
        }
    }

    pub fn title(mut self, title: impl Into<SharedString>) -> Self {
        self.title = Some(title.into());
        self
    }

    pub fn title_badge(mut self, title_badge: Option<impl Into<SharedString>>) -> Self {
        self.title_badge = title_badge.map(Into::into);
        self
    }

    pub const fn title_inside(mut self, title_inside: bool) -> Self {
        self.title_inside = title_inside;
        self
    }

    pub const fn title_visible(mut self, title_visible: bool) -> Self {
        self.title_visible = title_visible;
        self
    }

    pub const fn dense(mut self, dense: bool) -> Self {
        self.dense = dense;
        self
    }

    pub const fn inline(mut self, inline: bool) -> Self {
        self.inline = inline;
        self
    }

    pub const fn selection(mut self, selection: Option<bool>) -> Self {
        self.selection = selection;
        self
    }
}

impl ParentElement for Card {
    fn extend(&mut self, elements: impl IntoIterator<Item = AnyElement>) {
        self.children.extend(elements);
    }
}

impl RenderOnce for Card {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let tokens = WrenflowTheme::current(cx).tokens;
        let selection = self.selection;
        let selected = selection == Some(true);
        let dense = self.dense;
        let inline = self.inline;
        let visible_title = self.title_visible.then_some(self.title).flatten();
        let inside_title = self.title_inside.then(|| visible_title.clone()).flatten();
        let outside_title = (!self.title_inside).then_some(visible_title).flatten();
        let title_badge = self.title_badge;
        let surface = div()
            .flex()
            .when(!inline, |this| this.flex_col())
            .when(inline, |this| this.items_center())
            .w_full()
            .min_w(px(0.0))
            .gap(if dense {
                tokens.spacing.sm
            } else {
                tokens.spacing.md
            })
            .p(tokens.spacing.lg)
            .rounded(tokens.controls.radius)
            .border(tokens.controls.border_width)
            .border_color(if selected {
                tokens.colors.selected_border
            } else {
                tokens.colors.border
            })
            .bg(if selected {
                tokens.colors.subtle_surface
            } else {
                tokens.colors.surface
            })
            .when_some(inside_title, |this, title| {
                this.child(
                    div()
                        .flex()
                        .items_center()
                        .when(inline, |this| this.flex_1().min_w(px(0.)))
                        .gap(px(10.))
                        .when_some(selection, |this, selected| {
                            this.child(if selected {
                                svg()
                                    .path("icons/circle-check.svg")
                                    .size(px(15.))
                                    .text_color(tokens.colors.accent)
                                    .into_any_element()
                            } else {
                                div()
                                    .size(px(15.))
                                    .rounded(px(15.))
                                    .border(tokens.controls.border_width)
                                    .border_color(tokens.colors.tertiary_foreground)
                                    .into_any_element()
                            })
                        })
                        .child(
                            div()
                                .flex_1()
                                .min_w(px(0.))
                                .text_size(tokens.typography.body)
                                .font_weight(FontWeight::MEDIUM)
                                .child(title),
                        )
                        .when_some(title_badge, |this, badge| {
                            this.child(
                                div()
                                    .px(tokens.spacing.sm)
                                    .py(tokens.spacing.xxs)
                                    .flex_none()
                                    .rounded(px(8.))
                                    .border(tokens.controls.border_width)
                                    .border_color(tokens.colors.border)
                                    .font_family("Menlo")
                                    .text_size(tokens.typography.meta)
                                    .text_color(tokens.colors.muted_foreground)
                                    .child(badge),
                            )
                        }),
                )
            })
            .children(self.children);
        div()
            .flex()
            .flex_col()
            .w_full()
            .min_w(px(0.0))
            .gap(tokens.spacing.xs)
            .when_some(outside_title, |this, title| {
                this.child(
                    div()
                        .pl(tokens.spacing.xs)
                        .text_size(tokens.typography.navigation)
                        .text_color(tokens.colors.muted_foreground)
                        .child(title),
                )
            })
            .child(surface)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StatusKind {
    Loading,
    Empty,
    Error,
    Success,
}

#[derive(IntoElement)]
pub struct StatusSurface {
    kind: StatusKind,
    title: SharedString,
    detail: Option<SharedString>,
    action: Option<AnyElement>,
}

impl StatusSurface {
    pub fn new(kind: StatusKind, title: impl Into<SharedString>) -> Self {
        Self {
            kind,
            title: title.into(),
            detail: None,
            action: None,
        }
    }

    pub fn detail(mut self, detail: impl Into<SharedString>) -> Self {
        self.detail = Some(detail.into());
        self
    }

    pub fn action(mut self, action: impl IntoElement) -> Self {
        self.action = Some(action.into_any_element());
        self
    }

    pub fn semantics(&self) -> ControlSemantics {
        ControlSemantics {
            id: format!("status-{:?}", self.kind).to_lowercase(),
            role: SemanticRole::Status,
            label: self.title.to_string(),
            enabled: true,
            checked: None,
            value: self.detail.as_ref().map(ToString::to_string),
        }
    }
}

impl RenderOnce for StatusSurface {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let tokens = WrenflowTheme::current(cx).tokens;
        let color = if self.kind == StatusKind::Error {
            tokens.colors.danger
        } else {
            tokens.colors.muted_foreground
        };
        div()
            .flex()
            .flex_col()
            .min_w(px(0.0))
            .items_center()
            .justify_center()
            .gap(tokens.spacing.md)
            .p(tokens.spacing.xl)
            .when(self.kind == StatusKind::Loading, |this| {
                this.child(Spinner::new())
            })
            .child(
                div()
                    .min_w(px(0.0))
                    .text_size(tokens.typography.body)
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(color)
                    .child(self.title),
            )
            .when_some(self.detail, |this, detail| {
                this.child(
                    div()
                        .min_w(px(0.0))
                        .text_size(tokens.typography.caption)
                        .text_color(tokens.colors.muted_foreground)
                        .child(detail),
                )
            })
            .when_some(self.action, |this, action| this.child(action))
    }
}

#[derive(IntoElement)]
pub struct DialogSurface {
    id: SharedString,
    title: SharedString,
    body: AnyElement,
    actions: Vec<AnyElement>,
}

impl DialogSurface {
    pub fn new(
        id: impl Into<SharedString>,
        title: impl Into<SharedString>,
        body: impl IntoElement,
    ) -> Self {
        Self {
            id: id.into(),
            title: title.into(),
            body: body.into_any_element(),
            actions: Vec::new(),
        }
    }

    pub fn action(mut self, action: impl IntoElement) -> Self {
        self.actions.push(action.into_any_element());
        self
    }

    pub fn semantics(&self) -> ControlSemantics {
        ControlSemantics {
            id: self.id.to_string(),
            role: SemanticRole::Dialog,
            label: self.title.to_string(),
            enabled: true,
            checked: None,
            value: None,
        }
    }
}

impl RenderOnce for DialogSurface {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let tokens = WrenflowTheme::current(cx).tokens;
        div()
            .id(self.id)
            .flex()
            .flex_col()
            .w_full()
            .max_w(tokens.controls.dialog_width)
            .min_w(px(0.0))
            .gap(tokens.spacing.lg)
            .p(tokens.spacing.xl)
            .rounded(tokens.controls.radius)
            .border(tokens.controls.border_width)
            .border_color(tokens.colors.border)
            .bg(tokens.colors.surface)
            .child(
                div()
                    .text_size(tokens.typography.title)
                    .font_weight(FontWeight::MEDIUM)
                    .child(self.title),
            )
            .child(self.body)
            .child(
                div()
                    .flex()
                    .flex_wrap()
                    .justify_end()
                    .gap(tokens.spacing.sm)
                    .children(self.actions),
            )
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    };

    use gpui::{div, AppContext as _, Keystroke, TestAppContext};

    use super::super::{assert_semantics, init_for_test, SemanticRole};
    use super::{
        progress_semantics, select_semantics, text_input_semantics, AccessibleButton,
        AccessibleButtonEvent, AccessibleSwitch, DialogSurface, StatusKind, StatusSurface,
    };

    #[gpui::test]
    fn keyboard_activates_switch_and_button(cx: &mut TestAppContext) {
        let switch_window = cx.update(|cx| {
            init_for_test(cx);
            let Ok(window) = cx.open_window(Default::default(), |_, cx| {
                cx.new(|cx| AccessibleSwitch::new("launch", "Launch at login", false, cx))
            }) else {
                panic!("switch test window failed to open");
            };
            window
        });

        assert!(switch_window
            .update(cx, |switch, window, _| window.focus(&switch.focus_handle))
            .is_ok());
        let Ok(space) = Keystroke::parse("space") else {
            panic!("space keystroke failed to parse");
        };
        cx.dispatch_keystroke(*switch_window, space);
        assert!(switch_window
            .update(cx, |switch, window, cx| {
                assert!(switch.checked());
                switch.sync_checked(false, cx);
                assert!(switch.focus_handle.is_focused(window));
                assert_semantics(
                    &switch.semantics(),
                    SemanticRole::Switch,
                    "Launch at login",
                    true,
                );
            })
            .is_ok());

        let presses = Arc::new(AtomicUsize::new(0));
        let observed_presses = Arc::clone(&presses);
        let button_window = cx.update(move |cx| {
            let Ok(window) = cx.open_window(Default::default(), |_, cx| {
                cx.new(|cx| AccessibleButton::new("save", "Save", cx))
            }) else {
                panic!("button test window failed to open");
            };
            let Ok(button) = window.root(cx) else {
                panic!("button test root was unavailable");
            };
            cx.subscribe(&button, move |_, event: &AccessibleButtonEvent, _| {
                if *event == AccessibleButtonEvent::Pressed {
                    observed_presses.fetch_add(1, Ordering::Relaxed);
                }
            })
            .detach();
            window
        });
        assert!(button_window
            .update(cx, |button, window, _| window.focus(&button.focus_handle))
            .is_ok());
        let Ok(enter) = Keystroke::parse("enter") else {
            panic!("enter keystroke failed to parse");
        };
        cx.dispatch_keystroke(*button_window, enter);
        assert_eq!(presses.load(Ordering::Relaxed), 1);
        assert!(button_window
            .update(cx, |button, window, cx| {
                button.set_label("Save changes", cx);
                assert!(button.focus_handle.is_focused(window));
                assert_semantics(
                    &button.semantics(),
                    SemanticRole::Button,
                    "Save changes",
                    true,
                );
            })
            .is_ok());
    }

    #[test]
    fn status_and_dialog_expose_semantics() {
        let status = StatusSurface::new(StatusKind::Error, "Download failed").detail("Offline");
        assert_eq!(status.semantics().role, SemanticRole::Status);

        let dialog = DialogSurface::new("confirm", "Delete recording?", div());
        assert_eq!(dialog.semantics().role, SemanticRole::Dialog);
    }

    #[test]
    fn input_select_and_progress_expose_semantics() {
        let input = text_input_semantics("name", "Name", true, "Wrenflow");
        assert_semantics(&input, SemanticRole::TextField, "Name", true);
        assert_eq!(input.value.as_deref(), Some("Wrenflow"));

        let select = select_semantics("model", "Model", true, "Whisper Turbo");
        assert_semantics(&select, SemanticRole::ListBox, "Model", true);
        assert_eq!(select.value.as_deref(), Some("Whisper Turbo"));

        let progress = progress_semantics("download", "Download", 0.42);
        assert_semantics(&progress, SemanticRole::ProgressIndicator, "Download", true);
        assert_eq!(progress.value.as_deref(), Some("42%"));
    }
}
