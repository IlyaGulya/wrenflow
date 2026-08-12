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
  .workload.launch_samples.cold == 20 and
  .toolchain_policy.constrained == "exact Xcode 16.2 selected on the GitHub-hosted macos-14 runner" and
  (.toolchain_policy.physical_interactive | contains("actual selected non-unknown Xcode")) and
  ([.budgets[] | select(.metric == "launch.cold.p95_ms") | .min_samples] == [20]) and
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
grep -Fq -- '--retain-ui --malloc-stack-logging' "$DOC"
grep -Fq 'mutually exclusive with the synthetic' "$DOC"
if grep -Fq 'retained command above. Both scans' "$DOC" && grep -Fq 'add `--sudo`' "$DOC"; then
    echo "Retained documentation advertises unsupported sudo plumbing" >&2
    exit 1
fi
grep -Fq 'performance-retained-ack' "$DOC"
grep -Fq 'same signed PID' "$DOC"
grep -Fq 'actual selected compatible Xcode version/build' "$DOC"
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
mise exec -- python3 "$HARNESS" self-test --help | grep -Fq -- '--idle-duration'
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
assert module["parse_top_counter"]("0") == 0
assert module["parse_top_counter"]("132+") == 132
assert module["parse_top_counter"]("999+") == 999
for invalid_counter in ("", "+", "132-", "+132", "132++", "-1", "1.0", "N/A"):
    try:
        module["parse_top_counter"](invalid_counter)
    except module["EvidenceError"]:
        continue
    raise AssertionError(f"invalid top counter was accepted: {invalid_counter!r}")
assert module["REQUIRED_TEMPLATES"].isdisjoint(module["SUPPORTING_TEMPLATES"])
assert len(module["REQUIRED_TEMPLATES"]) == 7
assert module["SUPPORTING_TEMPLATES"] == {"Power Profiler"}
failure = module["launch_failure_message"]
assert failure(
    saw_exact_pid=True,
    exact_pid_running=True,
    startup_observed=True,
    ready_observed=False,
    terminal_observed=False,
    expected_application_type=None,
    launch_services_observations=None,
) == "exact candidate emitted startup but not menu_bar_ready"
assert failure(
    saw_exact_pid=True,
    exact_pid_running=True,
    startup_observed=True,
    ready_observed=True,
    terminal_observed=False,
    expected_application_type=None,
    launch_services_observations=None,
) == "exact candidate emitted menu_bar_ready but no terminal window policy diagnostic"

app = module["pathlib"].Path("/private/candidate/Wrenflow.app")
exact_info = "\n".join((
    "\"LSBundlePath\"=\"/private/candidate/Wrenflow.app\"",
    "\"CFBundleIdentifier\"=\"me.gulya.wrenflow\"",
    "\"pid\"=4242",
    "\"ApplicationType\"=\"UIElement\"",
))
state = module["sanitized_launch_services_state"](
    exact_info, expected_app=app, expected_pid=4242
)
assert state["returncode"] == 0
assert state["stdout_shape"] == "exact_fields"
assert state["stderr_category"] == "empty"
accessory = {"code": "window_policy_accessory_ready"}
foreground = {"code": "window_policy_foreground_ready"}
assert module["launch_services_state_matches"](state, accessory)
assert not module["launch_services_state_matches"](state, foreground)

# A transient pre-terminal UIElement state cannot satisfy a terminal Foreground route.
foreground_info = exact_info.replace("UIElement", "Foreground")
foreground_state = module["sanitized_launch_services_state"](
    foreground_info, expected_app=app, expected_pid=4242
)
assert module["launch_services_state_matches"](foreground_state, foreground)
assert not module["launch_services_state_matches"](foreground_state, accessory)

for malformed in (
    exact_info.replace("\"pid\"=4242", "\"pid\"=7"),
    exact_info.replace("me.gulya.wrenflow", "me.example.other"),
    exact_info.replace("/private/candidate/Wrenflow.app", "/private/other/Wrenflow.app"),
    exact_info + "\n\"pid\"=4242",
    exact_info.replace("\"ApplicationType\"=\"UIElement\"", ""),
):
    malformed_state = module["sanitized_launch_services_state"](
        malformed, expected_app=app, expected_pid=4242
    )
    assert not module["launch_services_state_matches"](malformed_state, accessory)

private_error_state = module["sanitized_launch_services_state"](
    exact_info,
    expected_app=app,
    expected_pid=4242,
    returncode=1,
    stderr="permission denied for /private/secret/Wrenflow.app",
)
assert private_error_state["stderr_category"] == "permission_denied"
assert not module["launch_services_state_matches"](private_error_state, accessory)

closed_message = failure(
    saw_exact_pid=True,
    exact_pid_running=True,
    startup_observed=True,
    ready_observed=True,
    terminal_observed=True,
    expected_application_type="Foreground",
    launch_services_observations={"count": 2, "first": state, "last": private_error_state},
)
assert "ApplicationType=Foreground" in closed_message
assert "\"application_type\":\"UIElement\"" in closed_message
assert "/private/" not in closed_message
assert "me.gulya.wrenflow" not in closed_message
assert "\"count\":2" in closed_message
assert module["launch_ready_at_ms"](1100, 1300) == 1300
assert module["launch_ready_at_ms"](1400, 1300) == 1400
assert module["GPUI_WINDOW_DIAGNOSTIC_STAGE_CODES"] == {
    "gpui_window_open_started", "gpui_window_callback_entered", "app_screens_ready",
    "gpui_root_ready", "gpui_window_created", "gpui_window_shown",
}
assert (
    set(module["LAUNCH_DIAGNOSTIC_STAGE_CODES"])
    - module["GPUI_WINDOW_DIAGNOSTIC_STAGE_CODES"]
) == {
    "runtime_bootstrap_started", "runtime_bootstrap_ready", "app_callback_entered",
    "app_model_ready", "swift_shell_installed", "tray_projection_ready", "menu_bar_ready",
    "window_policy_route_observed",
}
measure_source = inspect.getsource(module["measure_launch"])
assert "observe_launch_sample" in measure_source
assert "terminate_and_deregister_launch" in measure_source
assert measure_source.index("priming = {") < measure_source.index("for _ in range(args.iterations)")
assert "args.iterations != 10" in measure_source
assert "launch epochs cannot be appended or mixed" in measure_source
self_test_source = inspect.getsource(module["_run_signed_self_test"])
initial_accessory_barrier = self_test_source.index("validate_initial_self_test_accessory")
idle_call = self_test_source.index("phase=\"idle\"")
post_idle_barrier = self_test_source.index("validate_post_idle_self_test_observation")
cycle_call = self_test_source.index("phase=\"cycles_20\"")
start_signal_use = self_test_source.index("start_signal=str(start_signal)")
assert initial_accessory_barrier < idle_call < post_idle_barrier < cycle_call < start_signal_use
assert "except BaseException:" in self_test_source
assert "request_exact_typed_quit(identity, pid)" in self_test_source
retain_guard = self_test_source.index("if args.retain_ui and args.interaction")
launch_retain_env = self_test_source.index("f\"{RETAINED_UI_ENV}={RETAINED_UI_CONTRACT}\"")
workload_ack = self_test_source.index("RETAINED_WORKLOAD_ACK_NAME")
typed_show = self_test_source.index("show_retained_window(")
final_report = self_test_source.index("final_report = validate_self_test_report(")
assert retain_guard < launch_retain_env < workload_ack < typed_show < final_report
assert "performance_retained_window_shown" in inspect.getsource(module["show_retained_window"])
assert "if args.malloc_stack_logging and not args.retain_ui" in self_test_source
assert "launch_command.extend([\"--env\", \"MallocStackLogging=1\"])" in self_test_source
wrapper_source = inspect.getsource(module["run_signed_self_test"])
assert "write_failure_summary" in wrapper_source
sample_source = inspect.getsource(module["sample_phase"])
context_reset = sample_source.index(
    "replace_sampling_failure_context(failure_context_owner, None)"
)
sampler_ended = sample_source.index("process_stderr =")
context_populated = sample_source.index(
    "replace_sampling_failure_context(failure_context_owner, current_failure_context)"
)
report_validation = sample_source.index("report = validate_self_test_report")
assert context_reset < sampler_ended < context_populated < report_validation
accepted_row = sample_source.index("samples.append(sample)")
observer_ack = sample_source.index("observer_ack_evidence = maybe_create_observer_ack")
sample_limit = sample_source.index("if len(samples) >= target_sample_count")
assert accepted_row < observer_ack < sample_limit
reader_delivery = sample_source.index("reader_delivery_delay =")
boundary_detection = sample_source.index("new_boundary_correlations = {")
boundary_fd = sample_source.index("last_fd = count_fds(pid)")
assert reader_delivery < boundary_detection < boundary_fd < accepted_row

