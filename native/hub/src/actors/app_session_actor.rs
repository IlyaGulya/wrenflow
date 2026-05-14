//! App session actor — owns the top-level application lifecycle FSM.

use rinf::{DartSignal, RustSignal};

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
    fn new() -> Self {
        Self {
            state: signals::AppSessionState::Initializing,
            bootstrapped: false,
            has_completed_setup: false,
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

    fn evaluate_bootstrap(&mut self) {
        if !self.bootstrapped {
            self.state = signals::AppSessionState::Initializing;
            return;
        }

        if !self.has_completed_setup {
            self.state = signals::AppSessionState::Onboarding {
                step: signals::AppSessionOnboardingStep::Microphone,
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
                        step: signals::AppSessionOnboardingStep::Accessibility,
                    };
                }
                signals::AppSessionOnboardingStep::Accessibility
                    if self.accessibility == signals::PermissionStatus::Granted =>
                {
                    self.state = signals::AppSessionState::Onboarding {
                        step: signals::AppSessionOnboardingStep::Hotkey,
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
            signals::AppSessionOnboardingStep::Microphone => {
                signals::AppSessionOnboardingStep::Accessibility
            }
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
                signals::AppSessionOnboardingStep::Microphone
            }
            signals::AppSessionOnboardingStep::Hotkey => {
                signals::AppSessionOnboardingStep::Accessibility
            }
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

    fn complete_onboarding(&mut self) {
        self.has_completed_setup = true;
        self.bootstrapped = true;
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

pub async fn run() {
    let mut state = AppSessionRuntimeState::new();
    let request_recv = signals::RequestAppSessionSnapshot::get_dart_signal_receiver();
    let bootstrap_recv = signals::BootstrapAppSession::get_dart_signal_receiver();
    let permissions_recv = signals::ReportPermissionsSnapshot::get_dart_signal_receiver();
    let next_recv = signals::AdvanceOnboarding::get_dart_signal_receiver();
    let back_recv = signals::RetreatOnboarding::get_dart_signal_receiver();
    let complete_recv = signals::CompleteOnboarding::get_dart_signal_receiver();
    let quit_recv = signals::RequestQuit::get_dart_signal_receiver();

    send_snapshot(&state);

    loop {
        tokio::select! {
            Some(_) = request_recv.recv() => {
                send_snapshot(&state);
            }
            Some(pack) = bootstrap_recv.recv() => {
                state.bootstrapped = true;
                state.has_completed_setup = pack.message.has_completed_setup;
                state.evaluate_bootstrap();
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
            Some(_) = complete_recv.recv() => {
                state.complete_onboarding();
                send_snapshot(&state);
            }
            Some(_) = quit_recv.recv() => {
                state.state = signals::AppSessionState::ShuttingDown;
                send_snapshot(&state);
            }
            else => break,
        }
    }
}
