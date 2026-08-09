#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "usage: capture-instruments.sh <absolute-Wrenflow.app> <template> <duration-seconds> <absolute-output.trace>" >&2
    exit 64
}

[[ $# -eq 4 ]] || usage
APP_PATH="$1"
TEMPLATE="$2"
DURATION="$3"
OUTPUT="$4"

case "$APP_PATH" in
    /*.app) ;;
    *) echo "Candidate must be an absolute .app path" >&2; exit 65 ;;
esac
[[ -d "$APP_PATH" && ! -L "$APP_PATH" ]] || {
    echo "Candidate is missing or symlinked: $APP_PATH" >&2
    exit 66
}
case "$OUTPUT" in
    /*.trace) ;;
    *) echo "Trace output must be an absolute .trace path" >&2; exit 65 ;;
esac
[[ ! -e "$OUTPUT" && ! -L "$OUTPUT" ]] || {
    echo "Refusing to overwrite trace output: $OUTPUT" >&2
    exit 73
}
[[ "$DURATION" =~ ^[1-9][0-9]*$ ]] || {
    echo "Duration must be a positive integer number of seconds" >&2
    exit 64
}

case "$TEMPLATE" in
    "Activity Monitor" | "Allocations" | "Animation Hitches" | "Audio System Trace" | \
    "Leaks" | "Power Profiler" | "System Trace" | "Time Profiler") ;;
    *) echo "Template is not in the GPUI performance contract: $TEMPLATE" >&2; exit 65 ;;
esac

INFO_PLIST="$APP_PATH/Contents/Info.plist"
EXECUTABLE="$APP_PATH/Contents/MacOS/wrenflow"
[[ -f "$INFO_PLIST" && -f "$EXECUTABLE" && ! -L "$EXECUTABLE" ]] || {
    echo "Candidate bundle layout is invalid" >&2
    exit 66
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")" == "me.gulya.wrenflow" ]] || {
    echo "Candidate bundle identifier is not me.gulya.wrenflow" >&2
    exit 65
}
/usr/bin/codesign --verify --deep --strict "$APP_PATH"
SIGNING="$(/usr/bin/codesign -dv --verbose=4 "$APP_PATH" 2>&1)"
grep -Fq 'TeamIdentifier=T4LV8K9BGV' <<<"$SIGNING" || {
    echo "Candidate is not signed by the Wrenflow team" >&2
    exit 65
}

MATCHES=()
while IFS= read -r PID; do
    [[ -n "$PID" ]] || continue
    COMMAND="$(/bin/ps -p "$PID" -o comm= 2>/dev/null || true)"
    [[ "$COMMAND" == "$EXECUTABLE" ]] && MATCHES+=("$PID")
done < <(/usr/bin/pgrep -x wrenflow || true)
[[ ${#MATCHES[@]} -eq 1 ]] || {
    echo "Expected exactly one LaunchServices process for $EXECUTABLE; found ${#MATCHES[@]}" >&2
    exit 67
}
PID="${MATCHES[0]}"
APP_INFO="$(/usr/bin/lsappinfo info -only bundlepath,bundleid,pid -app "$PID" 2>/dev/null || true)"
grep -Fq '"CFBundleIdentifier"="me.gulya.wrenflow"' <<<"$APP_INFO" || {
    echo "PID $PID is not registered as the production bundle" >&2
    exit 67
}
grep -Fq "\"LSBundlePath\"=\"$APP_PATH\"" <<<"$APP_INFO" || {
    echo "PID $PID LaunchServices path does not match the candidate" >&2
    exit 67
}

mkdir -p "$(dirname "$OUTPUT")"
exec /usr/bin/xcrun xctrace record \
    --template "$TEMPLATE" \
    --attach "$PID" \
    --time-limit "${DURATION}s" \
    --output "$OUTPUT" \
    --no-prompt