owner = module["argparse"].Namespace(
    _sampling_failure_context={
        "sampling_contract": module["IDLE_SAMPLING_CONTRACT"],
        "row_count": 1800,
    }
)
module["replace_sampling_failure_context"](owner, None)
assert owner._sampling_failure_context is None
active_context = {
    "sampling_contract": module["ACTIVE_SAMPLING_CONTRACT"],
    "row_count": 47,
    "history_ready_count": 1,
    "direct_start_count": 20,
    "direct_completion_count": 20,
}
module["replace_sampling_failure_context"](owner, active_context)
summary_error = module["failure_summary_error"](
    module["EvidenceError"]("injected report validation failure"),
    owner._sampling_failure_context,
)
assert isinstance(summary_error, module["SamplingEvidenceError"])
assert summary_error.details == active_context
assert summary_error.details["sampling_contract"] == module["ACTIVE_SAMPLING_CONTRACT"]
assert summary_error.details["row_count"] == 47
assert summary_error.details["direct_start_count"] == 20
assert summary_error.details["direct_completion_count"] == 20
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
startup, ready, terminal, stages = module["launch_diagnostic_state"](diagnostics, 1000)
assert startup["timestamp_unix_ms"] == 1000 and ready is None and terminal is None and stages == {}
records.append(
    {"timestamp_unix_ms": 1002, "session_id": "s-0123456789abcdef", "code": "menu_bar_ready"}
)
diagnostics.write_text("".join(json.dumps(record) + "\n" for record in records), encoding="utf-8")
startup, ready, terminal, stages = module["launch_diagnostic_state"](diagnostics, 1000)
assert startup["timestamp_unix_ms"] == 1000 and ready["timestamp_unix_ms"] == 1002 and terminal is None
assert stages == {"menu_bar_ready": 1002}
records.extend((
    {"timestamp_unix_ms": 1003, "session_id": "s-other0000000000", "code": "window_policy_accessory_ready"},
    {"timestamp_unix_ms": 1004, "session_id": "s-0123456789abcdef", "code": "window_policy_foreground_ready"},
))
diagnostics.write_text("".join(json.dumps(record) + "\n" for record in records), encoding="utf-8")
startup, ready, terminal, stages = module["launch_diagnostic_state"](diagnostics, 1000)
assert startup["timestamp_unix_ms"] == 1000 and ready["timestamp_unix_ms"] == 1002
assert terminal["timestamp_unix_ms"] == 1004
assert terminal["code"] == "window_policy_foreground_ready"
assert stages == {"menu_bar_ready": 1002}

old_records = [
    {"timestamp_unix_ms": 998, "session_id": "s-old000000000000", "code": "startup"},
    {"timestamp_unix_ms": 999, "session_id": "s-old000000000000", "code": "menu_bar_ready"},
]
diagnostics.write_text("".join(json.dumps(record) + "\n" for record in old_records), encoding="utf-8")
assert module["launch_diagnostic_state"](diagnostics, 1000) == (None, None, None, {})
' "$HARNESS" "$TEST_ROOT/launch-diagnostics.ndjson"

mise exec -- python3 -c '
import pathlib, runpy, subprocess, sys
module = runpy.run_path(sys.argv[1])
observer = module["wait_for_route_aware_launch"]
globals_ = observer.__globals__
stage_times = {code: 1001 + index for index, code in enumerate(module["LAUNCH_DIAGNOSTIC_STAGE_CODES"])}
ready = {"timestamp_unix_ms": stage_times["menu_bar_ready"], "session_id": "s-0123456789abcdef", "code": "menu_bar_ready"}
terminal = {"timestamp_unix_ms": stage_times["gpui_window_shown"] + 1, "session_id": "s-0123456789abcdef", "code": "window_policy_foreground_ready"}
diagnostic_states = iter(((True, ready, None, stage_times), (True, ready, terminal, stage_times), (True, ready, terminal, stage_times)))
app_info = iter((
    "\n".join((
        "\"LSBundlePath\"=\"/private/candidate/Wrenflow.app\"",
        "\"CFBundleIdentifier\"=\"me.gulya.wrenflow\"",
        "\"pid\"=4242",
        "\"ApplicationType\"=\"UIElement\"",
    )),
    "\n".join((
        "\"LSBundlePath\"=\"/private/candidate/Wrenflow.app\"",
        "\"CFBundleIdentifier\"=\"me.gulya.wrenflow\"",
        "\"pid\"=4242",
        "\"ApplicationType\"=\"Foreground\"",
    )),
))
lsappinfo_calls = []
query = module["query_launch_services_state"]
def completed_run(argv, **kwargs):
    lsappinfo_calls.append((argv, kwargs))
    return subprocess.CompletedProcess(argv, 0, next(app_info), "")
globals_["subprocess"].run = completed_run
queried = query(app=pathlib.Path("/private/candidate/Wrenflow.app"), pid=4242)
assert queried["application_type"] == "UIElement"
assert lsappinfo_calls[0][1]["timeout"] == module["LSAPPINFO_TIMEOUT_SECONDS"]
assert lsappinfo_calls[0][1]["capture_output"] is True

def timeout_run(argv, **kwargs):
    raise subprocess.TimeoutExpired(argv, kwargs["timeout"])
globals_["subprocess"].run = timeout_run
timed_out = query(app=pathlib.Path("/private/candidate/Wrenflow.app"), pid=4242)
assert timed_out["returncode"] is None
assert timed_out["stderr_category"] == "timeout"
assert timed_out["stdout_shape"] == "empty"

def failed_run(argv, **kwargs):
    raise OSError("private launch services detail /private/secret")
globals_["subprocess"].run = failed_run
invocation_failed = query(app=pathlib.Path("/private/candidate/Wrenflow.app"), pid=4242)
assert invocation_failed["returncode"] is None
assert invocation_failed["stderr_category"] == "invocation_failed"
assert "/private/" not in str(invocation_failed)

# The observer queries only after the terminal route marker. Its first query
# sees a mismatching transient UIElement state and its second sees Foreground.
app_info = iter((
    "\n".join((
        "\"LSBundlePath\"=\"/private/candidate/Wrenflow.app\"",
        "\"CFBundleIdentifier\"=\"me.gulya.wrenflow\"",
        "\"pid\"=4242",
        "\"ApplicationType\"=\"UIElement\"",
    )),
    "\n".join((
        "\"LSBundlePath\"=\"/private/candidate/Wrenflow.app\"",
        "\"CFBundleIdentifier\"=\"me.gulya.wrenflow\"",
        "\"pid\"=4242",
        "\"ApplicationType\"=\"Foreground\"",
    )),
))
observer_queries = []
def fake_query(*, app, pid):
    observer_queries.append(pid)
    return module["sanitized_launch_services_state"](
        next(app_info), expected_app=app, expected_pid=pid
    )
globals_["exact_pid"] = lambda identity, required=False: 4242
startup_record = {"timestamp_unix_ms": 1000, "session_id": "s-0123456789abcdef", "code": "startup"}
diagnostic_states = iter(((startup_record, ready, None, stage_times), (startup_record, ready, terminal, stage_times), (startup_record, ready, terminal, stage_times)))
globals_["launch_diagnostic_state"] = lambda diagnostics, started_ms: next(diagnostic_states)
globals_["query_launch_services_state"] = fake_query
observation = observer(
    app=pathlib.Path("/private/candidate/Wrenflow.app"),
    identity={"executable_path": "/private/candidate/Wrenflow.app/Contents/MacOS/wrenflow"},
    diagnostics=pathlib.Path("/private/diagnostics.ndjson"),
    started_ms=1000,
    timeout_seconds=1,
)
assert observation["pid"] == 4242
assert observation["terminal"] == terminal
# No lsappinfo query happened before the terminal marker, and the transient
# post-marker UIElement mismatch did not satisfy the Foreground contract.
assert len(observer_queries) == 2
' "$HARNESS"

mise exec -- python3 -c '
import argparse, copy, pathlib, runpy, sys
module = runpy.run_path(sys.argv[1])

def sample(index, latency=40, shutdown=True):
    started = 1000 + index * 2000
    value = {
        "started_at_unix_ms": started,
        "startup_diagnostic_at_unix_ms": started + 10,
        "menu_bar_ready_at_unix_ms": started + 20,
        "terminal_policy_ready_at_unix_ms": started + 30,
        "launch_services_observed_at_unix_ms": started + latency,
        "ready_at_unix_ms": started + latency,
        "terminal_application_type": "Foreground",
        "latency_ms": latency,
        "session_id": f"s-{index:016x}",
        "diagnostic_stages_at_unix_ms": {
            "runtime_bootstrap_started": started + 11,
            "runtime_bootstrap_ready": started + 12,
            "app_callback_entered": started + 13,
            "app_model_ready": started + 14,
            "swift_shell_installed": started + 15,
            "tray_projection_ready": started + 16,
            "menu_bar_ready": started + 20,
            "gpui_window_open_started": started + 20,
            "gpui_window_callback_entered": started + 20,
            "app_screens_ready": started + 21,
            "gpui_root_ready": started + 21,
            "gpui_window_created": started + 21,
            "window_policy_route_observed": started + 22,
            "gpui_window_shown": started + 23,
        },
    }
    value["stages_ms"] = module["launch_stage_durations"](value)
    if shutdown:
        value.update({
            "typed_shutdown_requested_at_unix_ms": started + latency + 1,
            "process_terminated_at_unix_ms": started + latency + 2,
            "launch_services_deregistered_at_unix_ms": started + latency + 3,
        })
    return value

