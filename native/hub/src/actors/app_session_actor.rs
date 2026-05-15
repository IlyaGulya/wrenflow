//! App session actor — owns the top-level application lifecycle FSM.

use rinf::{DartSignal, RustSignal};
use tokio::sync::watch;
use wrenflow_domain::config::AppConfig;

use crate::signals;

const PERMISSION_LOST_THRESHOLD: u8 = 3;

#[derive(Clone, Debug)]
struct AppSessionRuntimeState {
    state: signals::AppSessionState,
    bootstrapped: bool,
    has_completed_setup: bool,
    has_permission_snapshot: bool,
    microphone: signals::PermissionStatus,
    accessibility: signals::PermissionStatus,
    permission_lost_count: u8,
}

impl AppSessionRuntimeState {
    fn new(has_completed_setup: bool) -> Self {
        Self {
            state: signals::AppSessionState::Initializing,
            bootstrapped: true,
            has_completed_setup,
            has_permission_snapshot: false,
            microphone: signals::PermissionStatus::Unknown,
            accessibility: signals::PermissionStatus::Unknown,
            permission_lost_count: 0,
        }
    }

    fn all_permissions_granted(&self) -> bool {
        self.microphone == signals::PermissionStatus::Granted
            && self.accessibility == signals::PermissionStatus::Granted
    }

    fn missing_permissions(&self) -> (bool, bool) {
        (
            self.microphone != signals::PermissionStatus::Granted,
            self.accessibility != signals::PermissionStatus::Granted,
        )
    }

    fn initial_onboarding_step(&self) -> signals::AppSessionOnboardingStep {
        if self.has_permission_snapshot {
            if self.microphone != signals::PermissionStatus::Granted {
                return signals::AppSessionOnboardingStep::Microphone;
            }
            if self.accessibility != signals::PermissionStatus::Granted {
                return signals::AppSessionOnboardingStep::Accessibility;
            }
        }

        signals::AppSessionOnboardingStep::Hotkey
    }

    fn evaluate_bootstrap(&mut self) {
        if !self.bootstrapped {
            self.state = signals::AppSessionState::Initializing;
            return;
        }

        if !self.has_completed_setup {
            if !self.has_permission_snapshot {
                self.state = signals::AppSessionState::Initializing;
                return;
            }

            self.state = signals::AppSessionState::Onboarding {
                step: self.initial_onboarding_step(),
            };
            return;
        }

        if !self.has_permission_snapshot {
            self.state = signals::AppSessionState::Initializing;
            return;
        }

        if self.all_permissions_granted() {
            self.state = signals::AppSessionState::Ready;
        } else {
            let (microphone_missing, accessibility_missing) = self.missing_permissions();
            self.state = signals::AppSessionState::PermissionRecovery {
                microphone_missing,
                accessibility_missing,
            };
        }
    }

    fn update_permissions(
        &mut self,
        microphone: signals::PermissionStatus,
        accessibility: signals::PermissionStatus,
    ) {
        self.has_permission_snapshot = true;
        self.microphone = microphone;
        self.accessibility = accessibility;

        match &self.state {
            signals::AppSessionState::Initializing => {
                self.evaluate_bootstrap();
            }
            signals::AppSessionState::Onboarding { step } => match step {
                signals::AppSessionOnboardingStep::Microphone
                    if self.microphone == signals::PermissionStatus::Granted =>
                {
                    self.state = signals::AppSessionState::Onboarding {
                        step: self.initial_onboarding_step(),
                    };
                }
                signals::AppSessionOnboardingStep::Accessibility
                    if self.accessibility == signals::PermissionStatus::Granted =>
                {
                    self.state = signals::AppSessionState::Onboarding {
                        step: self.initial_onboarding_step(),
                    };
                }
                _ => {}
            },
            signals::AppSessionState::PermissionRecovery { .. } => {
                if self.all_permissions_granted() {
                    self.permission_lost_count = 0;
                    self.state = signals::AppSessionState::Ready;
                } else {
                    let (microphone_missing, accessibility_missing) = self.missing_permissions();
                    self.state = signals::AppSessionState::PermissionRecovery {
                        microphone_missing,
                        accessibility_missing,
                    };
                }
            }
            signals::AppSessionState::Ready => {
                if self.all_permissions_granted() {
                    self.permission_lost_count = 0;
                } else {
                    self.permission_lost_count = self.permission_lost_count.saturating_add(1);
                    if self.permission_lost_count >= PERMISSION_LOST_THRESHOLD {
                        self.permission_lost_count = 0;
                        let (microphone_missing, accessibility_missing) =
                            self.missing_permissions();
                        self.state = signals::AppSessionState::PermissionRecovery {
                            microphone_missing,
                            accessibility_missing,
                        };
                    }
                }
            }
            signals::AppSessionState::ShuttingDown => {}
        }
    }

