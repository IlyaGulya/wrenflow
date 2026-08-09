#!/usr/bin/env bash
set -euo pipefail

CRATE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$CRATE_DIR/../.." && pwd)"
APP_PATH="${WRENFLOW_TEST_APP:-$REPO_DIR/build/gpui/Wrenflow.app}"
source "$CRATE_DIR/scripts/verified-app-process.sh"
case "$APP_PATH" in
    "$REPO_DIR/build/gpui/Wrenflow.app" | "/Applications/Wrenflow.app" | "$HOME/Applications/Wrenflow.app") ;;
    *) echo "Refusing unexpected lifecycle app path: $APP_PATH" >&2; exit 65 ;;
esac
[[ -d "$APP_PATH" && ! -L "$APP_PATH" ]] || { echo "App not found: $APP_PATH" >&2; exit 66; }
codesign --verify --deep --strict "$APP_PATH"
PROBE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wrenflow-lifecycle-probe.XXXXXX")"
WINDOW_EVIDENCE_TOOL="$PROBE_ROOT/window-evidence"
cleanup_probe() {
    rm -rf "$PROBE_ROOT"
}
trap cleanup_probe EXIT
mise exec -- xcrun swiftc "$REPO_DIR/scripts/window-evidence.swift" -o "$WINDOW_EVIDENCE_TOOL"
request_quit() {
    wrenflow_request_typed_quit "$APP_PATH" 100
}

request_quit || exit 67

# Exercise the ready/accessory cold-start path. Window creation is deferred
# beyond AppKit restoration and only the typed current-line signal shows it.
open -n "$APP_PATH"
PID=""
for _ in $(seq 1 100); do
    PID="$(wrenflow_verified_pids "$APP_PATH" | head -1 || true)"
    [[ -n "$PID" ]] && break
    sleep 0.1
done
[[ -n "$PID" ]] || { echo "LaunchServices did not start bundle me.gulya.wrenflow" >&2; exit 68; }
START_INFO="$(lsappinfo info -only bundlepath,pid,ApplicationType -app "$PID")"
if [[ "$START_INFO" != *'"ApplicationType"="UIElement"'* ]]; then
    echo "Ready launch did not settle as a Dock-free menu-bar app: $START_INFO" >&2
    exit 69
fi

# Allow the startup route policy to finish closing and removing a ready-state
# window before asking LaunchServices to reopen it.
sleep 0.2

# Plain Finder reopen is intentionally not a show-window contract for an
# LSUIElement app. Tooling and forced duplicates send this typed current-line
# signal, which the Swift shell maps to OpenSettings/AppAction.
kill -USR2 "$PID"
REOPEN_INFO=""
for _ in $(seq 1 100); do
    REOPEN_INFO="$(lsappinfo info -only bundlepath,pid,ApplicationType -app "$PID")"
    [[ "$REOPEN_INFO" == *'"ApplicationType"="Foreground"'* ]] && break
    sleep 0.1
done
[[ "$REOPEN_INFO" == *'"ApplicationType"="Foreground"'* ]] || {
    echo "Typed show signal did not show the existing settings window: $REOPEN_INFO" >&2
    exit 70
}

# Then force a duplicate process. The early Swift guard must terminate only the
# duplicate before runtime IO while preserving the already foreground PID.
open -n "$APP_PATH"
for _ in $(seq 1 100); do
    PROCESS_COUNT="$(wrenflow_verified_pids "$APP_PATH" | wc -l | tr -d ' ')"
    [[ "$PROCESS_COUNT" == "1" ]] && break
    sleep 0.1
done
[[ "$PROCESS_COUNT" == "1" ]] || { echo "Duplicate launch left $PROCESS_COUNT processes" >&2; exit 70; }
[[ "$(wrenflow_verified_pids "$APP_PATH")" == "$PID" ]] || {
    echo "Duplicate launch replaced the existing process instead of reopening it" >&2
    exit 70
}
[[ "$REOPEN_INFO" == *'"ApplicationType"="Foreground"'* ]] || {
    echo "Forced duplicate changed foreground policy: $REOPEN_INFO" >&2
    exit 71
}

WINDOW_EVIDENCE=""
for _ in $(seq 1 200); do
    WINDOW_EVIDENCE="$("$WINDOW_EVIDENCE_TOOL" "$PID" 2>/dev/null || true)"
    if { [[ "$WINDOW_EVIDENCE" == *'Width = 720'* ]] || [[ "$WINDOW_EVIDENCE" == *'"Width": 720'* ]]; } &&
       { [[ "$WINDOW_EVIDENCE" == *'Height = 520'* ]] || [[ "$WINDOW_EVIDENCE" == *'"Height": 520'* ]]; } ||
       { [[ "$WINDOW_EVIDENCE" == *'Width = 340'* ]] || [[ "$WINDOW_EVIDENCE" == *'"Width": 340'* ]]; } &&
       { [[ "$WINDOW_EVIDENCE" == *'Height = 380'* ]] || [[ "$WINDOW_EVIDENCE" == *'"Height": 380'* ]]; }; then
        break
    fi
    sleep 0.1
