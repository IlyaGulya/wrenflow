use crate::ui::{
    AccessibilityAction, AccessibilityAnnouncement, AccessibilityCoordinateSpace,
    AccessibilityFrame, AccessibilityNode, AccessibilityPriority, AccessibilityRole,
    AccessibilitySnapshot,
};

#[derive(Clone, Debug, PartialEq)]
pub(super) struct AccessibilityNodeDraft {
    pub id: String,
    pub parent_id: Option<String>,
    pub role: AccessibilityRole,
    pub label: String,
    pub value: Option<String>,
    pub enabled: bool,
    pub actions: Vec<AccessibilityAction>,
}

impl AccessibilityNodeDraft {
    pub fn new(
        id: impl Into<String>,
        parent_id: Option<impl Into<String>>,
        role: AccessibilityRole,
        label: impl Into<String>,
    ) -> Self {
        Self {
            id: id.into(),
            parent_id: parent_id.map(Into::into),
            role,
            label: label.into(),
            value: None,
            enabled: true,
            actions: Vec::new(),
        }
    }

    pub fn value(mut self, value: impl Into<String>) -> Self {
        self.value = Some(value.into());
        self
    }

    pub const fn enabled(mut self, enabled: bool) -> Self {
        self.enabled = enabled;
        self
    }

    pub fn actions(mut self, actions: impl IntoIterator<Item = AccessibilityAction>) -> Self {
        self.actions.extend(actions);
        self
    }
}

#[derive(Clone, Debug)]
struct WorkingNode {
    draft: AccessibilityNodeDraft,
    frame: Option<AccessibilityFrame>,
    order: u32,
}

#[derive(Clone, Debug)]
pub(super) struct AccessibilityState {
    epoch: u64,
    working: Vec<WorkingNode>,
    sealed: bool,
    modal_root: Option<String>,
    published: AccessibilitySnapshot,
    latest_announcement: Option<AccessibilityAnnouncement>,
    last_announcement_key: Option<String>,
    next_announcement_serial: u64,
}

impl Default for AccessibilityState {
    fn default() -> Self {
        Self {
            epoch: 0,
            working: Vec::new(),
            sealed: false,
            modal_root: None,
            published: AccessibilitySnapshot::default(),
            latest_announcement: None,
            last_announcement_key: None,
            next_announcement_serial: 1,
        }
    }
}

impl AccessibilityState {
    pub fn begin_frame(&mut self) -> u64 {
        self.epoch = self.epoch.saturating_add(1);
        self.working.clear();
        self.sealed = false;
        self.modal_root = None;
        self.epoch
    }

    pub fn register(&mut self, draft: AccessibilityNodeDraft) {
        debug_assert!(
            self.working.iter().all(|node| node.draft.id != draft.id),
            "accessibility node ids must be unique within a frame"
        );
        if self.working.iter().any(|node| node.draft.id == draft.id) {
            return;
        }
        let order = u32::try_from(self.working.len()).unwrap_or(u32::MAX);
        self.working.push(WorkingNode {
            draft,
            frame: None,
            order,
        });
    }

    pub const fn current_epoch(&self) -> u64 {
        self.epoch
    }

    pub fn set_modal_root(&mut self, id: Option<impl Into<String>>) {
        self.modal_root = id.map(Into::into);
    }

    pub fn announce(
        &mut self,
        key: impl Into<String>,
        message: impl Into<String>,
        priority: AccessibilityPriority,
    ) {
        let key = key.into();
        if self.last_announcement_key.as_ref() == Some(&key) {
            return;
        }
        self.last_announcement_key = Some(key);
        self.latest_announcement = Some(AccessibilityAnnouncement {
            serial: self.next_announcement_serial,
            message: message.into(),
            priority,
        });
        self.next_announcement_serial = self.next_announcement_serial.saturating_add(1);
    }

    pub fn seal(&mut self, epoch: u64) {
        if epoch != self.epoch {
            return;
        }
        self.sealed = true;
        self.try_publish();
    }

    pub fn measure(&mut self, epoch: u64, id: &str, frame: AccessibilityFrame) {
        if epoch != self.epoch {
            return;
        }
        if let Some(node) = self.working.iter_mut().find(|node| node.draft.id == id) {
            node.frame = Some(frame);
        }
        self.try_publish();
    }

    pub fn snapshot(&self) -> AccessibilitySnapshot {
        self.published.clone()
    }

    fn try_publish(&mut self) {
        if !self.sealed || self.working.iter().any(|node| node.frame.is_none()) {
            return;
        }
        let nodes = self
            .working
            .iter()
            .filter_map(|node| {
                if !self.node_is_in_active_modal_subtree(node) {
                    return None;
                }
                let mut frame = node.frame?;
                let mut parent_id = node.draft.parent_id.as_deref();
                while let Some(parent) = parent_id {
                    let parent = self
                        .working
                        .iter()
                        .find(|candidate| candidate.draft.id == parent)?;
                    frame = frame.intersection(parent.frame?)?;
                    parent_id = parent.draft.parent_id.as_deref();
                }
                Some(AccessibilityNode {
                    id: node.draft.id.clone(),
                    parent_id: node.draft.parent_id.clone(),
                    role: node.draft.role,
                    label: node.draft.label.clone(),
                    value: node.draft.value.clone(),
                    enabled: node.draft.enabled,
                    focused: false,
                    actions: node.draft.actions.clone(),
                    frame,
                    order: node.order,
                })
            })
            .collect::<Vec<_>>();
        let announcement = self.latest_announcement.clone();
        if self.published.nodes == nodes && self.published.announcement == announcement {
            return;
        }
        self.published = AccessibilitySnapshot {
            generation: self.published.generation.saturating_add(1),
            coordinate_space: AccessibilityCoordinateSpace::WindowContentTopLeft,
            nodes,
            focused_id: None,
            announcement,
        };
    }