    fn onboarding_next(&mut self) {
        let signals::AppSessionState::Onboarding { step } = &self.state else {
            return;
        };

        let next = match step {
            signals::AppSessionOnboardingStep::Microphone => self.initial_onboarding_step(),
            signals::AppSessionOnboardingStep::Accessibility => {
                signals::AppSessionOnboardingStep::Hotkey
            }
            signals::AppSessionOnboardingStep::Hotkey => signals::AppSessionOnboardingStep::Model,
            signals::AppSessionOnboardingStep::Model => {
                signals::AppSessionOnboardingStep::Vocabulary
            }
            signals::AppSessionOnboardingStep::Vocabulary => {
                signals::AppSessionOnboardingStep::Complete
            }
            signals::AppSessionOnboardingStep::Complete => return,
        };

        self.state = signals::AppSessionState::Onboarding { step: next };
    }

    fn onboarding_back(&mut self) {
        let signals::AppSessionState::Onboarding { step } = &self.state else {
            return;
        };

        let previous = match step {
            signals::AppSessionOnboardingStep::Microphone => return,
            signals::AppSessionOnboardingStep::Accessibility => {
                if self.microphone == signals::PermissionStatus::Granted {
                    return;
                }
                signals::AppSessionOnboardingStep::Microphone
            }
            signals::AppSessionOnboardingStep::Hotkey => match (
                self.microphone == signals::PermissionStatus::Granted,
                self.accessibility == signals::PermissionStatus::Granted,
            ) {
                (false, _) => signals::AppSessionOnboardingStep::Microphone,
                (true, false) => signals::AppSessionOnboardingStep::Accessibility,
                (true, true) => return,
            },
            signals::AppSessionOnboardingStep::Model => signals::AppSessionOnboardingStep::Hotkey,
            signals::AppSessionOnboardingStep::Vocabulary => {
                signals::AppSessionOnboardingStep::Model
            }
            signals::AppSessionOnboardingStep::Complete => {
                signals::AppSessionOnboardingStep::Vocabulary
            }
        };

        self.state = signals::AppSessionState::Onboarding { step: previous };
    }

    fn set_has_completed_setup(&mut self, has_completed_setup: bool) {
        self.has_completed_setup = has_completed_setup;
        self.bootstrapped = true;

        if !has_completed_setup {
            self.evaluate_bootstrap();
            return;
        }

        if self.has_permission_snapshot && self.all_permissions_granted() {
            self.state = signals::AppSessionState::Ready;
        } else if self.has_permission_snapshot {
            let (microphone_missing, accessibility_missing) = self.missing_permissions();
            self.state = signals::AppSessionState::PermissionRecovery {
                microphone_missing,
                accessibility_missing,
            };
        } else {
            self.state = signals::AppSessionState::Initializing;
        }
    }
}

fn send_snapshot(state: &AppSessionRuntimeState) {
    signals::AppSessionSnapshotChanged {
        state: state.state.clone(),
    }
    .send_signal_to_dart();
}

