//! Updates actor — owns the latest updater snapshot reported by Dart.

use rinf::{DartSignal, RustSignal};

use crate::signals;

pub async fn run() {
    let mut status = signals::UpdateStatus::Idle;
    let request_recv = signals::RequestUpdatesSnapshot::get_dart_signal_receiver();
    let report_recv = signals::ReportUpdatesStatus::get_dart_signal_receiver();

    signals::UpdatesSnapshotChanged {
        status: status.clone(),
    }
    .send_signal_to_dart();

    loop {
        tokio::select! {
            Some(_) = request_recv.recv() => {
                signals::UpdatesSnapshotChanged {
                    status: status.clone(),
                }
                .send_signal_to_dart();
            }
            Some(pack) = report_recv.recv() => {
                status = pack.message.status;
                signals::UpdatesSnapshotChanged {
                    status: status.clone(),
                }
                .send_signal_to_dart();
            }
            else => break,
        }
    }
}
