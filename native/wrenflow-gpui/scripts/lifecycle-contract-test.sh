#!/usr/bin/env bash
set -euo pipefail

CRATE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$CRATE_DIR/../.." && pwd)"

for script in install-app.sh uninstall-app.sh reset-app-data.sh lifecycle-self-test.sh run-app.sh verified-app-process.sh verified-app-process-test.sh; do
    bash -n "$CRATE_DIR/scripts/$script"
done
"$CRATE_DIR/scripts/verified-app-process-test.sh"

if "$CRATE_DIR/scripts/install-app.sh" --dry-run --target /tmp/Wrenflow.app >/dev/null 2>&1; then
    echo "install-app accepted an unsafe target" >&2
    exit 65
fi
if "$CRATE_DIR/scripts/uninstall-app.sh" --dry-run --target /tmp/Wrenflow.app >/dev/null 2>&1; then
    echo "uninstall-app accepted an unsafe target" >&2
    exit 65
fi
if "$CRATE_DIR/scripts/reset-app-data.sh" >/dev/null 2>&1; then
    echo "reset-app-data accepted an implicit destructive scope" >&2
    exit 65
fi

"$CRATE_DIR/scripts/install-app.sh" --dry-run --target "$HOME/Applications/Wrenflow.app" >/dev/null
"$CRATE_DIR/scripts/uninstall-app.sh" --dry-run --target "$HOME/Applications/Wrenflow.app" >/dev/null
grep -Fq '<string>me.gulya.wrenflow</string>' "$CRATE_DIR/macos/Info.plist"
grep -Fq '<key>LSUIElement</key>' "$CRATE_DIR/macos/Info.plist"
[[ "$(plutil -extract LSUIElement raw "$CRATE_DIR/macos/Info.plist")" == "true" ]]
grep -Fq 'ApplePersistenceIgnoreState' "$CRATE_DIR/macos/WrenflowShell.swift"
grep -Fq 'makeSignalSource(signal: SIGUSR2' "$CRATE_DIR/macos/WrenflowShell.swift"
grep -Fq 'kill -USR2 "$APP_PID"' "$CRATE_DIR/scripts/run-app.sh"
grep -Fq 'makeSignalSource(signal: SIGUSR1' "$CRATE_DIR/macos/WrenflowShell.swift"
grep -Fq 'kill -USR1 "$pid"' "$CRATE_DIR/scripts/verified-app-process.sh"
grep -Fq 'existing.bundleURL?.resolvingSymlinksInPath().standardizedFileURL' "$CRATE_DIR/macos/WrenflowShell.swift"
grep -Fq 'existing.executableURL?.resolvingSymlinksInPath().standardizedFileURL' "$CRATE_DIR/macos/WrenflowShell.swift"
for script in install-app.sh reset-app-data.sh lifecycle-self-test.sh; do
    if rg -n 'kill[[:space:]]+-TERM|osascript' "$CRATE_DIR/scripts/$script"; then
        echo "$script bypasses typed SIGUSR1 shutdown" >&2
        exit 65
    fi
done
for forbidden in \
    wrenflow_shell_open_url \
    update_url \
    updateURL \
    openUpdatePage \
    'func openURL(' \
    'Open Update Page' \
    ShellOpenUrlFailed; do
    if rg -Fq "$forbidden" \
        "$CRATE_DIR/src/shell.rs" \
        "$CRATE_DIR/src/main.rs" \
        "$CRATE_DIR/macos/WrenflowShell.swift" \
        "$REPO_DIR/core/wrenflow-runtime/src/diagnostics.rs" \
        "$REPO_DIR/docs/gpui-macos-shell.md" \
        "$REPO_DIR/docs/gpui-runtime-architecture.md"; then
        echo "Generic update URL surface remains: $forbidden" >&2
        exit 65
    fi
done
grep -Fq 'x-apple.systempreferences:com.apple.preference.security?' "$CRATE_DIR/macos/WrenflowShell.swift"
[[ "$(rg -c 'NSWorkspace\.shared\.open\(' "$CRATE_DIR/macos/WrenflowShell.swift")" == "1" ]] || {
    echo "Swift shell must expose only the fixed permission-settings opener" >&2
    exit 65
}
! grep -Fq 'WrenflowApplicationDelegateProxy' "$CRATE_DIR/macos/WrenflowShell.swift"
[[ "$(rg -c 'claimSingleInstance\(\)' "$CRATE_DIR/macos/WrenflowShell.swift")" == "2" ]] || {
    echo "single-instance claim must run only at the early Rust/Swift boundary" >&2
    exit 65
}
if rg -Fq 'merge_legacy_preferences' "$REPO_DIR/core/wrenflow-runtime/src/supervisor.rs"; then
    echo "Current GPUI runtime still contains a legacy preference importer" >&2
    exit 65
fi

echo "WRENFLOW_LIFECYCLE_CONTRACT_OK"
