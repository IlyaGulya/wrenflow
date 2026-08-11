#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS="$REPO_DIR/scripts/perf/gpui-performance.py"
BUDGETS="$REPO_DIR/support/performance/budgets-v1.json"
TRANSCRIPTION_FIXTURE="$REPO_DIR/support/performance/transcription-fixture-v1.json"
FIXTURE_DOWNLOADER="$REPO_DIR/scripts/perf/download-transcription-fixture.sh"
FIXTURES="$REPO_DIR/scripts/fixtures/performance"
DOC="$REPO_DIR/docs/gpui-performance-budgets.md"
WORKFLOW="$REPO_DIR/.github/workflows/performance-preflight.yml"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wrenflow-performance-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

export PYTHONPYCACHEPREFIX="$TEST_ROOT/pycache"
mise exec -- python3 -m py_compile "$HARNESS"
mise exec -- jq -e '
  .schema_version == 1 and
  .budget_version == "gpui-performance-v1" and
  .workload.idle_seconds == 1800 and
  (.required_instruments_templates | length) == 7 and
  .supporting_instruments_templates == ["Power Profiler"] and
  ((.required_instruments_templates - .supporting_instruments_templates) | length) == 7 and
  ((.supporting_instruments_templates - .required_instruments_templates) | length) == 1 and
  ([.budgets[].comparison] | all(. == "<=" or . == ">=" or . == "==")) and
  ([.budgets[] | select(.metric == "cycles.completed.count" or .metric == "history.rows.count") | .comparison] | all(. == "==")) and
  ([.budgets[] | select(.metric == "idle.cpu.avg_percent" or .metric == "idle.cpu.p95_percent" or .metric == "idle.energy.avg_impact" or .metric == "idle.energy.p95_impact") | .min_samples] | all(. == 1800)) and
  ([.budgets[] | select(.metric == "idle.wakeups.avg_per_s" or .metric == "idle.wakeups.p95_per_s") | .min_samples] | all(. == 1799)) and
  ([.evidence_policy.constrained_noninteractive[], .evidence_policy.post_event_tap_synthetic[], .evidence_policy.physical_interactive[]] | length) == (.budgets | length) and
  ([.evidence_policy.constrained_noninteractive[], .evidence_policy.post_event_tap_synthetic[], .evidence_policy.physical_interactive[]] | unique | length) == (.budgets | length)
' "$BUDGETS" >/dev/null
mise exec -- jq -e '
  .schema_version == 1 and
  .fixture_id == "whispercpp-jfk-pcm16-v1" and
  (.source.commit | test("^[0-9a-f]{40}$")) and
  (.sha256 | test("^[0-9a-f]{64}$")) and
  .bytes == 352078 and
  .audio.channels == 1 and
  .audio.sample_rate_hz == 16000 and
  .audio.bits_per_sample == 16
' "$TRANSCRIPTION_FIXTURE" >/dev/null
grep -Fq 'gpui-performance-v1' "$DOC"
grep -Fq -- '--performance-self-test' "$DOC"
grep -Fq 'WRENFLOW_PERFORMANCE_SELF_TEST=gpui-performance-v1' "$DOC"
grep -Fq 'WRENFLOW_PERFORMANCE_INTERACTION=synthetic-in-process-v1' "$DOC"
grep -Fq 'tcc_or_microphone_evidence=false' "$DOC"
grep -Fq 'substituting a standalone' "$DOC"
grep -Fq 'test binary' "$DOC"
grep -Fq 'runs-on: macos-14' "$WORKFLOW"
grep -Fq -- '--expect-github-macos14' "$WORKFLOW"
grep -Fq '/Applications/Xcode_16.2.app/Contents/Developer' "$WORKFLOW"
grep -Fq 'scripts/perf/download-transcription-fixture.sh' "$WORKFLOW"
grep -Fq 'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a' "$WORKFLOW"
grep -Fq '[tasks.performance-preflight]' "$REPO_DIR/mise.toml"
grep -Fq '[tasks.performance-self-test]' "$REPO_DIR/mise.toml"
grep -Fq '[tasks.performance-leaks]' "$REPO_DIR/mise.toml"
grep -Fq '[tasks.performance-merge-cold]' "$REPO_DIR/mise.toml"
grep -Fq '[tasks.performance-verify]' "$REPO_DIR/mise.toml"
mise exec -- python3 "$HARNESS" --help | grep -Fq 'self-test'
mise exec -- python3 "$HARNESS" --help | grep -Fq 'leaks'
mise exec -- python3 "$HARNESS" --help | grep -Fq 'merge-cold'
mise exec -- python3 "$HARNESS" launch --help | grep -Fq -- '--malloc-stack-logging'
mise exec -- python3 "$HARNESS" self-test --help | grep -Fq -- '--interaction'
grep -Fq '"-o", "comm="' "$HARNESS"
if grep -Fq '"-o", "command="' "$HARNESS"; then
    echo "Exact PID verifier regressed to argv-bearing ps command output" >&2
    exit 1