prime = {
    "contract": module["WARM_PRIMING_CONTRACT"],
    "metric_contribution": False,
    **sample(0, 1057),
}
warm_samples = [sample(index + 20, latency) for index, latency in enumerate(
    (218, 328, 440, 239, 388, 209, 194, 232, 216, 300)
)]
result = {
    "phases": {"launch_warm": {
        "phase": "launch_warm",
        "definition": module["WARM_LAUNCH_DEFINITION"],
        "priming": prime,
        "samples": warm_samples,
    }},
    "metrics": {"launch.warm.p95_ms": {"value": 440, "sample_count": 10}},
}
launch_failures = module["check_launch_sampling"](result, "fixture")
assert launch_failures == [], launch_failures

for mutate in (
    lambda value: value["phases"]["launch_warm"]["priming"].update(metric_contribution=True),
    lambda value: value["phases"]["launch_warm"]["samples"].pop(),
    lambda value: value["phases"]["launch_warm"]["samples"][1].update(session_id=value["phases"]["launch_warm"]["samples"][0]["session_id"]),
    lambda value: value["phases"]["launch_warm"]["samples"][0].update(started_at_unix_ms=100),
    lambda value: value["phases"]["launch_warm"]["samples"][0]["stages_ms"].update(total_ms=999),
    lambda value: value["phases"]["launch_warm"]["samples"][0]["diagnostic_stages_at_unix_ms"].pop("app_model_ready"),
    lambda value: value["phases"]["launch_warm"]["samples"][0]["diagnostic_stages_at_unix_ms"].update(runtime_bootstrap_ready=999999),
    lambda value: value["metrics"]["launch.warm.p95_ms"].update(value=439),
):
    broken = copy.deepcopy(result)
    mutate(broken)
    assert module["check_launch_sampling"](broken, "fixture")

metric_without_phase = copy.deepcopy(result)
del metric_without_phase["phases"]["launch_warm"]
assert module["check_launch_sampling"](metric_without_phase, "fixture")
phase_without_metric = copy.deepcopy(result)
del phase_without_metric["metrics"]["launch.warm.p95_ms"]
assert module["check_launch_sampling"](phase_without_metric, "fixture")

ls_absent = {
    "returncode": 0,
    "stdout_shape": "empty",
    "stderr_category": "empty",
    "bundle_id_matches": False,
    "bundle_path_matches": False,
    "pid_matches": False,
    "application_type": "missing",
}
assert not module["launch_services_record_absent"](ls_absent)
assert module["launch_services_record_absent"]({
    **ls_absent, "returncode": 1, "stderr_category": "not_found"
})
null_output = "\n".join((
    "\"LSBundlePath\"=[ NULL ] ",
    "\"CFBundleIdentifier\"=[ NULL ] ",
    "\"pid\"=[ NULL ] ",
    "\"ApplicationType\"=[ NULL ] ",
))
null_state = module["sanitized_launch_services_state"](
    null_output,
    expected_app=pathlib.Path("/private/candidate/Wrenflow.app"),
    expected_pid=4242,
)
assert null_state["stdout_shape"] == "null_fields"
assert module["launch_services_record_absent"](null_state)
for key, value in (("stdout_shape", "exact_fields"), ("stderr_category", "permission_denied"), ("pid_matches", True)):
    assert not module["launch_services_record_absent"]({**ls_absent, key: value})

measure = module["measure_launch"]
globals_ = measure.__globals__
captured = {}
failure_base = {"candidate": {"executable_path": "/private/candidate/Wrenflow.app/Contents/MacOS/wrenflow"}, "phases": {}, "metrics": {}}
globals_["require_app"] = lambda value: pathlib.Path("/private/candidate/Wrenflow.app")
globals_["load_result"] = lambda output, app: failure_base
globals_["exact_pid"] = lambda identity, required=False: None
globals_["observe_launch_sample"] = lambda **kwargs: (_ for _ in ()).throw(
    module["EvidenceError"]("injected priming readiness failure")
)
globals_["write_json"] = lambda output, value: (_ for _ in ()).throw(
    AssertionError("failed priming persisted a partial phase")
)
try:
    measure(argparse.Namespace(
        app="unused", output="/private/result.json", mode="warm", iterations=10,
        cold_confirmed=False, fresh_runner_id=None, malloc_stack_logging=False,
        leave_running=False, settle_seconds=1.0, timeout=15.0,
        diagnostics="/private/diagnostics.ndjson",
    ))
except module["EvidenceError"] as error:
    assert "priming readiness failure" in str(error)
else:
    raise AssertionError("failed priming passed")
assert failure_base["phases"] == {} and failure_base["metrics"] == {}

launch_latencies = iter((1057, 218, 328, 440, 239, 388, 209, 194, 232, 216, 300))
launch_count = 0
last_ready = 0
def fake_observe(**kwargs):
    global launch_count, last_ready
    latency = next(launch_latencies)
    value = sample(launch_count + 100, latency, shutdown=False)
    launch_count += 1
    last_ready = value["ready_at_unix_ms"]
    return value, 4242
def fake_terminate(**kwargs):
    return {
        "typed_shutdown_requested_at_unix_ms": last_ready + 1,
        "process_terminated_at_unix_ms": last_ready + 2,
        "launch_services_deregistered_at_unix_ms": last_ready + 3,
    }
base = {"candidate": {"executable_path": "/private/candidate/Wrenflow.app/Contents/MacOS/wrenflow"}, "phases": {}, "metrics": {}}
globals_["load_result"] = lambda output, app: base
globals_["observe_launch_sample"] = fake_observe
globals_["terminate_and_deregister_launch"] = fake_terminate
globals_["write_json"] = lambda output, value: captured.update(result=copy.deepcopy(value))
globals_["time"].sleep = lambda seconds: None
measure(argparse.Namespace(
    app="unused", output="/private/result.json", mode="warm", iterations=10,
    cold_confirmed=False, fresh_runner_id=None, malloc_stack_logging=False,
    leave_running=False, settle_seconds=1.0, timeout=15.0,
    diagnostics="/private/diagnostics.ndjson",
))
assert launch_count == 11
phase = captured["result"]["phases"]["launch_warm"]
assert phase["priming"]["latency_ms"] == 1057
assert phase["priming"]["metric_contribution"] is False
assert len(phase["samples"]) == 10
assert captured["result"]["metrics"]["launch.warm.p95_ms"]["value"] == 440.0
assert captured["result"]["metrics"]["launch.warm.p95_ms"]["sample_count"] == 10

for iterations in (9, 11):
    try:
        measure(argparse.Namespace(
            app="unused", output="/private/result.json", mode="warm", iterations=iterations,
            cold_confirmed=False, fresh_runner_id=None, malloc_stack_logging=False,
            leave_running=False, settle_seconds=1.0, timeout=15.0,
            diagnostics="/private/diagnostics.ndjson",
        ))
    except module["EvidenceError"]:
        pass
    else:
        raise AssertionError("invalid warm measured sample count passed")
' "$HARNESS"

mise exec -- python3 -c '
import pathlib, runpy, sys
module = runpy.run_path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
start_signal = root / "performance-start-post-idle-test"
session = "s-0123456789abcdef"
idle_phase = {
    "started_at_unix_ms": 1000,
    "ended_at_unix_ms": 2000,
    "diagnostics": [
        {"timestamp_unix_ms": 1500, "session_id": "s-other0000000000", "code": "window_policy_apply_failed"},
    ],
}
info = "\n".join((
    "\"LSBundlePath\"=\"/private/candidate/Wrenflow.app\"",
    "\"CFBundleIdentifier\"=\"me.gulya.wrenflow\"",
    "\"pid\"=4242",
    "\"ApplicationType\"=\"UIElement\"",
))
state = module["sanitized_launch_services_state"](
    info,
    expected_app=pathlib.Path("/private/candidate/Wrenflow.app"),
    expected_pid=4242,
)
validate_initial = module["validate_initial_self_test_accessory"]
validate_initial(
    observation={
        "terminal": {"code": "window_policy_accessory_ready"},
        "launch_services_state": state,
    },
    start_signal=start_signal,
)
foreground_initial = dict(state)
foreground_initial["application_type"] = "Foreground"
try:
    validate_initial(
        observation={
            "terminal": {"code": "window_policy_foreground_ready"},
            "launch_services_state": foreground_initial,
        },
        start_signal=start_signal,
    )