pub async fn run(mut config_rx: watch::Receiver<AppConfig>) {
    let mut state = AppSessionRuntimeState::new(config_rx.borrow().has_completed_setup);
    let request_recv = signals::RequestAppSessionSnapshot::get_dart_signal_receiver();
    let permissions_recv = signals::ReportPermissionsSnapshot::get_dart_signal_receiver();
    let next_recv = signals::AdvanceOnboarding::get_dart_signal_receiver();
    let back_recv = signals::RetreatOnboarding::get_dart_signal_receiver();
    let quit_recv = signals::RequestQuit::get_dart_signal_receiver();
    let mut last_has_completed_setup = config_rx.borrow().has_completed_setup;

    state.evaluate_bootstrap();
    send_snapshot(&state);

    loop {
        tokio::select! {
            Some(_) = request_recv.recv() => {
                send_snapshot(&state);
            }
            Some(pack) = permissions_recv.recv() => {
                state.update_permissions(pack.message.microphone, pack.message.accessibility);
                send_snapshot(&state);
            }
            Some(_) = next_recv.recv() => {
                state.onboarding_next();
                send_snapshot(&state);
            }
            Some(_) = back_recv.recv() => {
                state.onboarding_back();
                send_snapshot(&state);
            }
            Ok(()) = config_rx.changed() => {
                let next_has_completed_setup = config_rx.borrow().has_completed_setup;
                if next_has_completed_setup != last_has_completed_setup {
                    last_has_completed_setup = next_has_completed_setup;
                    state.set_has_completed_setup(next_has_completed_setup);
                    send_snapshot(&state);
                }
            }
            Some(_) = quit_recv.recv() => {
                state.state = signals::AppSessionState::ShuttingDown;
                send_snapshot(&state);
            }
            else => break,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_onboarding_step(
        state: &AppSessionRuntimeState,
        expected: signals::AppSessionOnboardingStep,
    ) {
        match &state.state {
            signals::AppSessionState::Onboarding { step } => assert_eq!(*step, expected),
            other => panic!("expected onboarding state, got {other:?}"),
        }
    }

    #[test]
    fn completed_setup_waits_for_permission_snapshot_before_ready() {
        let mut state = AppSessionRuntimeState::new(true);
        state.evaluate_bootstrap();
        assert!(matches!(state.state, signals::AppSessionState::Initializing));
    }

    #[test]
    fn completed_setup_with_all_permissions_becomes_ready() {
        let mut state = AppSessionRuntimeState::new(true);
        state.update_permissions(
            signals::PermissionStatus::Granted,
            signals::PermissionStatus::Granted,
        );
        assert!(matches!(state.state, signals::AppSessionState::Ready));
    }

    #[test]
    fn onboarding_skips_granted_permission_steps() {
        let mut state = AppSessionRuntimeState::new(false);
        state.update_permissions(
            signals::PermissionStatus::Granted,
            signals::PermissionStatus::Granted,
        );
        assert_onboarding_step(&state, signals::AppSessionOnboardingStep::Hotkey);
    }

    #[test]
    fn onboarding_starts_at_microphone_when_missing() {
        let mut state = AppSessionRuntimeState::new(false);
        state.update_permissions(
            signals::PermissionStatus::Denied,
            signals::PermissionStatus::Granted,
        );
        assert_onboarding_step(&state, signals::AppSessionOnboardingStep::Microphone);
    }

    #[test]
    fn onboarding_advances_to_hotkey_after_permissions_resolved() {
        let mut state = AppSessionRuntimeState::new(false);
        state.update_permissions(
            signals::PermissionStatus::Denied,
            signals::PermissionStatus::Granted,
        );
        assert_onboarding_step(&state, signals::AppSessionOnboardingStep::Microphone);

        state.update_permissions(
            signals::PermissionStatus::Granted,
            signals::PermissionStatus::Granted,
        );
        assert_onboarding_step(&state, signals::AppSessionOnboardingStep::Hotkey);
    }

    #[test]
    fn completing_onboarding_after_permissions_goes_ready() {
        let mut state = AppSessionRuntimeState::new(false);
        state.update_permissions(
            signals::PermissionStatus::Granted,
            signals::PermissionStatus::Granted,
        );
        state.set_has_completed_setup(true);
        assert!(matches!(state.state, signals::AppSessionState::Ready));
    }
}