fi
mise exec -- python3 -c '
import inspect, runpy, sys
module = runpy.run_path(sys.argv[1])
assert module["parse_memory"]("38M-") == 38
assert module["parse_memory"]("1.5G+") == 1536
assert module["REQUIRED_TEMPLATES"].isdisjoint(module["SUPPORTING_TEMPLATES"])
assert len(module["REQUIRED_TEMPLATES"]) == 7
assert module["SUPPORTING_TEMPLATES"] == {"Power Profiler"}
failure = module["launch_failure_message"]
assert failure(
    saw_exact_pid=True,
    exact_pid_running=True,
    startup_observed=True,
    ready_observed=False,
    ui_element_observed=False,
) == "exact candidate emitted startup but not menu_bar_ready"
assert failure(
    saw_exact_pid=True,
    exact_pid_running=True,
    startup_observed=True,
    ready_observed=True,
    ui_element_observed=False,
) == "exact candidate emitted readiness but LaunchServices did not report UIElement"
assert module["launch_ready_at_ms"](1100, 1300) == 1300
assert module["launch_ready_at_ms"](1400, 1300) == 1400
measure_source = inspect.getsource(module["measure_launch"])
assert "if pid is not None:\n                try:\n                    terminate_exact(identity, pid)" in measure_source
' "$HARNESS"

mise exec -- python3 -c '
import json, pathlib, runpy, sys
module = runpy.run_path(sys.argv[1])
diagnostics = pathlib.Path(sys.argv[2])
records = [
    {"timestamp_unix_ms": 999, "session_id": "s-0123456789abcdef", "code": "menu_bar_ready"},
    {"timestamp_unix_ms": 1000, "session_id": "s-0123456789abcdef", "code": "startup"},
    {"timestamp_unix_ms": 1001, "session_id": "s-other0000000000", "code": "menu_bar_ready"},
]
diagnostics.write_text("".join(json.dumps(record) + "\n" for record in records), encoding="utf-8")
assert module["launch_diagnostic_state"](diagnostics, 1000) == (True, None)
records.append(
    {"timestamp_unix_ms": 1002, "session_id": "s-0123456789abcdef", "code": "menu_bar_ready"}
)
diagnostics.write_text("".join(json.dumps(record) + "\n" for record in records), encoding="utf-8")
startup, ready = module["launch_diagnostic_state"](diagnostics, 1000)
assert startup and ready["timestamp_unix_ms"] == 1002

old_records = [
    {"timestamp_unix_ms": 998, "session_id": "s-old000000000000", "code": "startup"},
    {"timestamp_unix_ms": 999, "session_id": "s-old000000000000", "code": "menu_bar_ready"},
]
diagnostics.write_text("".join(json.dumps(record) + "\n" for record in old_records), encoding="utf-8")
assert module["launch_diagnostic_state"](diagnostics, 1000) == (False, None)
' "$HARNESS" "$TEST_ROOT/launch-diagnostics.ndjson"

mise exec -- python3 -c '
import runpy, sys
module = runpy.run_path(sys.argv[1])
base = {
    "host": {
        "missing_required_templates": [],
        "missing_supporting_templates": ["Power Profiler"],
        "evidence_eligibility": {},
    },
    "candidate": {}, "source": {}, "phases": {},
}
failures = module["check_provenance"](base, "fixture")
assert not any("missing Instruments templates" in failure for failure in failures)
base["host"]["missing_required_templates"] = ["Time Profiler"]
failures = module["check_provenance"](base, "fixture")
assert any(
    "missing Instruments templates" in failure and "Time Profiler" in failure
    for failure in failures
)
' "$HARNESS"

mise exec -- python3 -c '
import runpy, sys
module = runpy.run_path(sys.argv[1])
summary = "Process 4242: 0 leaks for 0 total leaked bytes.\n"
assert module["parse_leaks_summary"](summary, expected_pid=4242) == (0, 0)
summary = "Process 4242: 1 leak for 64 total leaked bytes.\n"
assert module["parse_leaks_summary"](summary, expected_pid=4242) == (1, 64)
for invalid in (
    "Process 7: 0 leaks for 0 total leaked bytes.\n",
    "Process 4242: 0 leaks for 64 total leaked bytes.\n",
    "Process 4242: no leaks found\n",
):
    try:
        module["parse_leaks_summary"](invalid, expected_pid=4242)
    except module["EvidenceError"]:
        pass
    else:
        raise SystemExit("leaks summary verifier accepted invalid output")
