//! Launch-at-login actor — owns the latest launch-at-login snapshot.

use rinf::{DartSignal, RustSignal};

use crate::signals;

pub async fn run() {
    let request_recv = signals::RequestLaunchAtLoginSnapshot::get_dart_signal_receiver();
    let report_recv = signals::ReportLaunchAtLoginSnapshot::get_dart_signal_receiver();

    super::snapshot_mirror::run_snapshot_mirror(
        signals::LaunchAtLoginSnapshot {
            enabled: false,
            is_loading: true,
            error_message: None,
        },
        request_recv,
        report_recv,
        |snapshot| {
            signals::LaunchAtLoginSnapshotChanged {
                snapshot: snapshot.clone(),
            }
            .send_signal_to_dart();
        },
        |snapshot, pack: rinf::DartSignalPack<signals::ReportLaunchAtLoginSnapshot>| {
            *snapshot = pack.message.snapshot;
        },
    )
    .await;
}
