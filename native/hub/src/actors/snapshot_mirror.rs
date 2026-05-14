//! Shared helper for simple Rust-owned snapshot mirrors.

use rinf::SignalReceiver;

pub async fn run_snapshot_mirror<State, RequestPack, ReportPack, SendFn, ApplyFn>(
    initial_state: State,
    request_recv: SignalReceiver<RequestPack>,
    report_recv: SignalReceiver<ReportPack>,
    mut send: SendFn,
    mut apply: ApplyFn,
) where
    State: Clone,
    SendFn: FnMut(&State),
    ApplyFn: FnMut(&mut State, ReportPack),
{
    let mut state = initial_state;
    send(&state);

    loop {
        tokio::select! {
            Some(_) = request_recv.recv() => {
                send(&state);
            }
            Some(pack) = report_recv.recv() => {
                apply(&mut state, pack);
                send(&state);
            }
            else => break,
        }
    }
}