' "$HARNESS"

mise exec -- python3 -c '
import argparse, json, pathlib, runpy, sys
module = runpy.run_path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
base_path = root / "merge-base.json"
identity = {
    "bundle_tree_sha256": "b" * 64,
    "executable_sha256": "c" * 64,
    "cdhash": "d" * 40,
    "bundle_version": "fixture",
    "bundle_build": "fixture",
    "developer_id_signed": True,
    "architectures": ["arm64"],
}
base = {
    "schema_version": 1,
    "budget_version": "gpui-performance-v1",
    "source": {"commit": "a" * 40, "dirty": False},
    "host": {}, "candidate": identity, "metrics": {}, "phases": {}, "traces": [],
    "sealed": False,
}
shard_paths = []
for index in range(5):
    latency = 100 + index
    shard = {
        "schema_version": 1,
        "budget_version": "gpui-performance-v1",
        "source": {"commit": "a" * 40, "dirty": False},
        "host": {
            "missing_required_templates": [],
            "evidence_eligibility": {
                "github_m1_7gb_constrained_preflight": True,
                "physical_supported_interactive": False,
                "physical_base_m1_8gib_macos14": False,
            },
        },
        "candidate": identity,
        "candidate_id": "candidate-fixture",
        "metrics": {"launch.cold.p95_ms": {"value": latency, "sample_count": 1, "evidence": []}},
        "phases": {"launch_cold": {
            "phase": "launch_cold",
            "definition": module["CONSTRAINED_COLD_DEFINITION"],
            "samples": [{
                "started_at_unix_ms": 1000 + index,
                "ready_at_unix_ms": 1000 + index + latency,
                "diagnostic_ready_at_unix_ms": 1000 + index + latency - 1,
                "ui_element_observed_at_unix_ms": 1000 + index + latency,
                "latency_ms": latency,
                "session_id": f"s-{index:016x}",
                "fresh_runner_id": f"gh-12345-1-cold-{index + 1}",
            }],
        }},
        "traces": [], "sanitized": True, "sealed": True,
    }
    shard["evidence_sha256"] = module["canonical_hash"](shard)
    path = root / f"cold-{index}.json"
    path.write_text(json.dumps(shard), encoding="utf-8")
    shard_paths.append(str(path))
merge = module["merge_cold_launch"]
merge.__globals__["require_app"] = lambda _: pathlib.Path("/tmp/Wrenflow.app")
merge.__globals__["load_result"] = lambda path, app: base
merge(argparse.Namespace(
    app="/tmp/Wrenflow.app", result=str(base_path), candidate_id="candidate-fixture", shard=shard_paths,
))
merged = json.loads(base_path.read_text(encoding="utf-8"))
assert merged["metrics"]["launch.cold.p95_ms"]["value"] == 104
assert merged["metrics"]["launch.cold.p95_ms"]["sample_count"] == 5
assert len(merged["aggregations"]["launch_cold"]["sealed_shard_sha256"]) == 5
try:
    merge(argparse.Namespace(
        app="/tmp/Wrenflow.app", result=str(base_path), candidate_id="candidate-fixture", shard=shard_paths[:4],
    ))
except module["EvidenceError"]:
    pass
else:
    raise SystemExit("cold merge accepted fewer than five fresh-runner shards")
' "$HARNESS" "$TEST_ROOT"

mise exec -- python3 -c '
import copy, io, math, runpy, sys
module = runpy.run_path(sys.argv[1])
assert module["TOP_EVENT_COUNT_MODE"] == "e"
reader = module["start_line_reader"](io.StringIO("header one\nheader two\npid row\n"))
reader_items = [reader.get(timeout=1) for _ in range(4)]
assert [item[0] if item is not None else None for item in reader_items] == [
    "header one\n", "header two\n", "pid row\n", None,
]

BASELINE_ELAPSED = 0.5
BASELINE_WALL_MS = 1_000_000
BASELINE_WAKEUPS = 100

