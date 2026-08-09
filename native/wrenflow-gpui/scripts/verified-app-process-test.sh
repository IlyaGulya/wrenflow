#!/usr/bin/env bash
set -euo pipefail

CRATE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$CRATE_DIR/scripts/verified-app-process.sh"

FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wrenflow-process-contract.XXXXXX")"
cleanup() {
    [[ -z "${SLEEP_PID:-}" ]] || kill -KILL "$SLEEP_PID" >/dev/null 2>&1 || true
    rm -rf "$FIXTURE_ROOT"
}
trap cleanup EXIT

ADHOC_APP="$FIXTURE_ROOT/AdHoc.app"
mkdir -p "$ADHOC_APP/Contents/MacOS"
cp /usr/bin/true "$ADHOC_APP/Contents/MacOS/wrenflow"
plutil -create xml1 "$ADHOC_APP/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string me.gulya.wrenflow "$ADHOC_APP/Contents/Info.plist"
codesign --force --deep --sign - "$ADHOC_APP" >/dev/null 2>&1
if wrenflow_validate_bundle_identity "$ADHOC_APP" >/dev/null 2>&1; then
    echo "Exact-process boundary accepted an ad-hoc bundle" >&2
    exit 65
fi

WRONG_TEAM_BIN="$FIXTURE_ROOT/wrong-team-bin"
mkdir -p "$WRONG_TEAM_BIN"
printf '%s\n' '#!/usr/bin/env bash' \
    'if [[ "$1" == "--display" ]]; then' \
    '  echo "Identifier=me.gulya.wrenflow" >&2' \
    '  echo "TeamIdentifier=WRONGTEAM" >&2' \
    'fi' \
    'exit 0' > "$WRONG_TEAM_BIN/codesign"
chmod +x "$WRONG_TEAM_BIN/codesign"
if PATH="$WRONG_TEAM_BIN:$PATH" wrenflow_validate_bundle_identity "$ADHOC_APP" >/dev/null 2>&1; then
    echo "Exact-process boundary accepted a wrong-team bundle" >&2
    exit 65
fi

# Replace only the OS probes for deterministic process-selection tests. The
# production helper itself still owns same-ID/path rejection and signalling.
wrenflow_validate_bundle_identity() {
    [[ "$1" == "/expected/Wrenflow.app" || "$1" == "/other/Wrenflow.app" ]]
}
wrenflow_candidate_pids() {
    printf '101\n102\n'
}
wrenflow_process_info() {
    case "$1" in
        101) printf '{ "CFBundleIdentifier"="me.gulya.wrenflow"; "LSBundlePath"="/expected/Wrenflow.app"; }\n' ;;
        102) printf '{ "CFBundleIdentifier"="me.gulya.wrenflow"; "LSBundlePath"="/other/Wrenflow.app"; }\n' ;;
    esac
}
if wrenflow_verified_pids "/expected/Wrenflow.app" >/dev/null 2>&1; then
    echo "Exact-process boundary accepted a same-ID process from another copy" >&2
    exit 65
fi

wrenflow_candidate_pids() {
    [[ -n "${SLEEP_PID:-}" ]] && kill -0 "$SLEEP_PID" >/dev/null 2>&1 && printf '%s\n' "$SLEEP_PID"
}
wrenflow_process_info() {
    printf '{ "CFBundleIdentifier"="me.gulya.wrenflow"; "LSBundlePath"="/expected/Wrenflow.app"; }\n'
}
bash -c 'trap "exit 0" USR1; while true; do read -r -t 1 _ || true; done' &
SLEEP_PID=$!
sleep 0.05
wrenflow_request_typed_quit "/expected/Wrenflow.app" 20
wait "$SLEEP_PID" 2>/dev/null || true
SLEEP_PID=""

echo "WRENFLOW_VERIFIED_APP_PROCESS_TEST_OK"