done
if [[ "$WINDOW_EVIDENCE" != *'Width = 720'* &&
      "$WINDOW_EVIDENCE" != *'"Width": 720'* &&
      "$WINDOW_EVIDENCE" != *'Width = 340'* &&
      "$WINDOW_EVIDENCE" != *'"Width": 340'* ]]; then
    echo "Visible window did not match a route geometry contract: $WINDOW_EVIDENCE" >&2
    exit 72
fi

SAMPLE_PATH="$PROBE_ROOT/wrenflow.sample.txt"
if /usr/bin/sample "$PID" 1 1 -file "$SAMPLE_PATH" >/dev/null 2>&1 &&
   grep -Fq 'wrenflowShellUpdateTray' "$SAMPLE_PATH" &&
   grep -Fq '__DISPATCH_WAIT_FOR_QUEUE__' "$SAMPLE_PATH"; then
    echo "State restoration deadlocked runtime shell updates against AppKit main" >&2
    exit 72
fi
if grep -Fq 'NSPersistentUIRestorer' "$SAMPLE_PATH" &&
   grep -Fq 'window_did_change_key_status' "$SAMPLE_PATH" &&
   grep -Fq 'parking_lot::raw_mutex::RawMutex::lock_slow' "$SAMPLE_PATH"; then
    echo "AppKit persistent UI restoration re-entered the GPUI key-window mutex" >&2
    exit 72
fi

request_quit
for _ in $(seq 1 100); do
    ! kill -0 "$PID" >/dev/null 2>&1 && break
    sleep 0.1
done
! kill -0 "$PID" >/dev/null 2>&1 || { echo "Quit did not terminate PID $PID" >&2; exit 73; }

open -n "$APP_PATH"
RELAUNCH_PID=""
for _ in $(seq 1 100); do
    RELAUNCH_PID="$(wrenflow_verified_pids "$APP_PATH" | head -1 || true)"
    [[ -n "$RELAUNCH_PID" ]] && break
    sleep 0.1
done
[[ -n "$RELAUNCH_PID" && "$RELAUNCH_PID" != "$PID" ]] || {
    echo "Quit/relaunch did not produce a fresh single process" >&2
    exit 74
}

SIGNING_INFO="$(codesign --display --verbose=4 "$APP_PATH" 2>&1)"
printf 'WRENFLOW_LIFECYCLE_SELF_TEST_OK\nbundle=%s\ninitial_pid=%s\nrelaunch_pid=%s\n%s\n%s\n%s\n' \
    "$APP_PATH" "$PID" "$RELAUNCH_PID" "$START_INFO" "$REOPEN_INFO" "$WINDOW_EVIDENCE"
grep -E '^(Identifier|TeamIdentifier|Runtime Version)=' <<<"$SIGNING_INFO"
request_quit >/dev/null 2>&1 || true

COLD_FOREGROUND_SAMPLES=0
for iteration in $(seq 1 20); do
    open -n "$APP_PATH"
    COLD_PID=""
    for _ in $(seq 1 100); do
        COLD_PID="$(wrenflow_verified_pids "$APP_PATH" | head -1 || true)"
        [[ -n "$COLD_PID" ]] && break
        sleep 0.02
    done
    [[ -n "$COLD_PID" ]] || { echo "Cold launch $iteration produced no PID" >&2; exit 75; }
    SETTLED_ACCESSORY=0
    for _ in $(seq 1 100); do
        COLD_INFO="$(lsappinfo info -only ApplicationType -app "$COLD_PID" 2>/dev/null || true)"
        [[ "$COLD_INFO" == *'"ApplicationType"="Foreground"'* ]] &&
            COLD_FOREGROUND_SAMPLES=$((COLD_FOREGROUND_SAMPLES + 1))
        if [[ "$COLD_INFO" == *'"ApplicationType"="UIElement"'* ]]; then
            SETTLED_ACCESSORY=1
            break
        fi
        sleep 0.01
    done
    [[ "$SETTLED_ACCESSORY" == 1 ]] || {
        echo "Cold launch $iteration did not settle accessory: $COLD_INFO" >&2
        exit 75
    }
    request_quit || { echo "Cold launch $iteration did not complete typed quit" >&2; exit 75; }
done
[[ "$COLD_FOREGROUND_SAMPLES" == 0 ]] || {
    echo "Cold launches exposed $COLD_FOREGROUND_SAMPLES Foreground/Dock samples" >&2
    exit 75
}
printf 'WRENFLOW_COLD_LAUNCH_LOOP_OK loops=20 foreground_samples=0\n'
