#!/usr/bin/env bash

# Shared fail-closed process identity boundary for lifecycle tooling. Callers
# must set the intended bundle path before looking up or signalling a process.
WRENFLOW_PRODUCTION_BUNDLE_ID="me.gulya.wrenflow"
WRENFLOW_PRODUCTION_TEAM_ID="T4LV8K9BGV"

wrenflow_candidate_pids() {
    pgrep -x wrenflow || true
}

wrenflow_process_info() {
    lsappinfo info -only bundlepath,bundleid,pid -app "$1" 2>/dev/null || true
}

wrenflow_bundle_path_from_info() {
    sed -n 's/.*"LSBundlePath"="\([^"]*\)".*/\1/p' <<<"$1"
}

wrenflow_validate_bundle_identity() {
    local bundle_path="$1" bundle_id signing_info
    [[ -d "$bundle_path" && ! -L "$bundle_path" ]] || {
        echo "Refusing missing or symlinked Wrenflow bundle: $bundle_path" >&2
        return 78
    }
    bundle_id="$(plutil -extract CFBundleIdentifier raw "$bundle_path/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$bundle_id" == "$WRENFLOW_PRODUCTION_BUNDLE_ID" ]] || {
        echo "Refusing bundle identifier '$bundle_id' at $bundle_path" >&2
        return 78
    }
    codesign --verify --deep --strict "$bundle_path" >/dev/null 2>&1 || {
        echo "Refusing invalid Wrenflow signature at $bundle_path" >&2
        return 78
    }
    signing_info="$(codesign --display --verbose=4 "$bundle_path" 2>&1)"
    grep -Fq "Identifier=$WRENFLOW_PRODUCTION_BUNDLE_ID" <<<"$signing_info" &&
        grep -Fq "TeamIdentifier=$WRENFLOW_PRODUCTION_TEAM_ID" <<<"$signing_info" || {
            echo "Refusing non-production Wrenflow identity at $bundle_path" >&2
            return 78
        }
}

wrenflow_verified_pids() {
    local expected_bundle="$1" pid info running_bundle
    wrenflow_validate_bundle_identity "$expected_bundle" || return
    for pid in $(wrenflow_candidate_pids); do
        [[ "$pid" =~ ^[0-9]+$ ]] || {
            echo "Refusing non-numeric Wrenflow PID: $pid" >&2
            return 78
        }
        info="$(wrenflow_process_info "$pid")"
        [[ "$info" == *"\"CFBundleIdentifier\"=\"$WRENFLOW_PRODUCTION_BUNDLE_ID\""* ]] || continue
        running_bundle="$(wrenflow_bundle_path_from_info "$info")"
        [[ -n "$running_bundle" && "$running_bundle" == "$expected_bundle" ]] || {
            echo "Refusing same-ID Wrenflow process $pid from '${running_bundle:-unknown}'; expected $expected_bundle" >&2
            return 78
        }
        wrenflow_validate_bundle_identity "$running_bundle" || return
        printf '%s\n' "$pid"
    done
}

wrenflow_require_no_same_id_process() {
    local pid info running_bundle
    for pid in $(wrenflow_candidate_pids); do
        info="$(wrenflow_process_info "$pid")"
        [[ "$info" == *"\"CFBundleIdentifier\"=\"$WRENFLOW_PRODUCTION_BUNDLE_ID\""* ]] || continue
        running_bundle="$(wrenflow_bundle_path_from_info "$info")"
        echo "Refusing live same-ID Wrenflow process $pid from '${running_bundle:-unknown}'" >&2
        return 78
    done
}

wrenflow_request_typed_quit() {
    local expected_bundle="$1" attempts="${2:-100}" pids pid remaining
    if ! pids="$(wrenflow_verified_pids "$expected_bundle")"; then
        return 78
    fi
    for pid in $pids; do
        if ! kill -USR1 "$pid"; then
            echo "Could not send typed SIGUSR1 quit to verified PID $pid" >&2
            return 79
        fi
    done
    for _ in $(seq 1 "$attempts"); do
        remaining=""
        for pid in $pids; do
            if kill -0 "$pid" >/dev/null 2>&1 &&
               [[ "$(ps -p "$pid" -o stat= 2>/dev/null || true)" != Z* ]]; then
                remaining="${remaining}${remaining:+ }$pid"
            fi
        done
        [[ -z "$remaining" ]] && return 0
        sleep 0.1
    done
    echo "Verified Wrenflow process did not complete typed shutdown within $((attempts / 10)) seconds" >&2
    printf '%s\n' "$remaining" >&2
    return 79
}
