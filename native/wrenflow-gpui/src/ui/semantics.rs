/// Platform-neutral roles retained even though GPUI 0.2.2 has no public
/// accessibility-tree API.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SemanticRole {
    Button,
    Switch,
    TextField,
    ListBox,
    ProgressIndicator,
    Dialog,
    Navigation,
    Status,
}

/// Testable semantic snapshot. The AppKit shell can translate this into
/// NSAccessibility roles and values once the platform bridge is implemented.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ControlSemantics {
    pub id: String,
    pub role: SemanticRole,
    pub label: String,
    pub enabled: bool,
    pub checked: Option<bool>,
    pub value: Option<String>,
}
