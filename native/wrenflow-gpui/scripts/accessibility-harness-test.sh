#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS="$SCRIPT_DIR/accessibility-self-test.sh"
FIXTURE_ROOT="$(mktemp -d /tmp/wrenflow-accessibility-harness.XXXXXX)"
cleanup_fixture() {
    rm -rf "$FIXTURE_ROOT"
}
trap cleanup_fixture EXIT

if WRENFLOW_TEST_APP="relative/Wrenflow.app" "$HARNESS" >/dev/null 2>&1; then
    echo "Accessibility harness accepted a relative candidate path" >&2
    exit 1
fi

mkdir -p "$FIXTURE_ROOT/Unsigned.app"
if WRENFLOW_TEST_APP="$FIXTURE_ROOT/Unsigned.app" "$HARNESS" >/dev/null 2>&1; then
    echo "Accessibility harness accepted a non-Wrenflow bundle name" >&2
    exit 1
fi

mkdir -p "$FIXTURE_ROOT/Unsigned/Wrenflow.app"
if WRENFLOW_TEST_APP="$FIXTURE_ROOT/Unsigned/Wrenflow.app" "$HARNESS" >/dev/null 2>&1; then
    echo "Accessibility harness accepted an unsigned candidate" >&2
    exit 1
fi

ln -s "$FIXTURE_ROOT/Unsigned/Wrenflow.app" "$FIXTURE_ROOT/Wrenflow.app"
if WRENFLOW_TEST_APP="$FIXTURE_ROOT/Wrenflow.app" "$HARNESS" >/dev/null 2>&1; then
    echo "Accessibility harness followed a candidate symlink" >&2
    exit 1
fi

grep -Fq 'APP_PATH="${WRENFLOW_TEST_APP:-$REPO_DIR/build/gpui/Wrenflow.app}"' "$HARNESS"
grep -Fq 'codesign --verify --deep --strict "$APP_PATH"' "$HARNESS"
grep -Fq 'TEAM_ID" != "T4LV8K9BGV"' "$HARNESS"
if sed -n '/\[tasks.hardening-accessibility\]/,/^$/p' "$SCRIPT_DIR/../../../mise.toml" | \
    grep -Fq 'depends = ["build"]'; then
    echo "Candidate accessibility smoke must not rebuild a different app" >&2
    exit 1
fi

echo "Accessibility candidate-path and no-rebuild invariants pass"