def make_samples(intervals):
    samples = []
    elapsed = BASELINE_ELAPSED
    wall_ms = BASELINE_WALL_MS
    counter = BASELINE_WAKEUPS
    for index, interval in enumerate(intervals):
        elapsed = round(elapsed + interval, 6)
        wall_ms += max(1, round(interval * 1000))
        counter += 1
        samples.append({
            "timestamp_unix_ms": wall_ms,
            "elapsed_seconds": elapsed,
            "observed_interval_seconds": round(interval, 6),
            "cpu_percent": float(index % 2),
            "rss_mib": 100.0,
            "threads": 4,
            "idle_wakeups_counter": counter,
            "idle_wakeups_per_s": round(1.0 / interval, 6),
            "energy_impact": float((index + 1) % 2),
            "file_descriptors": 8,
            "file_descriptors_measured": index % 5 == 0,
        })
    return samples

def summarize(samples, *, duration=1800.0, require_full_count=True):
    return module["sampling_summary"](
        samples,
        baseline_elapsed_seconds=BASELINE_ELAPSED,
        baseline_at_unix_ms=BASELINE_WALL_MS,
        baseline_idle_wakeups=BASELINE_WAKEUPS,
        requested_duration_seconds=duration,
        requested_interval_seconds=1.0,
        require_full_count=require_full_count,
        require_full_duration=True,
    )

samples = make_samples([1.11] * 1800)
summary = summarize(samples)
assert summary["observed_sample_count"] == 1800
assert summary["wall_coverage_seconds"] == 1998.0
assert summary["average_observed_interval_seconds"] == 1.11

def rejected(samples, message, *, duration=1800.0, require_full_count=True):
    try:
        summarize(samples, duration=duration, require_full_count=require_full_count)
    except module["EvidenceError"]:
        return
    raise SystemExit(message)

# Exact CI shape: full wall duration but only 1623 rows cannot satisfy unchanged budgets.
rejected(
    make_samples([1800.0 / 1623.0] * 1623),
    "sampling contract accepted the exact undersampled CI shape",
)
rejected(make_samples([0.9] * 1800), "sampling contract accepted short wall coverage")
rejected(make_samples([1.26] * 1800), "sampling contract accepted too-low effective cadence")
long_gap = make_samples([1.0] * 1799 + [2.01])
rejected(long_gap, "sampling contract accepted an overlong gap")

duplicate_wall = copy.deepcopy(samples)
duplicate_wall[10]["timestamp_unix_ms"] = duplicate_wall[9]["timestamp_unix_ms"]
rejected(duplicate_wall, "sampling contract accepted duplicate wall timestamps")
forward_wall_jump = copy.deepcopy(samples)
for sample in forward_wall_jump[10:]:
    sample["timestamp_unix_ms"] += 5_000
rejected(forward_wall_jump, "sampling contract accepted a wall-clock jump")
reordered_mono = copy.deepcopy(samples)
reordered_mono[10]["elapsed_seconds"] = reordered_mono[9]["elapsed_seconds"]
rejected(reordered_mono, "sampling contract accepted reordered monotonic timestamps")
nonfinite = copy.deepcopy(samples)
nonfinite[10]["observed_interval_seconds"] = math.nan
rejected(nonfinite, "sampling contract accepted a non-finite interval")
reset_counter = copy.deepcopy(samples)
reset_counter[10]["idle_wakeups_counter"] = reset_counter[9]["idle_wakeups_counter"] - 1
rejected(reset_counter, "sampling contract accepted an idle-wakeup counter reset")

assert math.isclose(module["idle_wakeup_rate"](10, 11, 1.1), 0.909090909, abs_tol=1e-9)
weighted = [
    {"cpu_percent": 0.0, "observed_interval_seconds": 1.0},
    {"cpu_percent": 3.0, "observed_interval_seconds": 2.0},
]
assert module["time_weighted_mean"](weighted, "cpu_percent") == 2.0

phase = {
    "phase": "idle",
    "requested_duration_seconds": 1800.0,
    "sample_interval_seconds": 1.0,
    "sampling": summary,
    "samples": samples,
}
metrics = {}
def metric(key, value, count):
    metrics[key] = {"value": round(float(value), 6), "sample_count": count, "evidence": []}
metric("idle.duration_seconds", summary["wall_coverage_seconds"], 1)
metric("idle.cpu.avg_percent", module["time_weighted_mean"](samples, "cpu_percent"), 1800)
metric("idle.cpu.p95_percent", module["percentile"](sample["cpu_percent"] for sample in samples), 1800)
metric("idle.wakeups.avg_per_s", module["time_weighted_mean"](samples, "idle_wakeups_per_s"), 1800)
metric("idle.wakeups.p95_per_s", module["percentile"](sample["idle_wakeups_per_s"] for sample in samples), 1800)
metric("idle.energy.avg_impact", module["time_weighted_mean"](samples, "energy_impact"), 1800)
metric("idle.energy.p95_impact", module["percentile"](sample["energy_impact"] for sample in samples), 1800)
result = {"phases": {"idle": phase}, "metrics": metrics}
assert module["check_idle_sampling"](result, "fixture") == []
result["metrics"]["idle.cpu.avg_percent"]["value"] += 0.1
assert any("differs from raw idle samples" in failure for failure in module["check_idle_sampling"](result, "fixture"))
' "$HARNESS"

