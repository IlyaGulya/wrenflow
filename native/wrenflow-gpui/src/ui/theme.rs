use gpui::{px, rems, rgb, rgba, App, Global, Hsla, Pixels, Rems, Window, WindowAppearance};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ThemeMode {
    #[default]
    Light,
    Dark,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ThemeSelection {
    #[default]
    System,
    Light,
    Dark,
}

impl ThemeSelection {
    const fn effective_mode(self, system_mode: ThemeMode) -> ThemeMode {
        match self {
            Self::System => system_mode,
            Self::Light => ThemeMode::Light,
            Self::Dark => ThemeMode::Dark,
        }
    }
}

impl ThemeMode {
    #[must_use]
    pub const fn for_window_appearance(appearance: WindowAppearance) -> Self {
        match appearance {
            WindowAppearance::Dark | WindowAppearance::VibrantDark => Self::Dark,
            WindowAppearance::Light | WindowAppearance::VibrantLight => Self::Light,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AccessibilityPreferences {
    pub increase_contrast: bool,
    pub differentiate_without_color: bool,
    pub reduce_motion: bool,
    pub reduce_transparency: bool,
    pub text_scale_percent: u16,
}

impl Default for AccessibilityPreferences {
    fn default() -> Self {
        Self {
            increase_contrast: false,
            differentiate_without_color: false,
            reduce_motion: false,
            reduce_transparency: false,
            text_scale_percent: 100,
        }
    }
}

impl AccessibilityPreferences {
    #[must_use]
    pub fn text_scale(self) -> f32 {
        f32::from(self.text_scale_percent.clamp(100, 200)) / 100.0
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SpacingTokens {
    pub xxs: Pixels,
    pub xs: Pixels,
    pub sm: Pixels,
    pub md: Pixels,
    pub lg: Pixels,
    pub xl: Pixels,
    pub xxl: Pixels,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TypographyTokens {
    pub meta: Rems,
    pub caption: Rems,
    pub body: Rems,
    pub navigation: Rems,
    pub title: Rems,
    pub hero: Rems,
    pub body_line_height: Rems,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ControlTokens {
    pub small_radius: Pixels,
    pub radius: Pixels,
    pub large_radius: Pixels,
    pub button_radius: Pixels,
    pub border_width: Pixels,
    pub focus_width: Pixels,
    pub switch_width: Pixels,
    pub switch_height: Pixels,
    pub switch_thumb: Pixels,
    pub sidebar_width: Pixels,
    pub dialog_width: Pixels,
    pub content_max_width: Pixels,
    pub compact_breakpoint: Pixels,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ColorTokens {
    pub background: Hsla,
    pub surface: Hsla,
    pub foreground: Hsla,
    pub muted_foreground: Hsla,
    pub tertiary_foreground: Hsla,
    pub border: Hsla,
    pub selected_border: Hsla,
    pub accent: Hsla,
    pub accent_foreground: Hsla,
    pub success_foreground: Hsla,
    pub control_inactive: Hsla,
    pub subtle_surface: Hsla,
    pub selected_surface: Hsla,
    pub button_surface: Hsla,
    pub track_background: Hsla,
    pub track_fill: Hsla,
    pub focus_ring: Hsla,
    pub danger: Hsla,
    pub danger_surface: Hsla,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct WrenflowTokens {
    pub spacing: SpacingTokens,
    pub typography: TypographyTokens,
    pub controls: ControlTokens,
    pub colors: ColorTokens,
}

impl WrenflowTokens {
    pub fn light() -> Self {
        Self {
            spacing: spacing(),
            typography: typography(),
            controls: controls(),
            colors: ColorTokens {
                // Exact Flutter baseline roles from WrenflowStyle.
                background: rgb(0xf5f5f5).into(),
                surface: rgb(0xfcfcfc).into(),
                foreground: rgb(0x262626).into(),
                // Flutter used #737373 and #999999. The closest neutral that
                // keeps 12 px captions and 10 px metadata at 4.5:1 on the
                // baseline background is #707070.
                muted_foreground: rgb(0x707070).into(),
                tertiary_foreground: rgb(0x707070).into(),
                border: rgba(0x00000014).into(),
                selected_border: rgba(0x26262626).into(),
                // Flutter's #33B366 misses 3:1 against its own surface. This
                // minimally darker adaptation preserves the hue and reaches
                // the non-text control boundary gate.
                accent: rgb(0x30a65f).into(),
                accent_foreground: rgb(0xfcfcfc).into(),
                success_foreground: rgb(0x247a47).into(),
                control_inactive: rgba(0x26262626).into(),
                subtle_surface: rgba(0x2626260d).into(),
                selected_surface: rgba(0x26262612).into(),
                button_surface: rgba(0x2626260f).into(),
                track_background: rgba(0x26262614).into(),
                track_fill: rgba(0x26262659).into(),
                focus_ring: rgba(0x262626b3).into(),
                danger: rgb(0xd94033).into(),
                danger_surface: rgba(0xd9403314).into(),
            },
        }
    }

    pub fn dark() -> Self {
        Self {
            spacing: spacing(),
            typography: typography(),
            controls: controls(),
            colors: ColorTokens {
                background: rgb(0x191a1c).into(),
                surface: rgb(0x222326).into(),
                foreground: rgb(0xe8e9eb).into(),
                muted_foreground: rgb(0xaaaeb4).into(),
                tertiary_foreground: rgb(0x858a91).into(),
                border: rgba(0xffffff24).into(),
                selected_border: rgba(0xffffff3d).into(),
                accent: rgb(0x45c879).into(),
                accent_foreground: rgb(0x151816).into(),
                success_foreground: rgb(0x69d994).into(),
                control_inactive: rgba(0xffffff33).into(),
                subtle_surface: rgba(0xffffff0d).into(),
                selected_surface: rgba(0xffffff14).into(),
                button_surface: rgba(0xffffff17).into(),
                track_background: rgba(0xffffff1f).into(),
                track_fill: rgba(0xffffff70).into(),
                focus_ring: rgba(0xffffffcc).into(),
                danger: rgb(0xff756a).into(),
                danger_surface: rgba(0xff756a1f).into(),
            },
        }
    }

    #[must_use]
    pub fn adapted(mut self, preferences: AccessibilityPreferences) -> Self {
        let text_scale = preferences.text_scale();
        self.typography.meta.0 *= text_scale;
        self.typography.caption.0 *= text_scale;
        self.typography.body.0 *= text_scale;
        self.typography.navigation.0 *= text_scale;
        self.typography.title.0 *= text_scale;
        self.typography.hero.0 *= text_scale;
        self.typography.body_line_height.0 *= text_scale;
        if preferences.increase_contrast {
            match self.colors.background == WrenflowTokens::light().colors.background {
                true => {
                    self.colors.muted_foreground = rgb(0x595959).into();
                    self.colors.tertiary_foreground = rgb(0x595959).into();
                    self.colors.border = rgba(0x0000004d).into();
                    self.colors.selected_border = rgba(0x00000080).into();
                    self.colors.control_inactive = rgba(0x2626264d).into();
                    self.colors.selected_surface = rgba(0x2626261f).into();
                    self.colors.track_background = rgba(0x26262633).into();
                }
                false => {
                    self.colors.muted_foreground = rgb(0xc2c5ca).into();
                    self.colors.tertiary_foreground = rgb(0xc2c5ca).into();
                    self.colors.border = rgba(0xffffff59).into();
                    self.colors.selected_border = rgba(0xffffff8c).into();
                    self.colors.control_inactive = rgba(0xffffff59).into();
                    self.colors.selected_surface = rgba(0xffffff29).into();
                    self.colors.track_background = rgba(0xffffff3d).into();
                }
            }
        }
        if preferences.differentiate_without_color {
            // Selected rows already retain a checkmark or navigation icon. A
            // stronger outline makes that non-color distinction visible even
            // when accent hues cannot be distinguished.
            self.colors.selected_border = self.colors.foreground.opacity(0.55);
        }
        if preferences.reduce_transparency {
            // Wrenflow never uses blur materials. Keep all semantic surfaces
            // fully opaque and let only borders/indicators retain alpha.
            self.colors.subtle_surface = self.colors.surface;
            self.colors.selected_surface = self.colors.surface;
            self.colors.button_surface = self.colors.surface;
            self.colors.danger_surface = self.colors.surface;
        }
        self
    }
}

fn spacing() -> SpacingTokens {
    SpacingTokens {
        xxs: px(2.),
        xs: px(4.),
        sm: px(6.),
        md: px(8.),
        lg: px(12.),
        xl: px(16.),
        xxl: px(24.),
    }
}

fn typography() -> TypographyTokens {
    TypographyTokens {
        meta: rems(10. / 14.),
        caption: rems(11. / 14.),
        body: rems(12. / 14.),
        navigation: rems(13. / 14.),
        title: rems(16. / 14.),
        hero: rems(16. / 14.),
        body_line_height: rems(16. / 14.),
    }
}

fn controls() -> ControlTokens {
    ControlTokens {
        small_radius: px(5.),
        radius: px(8.),
        large_radius: px(12.),
        button_radius: px(6.),
        border_width: px(1.),
        focus_width: px(2.),
        switch_width: px(36.),
        switch_height: px(20.),
        switch_thumb: px(16.),
        sidebar_width: px(150.),
        dialog_width: px(440.),
        content_max_width: px(520.),
        compact_breakpoint: px(620.),
    }
}

#[derive(Clone, Debug)]
pub struct WrenflowTheme {
    pub selection: ThemeSelection,
    pub mode: ThemeMode,
    pub accessibility: AccessibilityPreferences,
    pub tokens: WrenflowTokens,
}

impl Global for WrenflowTheme {}

impl Default for WrenflowTheme {
    fn default() -> Self {
        Self::new(ThemeMode::Light)
    }
}

impl WrenflowTheme {
    pub fn new(mode: ThemeMode) -> Self {
        Self::with_accessibility(mode, AccessibilityPreferences::default())
    }

    pub fn with_accessibility(mode: ThemeMode, accessibility: AccessibilityPreferences) -> Self {
        Self::with_selection(ThemeSelection::System, mode, accessibility)
    }

    pub fn with_selection(
        selection: ThemeSelection,
        system_mode: ThemeMode,
        accessibility: AccessibilityPreferences,
    ) -> Self {
        let mode = selection.effective_mode(system_mode);
        let tokens = match mode {
            ThemeMode::Light => WrenflowTokens::light(),
            ThemeMode::Dark => WrenflowTokens::dark(),
        }
        .adapted(accessibility);
        Self {
            selection,
            mode,
            accessibility,
            tokens,
        }
    }

    pub fn current(cx: &App) -> Self {
        cx.try_global::<Self>().cloned().unwrap_or_default()
    }
}

pub fn install_theme(cx: &mut App, mode: ThemeMode) {
    let current = WrenflowTheme::current(cx);
    cx.set_global(WrenflowTheme::with_selection(
        current.selection,
        mode,
        current.accessibility,
    ));
}

pub fn install_theme_selection(cx: &mut App, selection: ThemeSelection, system_mode: ThemeMode) {
    let accessibility = WrenflowTheme::current(cx).accessibility;
    cx.set_global(WrenflowTheme::with_selection(
        selection,
        system_mode,
        accessibility,
    ));
}

pub fn install_accessibility_preferences(cx: &mut App, accessibility: AccessibilityPreferences) {
    let current = WrenflowTheme::current(cx);
    cx.set_global(WrenflowTheme::with_selection(
        current.selection,
        current.mode,
        accessibility,
    ));
}

pub fn synchronize_window_theme(window: &mut Window, cx: &mut App) {
    install_theme(cx, ThemeMode::for_window_appearance(window.appearance()));
    window.refresh();
}

#[cfg(test)]
mod tests {
    use gpui::Hsla;

    use gpui::WindowAppearance;

    use super::{
        AccessibilityPreferences, ThemeMode, ThemeSelection, WrenflowTheme, WrenflowTokens,
    };

    fn relative_luminance(color: Hsla) -> f32 {
        let chroma = (1.0 - (2.0 * color.l - 1.0).abs()) * color.s;
        let hue = color.h * 6.0;
        let x = chroma * (1.0 - (hue.rem_euclid(2.0) - 1.0).abs());
        let (red, green, blue) = match hue as u8 {
            0 => (chroma, x, 0.0),
            1 => (x, chroma, 0.0),
            2 => (0.0, chroma, x),
            3 => (0.0, x, chroma),
            4 => (x, 0.0, chroma),
            _ => (chroma, 0.0, x),
        };
        let offset = color.l - chroma / 2.0;
        let linear = |channel: f32| {
            let channel = channel + offset;
            if channel <= 0.040_45 {
                channel / 12.92
            } else {
                ((channel + 0.055) / 1.055).powf(2.4)
            }
        };
        0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    fn contrast_ratio(first: Hsla, second: Hsla) -> f32 {
        let first = relative_luminance(first);
        let second = relative_luminance(second);
        (first.max(second) + 0.05) / (first.min(second) + 0.05)
    }

    #[test]
    fn themes_share_layout_and_typography_tokens() {
        let light = WrenflowTokens::light();
        let dark = WrenflowTokens::dark();
        assert_eq!(light.spacing, dark.spacing);
        assert_eq!(light.typography, dark.typography);
        assert_eq!(light.controls, dark.controls);
        assert_ne!(light.colors.background, dark.colors.background);
    }

    #[test]
    fn normal_text_colors_meet_wcag_aa_in_both_themes() {
        for tokens in [WrenflowTokens::light(), WrenflowTokens::dark()] {
            assert!(contrast_ratio(tokens.colors.foreground, tokens.colors.background) >= 4.5);
            assert!(
                contrast_ratio(tokens.colors.muted_foreground, tokens.colors.background) >= 4.5
            );
            assert!(
                contrast_ratio(tokens.colors.tertiary_foreground, tokens.colors.background) >= 3.0
            );
            assert!(
                contrast_ratio(tokens.colors.success_foreground, tokens.colors.background) >= 4.5
            );
        }
    }

    #[test]
    fn switch_tracks_and_two_tone_focus_indicators_meet_non_text_contrast() {
        for tokens in [WrenflowTokens::light(), WrenflowTokens::dark()] {
            assert!(contrast_ratio(tokens.colors.accent, tokens.colors.surface) >= 3.0);
            assert!(contrast_ratio(tokens.colors.foreground, tokens.colors.background) >= 3.0);
            assert!(contrast_ratio(tokens.colors.foreground, tokens.colors.surface) >= 3.0);
        }
    }

    #[test]
    fn light_theme_matches_the_flutter_source_roles_and_geometry() {
        let tokens = WrenflowTokens::light();
        assert_eq!(tokens.colors.background, gpui::rgb(0xf5f5f5).into());
        assert_eq!(tokens.colors.surface, gpui::rgb(0xfcfcfc).into());
        assert_eq!(tokens.colors.foreground, gpui::rgb(0x262626).into());
        assert_eq!(tokens.colors.accent, gpui::rgb(0x30a65f).into());
        assert_eq!(tokens.controls.sidebar_width, gpui::px(150.));
        assert_eq!(tokens.controls.switch_width, gpui::px(36.));
        assert_eq!(tokens.controls.switch_height, gpui::px(20.));
        assert_eq!(tokens.controls.switch_thumb, gpui::px(16.));
        assert_eq!(tokens.controls.radius, gpui::px(8.));
    }

    #[test]
    fn window_appearance_selects_the_live_semantic_palette() {
        assert_eq!(
            ThemeMode::for_window_appearance(WindowAppearance::Light),
            ThemeMode::Light
        );
        assert_eq!(
            ThemeMode::for_window_appearance(WindowAppearance::VibrantDark),
            ThemeMode::Dark
        );
    }

    #[test]
    fn local_theme_override_ignores_system_changes_until_system_is_reselected() {
        let forced_light = WrenflowTheme::with_selection(
            ThemeSelection::Light,
            ThemeMode::Dark,
            AccessibilityPreferences::default(),
        );
        assert_eq!(forced_light.mode, ThemeMode::Light);
        let forced_dark = WrenflowTheme::with_selection(
            ThemeSelection::Dark,
            ThemeMode::Light,
            AccessibilityPreferences::default(),
        );
        assert_eq!(forced_dark.mode, ThemeMode::Dark);
        let system = WrenflowTheme::with_selection(
            ThemeSelection::System,
            ThemeMode::Dark,
            AccessibilityPreferences::default(),
        );
        assert_eq!(system.mode, ThemeMode::Dark);
    }

    #[test]
    fn accessibility_preferences_preserve_geometry_and_strengthen_non_color_cues() {
        let baseline = WrenflowTokens::light();
        let adapted = baseline.adapted(AccessibilityPreferences {
            increase_contrast: true,
            differentiate_without_color: true,
            reduce_motion: true,
            reduce_transparency: true,
            text_scale_percent: 100,
        });
        assert_eq!(adapted.spacing, baseline.spacing);
        assert_eq!(adapted.typography, baseline.typography);
        assert_eq!(adapted.controls, baseline.controls);
        assert_eq!(adapted.colors.surface, adapted.colors.selected_surface);
        assert!(contrast_ratio(adapted.colors.selected_border, adapted.colors.background) >= 3.0);
    }

    #[test]
    fn live_text_scale_changes_typography_without_mutating_control_geometry() {
        let baseline = WrenflowTokens::light();
        let scaled = baseline.adapted(AccessibilityPreferences {
            text_scale_percent: 150,
            ..AccessibilityPreferences::default()
        });
        assert_eq!(scaled.controls, baseline.controls);
        assert_eq!(scaled.spacing, baseline.spacing);
        assert!((scaled.typography.body.0 / baseline.typography.body.0 - 1.5).abs() < 0.001);
        assert!((scaled.typography.title.0 / baseline.typography.title.0 - 1.5).abs() < 0.001);
    }
}
