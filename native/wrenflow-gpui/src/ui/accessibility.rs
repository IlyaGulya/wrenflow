use gpui::{
    AnyElement, App, Bounds, Element, ElementId, GlobalElementId, InspectorElementId, IntoElement,
    LayoutId, Pixels, Window,
};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AccessibilityCoordinateSpace {
    WindowContentTopLeft,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AccessibilityRole {
    Window,
    Group,
    Heading,
    StaticText,
    Navigation,
    Button,
    Switch,
    TextField,
    ProgressIndicator,
    Dialog,
    Status,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AccessibilityAction {
    Press,
    Focus,
    Increment,
    Decrement,
    SetValue,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AccessibilityPriority {
    Low,
    Medium,
    High,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AccessibilityFrame {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

impl From<Bounds<Pixels>> for AccessibilityFrame {
    fn from(bounds: Bounds<Pixels>) -> Self {
        Self {
            x: f32::from(bounds.origin.x),
            y: f32::from(bounds.origin.y),
            width: f32::from(bounds.size.width),
            height: f32::from(bounds.size.height),
        }
    }
}

impl AccessibilityFrame {
    #[must_use]
    pub fn intersection(self, other: Self) -> Option<Self> {
        let left = self.x.max(other.x);
        let top = self.y.max(other.y);
        let right = (self.x + self.width).min(other.x + other.width);
        let bottom = (self.y + self.height).min(other.y + other.height);
        (right > left && bottom > top).then_some(Self {
            x: left,
            y: top,
            width: right - left,
            height: bottom - top,
        })
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AccessibilityNode {
    pub id: String,
    pub parent_id: Option<String>,
    pub role: AccessibilityRole,
    pub label: String,
    pub value: Option<String>,
    pub enabled: bool,
    pub focused: bool,
    pub actions: Vec<AccessibilityAction>,
    pub frame: AccessibilityFrame,
    pub order: u32,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AccessibilityAnnouncement {
    pub serial: u64,
    pub message: String,
    pub priority: AccessibilityPriority,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AccessibilitySnapshot {
    pub generation: u64,
    pub coordinate_space: AccessibilityCoordinateSpace,
    pub nodes: Vec<AccessibilityNode>,
    pub focused_id: Option<String>,
    pub announcement: Option<AccessibilityAnnouncement>,
}

impl Default for AccessibilitySnapshot {
    fn default() -> Self {
        Self {
            generation: 0,
            coordinate_space: AccessibilityCoordinateSpace::WindowContentTopLeft,
            nodes: Vec::new(),
            focused_id: None,
            announcement: None,
        }
    }
}

type BoundsListener = Box<dyn Fn(Bounds<Pixels>, &mut Window, &mut App) + 'static>;

/// Layout-transparent wrapper that reports the child's real, window-content
/// bounds after GPUI has completed layout. It deliberately reuses the child's
/// `LayoutId`, so measuring accessibility geometry cannot change layout.
pub struct MeasuredElement {
    child: AnyElement,
    listener: BoundsListener,
}

impl MeasuredElement {
    pub fn new(
        child: impl IntoElement,
        listener: impl Fn(Bounds<Pixels>, &mut Window, &mut App) + 'static,
    ) -> Self {
        Self {
            child: child.into_any_element(),
            listener: Box::new(listener),
        }
    }
}

impl Element for MeasuredElement {
    type RequestLayoutState = ();
    type PrepaintState = ();

    fn id(&self) -> Option<ElementId> {
        None
    }

    fn source_location(&self) -> Option<&'static std::panic::Location<'static>> {
        None
    }

    fn request_layout(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        window: &mut Window,
        cx: &mut App,
    ) -> (LayoutId, Self::RequestLayoutState) {
        (self.child.request_layout(window, cx), ())
    }

    fn prepaint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        _: &mut Self::RequestLayoutState,
        window: &mut Window,
        cx: &mut App,
    ) {
        self.child.prepaint(window, cx);
        (self.listener)(bounds, window, cx);
    }

    fn paint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        _: Bounds<Pixels>,
        _: &mut Self::RequestLayoutState,
        _: &mut Self::PrepaintState,
        window: &mut Window,
        cx: &mut App,
    ) {
        self.child.paint(window, cx);
    }
}

impl IntoElement for MeasuredElement {
    type Element = Self;

    fn into_element(self) -> Self::Element {
        self
    }
}

#[cfg(test)]
mod tests {
    use gpui::{bounds, point, px, size};

    use super::{
        AccessibilityAction, AccessibilityCoordinateSpace, AccessibilityFrame, AccessibilityNode,
        AccessibilityRole, AccessibilitySnapshot,
    };

    #[test]
    fn serializes_stable_camel_case_bridge_schema() {
        let snapshot = AccessibilitySnapshot {
            generation: 7,
            coordinate_space: AccessibilityCoordinateSpace::WindowContentTopLeft,
            nodes: vec![AccessibilityNode {
                id: "save".to_string(),
                parent_id: Some("settings".to_string()),
                role: AccessibilityRole::Button,
                label: "Save".to_string(),
                value: None,
                enabled: true,
                focused: false,
                actions: vec![AccessibilityAction::Press, AccessibilityAction::Focus],
                frame: AccessibilityFrame::from(bounds(
                    point(px(10.0), px(20.0)),
                    size(px(80.0), px(32.0)),
                )),
                order: 3,
            }],
            focused_id: None,
            announcement: None,
        };

        let json = serde_json::to_value(snapshot).unwrap_or_default();
        assert_eq!(json["coordinateSpace"], "windowContentTopLeft");
        assert_eq!(json["nodes"][0]["actions"][0], "press");
        assert_eq!(json["nodes"][0]["frame"]["width"], 80.0);
    }

    #[test]
    fn frame_intersection_reports_only_visible_geometry() {
        let viewport = AccessibilityFrame {
            x: 10.0,
            y: 20.0,
            width: 100.0,
            height: 80.0,
        };
        let partly_visible = AccessibilityFrame {
            x: 90.0,
            y: 90.0,
            width: 40.0,
            height: 30.0,
        };
        assert_eq!(
            partly_visible.intersection(viewport),
            Some(AccessibilityFrame {
                x: 90.0,
                y: 90.0,
                width: 20.0,
                height: 10.0,
            })
        );
        assert_eq!(
            AccessibilityFrame {
                x: 0.0,
                y: 0.0,
                width: 5.0,
                height: 5.0,
            }
            .intersection(viewport),
            None
        );
    }
}
