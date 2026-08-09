use wrenflow_runtime::AppSessionState;

/// Every top-level product surface owned by the GPUI window.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum NavigationTarget {
    Loading,
    Onboarding,
    PermissionRecovery,
    #[default]
    Settings,
    Models,
    History,
    About,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct NavigationState {
    requested: NavigationTarget,
}

impl NavigationState {
    #[must_use]
    pub const fn requested(self) -> NavigationTarget {
        self.requested
    }

    pub fn request(&mut self, target: NavigationTarget) {
        if matches!(
            target,
            NavigationTarget::Settings
                | NavigationTarget::Models
                | NavigationTarget::History
                | NavigationTarget::About
        ) {
            self.requested = target;
        }
    }

    /// Session-critical routes override user navigation. Once the runtime is
    /// ready, the last requested product page is restored.
    #[must_use]
    pub fn resolve(self, session: &AppSessionState) -> NavigationTarget {
        match session {
            AppSessionState::Initializing => NavigationTarget::Loading,
            AppSessionState::Onboarding { .. } => NavigationTarget::Onboarding,
            AppSessionState::PermissionRecovery { .. } => NavigationTarget::PermissionRecovery,
            AppSessionState::Ready | AppSessionState::ShuttingDown => self.requested,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wrenflow_runtime::OnboardingStep;

    #[test]
    fn session_routes_override_and_then_restore_requested_page() {
        let mut navigation = NavigationState::default();
        navigation.request(NavigationTarget::History);
        assert_eq!(
            navigation.resolve(&AppSessionState::Onboarding {
                step: OnboardingStep::Hotkey,
            }),
            NavigationTarget::Onboarding
        );
        assert_eq!(
            navigation.resolve(&AppSessionState::Ready),
            NavigationTarget::History
        );
    }

    #[test]
    fn synthetic_routes_cannot_be_requested_by_sidebar_navigation() {
        let mut navigation = NavigationState::default();
        navigation.request(NavigationTarget::Loading);
        navigation.request(NavigationTarget::PermissionRecovery);
        assert_eq!(navigation.requested(), NavigationTarget::Settings);
    }
}
