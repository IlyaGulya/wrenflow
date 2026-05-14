//! Permissions actor — owns the latest permission snapshot reported by shell.

use rinf::{DartSignal, RustSignal};
use std::sync::{Arc, Mutex};

use crate::signals;

type SharedPermissionsState = Arc<Mutex<PermissionsRuntimeState>>;

#[derive(Clone, Debug)]
struct PermissionsRuntimeState {
    has_snapshot: bool,
    microphone: signals::PermissionStatus,
    accessibility: signals::PermissionStatus,
}

impl PermissionsRuntimeState {
    fn new() -> Self {
        Self {
            has_snapshot: false,
            microphone: signals::PermissionStatus::Unknown,
            accessibility: signals::PermissionStatus::Unknown,
        }
    }
}

fn send_permissions_snapshot(state: &SharedPermissionsState) {
    let Ok(guard) = state.lock() else {
        return;
    };

    signals::PermissionsSnapshotChanged {
        has_snapshot: guard.has_snapshot,
        microphone: guard.microphone.clone(),
        accessibility: guard.accessibility.clone(),
    }
    .send_signal_to_dart();
}

fn update_permissions_snapshot(
    state: &SharedPermissionsState,
    update: impl FnOnce(&mut PermissionsRuntimeState),
) {
    let Ok(mut guard) = state.lock() else {
        return;
    };
    update(&mut guard);
    drop(guard);
    send_permissions_snapshot(state);
}

pub async fn run() {
    let snapshot_state: SharedPermissionsState =
        Arc::new(Mutex::new(PermissionsRuntimeState::new()));
    let request_recv = signals::RequestPermissionsSnapshot::get_dart_signal_receiver();
    let report_recv = signals::ReportPermissionsSnapshot::get_dart_signal_receiver();

    send_permissions_snapshot(&snapshot_state);

    loop {
        tokio::select! {
            Some(_) = request_recv.recv() => {
                send_permissions_snapshot(&snapshot_state);
            }
            Some(pack) = report_recv.recv() => {
                update_permissions_snapshot(&snapshot_state, |snapshot| {
                    snapshot.has_snapshot = true;
                    snapshot.microphone = pack.message.microphone;
                    snapshot.accessibility = pack.message.accessibility;
                });
            }
            else => break,
        }
    }
}