if "$FIXTURE_DOWNLOADER" relative-fixture.wav >/dev/null 2>&1; then
    echo "Fixture downloader accepted a relative destination" >&2
    exit 1
fi
printf 'not the pinned fixture' > "$TEST_ROOT/corrupt.wav"
if "$FIXTURE_DOWNLOADER" "$TEST_ROOT/corrupt.wav" >/dev/null 2>&1; then
    echo "Fixture downloader accepted an existing corrupt fixture" >&2
    exit 1
fi
ln -s "$TEST_ROOT/corrupt.wav" "$TEST_ROOT/symlink.wav"
if "$FIXTURE_DOWNLOADER" "$TEST_ROOT/symlink.wav" >/dev/null 2>&1; then
    echo "Fixture downloader accepted a symlink destination" >&2
    exit 1
fi
if [[ -f "$REPO_DIR/vendor/whisper.cpp/samples/jfk.wav" ]]; then
    EXPECTED_FIXTURE_SHA="$(mise exec -- jq -r '.sha256' "$TRANSCRIPTION_FIXTURE")"
    ACTUAL_FIXTURE_SHA="$(shasum -a 256 "$REPO_DIR/vendor/whisper.cpp/samples/jfk.wav" | awk '{print $1}')"
    [[ "$ACTUAL_FIXTURE_SHA" == "$EXPECTED_FIXTURE_SHA" ]]
fi

EMPTY_ROOT="$TEST_ROOT/empty-root"
mkdir -p "$EMPTY_ROOT"
mise exec -- python3 -c '
import runpy, sys
module = runpy.run_path(sys.argv[1])
assert module["validate_empty_disposable_root"](sys.argv[2]).is_absolute()
' "$HARNESS" "$EMPTY_ROOT"
printf 'occupied' > "$EMPTY_ROOT/unexpected"
if mise exec -- python3 -c '
import runpy, sys
module = runpy.run_path(sys.argv[1])
module["validate_empty_disposable_root"](sys.argv[2])
' "$HARNESS" "$EMPTY_ROOT" >/dev/null 2>&1; then
    echo "Self-test root verifier accepted a non-empty root" >&2
    exit 1
fi

CACHE_ROOT="$TEST_ROOT/model-cache"
CACHE_DATA_ROOT="$TEST_ROOT/cache-data-root"
mkdir -p "$CACHE_ROOT" "$CACHE_DATA_ROOT"
mise exec -- python3 -c '
import hashlib, pathlib, runpy, sys
module = runpy.run_path(sys.argv[1])
cache = pathlib.Path(sys.argv[2])
assets = [
  "encoder-model.int8.onnx", "decoder_joint-model.int8.onnx", "nemo128.onnx",
  "vocab.txt", "config.json",
]
lines = [
  "format=2",
  "model_id=parakeet-tdt-0.6b-v3-onnx",
  "repo_id=istupakov/parakeet-tdt-0.6b-v3-onnx",
  "revision=8f23f0c03c8761650bdb5b40aaf3e40d2c15f1ce",
]
for index, name in enumerate(assets):
  data = f"asset-{index}".encode()
  (cache / name).write_bytes(data)
  lines.append(f"asset={name} size={len(data)} sha256={hashlib.sha256(data).hexdigest()} modified_ns=1")
(cache / ".wrenflow-model-ready").write_text("\n".join(lines) + "\n", encoding="utf-8")
module["stage_verified_model_cache"](cache, pathlib.Path(sys.argv[3]))
destination = pathlib.Path(sys.argv[3]) / module["CURRENT_DATA_NAMESPACE"] / "models/parakeet-tdt"
assert not (destination / ".wrenflow-model-ready").exists()
assert sorted(path.name for path in destination.iterdir()) == sorted(assets)
' "$HARNESS" "$CACHE_ROOT" "$CACHE_DATA_ROOT"

