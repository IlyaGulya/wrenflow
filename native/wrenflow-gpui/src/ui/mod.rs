//! Wrenflow-owned design system for the GPUI application.
//!
//! Keep direct dependencies on unstable GPUI/component APIs inside this module.

mod accessibility;
mod assets;
mod controls;
mod semantics;
mod settings;
mod theme;

pub use accessibility::{
    AccessibilityAction, AccessibilityAnnouncement, AccessibilityCoordinateSpace,
    AccessibilityFrame, AccessibilityNode, AccessibilityPriority, AccessibilityRole,
    AccessibilitySnapshot, MeasuredElement,
};
pub use assets::{asset_paths, WrenflowAssets};
pub use controls::{
    init_control_keybindings, progress, progress_semantics, select, select_semantics, text_input,
    text_input_semantics, AccessibleButton, AccessibleButtonEvent, AccessibleSwitch,
    AccessibleSwitchEvent, ButtonStyle, Card, DialogSurface, StatusKind, StatusSurface,
};
pub use semantics::{ControlSemantics, SemanticRole};
pub use settings::{
    ChoiceOption, NavigationSidebar, SettingControlSpec, SettingRow, SettingRowSpec,
    SettingsPageSpec, SettingsSchema, SettingsSchemaError, SettingsSection, SettingsSectionSpec,
    SettingsSurface,
};
pub use theme::{
    install_theme, ColorTokens, ControlTokens, SpacingTokens, ThemeMode, TypographyTokens,
    WrenflowTheme, WrenflowTokens,
};

use gpui::App;

/// Install all Wrenflow-owned UI globals and keyboard actions.
pub fn init(cx: &mut App, mode: ThemeMode) {
    install_theme(cx, mode);
    init_control_keybindings(cx);
}

/// Minimal helper shared by GPUI interaction tests in future screen modules.
pub fn init_for_test(cx: &mut App) {
    init(cx, ThemeMode::Light);
}

#[cfg(test)]
pub fn assert_semantics(actual: &ControlSemantics, role: SemanticRole, label: &str, enabled: bool) {
    assert_eq!(actual.role, role);
    assert_eq!(actual.label, label);
    assert_eq!(actual.enabled, enabled);
}
