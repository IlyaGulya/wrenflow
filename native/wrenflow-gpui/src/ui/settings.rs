use std::collections::BTreeSet;

use gpui::{
    div, prelude::FluentBuilder as _, AnyElement, App, ElementId, InteractiveElement as _,
    IntoElement, ParentElement as _, RenderOnce, SharedString, Styled as _, Window,
};
use gpui_component::scroll::ScrollableElement as _;

use super::{ControlSemantics, SemanticRole, WrenflowTheme};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChoiceOption {
    pub id: String,
    pub label: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SettingControlSpec {
    Switch {
        checked: bool,
    },
    Text {
        value: String,
        placeholder: String,
    },
    Choice {
        selected: String,
        options: Vec<ChoiceOption>,
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SettingRowSpec {
    pub id: String,
    pub title: String,
    pub description: Option<String>,
    pub control: SettingControlSpec,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SettingsSectionSpec {
    pub id: String,
    pub title: String,
    pub rows: Vec<SettingRowSpec>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SettingsPageSpec {
    pub id: String,
    pub title: String,
    pub sections: Vec<SettingsSectionSpec>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SettingsSchema {
    pub pages: Vec<SettingsPageSpec>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SettingsSchemaError {
    DuplicatePageId(String),
    DuplicateSettingId(String),
    EmptyChoice(String),
    DuplicateChoiceId { setting: String, option: String },
    UnknownChoice { setting: String, selected: String },
}

impl SettingsSchema {
    pub fn validate(&self) -> Result<(), SettingsSchemaError> {
        let mut page_ids = BTreeSet::new();
        let mut setting_ids = BTreeSet::new();

        for page in &self.pages {
            if !page_ids.insert(page.id.clone()) {
                return Err(SettingsSchemaError::DuplicatePageId(page.id.clone()));
            }

            for section in &page.sections {
                for row in &section.rows {
                    if !setting_ids.insert(row.id.clone()) {
                        return Err(SettingsSchemaError::DuplicateSettingId(row.id.clone()));
                    }

                    if let SettingControlSpec::Choice { selected, options } = &row.control {
                        if options.is_empty() {
                            return Err(SettingsSchemaError::EmptyChoice(row.id.clone()));
                        }

                        let mut option_ids = BTreeSet::new();
                        for option in options {
                            if !option_ids.insert(option.id.clone()) {
                                return Err(SettingsSchemaError::DuplicateChoiceId {
                                    setting: row.id.clone(),
                                    option: option.id.clone(),
                                });
                            }
                        }

                        if !option_ids.contains(selected) {
                            return Err(SettingsSchemaError::UnknownChoice {
                                setting: row.id.clone(),
                                selected: selected.clone(),
                            });
                        }
                    }
                }
            }
        }

        Ok(())
    }
}

/// Settings label/description paired with an arbitrary Wrenflow control.
#[derive(IntoElement)]
pub struct SettingRow {
    id: ElementId,
    title: SharedString,
    description: Option<SharedString>,
    control: AnyElement,
}

impl SettingRow {
    pub fn new(
        id: impl Into<ElementId>,
        title: impl Into<SharedString>,
        control: impl IntoElement,
    ) -> Self {
        Self {
            id: id.into(),
            title: title.into(),
            description: None,
            control: control.into_any_element(),
        }
    }

    pub fn description(mut self, description: impl Into<SharedString>) -> Self {
        self.description = Some(description.into());
        self
    }
}

impl RenderOnce for SettingRow {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let tokens = WrenflowTheme::current(cx).tokens;
        div()
            .id(self.id)
            .flex()
            .flex_wrap()
            .items_start()
            .justify_between()
            .gap(tokens.spacing.lg)
            .py(tokens.spacing.md)
            .border_b_1()
            .border_color(tokens.colors.border)
            .child(
                div()
                    .flex()
                    .flex_col()
                    .flex_1()
                    .min_w(tokens.controls.sidebar_width)
                    .gap(tokens.spacing.xs)
                    .child(self.title)
                    .when_some(self.description, |this, description| {
                        this.child(
                            div()
                                .text_size(tokens.typography.caption)
                                .text_color(tokens.colors.muted_foreground)
                                .child(description),
                        )
                    }),
            )
            .child(self.control)
    }
}

#[derive(IntoElement)]
pub struct SettingsSection {
    title: SharedString,
    rows: Vec<SettingRow>,
}

impl SettingsSection {
    pub fn new(title: impl Into<SharedString>) -> Self {
        Self {
            title: title.into(),
            rows: Vec::new(),
        }
    }

    pub fn row(mut self, row: SettingRow) -> Self {
        self.rows.push(row);
        self
    }

    pub fn rows(mut self, rows: impl IntoIterator<Item = SettingRow>) -> Self {
        self.rows.extend(rows);
        self
    }
}

impl RenderOnce for SettingsSection {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let tokens = WrenflowTheme::current(cx).tokens;
        div()
            .flex()
            .flex_col()
            .gap(tokens.spacing.sm)
            .child(
                div()
                    .text_size(tokens.typography.caption)
                    .text_color(tokens.colors.muted_foreground)
                    .child(self.title),
            )
            .children(self.rows)
    }
}

/// Navigation items remain Wrenflow-owned measured elements, so the sidebar can
/// preserve their exact layout while publishing accessibility geometry.
#[derive(IntoElement)]
pub struct NavigationSidebar {
    id: SharedString,
    title: SharedString,
    items: Vec<AnyElement>,
    compact: bool,
}

impl NavigationSidebar {
    pub fn new(id: impl Into<SharedString>, title: impl Into<SharedString>) -> Self {
        Self {
            id: id.into(),
            title: title.into(),
            items: Vec::new(),
            compact: false,
        }
    }

    pub fn item(mut self, item: impl IntoElement) -> Self {
        self.items.push(item.into_any_element());
        self
    }

    pub fn items(mut self, items: impl IntoIterator<Item = impl IntoElement>) -> Self {
        self.items
            .extend(items.into_iter().map(IntoElement::into_any_element));
        self
    }

    pub const fn compact(mut self, compact: bool) -> Self {
        self.compact = compact;
        self
    }

    pub fn semantics(&self) -> ControlSemantics {
        ControlSemantics {
            id: self.id.to_string(),
            role: SemanticRole::Navigation,
            label: self.title.to_string(),
            enabled: true,
            checked: None,
            value: Some(format!("{} items", self.items.len())),
        }
    }
}

impl RenderOnce for NavigationSidebar {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let tokens = WrenflowTheme::current(cx).tokens;
        div()
            .id(self.id)
            .flex()
            .when(!self.compact, |this| {
                this.flex_col()
                    .w(tokens.controls.sidebar_width)
                    .h_full()
                    .border_r_1()
            })
            .when(self.compact, |this| {
                this.w_full().flex_wrap().items_center().border_b_1()
            })
            .gap(tokens.spacing.sm)
            .p(tokens.spacing.md)
            .border_color(tokens.colors.border)
            .bg(tokens.colors.surface)
            .child(
                div()
                    .text_size(tokens.typography.title)
                    .when(self.compact, |this| this.w_full())
                    .child(self.title),
            )
            .children(self.items)
    }
}

#[derive(IntoElement)]
pub struct SettingsSurface {
    id: ElementId,
    title: SharedString,
    navigation: Option<AnyElement>,
    sections: Vec<SettingsSection>,
}

impl SettingsSurface {
    pub fn new(id: impl Into<ElementId>, title: impl Into<SharedString>) -> Self {
        Self {
            id: id.into(),
            title: title.into(),
            navigation: None,
            sections: Vec::new(),
        }
    }

    pub fn navigation(mut self, navigation: impl IntoElement) -> Self {
        self.navigation = Some(navigation.into_any_element());
        self
    }

    pub fn section(mut self, section: SettingsSection) -> Self {
        self.sections.push(section);
        self
    }

    pub fn sections(mut self, sections: impl IntoIterator<Item = SettingsSection>) -> Self {
        self.sections.extend(sections);
        self
    }
}

impl RenderOnce for SettingsSurface {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let tokens = WrenflowTheme::current(cx).tokens;
        div()
            .id(self.id)
            .flex()
            .size_full()
            .bg(tokens.colors.background)
            .text_color(tokens.colors.foreground)
            .when_some(self.navigation, |this, navigation| this.child(navigation))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .flex_1()
                    .h_full()
                    .child(
                        div()
                            .p(tokens.spacing.lg)
                            .text_size(tokens.typography.title)
                            .border_b_1()
                            .border_color(tokens.colors.border)
                            .child(self.title),
                    )
                    .child(
                        div()
                            .id("settings-scroll")
                            .flex()
                            .flex_col()
                            .flex_1()
                            .gap(tokens.spacing.xl)
                            .p(tokens.spacing.lg)
                            .children(self.sections)
                            .overflow_y_scrollbar(),
                    ),
            )
    }
}

#[cfg(test)]
mod tests {
    use super::{
        ChoiceOption, SettingControlSpec, SettingRowSpec, SettingsPageSpec, SettingsSchema,
        SettingsSchemaError, SettingsSectionSpec,
    };

    fn valid_schema() -> SettingsSchema {
        SettingsSchema {
            pages: vec![SettingsPageSpec {
                id: "general".into(),
                title: "General".into(),
                sections: vec![SettingsSectionSpec {
                    id: "recognition".into(),
                    title: "Recognition".into(),
                    rows: vec![SettingRowSpec {
                        id: "model".into(),
                        title: "Model".into(),
                        description: None,
                        control: SettingControlSpec::Choice {
                            selected: "turbo".into(),
                            options: vec![ChoiceOption {
                                id: "turbo".into(),
                                label: "Whisper Turbo".into(),
                            }],
                        },
                    }],
                }],
            }],
        }
    }

    #[test]
    fn validates_a_settings_contract() {
        assert_eq!(valid_schema().validate(), Ok(()));
    }

    #[test]
    fn rejects_unknown_selected_choice() {
        let mut schema = valid_schema();
        let SettingControlSpec::Choice { selected, .. } =
            &mut schema.pages[0].sections[0].rows[0].control
        else {
            unreachable!();
        };
        *selected = "missing".into();
        assert_eq!(
            schema.validate(),
            Err(SettingsSchemaError::UnknownChoice {
                setting: "model".into(),
                selected: "missing".into(),
            })
        );
    }

    #[test]
    fn rejects_duplicate_setting_ids_across_pages() {
        let mut schema = valid_schema();
        schema.pages.push(schema.pages[0].clone());
        schema.pages[1].id = "models".into();
        assert_eq!(
            schema.validate(),
            Err(SettingsSchemaError::DuplicateSettingId("model".into()))
        );
    }
}
