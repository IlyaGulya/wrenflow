#!/usr/bin/env bash
set -euo pipefail

CRATE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$CRATE_DIR/../.." && pwd)"
APP_DIR="$REPO_DIR/build/gpui/Wrenflow.app"
BUNDLE_ID="me.gulya.wrenflow"
TEAM_ID="T4LV8K9BGV"
source "$CRATE_DIR/scripts/verified-app-process.sh"

if [[ ! -d "$APP_DIR" ]]; then
    echo "Production GPUI bundle not found at $APP_DIR" >&2
    exit 1
fi

wrenflow_validate_bundle_identity "$APP_DIR" || exit 2

# A running installed copy must quit through the typed current-line boundary;
# otherwise LaunchServices could silently reopen /Applications instead of the
# freshly built candidate this task is meant to exercise.
for installed_app in "/Applications/Wrenflow.app" "$HOME/Applications/Wrenflow.app"; do
    if [[ -d "$installed_app" && "$installed_app" != "$APP_DIR" ]]; then
        wrenflow_request_typed_quit "$installed_app" 100 || exit 2
    fi
done
open "$APP_DIR" --args "$@"

APP_PID=""
for _ in $(seq 1 100); do
    APP_PID="$(wrenflow_verified_pids "$APP_DIR" | head -1 || true)"
    [[ -n "$APP_PID" ]] && break
    sleep 0.1
done
[[ -n "$APP_PID" ]] || { echo "LaunchServices did not start Wrenflow" >&2; exit 2; }
[[ "$(wrenflow_verified_pids "$APP_DIR" | wc -l | tr -d ' ')" == "1" ]] || {
    echo "LaunchServices left multiple Wrenflow processes" >&2
    exit 2
}

APP_INFO="$(lsappinfo info -only bundlepath,bundleid,pid -app "$APP_PID")"
RUNNING_APP="$(sed -n 's/.*"LSBundlePath"="\([^"]*\)".*/\1/p' <<<"$APP_INFO")"
[[ -n "$RUNNING_APP" && -d "$RUNNING_APP" && ! -L "$RUNNING_APP" ]] || {
    echo "Could not resolve the exact running Wrenflow bundle: $APP_INFO" >&2
    exit 2
}
[[ "$RUNNING_APP" == "$APP_DIR" ]] || {
    echo "LaunchServices started $RUNNING_APP instead of exact candidate $APP_DIR" >&2
    exit 2
}
RUNNING_SIGNING="$(codesign --display --verbose=4 "$RUNNING_APP" 2>&1)"
grep -Fq "Identifier=$BUNDLE_ID" <<<"$RUNNING_SIGNING"
grep -Fq "TeamIdentifier=$TEAM_ID" <<<"$RUNNING_SIGNING"

# SIGUSR2 is a current-line typed show-settings request. The native shell
# installs its DispatchSource during process preflight, so the signal is safe
# even before AppModel has finished initializing; the request is retained and
# later enters AppAction::Navigate(Settings).
kill -USR2 "$APP_PID"
printf 'running_bundle=%s\npid=%s\nshow_signal=SIGUSR2\n' "$RUNNING_APP" "$APP_PID"
