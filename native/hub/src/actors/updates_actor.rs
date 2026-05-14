//! Updates actor — owns the latest updater snapshot reported by Dart.

use rinf::{DartSignal, RustSignal};

use crate::signals;

pub async fn run() {
    let request_recv = signals::RequestUpdatesSnapshot::get_dart_signal_receiver();
    let report_recv = signals::ReportUpdatesStatus::get_dart_signal_receiver();

    super::snapshot_mirror::run_snapshot_mirror(
        signals::UpdateStatus::Idle,
        request_recv,
        report_recv,
        |status| {
            signals::UpdatesSnapshotChanged {
                status: status.clone(),
            }
            .send_signal_to_dart();
        },
        |status, pack: rinf::DartSignalPack<signals::ReportUpdatesStatus>| {
            *status = pack.message.status;
        },
    )
    .await;
}
