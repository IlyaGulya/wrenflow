#!/usr/bin/env python3
"""Generate synthetic verifier-only hybrid results for harness unit tests."""

import hashlib
import json
import pathlib
import sys


def evidence_hash(result):
    encoded = json.dumps(result, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def payload_hash(value):
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def retained_phases_and_metric():
    pid = 4242
    session = "s-0123456789abcdef"
    fixture = {
        "id": "whispercpp-jfk-pcm16-v1",
        "sha256": "59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e",
        "bytes": 352078,
        "channels": 1,
        "sample_rate_hz": 16000,
        "bits_per_sample": 16,
        "duration_ms": 11000,
    }
    model = {
        "id": "parakeet-tdt-0.6b-v3-onnx",
        "revision": "8f23f0c03c8761650bdb5b40aaf3e40d2c15f1ce",
        "engine_instances": 1,
        "warmed": True,
        "downloaded": True,
    }
    workload = {"cycles": 20, "history_rows": 50}
    history = {"schema_version": 1, "integrity_ok": True}
    timings = {
        "ready_at_unix_ms": 1000,
        "started_at_unix_ms": 2000,
        "history_ready_at_unix_ms": 2100,
        "activation_started_at_unix_ms": 2200,
        "loading_started_at_unix_ms": 2300,
        "model_ready_at_unix_ms": 2400,
        "warmup_completed_at_unix_ms": 2500,
        "completed_at_unix_ms": 25000,
        "model_download_ms": 100.0,
        "model_cold_load_ms": 100.0,
        "total_ms": 24000.0,
        "cycles_ms": [400.0] * 20,
    }
    common = {
        "schema_version": 1,
        "fixture": fixture,
        "process": {"pid": pid},
        "session_id": session,
        "model": model,
        "requested": workload,
        "completed": workload,
        "history": history,
        "timings": timings,
        "observer_acknowledged": True,
        "interaction_completed": False,
        "retained_exit_acknowledged": False,
        "passed": True,
    }
    workload_checkpoint = {
        **common,
        "contract": "gpui-performance-retained-workload-v1",
        "phase": "workload_observed",
    }
    ui_checkpoint = {
        **common,
        "contract": "gpui-performance-retained-ui-v1",
        "phase": "ui_retained",
    }
    final_report = {
        "schema_version": 1,
        "contract": "gpui-performance-self-test-v1",
        "fixture": fixture,
        "process": {"pid": pid},
        "session_id": session,
        "model": model,
        "requested": workload,
        "completed": workload,
        "history": history,
        "timings": {**timings, "completed_at_unix_ms": 28000, "total_ms": 27000.0},
        "quit_requested": True,
        "passed": True,
        "failure_code": None,
    }
    diagnostics = []
    for index in range(20):
        correlation = f"direct-{index:02d}"
        started = 3000 + index * 1000
        diagnostics.extend([
            {
                "timestamp_unix_ms": started,
                "session_id": session,
                "correlation_id": correlation,
                "code": "transcription_started",
            },
            {
                "timestamp_unix_ms": started + 400,
                "session_id": session,
                "correlation_id": correlation,
                "code": "transcription_completed",
            },
        ])
    def leak_summary(count, leaked_bytes, captured):
        canonical = (
            "leaks-stacklogged-summary-v1\n"
            f"count={count}\nbytes={leaked_bytes}\n"
        )
        return {
            "count": count,
            "bytes": leaked_bytes,
            "captured_at_unix_ms": captured,
            "canonical_summary_sha256": hashlib.sha256(canonical.encode()).hexdigest(),
            "private_raw_output_sha256": hashlib.sha256(
                f"private-fixture-{captured}".encode()
            ).hexdigest(),
        }
    baseline = leak_summary(2, 64, 1900)
    comparison = leak_summary(2, 64, 26000)
    evidence = [
        {
            "kind": "macos_leaks_live_attach",
            "name": "leaks-stacklogged-summary-v1",
            "sha256": baseline["private_raw_output_sha256"],
        },
        {
            "kind": "macos_leaks_live_attach",
            "name": "leaks-stacklogged-summary-v1",
            "sha256": comparison["private_raw_output_sha256"],
        },
    ]
    phases = {
        "retained_ui": {
            "contract": "same-signed-pid-physical-observer-v1",
            "pid": pid,
            "session_id": session,
            "workload_checkpoint": workload_checkpoint,
            "workload_checkpoint_sha256": payload_hash(workload_checkpoint),
            "ui_checkpoint": ui_checkpoint,
            "ui_checkpoint_sha256": payload_hash(ui_checkpoint),
            "window": {
                "contract": "same-pid-typed-settings-v1",
                "typed_show_requested_at_unix_ms": 27000,
                "retained_window_shown_at_unix_ms": 27100,
                "launch_services_observed_at_unix_ms": 27200,
                "terminal_application_type": "Foreground",
                "pid": pid,
                "session_id": session,
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
            "exit_ack_name": "performance-retained-exit-ack-v1",
            "exit_acknowledged": True,
            "final_report_observed": True,
            "final_report": final_report,
            "final_report_sha256": payload_hash(final_report),
        },
        "leaks_stacklogged": {
            "phase": "leaks_stacklogged",
            "contract": "same-pid-direct-twenty-v1",
            "pid": pid,
            "session_id": session,
            "stack_logging_confirmed": True,
            "baseline": baseline,
            "comparison": comparison,
            "closed_cycle_count": 20,
            "first_correlation_id": "direct-00",
            "last_correlation_id": "direct-19",
            "diagnostics": diagnostics,
            "count_delta": 0,
            "bytes_delta": 0,
        },
        "signed_self_test": {
            "pid": pid,
            "retained_ui_contract": "same-signed-pid-physical-observer-v1",
            "interaction_classification": "none",
            "auto_exit_observed": True,
        },
    }
    metric = {"value": 0.0, "sample_count": 20, "evidence": evidence}
    return phases, metric, evidence


def idle_phase_and_metrics():
    baseline_elapsed = 0.5
    baseline_wall_ms = 1_000_000
    baseline_wakeups = 100
    samples = []
    for index in range(1800):
        samples.append({
            "timestamp_unix_ms": baseline_wall_ms + (index + 1) * 1000,
            "elapsed_seconds": baseline_elapsed + index + 1,
            "observed_interval_seconds": 1.0,
            "cpu_percent": 0.0,
            "rss_mib": 100.0,
            "threads": 4,
            "idle_wakeups_counter": baseline_wakeups,
            "idle_wakeups_per_s": 0.0,
            "energy_impact": 0.0,
            "file_descriptors": 8,
            "file_descriptors_measured": index % 5 == 0,
        })
    sampling = {
        "contract": "fixed-count-monotonic-v1",
        "baseline_elapsed_seconds": baseline_elapsed,
        "baseline_at_unix_ms": baseline_wall_ms,
        "baseline_idle_wakeups": baseline_wakeups,
        "target_sample_count": 1800,
        "observed_sample_count": 1800,
        "wall_coverage_seconds": 1800.0,
        "average_observed_interval_seconds": 1.0,
        "maximum_observed_interval_seconds": 1.0,
        "effective_samples_per_second": 1.0,
        "average_gap_multiplier_limit": 1.25,
        "maximum_gap_multiplier_limit": 2.0,
    }
    phase = {
        "phase": "idle",
        "requested_duration_seconds": 1800.0,
        "sample_interval_seconds": 1.0,
        "sampling": sampling,
        "samples": samples,
    }
    metrics = {
        "idle.duration_seconds": {"value": 1800.0, "sample_count": 1, "evidence": []},
        "idle.cpu.avg_percent": {"value": 0.0, "sample_count": 1800, "evidence": []},
        "idle.cpu.p95_percent": {"value": 0.0, "sample_count": 1800, "evidence": []},
        "idle.wakeups.avg_per_s": {"value": 0.0, "sample_count": 1800, "evidence": []},
        "idle.wakeups.p95_per_s": {"value": 0.0, "sample_count": 1800, "evidence": []},
        "idle.energy.avg_impact": {"value": 0.0, "sample_count": 1800, "evidence": []},
        "idle.energy.p95_impact": {"value": 0.0, "sample_count": 1800, "evidence": []},
    }
    return phase, metrics


def launch_sample(index, latency, *, shutdown=False, fresh_runner_id=None, shard_digest=None):
    started = 10_000_000 + index * 10_000
    sample = {
        "started_at_unix_ms": started,
        "startup_diagnostic_at_unix_ms": started + 100,
        "menu_bar_ready_at_unix_ms": started + 300,
        "terminal_policy_ready_at_unix_ms": started + 350,
        "launch_services_observed_at_unix_ms": started + latency,
        "ready_at_unix_ms": started + latency,
        "terminal_application_type": "Foreground",
        "latency_ms": latency,
        "session_id": f"s-{index:016x}",
        "diagnostic_stages_at_unix_ms": {
            "runtime_bootstrap_started": started + 110,
            "runtime_bootstrap_ready": started + 120,
            "app_callback_entered": started + 130,
            "app_model_ready": started + 140,
            "swift_shell_installed": started + 150,
            "tray_projection_ready": started + 160,
            "menu_bar_ready": started + 300,
            "gpui_window_open_started": started + 301,
            "gpui_window_callback_entered": started + 302,
            "app_screens_ready": started + 303,
            "gpui_root_ready": started + 304,
            "gpui_window_created": started + 310,
            "window_policy_route_observed": started + 320,
            "gpui_window_shown": started + 330,
        },
        "stages_ms": {
            "external_open_to_startup_ms": 100,
            "startup_to_menu_bar_ms": 200,
            "menu_bar_to_terminal_policy_ms": 50,
            "terminal_policy_to_launch_services_ms": latency - 350,
            "total_ms": latency,
        },
    }
    if shutdown:
        sample.update({
            "typed_shutdown_requested_at_unix_ms": started + latency + 1,
            "process_terminated_at_unix_ms": started + latency + 2,
            "launch_services_deregistered_at_unix_ms": started + latency + 3,
        })
    if fresh_runner_id is not None:
        sample["fresh_runner_id"] = fresh_runner_id
    if shard_digest is not None:
        sample["shard_evidence_sha256"] = shard_digest
    return sample


def launch_phases_and_metrics():
    priming = {
        "contract": "unmeasured-route-aware-exact-candidate-v1",
        "metric_contribution": False,
        **launch_sample(1, 500, shutdown=True),
    }
    warm = [launch_sample(index + 2, 500, shutdown=True) for index in range(10)]
    for index, sample in enumerate(warm):
        if index == 0:
            previous_deregistered = priming["launch_services_deregistered_at_unix_ms"]
        else:
            previous_deregistered = warm[index - 1][
                "launch_services_deregistered_at_unix_ms"
            ]
        if sample["started_at_unix_ms"] < previous_deregistered:
            raise AssertionError("synthetic launch epochs overlap")
    cold = [
        launch_sample(
            index + 20,
            1_000,
            fresh_runner_id=f"gh-12345-1-cold-{index + 1}",
            shard_digest=f"{index + 1:064x}",
        )
        for index in range(20)
    ]
    phases = {
        "launch_warm": {
            "phase": "launch_warm",
            "definition": "ten measured exact signed LaunchServices restarts after one excluded route-aware priming launch",
            "priming": priming,
            "samples": warm,
        },
        "launch_cold": {
            "phase": "launch_cold",
            "definition": "one exact signed LaunchServices launch on each of twenty fresh GitHub-hosted macos-14 runners",
            "samples": cold,
        },
    }
    metrics = {
        "launch.warm.p95_ms": {"value": 500.0, "sample_count": 10, "evidence": []},
        "launch.cold.p95_ms": {
            "value": 1_000.0,
            "sample_count": 20,
            "evidence": [
                {
                    "kind": "sealed_cold_runner_shard",
                    "name": "cold-shard-v1",
                    "sha256": f"{index + 1:064x}",
                }
                for index in range(20)
            ],
        },
    }
    return phases, metrics


def make_result(role, budgets):
    metrics = {}
    assigned = set(budgets["evidence_policy"][role])
    synthetic = set()
    if role == "physical_interactive":
        synthetic = set(budgets["evidence_policy"]["post_event_tap_synthetic"])
        assigned.update(synthetic)
    for budget in budgets["budgets"]:
        if budget["metric"] in assigned:
            evidence = (
                [{
                    "kind": "post_event_tap_synthetic",
                    "name": "performance-interaction-v1.json",
                    "sha256": "e" * 64,
                }]
                if budget["metric"] in synthetic
                else [{"kind": "synthetic_verifier_fixture"}]
            )
            metrics[budget["metric"]] = {
                "value": budget["threshold"],
                "sample_count": budget["min_samples"],
                "evidence": evidence,
            }
    phases = {}
    traces = []
    if role == "constrained_noninteractive":
        idle_phase, idle_metrics = idle_phase_and_metrics()
        phases["idle"] = idle_phase
        metrics.update(idle_metrics)
        launch_phases, launch_metrics = launch_phases_and_metrics()
        phases.update(launch_phases)
        metrics.update(launch_metrics)
    elif role == "physical_interactive":
        retained_phases, retained_metric, retained_traces = retained_phases_and_metric()
        phases.update(retained_phases)
        metrics["leaks.definite.growth_count"] = retained_metric
        traces.extend(retained_traces)
    eligibility = {
        "github_m1_7gb_constrained_preflight": role == "constrained_noninteractive",
        "physical_supported_interactive": role == "physical_interactive",
        "physical_base_m1_8gib_macos14": False,
    }
    constrained = role == "constrained_noninteractive"
    result = {
        "schema_version": 1,
        "budget_version": budgets["budget_version"],
        "source": {"commit": "a" * 40, "dirty": False},
        "host": {
            "os_version": "14.8.7" if constrained else "26.5.1",
            "os_build": "23J520" if constrained else "25F80",
            "architecture": "arm64",
            "chip": "Apple M1" if constrained else "Apple M1 Max",
            "machine_model": "VirtualMac2,1" if constrained else "Mac13,1",
            "memory_bytes": 7_516_192_768 if constrained else 68_719_476_736,
            "logical_cpu_count": 3 if constrained else 10,
            "xcode_version": "Xcode 16.2" if constrained else "Xcode 26.6",
            "xcode_build": "Build version 16C5032a" if constrained else "Build version 17F113",
            "xctrace_version": "xctrace version 16.0 (17F113)",
            "xctrace_templates": [
                "Activity Monitor",
                "Allocations",
                "Animation Hitches",
                "Audio System Trace",
                "Leaks",
                "System Trace",
                "Time Profiler",
            ],
            "missing_required_templates": [],
            "missing_supporting_templates": ["Power Profiler"],
            "github": {
                "actions": role == "constrained_noninteractive",
                "runner_os": "macOS" if role == "constrained_noninteractive" else None,
                "runner_arch": "ARM64" if role == "constrained_noninteractive" else None,
                "runner_environment": "github-hosted" if role == "constrained_noninteractive" else None,
            },
            "evidence_eligibility": eligibility,
            "power": {
                "source": "ac",
                "low_power_mode": False,
                "thermal_nominal": True,
            },
        },
        "candidate": {
            "bundle_tree_sha256": "b" * 64,
            "executable_sha256": "c" * 64,
            "cdhash": "d" * 40,
            "bundle_version": "fixture",
            "bundle_build": "fixture",
            "developer_id_signed": True,
            "architectures": ["arm64"],
        },
        "candidate_id": "synthetic-verifier-fixture",
        "metrics": metrics,
        "traces": traces,
        "phases": ({
            **phases,
            "post_event_tap_synthetic": {
                "classification": "post_event_tap_synthetic",
                "source": "signed_wrenflow_typed_hotkey_callback",
                "tcc_or_microphone_evidence": False,
            }
        } if synthetic else phases),
        "aggregations": ({
            "launch_cold": {
                "contract": "twenty-fresh-macos14-runners-v1",
                "sealed_shard_sha256": [f"{index + 1:064x}" for index in range(20)],
                "raw_max_ms": 1_000,
            }
        } if role == "constrained_noninteractive" else {}),
        "sanitized": True,
        "sealed": True,
    }
    result["evidence_sha256"] = evidence_hash(result)
    return result


if len(sys.argv) != 4:
    raise SystemExit("usage: generate-hybrid-verifier-fixture.py <budgets> <constrained.json> <physical.json>")

with pathlib.Path(sys.argv[1]).open(encoding="utf-8") as handle:
    budget_document = json.load(handle)
for evidence_role, output in zip(
    ("constrained_noninteractive", "physical_interactive"), sys.argv[2:]
):
    with pathlib.Path(output).open("w", encoding="utf-8") as handle:
        json.dump(make_result(evidence_role, budget_document), handle, indent=2, sort_keys=True)
        handle.write("\n")
