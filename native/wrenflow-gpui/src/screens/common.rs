use crate::app::{AppAction, NavigationTarget};
use crate::ui::{ButtonStyle, StatusKind};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScreenLayout {
    Centered,
    Application,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TextTone {
    Normal,
    Muted,
    Success,
    Danger,
    Monospace,
}

#[derive(Clone, Debug, PartialEq)]
pub enum ScreenIntent {
    Dispatch(AppAction),
    ShowClearHistoryConfirmation,
    DismissClearHistoryConfirmation,
    ConfirmClearHistory,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ActionPlan {
    pub id: String,
    pub label: String,
    pub style: ButtonStyle,
    pub enabled: bool,
    pub intent: ScreenIntent,
}

impl ActionPlan {
    pub fn intent(id: impl Into<String>, label: impl Into<String>, intent: ScreenIntent) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
            style: ButtonStyle::Secondary,
            enabled: true,
            intent,
        }
    }

    pub fn dispatch(id: impl Into<String>, label: impl Into<String>, action: AppAction) -> Self {
        Self::intent(id, label, ScreenIntent::Dispatch(action))
    }

    pub const fn primary(mut self) -> Self {
        self.style = ButtonStyle::Primary;
        self
    }

    pub const fn danger(mut self) -> Self {
        self.style = ButtonStyle::Danger;
        self
    }

    pub const fn enabled(mut self, enabled: bool) -> Self {
        self.enabled = enabled;
        self
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InputKind {
    Hotkey,
    Vocabulary,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ToggleKind {
    SoundEnabled,
    LaunchAtLogin,
}

#[derive(Clone, Debug, PartialEq)]
pub enum ControlPlan {
    Actions(Vec<ActionPlan>),
    Toggle {
        id: String,
        label: String,
        checked: bool,
        enabled: bool,
        kind: ToggleKind,
    },
    Input {
        kind: InputKind,
        id: String,
        label: String,
        value: String,
        hint: String,
        enabled: bool,
    },
    Progress {
        id: String,
        label: String,
        value: f32,
        detail: Option<String>,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub struct TextPlan {
    pub label: Option<String>,
    pub value: String,
    pub tone: TextTone,
}

impl TextPlan {
    pub fn body(value: impl Into<String>) -> Self {
        Self {
            label: None,
            value: value.into(),
            tone: TextTone::Normal,
        }
    }

    pub fn muted(value: impl Into<String>) -> Self {
        Self {
            label: None,
            value: value.into(),
            tone: TextTone::Muted,
        }
    }

    pub fn pair(label: impl Into<String>, value: impl Into<String>) -> Self {
        Self {
            label: Some(label.into()),
            value: value.into(),
            tone: TextTone::Normal,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct CardPlan {
    pub id: String,
    pub title: String,
    pub lines: Vec<TextPlan>,
    pub controls: Vec<ControlPlan>,
}

impl CardPlan {
    pub fn new(id: impl Into<String>, title: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            title: title.into(),
            lines: Vec::new(),
            controls: Vec::new(),
        }
    }

    pub fn line(mut self, line: TextPlan) -> Self {
        self.lines.push(line);
        self
    }

    pub fn control(mut self, control: ControlPlan) -> Self {
        self.controls.push(control);
        self
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum BlockPlan {
    Card(CardPlan),
    Status {
        kind: StatusKind,
        title: String,
        detail: Option<String>,
        action: Option<ActionPlan>,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub struct SectionPlan {
    pub title: Option<String>,
    pub blocks: Vec<BlockPlan>,
}

impl SectionPlan {
    pub fn new(title: impl Into<String>, blocks: Vec<BlockPlan>) -> Self {
        Self {
            title: Some(title.into()),
            blocks,
        }
    }

    pub fn untitled(blocks: Vec<BlockPlan>) -> Self {
        Self {
            title: None,
            blocks,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ScreenPlan {
    pub layout: ScreenLayout,
    pub route: NavigationTarget,
    pub title: String,
    pub subtitle: Option<String>,
    pub sections: Vec<SectionPlan>,
    pub footer_actions: Vec<ActionPlan>,
    pub confirm_clear_history: bool,
}

impl ScreenPlan {
    pub fn application(route: NavigationTarget, title: impl Into<String>) -> Self {
        Self {
            layout: ScreenLayout::Application,
            route,
            title: title.into(),
            subtitle: None,
            sections: Vec::new(),
            footer_actions: Vec::new(),
            confirm_clear_history: false,
        }
    }

    pub fn centered(route: NavigationTarget, title: impl Into<String>) -> Self {
        Self {
            layout: ScreenLayout::Centered,
            route,
            title: title.into(),
            subtitle: None,
            sections: Vec::new(),
            footer_actions: Vec::new(),
            confirm_clear_history: false,
        }
    }
}
