#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$REPO_DIR/scripts/gpui-owner-smoke.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wrenflow-owner-smoke-test.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

ROOT="$TEST_ROOT/disposable"
SESSION="$(mise exec -- "$TOOL" prepare-root "$ROOT")"
[[ "$SESSION" =~ ^[0-9a-f]{32}$ ]]
[[ -d "$ROOT" && ! -L "$ROOT" && "$(/usr/bin/stat -f '%Lp' "$ROOT")" == 700 ]]
[[ -z "$(find "$ROOT" -mindepth 1 -maxdepth 1 -print -quit)" ]]

if mise exec -- "$TOOL" prepare-root "$ROOT" >"$TEST_ROOT/reuse.out" 2>"$TEST_ROOT/reuse.err"; then
    echo "owner-smoke root preparation reused an existing root" >&2
    exit 1
fi
[[ -z "$(find "$ROOT" -mindepth 1 -maxdepth 1 -print -quit)" ]]

ln -s "$TEST_ROOT/missing" "$TEST_ROOT/link"
if mise exec -- "$TOOL" prepare-root "$TEST_ROOT/link" >"$TEST_ROOT/link.out" 2>"$TEST_ROOT/link.err"; then
    echo "owner-smoke root preparation accepted a symlink" >&2
    exit 1
fi

if rg -n 'tccutil|WRENFLOW_PERFORMANCE_|synthetic|Contents/MacOS/wrenflow|__test-launch|WRENFLOW_OWNER_SMOKE_TEST_' "$TOOL"; then
    echo "owner-smoke launcher gained a forbidden test/TCC/direct-executable path" >&2
    exit 1
fi
mise exec -- python3 - "$TOOL" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
required = [
    '/usr/bin/plutil -extract CFBundleIdentifier raw',
    '/usr/bin/codesign --verify --deep --strict --verbose=2',
    'source "$REPO_DIR/native/wrenflow-gpui/scripts/verified-app-process.sh"',
    'PATH="$SYSTEM_PATH" wrenflow_require_no_same_id_process',
]
positions = [source.find(item) for item in required]
if min(positions) < 0 or positions != sorted(positions):
    raise SystemExit(f"signed identity/preflight contract drifted: {positions!r}")
open_block = source[source.find('/usr/bin/open -n'):]
launch_required = [
    '/usr/bin/open -n',
    '--env "WRENFLOW_OWNER_SMOKE_CONTRACT=$CONTRACT"',
    '--env "WRENFLOW_OWNER_SMOKE_DATA_ROOT=$root"',
    '--env "WRENFLOW_OWNER_SMOKE_SESSION=$session"',
    '--env "WRENFLOW_OWNER_SMOKE_LAUNCH=$launch"',
    '"$app"',
    '--args --owner-smoke',
    'PATH="$SYSTEM_PATH" wrenflow_verified_pids "$app"',
]
launch_positions = [open_block.find(item) for item in launch_required]
if min(launch_positions) < 0 or launch_positions != sorted(launch_positions):
    raise SystemExit(f"signed LaunchServices/current-PID contract drifted: {launch_positions!r}")
PY

mise exec -- python3 - "$REPO_DIR/native/wrenflow-gpui/src/main.rs" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
owner = source.find("prepare_owner_smoke(&arguments)")
performance = source.find("prepare_performance_self_test(&arguments)")
diagnostics = source.find("initialize_production_diagnostics()")
recovery = source.find("run_reset_helper_from_args(&arguments)")
if min(owner, performance, diagnostics, recovery) < 0 or not owner < performance < recovery < diagnostics:
    raise SystemExit("owner-smoke root is not derived before every production path surface")
PY

echo "Owner-smoke gate source and preparation tests passed"
