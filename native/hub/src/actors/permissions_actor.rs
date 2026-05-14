//! Permissions actor — owns the latest permission snapshot reported by shell.

use rinf::{DartSignal, RustSignal};

use crate::signals;

#[derive(Clone)]
struct PermissionsSnapshotState {
    has_snapshot: bool,
    microphone: signals::PermissionStatus,
    accessibility: signals::PermissionStatus,
}

pub async fn run() {
    let request_recv = signals::RequestPermissionsSnapshot::get_dart_signal_receiver();
    let report_recv = signals::ReportPermissionsSnapshot::get_dart_signal_receiver();

    super::snapshot_mirror::run_snapshot_mirror(
        PermissionsSnapshotState {
            has_snapshot: false,
            microphone: signals::PermissionStatus::Unknown,
            accessibility: signals::PermissionStatus::Unknown,
        },
        request_recv,
        report_recv,
        |snapshot| {
            signals::PermissionsSnapshotChanged {
                has_snapshot: snapshot.has_snapshot,
                microphone: snapshot.microphone.clone(),
                accessibility: snapshot.accessibility.clone(),
            }
            .send_signal_to_dart();
        },
        |snapshot, pack: rinf::DartSignalPack<signals::ReportPermissionsSnapshot>| {
            snapshot.has_snapshot = true;
            snapshot.microphone = pack.message.microphone;
            snapshot.accessibility = pack.message.accessibility;
        },
    )
    .await;
}
