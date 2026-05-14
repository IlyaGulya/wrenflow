//! Shell capabilities actor — owns the latest platform capability snapshot.

use rinf::{DartSignal, RustSignal};

use crate::signals;

pub async fn run() {
    let mut snapshot = signals::ShellCapabilitiesSnapshot {
        launch_at_login: false,
        updates: false,
        local_transcription: false,
        microphone_selection: false,
        tray: false,
        overlays: false,
    };

    let request_recv = signals::RequestShellCapabilitiesSnapshot::get_dart_signal_receiver();
    let report_recv = signals::ReportShellCapabilitiesSnapshot::get_dart_signal_receiver();

    signals::ShellCapabilitiesSnapshotChanged {
        snapshot: snapshot.clone(),
    }
    .send_signal_to_dart();

    loop {
        tokio::select! {
            Some(_) = request_recv.recv() => {
                signals::ShellCapabilitiesSnapshotChanged {
                    snapshot: snapshot.clone(),
                }
                .send_signal_to_dart();
            }
            Some(pack) = report_recv.recv() => {
                snapshot = pack.message.snapshot;
                signals::ShellCapabilitiesSnapshotChanged {
                    snapshot: snapshot.clone(),
                }
                .send_signal_to_dart();
            }
            else => break,
        }
    }
}