INTERACTION_REPORT="$TEST_ROOT/performance-interaction-v1.json"
mise exec -- python3 -c '
import json, runpy, sys
module = runpy.run_path(sys.argv[1])
report = {
  "schema_version": 1,
  "classification": "post_event_tap_synthetic",
  "source": "signed_wrenflow_typed_hotkey_callback",
  "key_code": 96,
  "pulses": {
    "requested": 20,
    "completed": 20,
    "generation_uptime_ms": [1000 + index * 1000 for index in range(20)],
    "overlay_ms": [12.5] * 20,
    "paste_dispatch_ms": [900.0] * 20,
  },
  "hold": {"requested_ms": 60000, "observed_ms": 60000.5, "overlay_ms": 13.0, "paste_dispatch_ms": 60900.0},
  "tcc_or_microphone_evidence": False,
  "passed": True,
  "failure_code": None,
}
with open(sys.argv[2], "w", encoding="utf-8") as handle:
  json.dump(report, handle)
module["validate_interaction_report"](module["pathlib"].Path(sys.argv[2]))
' "$HARNESS" "$INTERACTION_REPORT"
mise exec -- jq '.tcc_or_microphone_evidence = true' "$INTERACTION_REPORT" > "$INTERACTION_REPORT.bad"
mv "$INTERACTION_REPORT.bad" "$INTERACTION_REPORT"
if mise exec -- python3 -c '
import runpy, sys
module = runpy.run_path(sys.argv[1])
module["validate_interaction_report"](module["pathlib"].Path(sys.argv[2]))
' "$HARNESS" "$INTERACTION_REPORT" >/dev/null 2>&1; then
    echo "Interaction verifier accepted a TCC/microphone evidence claim" >&2
    exit 1
fi

SELF_TEST_REPORT="$TEST_ROOT/performance-self-test-v1.json"
mise exec -- python3 -c '
import json, runpy, sys
module = runpy.run_path(sys.argv[1])
manifest = json.load(open(sys.argv[2], encoding="utf-8"))
audio = manifest["audio"]
report = {
  "schema_version": 1,
  "contract": "gpui-performance-self-test-v1",
  "fixture": {
    "id": manifest["fixture_id"], "sha256": manifest["sha256"], "bytes": manifest["bytes"],
    "channels": audio["channels"], "sample_rate_hz": audio["sample_rate_hz"],
    "bits_per_sample": audio["bits_per_sample"], "duration_ms": int(audio["duration_seconds"] * 1000),
  },
  "process": {"pid": 4242},
  "session_id": "s-0123456789abcdef",
  "model": {
    "id": "parakeet-tdt-0.6b-v3-onnx",
    "revision": "8f23f0c03c8761650bdb5b40aaf3e40d2c15f1ce",
    "engine_instances": 1, "warmed": True, "downloaded": True,
  },
  "requested": {"cycles": 20, "history_rows": 50},
  "completed": {"cycles": 20, "history_rows": 50},
  "history": {"schema_version": 1, "integrity_ok": True},
  "timings": {
    "ready_at_unix_ms": 1000, "started_at_unix_ms": 1100, "completed_at_unix_ms": 3100,
    "model_download_ms": 500, "model_cold_load_ms": 200, "total_ms": 2000,
    "cycles_ms": [50] * 20,
  },
  "quit_requested": True, "passed": True, "failure_code": None,
}
with open(sys.argv[3], "w", encoding="utf-8") as handle:
  json.dump(report, handle)
module["validate_self_test_report"](
  module["pathlib"].Path(sys.argv[3]), expected_pid=4242, fixture_manifest=manifest
)
' "$HARNESS" "$TRANSCRIPTION_FIXTURE" "$SELF_TEST_REPORT"
mise exec -- python3 -c '
import json, sys
path = sys.argv[1]
report = json.load(open(path, encoding="utf-8"))
report["transcript"] = "must never leave the app"
with open(path, "w", encoding="utf-8") as handle:
  json.dump(report, handle)
' "$SELF_TEST_REPORT"
if mise exec -- python3 -c '
import json, runpy, sys
module = runpy.run_path(sys.argv[1])
manifest = json.load(open(sys.argv[2], encoding="utf-8"))
module["validate_self_test_report"](
  module["pathlib"].Path(sys.argv[3]), expected_pid=4242, fixture_manifest=manifest
)
' "$HARNESS" "$TRANSCRIPTION_FIXTURE" "$SELF_TEST_REPORT" >/dev/null 2>&1; then
    echo "Self-test report verifier accepted a private transcript field" >&2
    exit 1
fi

mise exec -- python3 "$HARNESS" preflight --output "$TEST_ROOT/preflight.json" >/dev/null
mise exec -- jq -e '
  .schema_version == 1 and
  (.host.architecture == "arm64") and
  (.host.missing_required_templates == []) and
  ((.host.missing_supporting_templates - ["Power Profiler"]) == []) and
  (.host | has("platform_UUID") | not) and
  (.host | has("serial_number") | not)
