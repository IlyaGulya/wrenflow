#!/usr/bin/env bash
set -euo pipefail

CONTRACT="wrenflow-owner-smoke-v1"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SYSTEM_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

usage() {
    cat >&2 <<'USAGE'
Usage:
  gpui-owner-smoke.sh prepare-root <absolute-new-disposable-root>
  gpui-owner-smoke.sh launch <absolute-Wrenflow.app> <absolute-disposable-root> <32-lowercase-hex-session>

prepare-root prints the session id that must be retained outside the data root
and reused for every launch in the same S01/S02/L01/L02 observation. launch
uses LaunchServices only. It does not alter TCC, user settings, or production data.
USAGE
}

canonical_parent() {
    local path="$1"
    local parent
    parent="$(dirname "$path")"
    [[ "$path" == /* && "$path" != *"/../"* && "$path" != *"/./"* && "$path" != */.. && "$path" != */. ]] || return 1
    [[ -d "$parent" && ! -L "$parent" ]] || return 1
    [[ "$(cd "$parent" && pwd -P)/$(basename "$path")" == "$path" ]] || return 1
}

case "${1:-}" in
    prepare-root)
        [[ $# -eq 2 ]] || { usage; exit 64; }
        root="$2"
        canonical_parent "$root" || { echo "owner-smoke root must be a canonical absolute path below an existing non-symlink parent" >&2; exit 64; }
        [[ ! -e "$root" && ! -L "$root" ]] || { echo "owner-smoke root must be new" >&2; exit 64; }
        /bin/mkdir -m 700 "$root"
        [[ -d "$root" && ! -L "$root" && "$(/usr/bin/stat -f '%Lp' "$root")" == 700 ]] || exit 65
        session="$(mise exec -- python3 -c 'import secrets; print(secrets.token_hex(16))')"
        [[ "$session" =~ ^[0-9a-f]{32}$ ]] || exit 65
        printf '%s\n' "$session"
        ;;
    launch)
        [[ $# -eq 4 ]] || { usage; exit 64; }
        app="$2"
        root="$3"
        session="$4"
        [[ "$app" == /* && -d "$app" && ! -L "$app" && "$app" == *.app ]] || { echo "owner-smoke app must be an absolute non-symlink app copy" >&2; exit 64; }
        [[ "$root" == /* && -d "$root" && ! -L "$root" && "$(/usr/bin/stat -f '%Lp' "$root")" == 700 ]] || { echo "owner-smoke root must remain a mode-0700 absolute non-symlink directory" >&2; exit 64; }
        [[ "$session" =~ ^[0-9a-f]{32}$ ]] || { echo "owner-smoke session must be 32 lowercase hex characters" >&2; exit 64; }
        [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")" == "me.gulya.wrenflow" ]] || { echo "owner-smoke app bundle identity is invalid" >&2; exit 65; }
        /usr/bin/codesign --verify --deep --strict --verbose=2 "$app" >/dev/null 2>&1 || { echo "owner-smoke app signature verification failed" >&2; exit 65; }
        signing="$(/usr/bin/codesign --display --verbose=4 "$app" 2>&1)"
        /usr/bin/grep -Fq 'Identifier=me.gulya.wrenflow' <<<"$signing" || { echo "owner-smoke app signing identifier is invalid" >&2; exit 65; }
        /usr/bin/grep -Fq 'TeamIdentifier=T4LV8K9BGV' <<<"$signing" || { echo "owner-smoke app signing team is invalid" >&2; exit 65; }
        # shellcheck source=native/wrenflow-gpui/scripts/verified-app-process.sh
        source "$REPO_DIR/native/wrenflow-gpui/scripts/verified-app-process.sh"
        PATH="$SYSTEM_PATH" wrenflow_require_no_same_id_process
        launch="$(mise exec -- python3 -c 'import secrets; print(secrets.token_hex(16))')"
        [[ "$launch" =~ ^[0-9a-f]{32}$ ]] || exit 65
        /usr/bin/open -n \
            --env "WRENFLOW_OWNER_SMOKE_CONTRACT=$CONTRACT" \
            --env "WRENFLOW_OWNER_SMOKE_DATA_ROOT=$root" \
            --env "WRENFLOW_OWNER_SMOKE_SESSION=$session" \
            --env "WRENFLOW_OWNER_SMOKE_LAUNCH=$launch" \
            "$app" \
            --args --owner-smoke
        ready="$root/.wrenflow-owner-smoke-ready-v1.json"
        for _ in $(/usr/bin/seq 1 200); do
            if [[ -f "$ready" && ! -L "$ready" && "$(/usr/bin/stat -f '%Lp' "$ready")" == 600 ]]; then
                pid="$(mise exec -- jq -er \
                    --arg contract "$CONTRACT" --arg session "$session" --arg launch "$launch" '
                      if (keys | sort) == (["contract","launch_id","pid","session_id","state"] | sort) and
                         .contract == $contract and .session_id == $session and
                         .launch_id == $launch and .state == "terminal_window_policy_ready" and
                         (.pid | type == "number" and . > 0 and floor == .)
                      then .pid else error("not current owner-smoke readiness") end
                    ' "$ready" 2>/dev/null || true)"
                if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
                    pids="$(PATH="$SYSTEM_PATH" wrenflow_verified_pids "$app")"
                    if [[ "$pids" == "$pid" ]]; then
                        printf 'owner-smoke terminal readiness confirmed for PID %s session %s\n' "$pid" "$session"
                        exit 0
                    fi
                fi
            fi
            /bin/sleep 0.1
        done
        echo "owner-smoke did not produce current exact terminal readiness" >&2
        exit 66
        ;;
    *)
        usage
        exit 64
        ;;
esac