except module["EvidenceError"]:
    pass
else:
    raise SystemExit("self-test launch accepted terminal Foreground instead of Accessory/UIElement")
assert not start_signal.exists()

validate = module["validate_post_idle_self_test_observation"]
observation = validate(
    idle_phase=idle_phase,
    session_id=session,
    state=state,
    observed_at_unix_ms=2001,
    start_signal=start_signal,
)
assert observation["observed_at_unix_ms"] == 2001
assert observation["application_type"] == "UIElement"
assert not start_signal.exists()

same_session_failure = dict(idle_phase)
same_session_failure["diagnostics"] = [
    {"timestamp_unix_ms": 1500, "session_id": session, "code": "window_policy_apply_failed"},
]
try:
    validate(
        idle_phase=same_session_failure,
        session_id=session,
        state=state,
        observed_at_unix_ms=2001,
        start_signal=start_signal,
    )
except module["EvidenceError"]:
    pass
else:
    raise SystemExit("post-idle barrier accepted a same-session window policy failure")
assert not start_signal.exists()

foreground = dict(state)
foreground["application_type"] = "Foreground"
try:
    validate(
        idle_phase=idle_phase,
        session_id=session,
        state=foreground,
        observed_at_unix_ms=2001,
        start_signal=start_signal,
    )
except module["EvidenceError"]:
    pass
else:
    raise SystemExit("post-idle barrier accepted Foreground instead of Accessory/UIElement")
assert not start_signal.exists()

start_signal.write_text("premature", encoding="utf-8")
try:
    validate(
        idle_phase=idle_phase,
        session_id=session,
        state=state,
        observed_at_unix_ms=2001,
        start_signal=start_signal,
    )
except module["EvidenceError"]:
    pass
else:
    raise SystemExit("post-idle barrier accepted a pre-existing workload start signal")
' "$HARNESS" "$TEST_ROOT"

mise exec -- python3 -c '
import pathlib, runpy, sys
module = runpy.run_path(sys.argv[1])
test_root = pathlib.Path(sys.argv[2])
session = "s-0123456789abcdef"

def workload_records(count):
    records = []
    for index in range(count):
        correlation = f"direct-{index:02d}"
        records.extend((
            {"timestamp_unix_ms": 1000 + index * 10, "session_id": session, "correlation_id": correlation, "code": "transcription_started"},
            {"timestamp_unix_ms": 1005 + index * 10, "session_id": session, "correlation_id": correlation, "code": "transcription_completed"},
        ))
    return records

readiness = module["observer_ack_readiness"]
nineteen = workload_records(19)
assert not readiness(
    nineteen, session_id=session, resource_row_timestamp_unix_ms=9999
)["ready"]

twenty = workload_records(20)
latest = 1195
assert not readiness(
    twenty, session_id=session, resource_row_timestamp_unix_ms=latest - 1
)["ready"]

missing_start = [
    record for record in twenty
    if not (record["code"] == "transcription_started" and record["correlation_id"] == "direct-19")
]
assert not readiness(
    missing_start, session_id=session, resource_row_timestamp_unix_ms=9999
)["ready"]

rogue_completion = [
    *twenty,
    {"timestamp_unix_ms": 1200, "session_id": session, "correlation_id": "rogue", "code": "transcription_completed"},
]
assert not readiness(
    rogue_completion, session_id=session, resource_row_timestamp_unix_ms=9999
)["ready"]

with_interaction = [
    *twenty,
    {"timestamp_unix_ms": 900, "session_id": session, "correlation_id": "recording-1", "code": "recording_started"},
    {"timestamp_unix_ms": 3000, "session_id": session, "correlation_id": "recording-1", "code": "transcription_started"},
    {"timestamp_unix_ms": 4000, "session_id": session, "correlation_id": "recording-1", "code": "transcription_completed"},
]
accepted = readiness(
    with_interaction, session_id=session, resource_row_timestamp_unix_ms=latest
)
assert accepted["ready"]
assert accepted["started_correlation_count"] == 20
assert accepted["completion_correlation_count"] == 20
assert accepted["latest_completion_timestamp_unix_ms"] == latest

ack_root = test_root / "observer-ack-root"
ack_root.mkdir()
ack = ack_root / module["SELF_TEST_OBSERVER_ACK_NAME"]
maybe_create = module["maybe_create_observer_ack"]
assert maybe_create(
    nineteen,
    session_id=session,
    resource_row_timestamp_unix_ms=9999,
    path=ack,
    data_root=ack_root,
) is None
assert not ack.exists()
assert maybe_create(
    twenty,
    session_id=session,
    resource_row_timestamp_unix_ms=latest - 1,
    path=ack,
    data_root=ack_root,
) is None
assert not ack.exists()
evidence = maybe_create(
    with_interaction,
    session_id=session,
    resource_row_timestamp_unix_ms=latest,
    path=ack,
    data_root=ack_root,
)
assert evidence["name"] == "performance-observer-ack-v1"
assert evidence["bytes"] == 0
assert ack.is_file() and not ack.is_symlink() and ack.stat().st_size == 0

validate_path = module["validate_observer_ack_path"]
for unsafe in (pathlib.Path("relative-ack"), ack_root / "wrong-name"):
    try:
        validate_path(unsafe, data_root=ack_root, require_existing=False)
    except module["EvidenceError"]:
        pass
    else:
        raise SystemExit("observer ack accepted an unsafe path")

preexisting_root = test_root / "observer-ack-preexisting"
preexisting_root.mkdir()
preexisting = preexisting_root / module["SELF_TEST_OBSERVER_ACK_NAME"]
preexisting.write_bytes(b"")
try:
    validate_path(preexisting, data_root=preexisting_root, require_existing=False)
except module["EvidenceError"]:
    pass
else:
    raise SystemExit("observer ack accepted a pre-existing zero-byte file")

nonzero_root = test_root / "observer-ack-nonzero"
nonzero_root.mkdir()
nonzero = nonzero_root / module["SELF_TEST_OBSERVER_ACK_NAME"]
nonzero.write_bytes(b"x")
try:
    validate_path(nonzero, data_root=nonzero_root, require_existing=True)
except module["EvidenceError"]:
    pass
else:
    raise SystemExit("observer ack accepted a nonzero file")

symlink_root = test_root / "observer-ack-symlink"
symlink_root.mkdir()
target = symlink_root / "target"
target.write_bytes(b"")
symlink = symlink_root / module["SELF_TEST_OBSERVER_ACK_NAME"]
symlink.symlink_to(target)
for require_existing in (False, True):
    try:
        validate_path(symlink, data_root=symlink_root, require_existing=require_existing)
    except module["EvidenceError"]:
        pass
    else:
        raise SystemExit("observer ack accepted a symlink")