' "$TEST_ROOT/preflight.json" >/dev/null

HISTORY_DB="$TEST_ROOT/history.sqlite"
mise exec -- python3 -c '
import sqlite3, sys
database = sqlite3.connect(sys.argv[1])
database.executescript("""
CREATE TABLE pipeline_history (
  id TEXT PRIMARY KEY,
  timestamp REAL NOT NULL,
  transcript TEXT NOT NULL DEFAULT "",
  custom_vocabulary TEXT NOT NULL DEFAULT "",
  audio_file_name TEXT,
  metrics_json TEXT NOT NULL DEFAULT "{}"
);
PRAGMA user_version = 1;
""")
database.executemany(
    "INSERT INTO pipeline_history (id, timestamp) VALUES (?, ?)",
    [(f"fixture-{index:02d}", float(index)) for index in range(50)],
)
database.commit()
' "$HISTORY_DB"
mise exec -- python3 -c '
import pathlib, runpy, sys
module = runpy.run_path(sys.argv[1])
result = {"metrics": {}}
module["add_history_count"](result, pathlib.Path(sys.argv[2]))
assert result["metrics"]["history.rows.count"]["value"] == 50
' "$HARNESS" "$HISTORY_DB"
mise exec -- python3 -c '
import sqlite3, sys
database = sqlite3.connect(sys.argv[1])
database.execute("PRAGMA user_version = 0")
database.commit()
' "$HISTORY_DB"
if mise exec -- python3 -c '
import pathlib, runpy, sys
module = runpy.run_path(sys.argv[1])
module["add_history_count"]({"metrics": {}}, pathlib.Path(sys.argv[2]))
' "$HARNESS" "$HISTORY_DB" >/dev/null 2>&1; then
    echo "History verifier accepted a non-current schema" >&2
    exit 1
fi
mise exec -- python3 -c '
import runpy, sys
module = runpy.run_path(sys.argv[1])
phase = {
    "diagnostics": [
        {"code": "transcription_completed", "correlation_id": "c1", "timestamp_unix_ms": 1000},
        {"code": "transcription_completed", "correlation_id": "c2", "timestamp_unix_ms": 1100},
    ],
    "samples": [
        {"timestamp_unix_ms": 1200, "rss_mib": 10.0, "file_descriptors": 5, "threads": 4},
    ],
    "sample_interval_seconds": 1,
}
try:
    module["add_cycle_growth_metrics"]({"metrics": {}}, phase)
except module["EvidenceError"]:
    pass
else:
    raise SystemExit("cycle verifier reused one resource sample for multiple completions")
' "$HARNESS"
mise exec -- python3 -c '
import runpy, sys
module = runpy.run_path(sys.argv[1])
phase = {
    "diagnostics": [
        {"code": "transcription_started", "correlation_id": "direct-1", "timestamp_unix_ms": 1000},
        {"code": "transcription_completed", "correlation_id": "direct-1", "timestamp_unix_ms": 1400},
        {"code": "recording_started", "correlation_id": "typed-1", "timestamp_unix_ms": 1500},
        {"code": "transcription_started", "correlation_id": "typed-1", "timestamp_unix_ms": 1600},
        {"code": "transcription_completed", "correlation_id": "typed-1", "timestamp_unix_ms": 1700},
        {"code": "transcription_started", "correlation_id": "direct-2", "timestamp_unix_ms": 2000},
        {"code": "transcription_completed", "correlation_id": "direct-2", "timestamp_unix_ms": 2400},
        {"code": "recording_started", "correlation_id": "typed-2", "timestamp_unix_ms": 2500},
        {"code": "transcription_completed", "correlation_id": "typed-2", "timestamp_unix_ms": 2600},
    ],
    "samples": [
        {"timestamp_unix_ms": 1450, "rss_mib": 10.0, "file_descriptors": 5, "threads": 4, "cpu_percent": 20.0, "energy_impact": 1.0},
        {"timestamp_unix_ms": 2450, "rss_mib": 11.0, "file_descriptors": 5, "threads": 4, "cpu_percent": 21.0, "energy_impact": 1.1},
        {"timestamp_unix_ms": 2650, "rss_mib": 11.0, "file_descriptors": 5, "threads": 4, "cpu_percent": 1.0, "energy_impact": 0.1},
    ],
    "sample_interval_seconds": 1,
}
result = {"metrics": {}}
module["add_cycle_growth_metrics"](result, phase)
assert result["metrics"]["cycles.completed.count"]["value"] == 2
assert result["metrics"]["cycles.completed.count"]["sample_count"] == 1
' "$HARNESS"

