use gpui::{hsla, px, rems, App, Global, Hsla, Pixels, Rems};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ThemeMode {
    #[default]
    Light,
    Dark,
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
    pub caption: Rems,
    pub body: Rems,
    pub title: Rems,
    pub hero: Rems,
    pub body_line_height: Rems,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ControlTokens {
    pub radius: Pixels,
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
    pub border: Hsla,
    pub accent: Hsla,
    pub accent_foreground: Hsla,
    pub control_inactive: Hsla,
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
                background: hsla(220. / 360., 0.20, 0.98, 1.0),
                surface: hsla(0.0, 0.0, 1.0, 1.0),
                foreground: hsla(222. / 360., 0.35, 0.12, 1.0),
                muted_foreground: hsla(220. / 360., 0.10, 0.42, 1.0),
                border: hsla(220. / 360., 0.13, 0.86, 1.0),
                // Dark enough for 4.5:1 both as normal text on the page and
                // behind the white primary-button label.
                accent: hsla(199. / 360., 0.82, 0.37, 1.0),
                accent_foreground: hsla(0.0, 0.0, 1.0, 1.0),
                control_inactive: hsla(220. / 360., 0.10, 0.56, 1.0),
                focus_ring: hsla(0.0, 0.0, 1.0, 1.0),
                danger: hsla(2. / 360., 0.72, 0.48, 1.0),
                danger_surface: hsla(2. / 360., 0.72, 0.96, 1.0),
            },
        }
    }

    pub fn dark() -> Self {
        Self {
            spacing: spacing(),
            typography: typography(),
            controls: controls(),
            colors: ColorTokens {
                background: hsla(224. / 360., 0.28, 0.09, 1.0),
                surface: hsla(224. / 360., 0.23, 0.13, 1.0),
                foreground: hsla(210. / 360., 0.20, 0.94, 1.0),
                muted_foreground: hsla(215. / 360., 0.12, 0.66, 1.0),
                border: hsla(220. / 360., 0.13, 0.25, 1.0),
                accent: hsla(195. / 360., 0.78, 0.55, 1.0),
                accent_foreground: hsla(224. / 360., 0.28, 0.09, 1.0),
                control_inactive: hsla(220. / 360., 0.10, 0.52, 1.0),
                focus_ring: hsla(224. / 360., 0.28, 0.09, 1.0),
                danger: hsla(3. / 360., 0.78, 0.65, 1.0),
                danger_surface: hsla(2. / 360., 0.35, 0.18, 1.0),
            },
        }
    }
}

fn spacing() -> SpacingTokens {
    SpacingTokens {
        xxs: px(2.),
        xs: px(4.),
        sm: px(8.),
        md: px(12.),
        lg: px(16.),
        xl: px(24.),
        xxl: px(32.),
    }
}

fn typography() -> TypographyTokens {
    TypographyTokens {
        caption: rems(12. / 14.),
        body: rems(1.),
        title: rems(20. / 14.),
        hero: rems(2.),
        body_line_height: rems(20. / 14.),
    }
}

fn controls() -> ControlTokens {
    ControlTokens {
        radius: px(8.),
        focus_width: px(2.),
        switch_width: px(36.),
        switch_height: px(20.),
        switch_thumb: px(14.),
        sidebar_width: px(220.),
        dialog_width: px(440.),
        content_max_width: px(680.),
        compact_breakpoint: px(640.),
    }
}

#[derive(Clone, Debug)]
pub struct WrenflowTheme {
    pub mode: ThemeMode,
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
        let tokens = match mode {
            ThemeMode::Light => WrenflowTokens::light(),
            ThemeMode::Dark => WrenflowTokens::dark(),
        };
        Self { mode, tokens }
    }

    pub fn current(cx: &App) -> Self {
        cx.try_global::<Self>().cloned().unwrap_or_default()
    }
}

pub fn install_theme(cx: &mut App, mode: ThemeMode) {
    cx.set_global(WrenflowTheme::new(mode));
}

#[cfg(test)]
mod tests {
    use gpui::Hsla;

    use super::WrenflowTokens;

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
            assert!(contrast_ratio(tokens.colors.accent, tokens.colors.background) >= 4.5);
            assert!(contrast_ratio(tokens.colors.accent_foreground, tokens.colors.accent) >= 4.5);
            assert!(contrast_ratio(tokens.colors.accent_foreground, tokens.colors.danger) >= 4.5);
        }
    }

    #[test]
    fn switch_tracks_and_two_tone_focus_indicators_meet_non_text_contrast() {
        for tokens in [WrenflowTokens::light(), WrenflowTokens::dark()] {
            assert!(contrast_ratio(tokens.colors.control_inactive, tokens.colors.surface) >= 3.0);
            assert!(contrast_ratio(tokens.colors.focus_ring, tokens.colors.accent) >= 3.0);
            assert!(contrast_ratio(tokens.colors.foreground, tokens.colors.background) >= 3.0);
            assert!(contrast_ratio(tokens.colors.foreground, tokens.colors.surface) >= 3.0);
        }
    }
}
