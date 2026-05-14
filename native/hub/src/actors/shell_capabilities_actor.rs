//! Shell capabilities actor — owns the latest platform capability snapshot.

use rinf::{DartSignal, RustSignal};

use crate::signals;

pub async fn run() {
    let request_recv = signals::RequestShellCapabilitiesSnapshot::get_dart_signal_receiver();
    let report_recv = signals::ReportShellCapabilitiesSnapshot::get_dart_signal_receiver();

    super::snapshot_mirror::run_snapshot_mirror(
        signals::ShellCapabilitiesSnapshot {
            launch_at_login: false,
            updates: false,
            local_transcription: false,
            microphone_selection: false,
            tray: false,
            overlays: false,
        },
        request_recv,
        report_recv,
        |snapshot| {
            signals::ShellCapabilitiesSnapshotChanged {
                snapshot: snapshot.clone(),
            }
            .send_signal_to_dart();
        },
        |snapshot, pack: rinf::DartSignalPack<signals::ReportShellCapabilitiesSnapshot>| {
            *snapshot = pack.message.snapshot;
        },
    )
    .await;
}