' "$HARNESS" "$TEST_ROOT"

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
import argparse, copy, json, pathlib, runpy, sys
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
for index in range(20):
    latency = 100 + index
    shard = {
        "schema_version": 1,
        "budget_version": "gpui-performance-v1",
        "source": {"commit": "a" * 40, "dirty": False},
        "host": {
            "os_version": "14.8.7",
            "architecture": "arm64",
            "chip": "Apple M1",
            "machine_model": "VirtualMac2,1",
            "memory_bytes": 7516192768,
            "logical_cpu_count": 3,
            "xcode_version": "Xcode 16.2",
            "github": {
                "actions": True,
                "runner_os": "macOS",
                "runner_arch": "ARM64",
                "runner_environment": "github-hosted",
            },
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
                "startup_diagnostic_at_unix_ms": 1001 + index,
                "ready_at_unix_ms": 1000 + index + latency,
                "menu_bar_ready_at_unix_ms": 1000 + index + latency - 2,
                "terminal_policy_ready_at_unix_ms": 1000 + index + latency - 1,
                "launch_services_observed_at_unix_ms": 1000 + index + latency,
                "terminal_application_type": "Foreground",
                "latency_ms": latency,
                "session_id": f"s-{index:016x}",
                "fresh_runner_id": f"gh-12345-1-cold-{index + 1}",
                "diagnostic_stages_at_unix_ms": {
                    "runtime_bootstrap_started": 1001 + index,
                    "runtime_bootstrap_ready": 1001 + index,
                    "app_callback_entered": 1001 + index,
                    "app_model_ready": 1001 + index,
                    "swift_shell_installed": 1001 + index,
                    "tray_projection_ready": 1001 + index,
                    "menu_bar_ready": 1000 + index + latency - 2,
                    "gpui_window_open_started": 1000 + index + latency - 2,
                    "gpui_window_callback_entered": 1000 + index + latency - 2,
                    "app_screens_ready": 1000 + index + latency - 2,
                    "gpui_root_ready": 1000 + index + latency - 2,
                    "gpui_window_created": 1000 + index + latency - 2,
                    "window_policy_route_observed": 1000 + index + latency - 1,
                    "gpui_window_shown": 1000 + index + latency - 1,
                },
                "stages_ms": {
                    "external_open_to_startup_ms": 1,
                    "startup_to_menu_bar_ms": latency - 3,
                    "menu_bar_to_terminal_policy_ms": 1,
                    "terminal_policy_to_launch_services_ms": 1,
                    "total_ms": latency,
                },
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
assert merged["metrics"]["launch.cold.p95_ms"]["value"] == 118
assert merged["metrics"]["launch.cold.p95_ms"]["sample_count"] == 20
assert len(merged["aggregations"]["launch_cold"]["sealed_shard_sha256"]) == 20
assert merged["aggregations"]["launch_cold"]["contract"] == module["AGGREGATED_COLD_CONTRACT"]
assert merged["aggregations"]["launch_cold"]["raw_max_ms"] == 119
assert module["check_launch_sampling"](merged, "merged") == []
tampered_metric_evidence = copy.deepcopy(merged)
tampered_metric_evidence["metrics"]["launch.cold.p95_ms"]["evidence"].pop()
assert module["check_launch_sampling"](tampered_metric_evidence, "tampered")
tampered_raw_max = copy.deepcopy(merged)
tampered_raw_max["aggregations"]["launch_cold"]["raw_max_ms"] = 118
assert module["check_launch_sampling"](tampered_raw_max, "tampered")

invalid_type = copy.deepcopy(json.loads(pathlib.Path(shard_paths[0]).read_text(encoding="utf-8")))
invalid_type["phases"]["launch_cold"]["samples"][0]["terminal_application_type"] = "Background"
invalid_type["evidence_sha256"] = module["canonical_hash"](invalid_type)
invalid_path = root / "cold-invalid-type.json"
invalid_path.write_text(json.dumps(invalid_type), encoding="utf-8")
try:
    merge(argparse.Namespace(
        app="/tmp/Wrenflow.app",
        result=str(base_path),
        candidate_id="candidate-fixture",
        shard=[str(invalid_path), *shard_paths[1:]],
    ))
except module["EvidenceError"]:
    pass
else:
    raise SystemExit("cold merge accepted an unbounded terminal ApplicationType")

try:
    merge(argparse.Namespace(
        app="/tmp/Wrenflow.app", result=str(base_path), candidate_id="candidate-fixture", shard=shard_paths[:19],
    ))
except module["EvidenceError"]:
    pass
else:
    raise SystemExit("cold merge accepted nineteen fresh-runner shards")

try:
    merge(argparse.Namespace(
        app="/tmp/Wrenflow.app", result=str(base_path), candidate_id="candidate-fixture", shard=[*shard_paths, shard_paths[-1]],
    ))
except module["EvidenceError"]:
    pass
else:
    raise SystemExit("cold merge accepted twenty-one fresh-runner shards")

duplicate_runner = copy.deepcopy(json.loads(pathlib.Path(shard_paths[-1]).read_text(encoding="utf-8")))
duplicate_runner["phases"]["launch_cold"]["samples"][0]["fresh_runner_id"] = "gh-12345-1-cold-1"
duplicate_runner["evidence_sha256"] = module["canonical_hash"](duplicate_runner)
duplicate_path = root / "cold-duplicate-runner.json"
duplicate_path.write_text(json.dumps(duplicate_runner), encoding="utf-8")
try:
    merge(argparse.Namespace(
        app="/tmp/Wrenflow.app", result=str(base_path), candidate_id="candidate-fixture", shard=[*shard_paths[:-1], str(duplicate_path)],
    ))
except module["EvidenceError"]:
    pass
else:
    raise SystemExit("cold merge accepted a duplicate fresh-runner identity")

duplicate_session = copy.deepcopy(json.loads(pathlib.Path(shard_paths[-1]).read_text(encoding="utf-8")))
duplicate_session["phases"]["launch_cold"]["samples"][0]["session_id"] = "s-0000000000000000"
duplicate_session["evidence_sha256"] = module["canonical_hash"](duplicate_session)
duplicate_session_path = root / "cold-duplicate-session.json"
duplicate_session_path.write_text(json.dumps(duplicate_session), encoding="utf-8")
try:
    merge(argparse.Namespace(
        app="/tmp/Wrenflow.app", result=str(base_path), candidate_id="candidate-fixture", shard=[*shard_paths[:-1], str(duplicate_session_path)],
    ))
except module["EvidenceError"]:
    pass
else:
    raise SystemExit("cold merge accepted a duplicate diagnostic session")

mixed = copy.deepcopy(json.loads(pathlib.Path(shard_paths[-1]).read_text(encoding="utf-8")))
mixed["source"]["commit"] = "e" * 40
mixed["evidence_sha256"] = module["canonical_hash"](mixed)
mixed_path = root / "cold-mixed-source.json"
mixed_path.write_text(json.dumps(mixed), encoding="utf-8")
try:
    merge(argparse.Namespace(
        app="/tmp/Wrenflow.app", result=str(base_path), candidate_id="candidate-fixture", shard=[*shard_paths[:-1], str(mixed_path)],
    ))
except module["EvidenceError"]:
    pass
else:
    raise SystemExit("cold merge accepted mixed-source evidence")

tampered_host = copy.deepcopy(json.loads(pathlib.Path(shard_paths[-1]).read_text(encoding="utf-8")))
tampered_host["host"]["os_version"] = "26.5"
tampered_host["evidence_sha256"] = module["canonical_hash"](tampered_host)
tampered_host_path = root / "cold-tampered-host.json"
tampered_host_path.write_text(json.dumps(tampered_host), encoding="utf-8")
try:
    merge(argparse.Namespace(
        app="/tmp/Wrenflow.app", result=str(base_path), candidate_id="candidate-fixture", shard=[*shard_paths[:-1], str(tampered_host_path)],
    ))
except module["EvidenceError"]:
    pass
else:
    raise SystemExit("cold merge accepted re-sealed non-macOS-14 host evidence")
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

def make_samples(intervals, *, counter_delta=1):
    samples = []
    elapsed = BASELINE_ELAPSED
    wall_ms = BASELINE_WALL_MS
    counter = BASELINE_WAKEUPS
    for index, interval in enumerate(intervals):
        persisted_interval = round(interval, 6)
        elapsed = round(elapsed + interval, 6)
        wall_ms += max(1, round(interval * 1000))
        counter += counter_delta
        samples.append({
            "timestamp_unix_ms": wall_ms,
            "elapsed_seconds": elapsed,
            "observed_interval_seconds": persisted_interval,
            "cpu_percent": float(index % 2),
            "rss_mib": 100.0,
            "threads": 4,
            "idle_wakeups_counter": counter,
            "idle_wakeups_per_s": round(counter_delta / persisted_interval, 6),
            "energy_impact": float((index + 1) % 2),
            "file_descriptors": 8,
            "file_descriptors_measured": index % 5 == 0,
            "observer_delivery_delay_seconds": 0.001,
        })
    return samples

def summarize(samples, *, duration=1800.0, contract=None):
    return module["sampling_summary"](
        samples,
        contract=contract or module["IDLE_SAMPLING_CONTRACT"],
        baseline_elapsed_seconds=BASELINE_ELAPSED,
        baseline_at_unix_ms=BASELINE_WALL_MS,
        baseline_idle_wakeups=BASELINE_WAKEUPS,
        requested_duration_seconds=duration,
        requested_interval_seconds=1.0,
    )

raw_quantized_interval = 1.109876543
persisted_quantized_interval = round(raw_quantized_interval, 6)
old_mismatched_rate = round(5.0 / raw_quantized_interval, 6)
recomputed_persisted_rate = 5.0 / persisted_quantized_interval
assert abs(old_mismatched_rate - recomputed_persisted_rate) > 0.000002
quantized_samples = make_samples([raw_quantized_interval], counter_delta=5)
quantized_summary = summarize(quantized_samples, duration=1.0)
assert quantized_summary["observed_sample_count"] == 1
assert math.isclose(
    quantized_samples[0]["idle_wakeups_per_s"],
    recomputed_persisted_rate,
    rel_tol=0.0,
    abs_tol=0.000002,
)

samples = make_samples([1.11] * 1800, counter_delta=5)
summary = summarize(samples)
assert summary["observed_sample_count"] == 1800
assert summary["wall_coverage_seconds"] == 1998.0
assert summary["average_observed_interval_seconds"] == 1.11

def rejected(samples, message, *, duration=1800.0, contract=None):
    try:
        summarize(samples, duration=duration, contract=contract)
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
try:
    summarize(long_gap)
except module["SamplingEvidenceError"] as error:
    failure_details = module["sampling_failure_details"](
        long_gap,
        contract=module["IDLE_SAMPLING_CONTRACT"],
        process_returncode=1,
        process_stderr="private /Users/secret/audio.ogg",
        diagnostics=[],
        session_id=None,
        existing=error.details,
    )
    assert failure_details["first_bad_index"] == 1799
    assert failure_details["first_bad_gap_seconds"] == 2.01
    assert failure_details["row_count"] == 1800
    assert failure_details["gap_p50_seconds"] == 1.0
    assert failure_details["gap_p99_seconds"] == 1.0
    assert failure_details["gap_max_seconds"] == 2.01
    assert failure_details["top_stderr_category"] == "other"
    assert "/Users/" not in str(failure_details)
else:
    raise SystemExit("sampling failure did not expose bounded diagnostic context")

active_contract = module["ACTIVE_SAMPLING_CONTRACT"]
active_with_isolated_gap = make_samples([1.0] * 19 + [2.4])
active_summary = summarize(
    active_with_isolated_gap,
    duration=2400.0,
    contract=active_contract,
)
assert active_summary["contract"] == active_contract
assert "target_sample_count" not in active_summary
assert "maximum_gap_multiplier_limit" not in active_summary
rejected(
    make_samples([1.3] * 20),
    "active sampling accepted sustained undersampling",
    duration=2400.0,
    contract=active_contract,
)

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
    "ready_at_unix_ms": 1000, "started_at_unix_ms": 1100,
    "history_ready_at_unix_ms": 1200, "activation_started_at_unix_ms": 1300,
    "loading_started_at_unix_ms": 1800, "model_ready_at_unix_ms": 2000,
    "warmup_completed_at_unix_ms": 2200, "completed_at_unix_ms": 3100,
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
import copy, json, runpy, sys
module = runpy.run_path(sys.argv[1])
base = 1_000_000
session = "s-0123456789abcdef"
samples = []
elapsed = 0.0
for index, interval in enumerate([1.0, 2.4, *([1.0] * 48)], start=1):
    elapsed += interval
    timestamp = base + round(elapsed * 1000)
    samples.append({
        "timestamp_unix_ms": timestamp,
        "elapsed_seconds": elapsed,
        "observed_interval_seconds": interval,
        "observer_delivery_delay_seconds": 0.001,
        "rss_mib": 100.0 + index,
        "file_descriptors": 8 + index // 10,
        "file_descriptors_measured": False,
        "threads": 4 + index // 20,
        "cpu_percent": 20.0 + index,
        "idle_wakeups_counter": 100 + index,
        "idle_wakeups_per_s": round(1.0 / interval, 6),
        "energy_impact": 1.0 + index / 10,
    })
diagnostics = [{
    "session_id": session,
    "code": "performance_self_test_history_ready",
    "timestamp_unix_ms": base + 100,
}]
for index in range(20):
    correlation = f"direct-{index:02d}"
    started = base + 5000 + index * 2000
    completed = started + 400
    diagnostics.extend([
        {"session_id": session, "code": "transcription_started", "correlation_id": correlation, "timestamp_unix_ms": started},
        {"session_id": session, "code": "transcription_completed", "correlation_id": correlation, "timestamp_unix_ms": completed},
    ])
completion_timestamps = [
    record["timestamp_unix_ms"]
    for record in diagnostics
    if record["code"] == "transcription_completed"
]
mapped_indexes = [
    next(
        index
        for index, sample in enumerate(samples)
        if sample["timestamp_unix_ms"] >= completed
    )
    for completed in completion_timestamps
]
assert len(set(mapped_indexes)) == 20
for index in mapped_indexes:
    samples[index]["file_descriptors_measured"] = True
# A pre-warm peak remains global but must not contaminate post-warm p95.
samples[0]["rss_mib"] = 9999.0
timings = {
    "ready_at_unix_ms": base - 500,
    "started_at_unix_ms": base,
    "history_ready_at_unix_ms": base + 100,
    "activation_started_at_unix_ms": base + 200,
    "loading_started_at_unix_ms": base + 2200,
    "model_ready_at_unix_ms": base + 3200,
    "warmup_completed_at_unix_ms": base + 4000,
    "completed_at_unix_ms": base + 45000,
    "model_download_ms": 2000.0,
    "model_cold_load_ms": 1000.0,
    "total_ms": 45500.0,
    "cycles_ms": [400.0] * 20,
}
sampling = module["sampling_summary"](
    samples,
    contract=module["ACTIVE_SAMPLING_CONTRACT"],
    baseline_elapsed_seconds=0.0,
    baseline_at_unix_ms=base,
    baseline_idle_wakeups=100,
    requested_duration_seconds=2400.0,
    requested_interval_seconds=1.0,
)
manifest = json.loads(module["FIXTURE_MANIFEST"].read_text(encoding="utf-8"))
audio = manifest["audio"]
self_test_report = {
    "schema_version": 1,
    "contract": module["SELF_TEST_CONTRACT"],
    "fixture": {
        "id": manifest["fixture_id"],
        "sha256": manifest["sha256"],
        "bytes": manifest["bytes"],
        "channels": audio["channels"],
        "sample_rate_hz": audio["sample_rate_hz"],
        "bits_per_sample": audio["bits_per_sample"],
        "duration_ms": int(audio["duration_seconds"] * 1000),
    },
    "process": {"pid": 4242},
    "session_id": session,
    "model": {
        "id": module["DEFAULT_MODEL_ID"],
        "revision": module["DEFAULT_MODEL_REVISION"],
        "engine_instances": 1,
        "warmed": True,
        "downloaded": True,
    },
    "requested": {"cycles": 20, "history_rows": 50},
    "completed": {"cycles": 20, "history_rows": 50},
    "history": {"schema_version": 1, "integrity_ok": True},
    "timings": timings,
    "quit_requested": True,
    "passed": True,
    "failure_code": None,
}
phase = {
    "phase": "cycles_20",
    "pid": 4242,
    "diagnostics": diagnostics,
    "samples": samples,
    "sample_interval_seconds": 1.0,
    "requested_duration_seconds": 2400.0,
    "sampling": sampling,
    "self_test_report": self_test_report,
    "observer_ack": {
        "resource_row_timestamp_unix_ms": samples[mapped_indexes[-1]]["timestamp_unix_ms"],
        "latest_completion_timestamp_unix_ms": base + 43400,
        "started_correlation_count": 20,
        "completion_correlation_count": 20,
    },
}
result = {
    "metrics": {},
    "phases": {
        "launch_warm": {"samples": [{"latency_ms": 500}]},
        "cycles_20": phase,
    },
}
module["add_cycle_growth_metrics"](result, phase)
module["update_global_resource_metrics"](result)
module["set_metric"](result, "cycles_20.duration_seconds", sampling["wall_coverage_seconds"], 1)
module["set_metric"](result, "cycles_20.cpu.avg_percent", module["time_weighted_mean"](samples, "cpu_percent"), 50)
module["set_metric"](result, "cycles_20.cpu.p95_percent", module["percentile"](sample["cpu_percent"] for sample in samples), 50)
module["set_metric"](result, "cycles_20.energy.avg_impact", module["time_weighted_mean"](samples, "energy_impact"), 50)
module["set_metric"](result, "cycles_20.energy.p95_impact", module["percentile"](sample["energy_impact"] for sample in samples), 50)
module["set_metric"](result, "cycles_20.wakeups.avg_per_s", module["time_weighted_mean"](samples, "idle_wakeups_per_s"), 50)
module["set_metric"](result, "cycles_20.wakeups.p95_per_s", module["percentile"](sample["idle_wakeups_per_s"] for sample in samples), 50)
post_warm = [sample for sample in samples if sample["timestamp_unix_ms"] >= timings["warmup_completed_at_unix_ms"]]
module["set_metric"](result, "memory.post_warmup.p95_mib", module["percentile"](sample["rss_mib"] for sample in post_warm), len(post_warm))
module["set_metric"](result, "model.download.p95_ms", 2000.0, 1)
module["set_metric"](result, "model.cold_load.p95_ms", 1000.0, 1)
module["set_metric"](result, "history.rows.count", 50, 1)
assert module["check_active_sampling"](result, "fixture") == []

omitted_failure_code = copy.deepcopy(result)
del omitted_failure_code["phases"]["cycles_20"]["self_test_report"]["failure_code"]
assert module["check_active_sampling"](omitted_failure_code, "fixture") == []
explicit_null_failure_code = copy.deepcopy(result)
explicit_null_failure_code["phases"]["cycles_20"]["self_test_report"]["failure_code"] = None
assert module["check_active_sampling"](explicit_null_failure_code, "fixture") == []
explicit_none_failure_code = copy.deepcopy(result)
explicit_none_failure_code["phases"]["cycles_20"]["self_test_report"]["failure_code"] = "none"
assert module["check_active_sampling"](explicit_none_failure_code, "fixture") == []
invalid_failure_code = copy.deepcopy(result)
invalid_failure_code["phases"]["cycles_20"]["self_test_report"]["failure_code"] = "model_timeout"
assert module["check_active_sampling"](invalid_failure_code, "fixture")

tampered = copy.deepcopy(result)
tampered["metrics"]["transcription.cpu.p95_percent"]["value"] += 1
assert module["check_active_sampling"](tampered, "fixture")
tampered = copy.deepcopy(result)
tampered["metrics"]["memory.peak_mib"]["value"] -= 1
assert module["check_active_sampling"](tampered, "fixture")
tampered = copy.deepcopy(result)
tampered["phases"]["cycles_20"]["cycle_resource_mapping"]["pairs"][0]["sample_index"] += 1
assert module["check_active_sampling"](tampered, "fixture")
tampered = copy.deepcopy(result)
tampered["phases"]["cycles_20"]["samples"][5]["file_descriptors_measured"] = False
assert module["check_active_sampling"](tampered, "fixture")
tampered = copy.deepcopy(result)
tampered["phases"]["cycles_20"]["self_test_report"]["timings"]["model_ready_at_unix_ms"] = base + 2200
assert module["check_active_sampling"](tampered, "fixture")
tampered = copy.deepcopy(result)
tampered_diagnostics = tampered["phases"]["cycles_20"]["diagnostics"]
tampered_diagnostics[2]["timestamp_unix_ms"] = tampered_diagnostics[1]["timestamp_unix_ms"]
assert module["check_active_sampling"](tampered, "fixture")
tampered = copy.deepcopy(result)
tampered["phases"]["cycles_20"]["self_test_report"]["transcript"] = "private"
assert module["check_active_sampling"](tampered, "fixture")
' "$HARNESS"

FAILURE_SUMMARY="$TEST_ROOT/constrained-failure-summary.json"
mise exec -- python3 -c '
import json, os, pathlib, runpy, sys
module = runpy.run_path(sys.argv[1])
path = pathlib.Path(sys.argv[2])
error = module["SamplingEvidenceError"](
    "overlong_collection_gap",
    "private detail /Users/private/audio.ogg",
    first_bad_index=7,
    first_bad_gap_seconds=2.4,
    sampling_contract=module["ACTIVE_SAMPLING_CONTRACT"],
    row_count=42,
    gap_p50_seconds=1.1,
    gap_p95_seconds=1.2,
    gap_p99_seconds=2.4,
    gap_max_seconds=2.4,
    reader_lag_p95_seconds=0.01,
    reader_lag_max_seconds=0.02,
    top_returncode=1,
    top_stderr_category="other",
    top_stderr_sha256="a" * 64,
    history_ready_count=1,
    direct_start_count=20,
    direct_completion_count=20,
)
module["write_failure_summary"](path, phase="cycles_20", error=error)
value = json.loads(path.read_text(encoding="utf-8"))
assert value["schema_version"] == 1
assert value["contract"] == "gpui-performance-failure-v1"
assert value["phase"] == "cycles_20"
assert value["code"] == "overlong_collection_gap"
assert value["passed"] is False
assert value["sampling"]["contract"] == module["ACTIVE_SAMPLING_CONTRACT"]
assert value["sampling"]["row_count"] == 42
assert value["sampling"]["first_bad_index"] == 7
assert value["sampling"]["first_bad_gap_seconds"] == 2.4
assert value["sampling"]["gap_p99_seconds"] == 2.4
assert value["sampling"]["reader_lag_max_seconds"] == 0.02
assert value["sampling"]["top_returncode"] == 1
assert value["sampling"]["top_stderr_sha256"] == "a" * 64
assert value["sampling"]["direct_completion_count"] == 20
assert os.stat(path).st_mode & 0o777 == 0o600
assert "/Users/" not in path.read_text(encoding="utf-8")
try:
    module["write_failure_summary"](path, phase="cycles_20", error=error)
except module["EvidenceError"]:
    pass
else:
    raise SystemExit("failure summary overwrote pre-existing evidence")
atomic_path = path.with_name("constrained-failure-summary-atomic-test.json")
replace = module["os"].replace
def fail_replace(source, target):
    raise OSError("injected publish failure /Users/private")
module["os"].replace = fail_replace
try:
    module["write_private_json"](atomic_path, {"passed": False})
except OSError:
    pass
else:
    raise SystemExit("atomic failure-summary publish injection unexpectedly passed")
finally:
    module["os"].replace = replace
assert not atomic_path.exists()
assert not list(atomic_path.parent.glob(f".{atomic_path.name}.tmp-*"))
' "$HARNESS" "$FAILURE_SUMMARY"

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
mise exec -- python3 - "$HARNESS" "$TEST_ROOT/physical.json" "$TEST_ROOT/constrained.json" <<'PY'
import copy
import json
import pathlib
import runpy
import sys

module = runpy.run_path(sys.argv[1])
physical = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
constrained = json.loads(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"))
assert module["evidence_role"](physical) == "physical_interactive"
assert module["evidence_role"](constrained) == "constrained_noninteractive"
assert module["check_retained_physical_evidence"](physical, "physical") == []
for mutation in ("missing", "tampered", "relabelled", "open_window"):
    invalid = copy.deepcopy(physical)
    if mutation == "missing":
        invalid["phases"].pop("retained_ui")
    elif mutation == "tampered":
        invalid["phases"]["leaks_stacklogged"]["count_delta"] = 1
    elif mutation == "relabelled":
        invalid["metrics"]["leaks.definite.growth_count"]["evidence"][0]["kind"] = "synthetic_verifier_fixture"
    else:
        invalid["phases"]["retained_ui"]["window"]["unexpected_private_field"] = "private"
    invalid["evidence_sha256"] = module["canonical_hash"](invalid)
    assert module["check_retained_physical_evidence"](invalid, "physical")
for key, value in (
    ("xcode_version", "unknown"),
    ("xcode_build", "unknown"),
    ("xctrace_version", "unknown"),
    ("xctrace_templates", []),
):
    invalid = copy.deepcopy(physical)
    invalid["host"][key] = value
    invalid["evidence_sha256"] = module["canonical_hash"](invalid)
    assert module["evidence_role"](invalid) is None
invalid_constrained = copy.deepcopy(constrained)
invalid_constrained["host"]["xcode_version"] = "Xcode 26.6"
invalid_constrained["evidence_sha256"] = module["canonical_hash"](invalid_constrained)
assert module["evidence_role"](invalid_constrained) is None
PY
mise exec -- python3 "$HARNESS" verify \
    --profile release \
    --result "$TEST_ROOT/constrained.json" \
    --budgets "$BUDGETS" \
    --report "$TEST_ROOT/release-report.json" >/dev/null
mise exec -- jq -e '
  .passed == true and
  .evaluated_metrics == 24 and
  .evaluated_measurements == 24 and
  ([.evidence_sets[].role] == ["constrained_noninteractive"])
' "$TEST_ROOT/release-report.json" >/dev/null
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
    --companion-result "$TEST_ROOT/physical.json" \
    --budgets "$BUDGETS" >/dev/null 2>&1; then
    echo "Release gate accepted nonblocking physical companion evidence" >&2
    exit 1
fi
if mise exec -- python3 "$HARNESS" verify \
    --profile release \
    --result "$TEST_ROOT/constrained.json" \
    --companion-result "$TEST_ROOT/constrained.json" \
    --budgets "$BUDGETS" >/dev/null 2>"$TEST_ROOT/release-duplicate.err"; then
    echo "Release gate accepted a duplicate constrained evidence set" >&2
    exit 1
fi
rg -F "exactly one constrained result and no companions" \
    "$TEST_ROOT/release-duplicate.err" >/dev/null

mise exec -- python3 - "$HARNESS" "$TEST_ROOT" "$TRANSCRIPTION_FIXTURE" <<'PY'
import copy
import json
import pathlib
import runpy
import sys

module = runpy.run_path(sys.argv[1])
root = pathlib.Path(sys.argv[2]) / "retained-contract"
root.mkdir()
manifest = json.loads(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"))
session = "s-0123456789abcdef"
pid = 4242
audio = manifest["audio"]
checkpoint = {
    "schema_version": 1,
    "contract": module["RETAINED_WORKLOAD_CONTRACT"],
    "phase": "workload_observed",
    "fixture": {
        "id": manifest["fixture_id"],
        "sha256": manifest["sha256"],
        "bytes": manifest["bytes"],
        "channels": audio["channels"],
        "sample_rate_hz": audio["sample_rate_hz"],
        "bits_per_sample": audio["bits_per_sample"],
        "duration_ms": int(audio["duration_seconds"] * 1000),
    },
    "process": {"pid": pid},
    "session_id": session,
    "model": {
        "id": module["DEFAULT_MODEL_ID"],
        "revision": module["DEFAULT_MODEL_REVISION"],
        "engine_instances": 1,
        "warmed": True,
        "downloaded": True,
    },
    "requested": {"cycles": 20, "history_rows": 50},
    "completed": {"cycles": 20, "history_rows": 50},
    "history": {"schema_version": 1, "integrity_ok": True},
    "timings": {
        "ready_at_unix_ms": 1000,
        "started_at_unix_ms": 1100,
        "history_ready_at_unix_ms": 1200,
        "activation_started_at_unix_ms": 1300,
        "loading_started_at_unix_ms": 1400,
        "model_ready_at_unix_ms": 1500,
        "warmup_completed_at_unix_ms": 1600,
        "completed_at_unix_ms": 50000,
        "model_download_ms": 100.0,
        "model_cold_load_ms": 100.0,
        "total_ms": 49000.0,
        "cycles_ms": [400.0] * 20,
    },
    "observer_acknowledged": True,
    "interaction_completed": False,
    "retained_exit_acknowledged": False,
    "passed": True,
}
workload = root / module["RETAINED_WORKLOAD_NAME"]
workload.write_text(json.dumps(checkpoint), encoding="utf-8")
workload.chmod(0o600)

workload_copy = root / "workload-copy"
workload.rename(workload_copy)
workload.symlink_to(workload_copy)
try:
    module["validate_retained_checkpoint"](
        workload,
        data_root=root,
        expected_pid=pid,
        expected_session_id=session,
        fixture_manifest=manifest,
        phase="workload_observed",
    )
except module["EvidenceError"]:
    pass
else:
    raise SystemExit("retained checkpoint accepted a symlink")
workload.unlink()
workload_copy.rename(workload)
assert module["validate_retained_checkpoint"](
    workload,
    data_root=root,
    expected_pid=pid,
    expected_session_id=session,
    fixture_manifest=manifest,
    phase="workload_observed",
)["process"] == {"pid": pid}
workload.chmod(0o644)
try:
    module["validate_retained_checkpoint"](
        workload,
        data_root=root,
        expected_pid=pid,
        expected_session_id=session,
        fixture_manifest=manifest,
        phase="workload_observed",
    )
except module["EvidenceError"]:
    pass
else:
    raise SystemExit("retained checkpoint accepted a non-0600 mode")
workload.chmod(0o600)

for field, value in (("process", {"pid": pid + 1}), ("session_id", "s-fedcba9876543210")):
    tampered = copy.deepcopy(checkpoint)
    tampered[field] = value
    workload.write_text(json.dumps(tampered), encoding="utf-8")
    try:
        module["validate_retained_checkpoint"](
            workload,
            data_root=root,
            expected_pid=pid,
            expected_session_id=session,
            fixture_manifest=manifest,
            phase="workload_observed",
        )
    except module["EvidenceError"]:
        pass
    else:
        raise SystemExit(f"retained checkpoint accepted wrong {field}")
workload.write_text(json.dumps(checkpoint), encoding="utf-8")

ack = root / module["RETAINED_EXIT_ACK_NAME"]
module["create_exact_empty_ack"](
    ack, data_root=root, name=module["RETAINED_EXIT_ACK_NAME"]
)
assert ack.is_file() and ack.stat().st_size == 0
try:
    module["create_exact_empty_ack"](
        ack, data_root=root, name=module["RETAINED_EXIT_ACK_NAME"]
    )
except module["EvidenceError"]:
    pass
else:
    raise SystemExit("retained ack accepted a pre-existing path")
ack.unlink()
ack.write_bytes(b"payload")
try:
    module["validate_exact_root_child"](
        ack,
        data_root=root,
        name=module["RETAINED_EXIT_ACK_NAME"],
        require_existing=True,
        require_empty=True,
    )
except module["EvidenceError"]:
    pass
else:
    raise SystemExit("retained ack accepted a nonzero payload")
ack.unlink()
target = root / "target"
target.touch()
ack.symlink_to(target)
try:
    module["validate_exact_root_child"](
        ack,
        data_root=root,
        name=module["RETAINED_EXIT_ACK_NAME"],
        require_existing=True,
        require_empty=True,
    )
except module["EvidenceError"]:
    pass
else:
    raise SystemExit("retained ack accepted a symlink")

def diagnostics(count=20, *, recording=False, duplicate=False):
    rows = []
    for index in range(count):
        correlation = "direct-00" if duplicate else f"direct-{index:02d}"
        started = 2000 + index * 1000
        rows.extend([
            {"session_id": session, "code": "transcription_started", "correlation_id": correlation, "timestamp_unix_ms": started},
            {"session_id": session, "code": "transcription_completed", "correlation_id": correlation, "timestamp_unix_ms": started + 400},
        ])
        if recording and index == 0:
            rows.append({"session_id": session, "code": "recording_started", "correlation_id": correlation, "timestamp_unix_ms": started - 1})
    return rows

assert len(module["direct_cycle_correlations"](diagnostics(), session)) == 20
for invalid in (diagnostics(19), diagnostics(21), diagnostics(recording=True), diagnostics(duplicate=True)):
    try:
        module["direct_cycle_correlations"](invalid, session)
    except module["EvidenceError"]:
        pass
    else:
        raise SystemExit("retained Malloc correlation contract accepted invalid 19/21/recording/duplicate evidence")

leak_result = {
    "metrics": {},
    "traces": [],
    "phases": {"cycles_20": {"pid": pid}},
}
module["add_retained_leak_comparison"](
    leak_result,
    baseline={"count": 2, "bytes": 64, "captured_at_unix_ms": 1900},
    comparison={"count": 2, "bytes": 64, "captured_at_unix_ms": 22000},
    baseline_evidence={"kind": "macos_leaks_live_attach", "name": "baseline", "sha256": "a" * 64},
    comparison_evidence={"kind": "macos_leaks_live_attach", "name": "comparison", "sha256": "b" * 64},
    diagnostics=diagnostics(),
    session_id=session,
)
assert leak_result["metrics"]["leaks.definite.growth_count"] == {
    "value": 0,
    "sample_count": 20,
    "evidence": [
        {"kind": "macos_leaks_live_attach", "name": "baseline", "sha256": "a" * 64},
        {"kind": "macos_leaks_live_attach", "name": "comparison", "sha256": "b" * 64},
    ],
}

parser = module["build_parser"]()
parsed = parser.parse_args([
    "self-test", "--app", "/A.app", "--fixture", "/fixture", "--data-root", "/root",
    "--output", "/result", "--retain-ui", "--malloc-stack-logging",
])
assert not parsed.interaction and parsed.retain_ui and parsed.malloc_stack_logging

ui_checkpoint = copy.deepcopy(checkpoint)
ui_checkpoint["contract"] = module["RETAINED_UI_CHECKPOINT_CONTRACT"]
ui_checkpoint["phase"] = "ui_retained"

ack_phase = {
    "contract": "same-signed-pid-physical-observer-v1",
    "pid": pid,
    "session_id": session,
    "workload_checkpoint": checkpoint,
    "workload_checkpoint_sha256": module["canonical_payload_sha256"](checkpoint),
    "ui_checkpoint": ui_checkpoint,
    "ui_checkpoint_sha256": module["canonical_payload_sha256"](ui_checkpoint),
    "window": {
        "contract": "same-pid-typed-settings-v1",
        "typed_show_requested_at_unix_ms": 51000,
        "retained_window_shown_at_unix_ms": 51001,
        "launch_services_observed_at_unix_ms": 51002,
        "pid": pid,
        "session_id": session,
        "terminal_application_type": "Foreground",
        "launch_services_state": {
            "returncode": 0,
            "stdout_shape": "exact_fields",
            "stderr_category": "empty",
            "bundle_id_matches": True,
            "bundle_path_matches": True,
            "pid_matches": True,
            "application_type": "Foreground",
        },
    },
    "exit_ack_name": module["RETAINED_EXIT_ACK_NAME"],
    "exit_acknowledged": False,
    "final_report_observed": False,
}
assert module["validate_retained_ack_phase"](ack_phase, expected_pid=pid) == (pid, session)
for mutation in (
    {"pid": pid + 1},
    {"window": {**ack_phase["window"], "pid": pid + 1}},
    {"window": {**ack_phase["window"], "unexpected_private_field": "private"}},
    {"session_id": "s-fedcba9876543210"},
    {"exit_acknowledged": True},
):
    invalid = {**ack_phase, **mutation}
    try:
        module["validate_retained_ack_phase"](invalid, expected_pid=pid)
    except module["EvidenceError"]:
        pass
    else:
        raise SystemExit("retained ack accepted wrong PID/session/window or completed state")
PY

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