mise exec -- python3 "$HARNESS" verify \
    --profile smoke \
    --result "$FIXTURES/smoke-pass.json" \
    --budgets "$BUDGETS" \
    --report "$TEST_ROOT/pass-report.json" >/dev/null
mise exec -- jq -e '.passed == true and .evaluated_metrics == 1' "$TEST_ROOT/pass-report.json" >/dev/null

mise exec -- jq '
  .candidate = {
    app_path:"/Users/private/Wrenflow.app",
    executable_path:"/Users/private/Wrenflow.app/Contents/MacOS/wrenflow",
    bundle_tree_sha256:("b" * 64)
  } |
  .sealed = false
' "$FIXTURES/smoke-pass.json" > "$TEST_ROOT/unsanitized.json"
if mise exec -- python3 "$HARNESS" seal \
    --result "$TEST_ROOT/unsanitized.json" \
    --candidate-id unsafe >/dev/null 2>&1; then
    echo "Sealer accepted evidence containing local paths" >&2
    exit 1
fi
mise exec -- python3 "$HARNESS" sanitize --result "$TEST_ROOT/unsanitized.json" >/dev/null
mise exec -- jq -e '
  .sanitized == true and
  (.candidate | has("app_path") | not) and
  (.candidate | has("executable_path") | not)
' "$TEST_ROOT/unsanitized.json" >/dev/null
mise exec -- python3 "$HARNESS" seal \
    --result "$TEST_ROOT/unsanitized.json" \
    --candidate-id sanitized-fixture >/dev/null

if mise exec -- python3 "$HARNESS" verify \
    --profile smoke \
    --result "$FIXTURES/smoke-fail.json" \
    --budgets "$BUDGETS" >/dev/null 2>&1; then
    echo "Over-budget fixture unexpectedly passed" >&2
    exit 1
fi

mise exec -- python3 "$FIXTURES/generate-hybrid-verifier-fixture.py" \
    "$BUDGETS" "$TEST_ROOT/constrained.json" "$TEST_ROOT/physical.json"
mise exec -- python3 "$HARNESS" verify \
    --profile release \
    --result "$TEST_ROOT/constrained.json" \
    --companion-result "$TEST_ROOT/physical.json" \
    --budgets "$BUDGETS" \
    --report "$TEST_ROOT/hybrid-report.json" >/dev/null
mise exec -- jq -e '
  .passed == true and
  .evaluated_metrics > 25 and
  ([.evidence_sets[].role] | sort == ["constrained_noninteractive", "physical_interactive"])
' "$TEST_ROOT/hybrid-report.json" >/dev/null
mise exec -- python3 "$HARNESS" verify \
    --profile constrained \
    --result "$TEST_ROOT/constrained.json" \
    --budgets "$BUDGETS" \
    --report "$TEST_ROOT/constrained-report.json" >/dev/null
mise exec -- jq -e '
  .passed == true and
  ([.evidence_sets[].role] == ["constrained_noninteractive"])
' "$TEST_ROOT/constrained-report.json" >/dev/null
if mise exec -- python3 "$HARNESS" verify \
    --profile release \
    --result "$TEST_ROOT/constrained.json" \
    --budgets "$BUDGETS" >/dev/null 2>&1; then
    echo "Constrained-only evidence unexpectedly passed the hybrid release gate" >&2
    exit 1
fi

mise exec -- xcrun swiftc "$REPO_DIR/scripts/perf/overlay-observer.swift" \
    -o "$TEST_ROOT/overlay-observer"
"$TEST_ROOT/overlay-observer" "$$" 0.01 > "$TEST_ROOT/overlay.ndjson"
mise exec -- jq -e 'select(.event == "observer_ready")' "$TEST_ROOT/overlay.ndjson" >/dev/null

mise exec -- xcrun swiftc "$REPO_DIR/scripts/perf/paste-target.swift" \
    -o "$TEST_ROOT/paste-target"
"$TEST_ROOT/paste-target" --self-test > "$TEST_ROOT/paste.ndjson"
mise exec -- jq -e '
  select(.event == "self_test" and .privacy == "character_count_only")
' "$TEST_ROOT/paste.ndjson" >/dev/null

if "$REPO_DIR/scripts/perf/capture-instruments.sh" \
    relative.app "Not A Contract Template" 10 relative.trace >/dev/null 2>&1; then
    echo "Trace wrapper accepted unsafe paths/template" >&2
    exit 1
fi

echo "GPUI performance harness fail-closed tests passed"
