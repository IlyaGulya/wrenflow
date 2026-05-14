//! Launch-at-login actor — owns the latest launch-at-login snapshot.

use rinf::{DartSignal, RustSignal};

use crate::signals;

pub async fn run() {
    let mut snapshot = signals::LaunchAtLoginSnapshot {
        enabled: false,
        is_loading: true,
        error_message: None,
    };

    let request_recv = signals::RequestLaunchAtLoginSnapshot::get_dart_signal_receiver();
    let report_recv = signals::ReportLaunchAtLoginSnapshot::get_dart_signal_receiver();

    signals::LaunchAtLoginSnapshotChanged {
        snapshot: snapshot.clone(),
    }
    .send_signal_to_dart();

    loop {
        tokio::select! {
            Some(_) = request_recv.recv() => {
                signals::LaunchAtLoginSnapshotChanged {
                    snapshot: snapshot.clone(),
                }
                .send_signal_to_dart();
            }
            Some(pack) = report_recv.recv() => {
                snapshot = pack.message.snapshot;
                signals::LaunchAtLoginSnapshotChanged {
                    snapshot: snapshot.clone(),
                }
                .send_signal_to_dart();
            }
            else => break,
        }
    }
}