    fn node_is_in_active_modal_subtree(&self, node: &WorkingNode) -> bool {
        let Some(modal_root) = self.modal_root.as_deref() else {
            return true;
        };
        if node.draft.parent_id.is_none() || node.draft.id == modal_root {
            return true;
        }
        let mut parent_id = node.draft.parent_id.as_deref();
        while let Some(parent) = parent_id {
            if parent == modal_root {
                return true;
            }
            parent_id = self
                .working
                .iter()
                .find(|candidate| candidate.draft.id == parent)
                .and_then(|candidate| candidate.draft.parent_id.as_deref());
        }
        false
    }
}

#[cfg(test)]
mod tests {
    use crate::ui::{AccessibilityFrame, AccessibilityPriority, AccessibilityRole};

    use super::{AccessibilityNodeDraft, AccessibilityState};

    #[test]
    fn publishes_only_complete_real_geometry_frames() {
        let mut state = AccessibilityState::default();
        let epoch = state.begin_frame();
        state.register(AccessibilityNodeDraft::new(
            "root",
            None::<String>,
            AccessibilityRole::Window,
            "Wrenflow",
        ));
        state.register(AccessibilityNodeDraft::new(
            "button",
            Some("root"),
            AccessibilityRole::Button,
            "Continue",
        ));
        state.seal(epoch);
        state.measure(
            epoch,
            "root",
            AccessibilityFrame {
                x: 0.0,
                y: 0.0,
                width: 760.0,
                height: 620.0,
            },
        );
        assert!(state.snapshot().nodes.is_empty());

        state.measure(
            epoch,
            "button",
            AccessibilityFrame {
                x: 20.0,
                y: 40.0,
                width: 100.0,
                height: 32.0,
            },
        );
        let snapshot = state.snapshot();
        assert_eq!(snapshot.generation, 1);
        assert_eq!(snapshot.nodes.len(), 2);
        assert_eq!(snapshot.nodes[1].frame.x, 20.0);
    }

    #[test]
    fn deduplicates_announcements_but_repeats_after_a_different_event() {
        let mut state = AccessibilityState::default();
        state.announce("saving", "Saving settings", AccessibilityPriority::Low);
        let first = state.latest_announcement.clone().unwrap_or_else(|| {
            panic!("first announcement should exist");
        });
        state.announce("saving", "Saving settings", AccessibilityPriority::Low);
        assert_eq!(state.latest_announcement.as_ref(), Some(&first));
        state.announce("saved", "Settings saved", AccessibilityPriority::Medium);
        assert!(state
            .latest_announcement
            .as_ref()
            .is_some_and(|announcement| announcement.serial > first.serial));
    }

    #[test]
    fn clips_scroll_descendants_and_excludes_modal_background() {
        let mut state = AccessibilityState::default();
        let epoch = state.begin_frame();
        state.register(AccessibilityNodeDraft::new(
            "root",
            None::<String>,
            AccessibilityRole::Window,
            "Wrenflow",
        ));
        state.register(AccessibilityNodeDraft::new(
            "background",
            Some("root"),
            AccessibilityRole::Button,
            "Clear all",
        ));
        state.register(AccessibilityNodeDraft::new(
            "dialog",
            Some("root"),
            AccessibilityRole::Dialog,
            "Confirm",
        ));
        state.register(AccessibilityNodeDraft::new(
            "cancel",
            Some("dialog"),
            AccessibilityRole::Button,
            "Cancel",
        ));
        state.set_modal_root(Some("dialog"));
        state.seal(epoch);
        for (id, frame) in [
            (
                "root",
                AccessibilityFrame {
                    x: 0.0,
                    y: 0.0,
                    width: 200.0,
                    height: 100.0,
                },
            ),
            (
                "background",
                AccessibilityFrame {
                    x: 10.0,
                    y: 10.0,
                    width: 60.0,
                    height: 30.0,
                },
            ),
            (
                "dialog",
                AccessibilityFrame {
                    x: 40.0,
                    y: 30.0,
                    width: 120.0,
                    height: 90.0,
                },
            ),
            (
                "cancel",
                AccessibilityFrame {
                    x: 130.0,
                    y: 90.0,
                    width: 50.0,
                    height: 30.0,
                },
            ),
        ] {
            state.measure(epoch, id, frame);
        }

        let snapshot = state.snapshot();
        assert_eq!(
            snapshot
                .nodes
                .iter()
                .map(|node| node.id.as_str())
                .collect::<Vec<_>>(),
            vec!["root", "dialog", "cancel"]
        );
        let cancel = &snapshot.nodes[2];
        assert_eq!(cancel.frame.width, 30.0);
        assert_eq!(cancel.frame.height, 10.0);
    }
}
