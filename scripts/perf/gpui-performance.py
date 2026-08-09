#!/usr/bin/env python3
"""Fail-closed GPUI performance evidence collector and budget verifier.

This tool observes an already signed LaunchServices app from the outside.  Its
deterministic non-interactive path is available only through the product's
two-gate performance self-test. Its optional signed in-process interaction
phase is explicitly synthetic and never claims microphone, TCC, external-key,
physical-input or human-acceptance evidence.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
import pathlib
import plistlib
import re
import signal
import shutil
import sqlite3
import statistics
import subprocess
import sys
import time
from typing import Any, Iterable


SCHEMA_VERSION = 1
BUDGET_VERSION = "gpui-performance-v1"
SELF_TEST_CONTRACT = "gpui-performance-self-test-v1"
SELF_TEST_ARGUMENT = "--performance-self-test"
SELF_TEST_GATE_ENV = "WRENFLOW_PERFORMANCE_SELF_TEST"
SELF_TEST_FIXTURE_ENV = "WRENFLOW_PERFORMANCE_FIXTURE"
SELF_TEST_ROOT_ENV = "WRENFLOW_PERFORMANCE_DATA_ROOT"
SELF_TEST_REPORT_NAME = "performance-self-test-v1.json"
INTERACTION_ENV = "WRENFLOW_PERFORMANCE_INTERACTION"
INTERACTION_CONTRACT = "synthetic-in-process-v1"
INTERACTION_REPORT_NAME = "performance-interaction-v1.json"
INTERACTION_PULSE_HOLD_MS = 350.0
SELF_TEST_START_NAME = "performance-start-v1"
CURRENT_DATA_NAMESPACE = "me.gulya.wrenflow/gpui-v1"
BUNDLE_ID = "me.gulya.wrenflow"
TEAM_ID = "T4LV8K9BGV"
EXECUTABLE_NAME = "wrenflow"
DEFAULT_MODEL_ID = "parakeet-tdt-0.6b-v3-onnx"
DEFAULT_MODEL_REVISION = "8f23f0c03c8761650bdb5b40aaf3e40d2c15f1ce"
REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
FIXTURE_MANIFEST = REPO_ROOT / "support/performance/transcription-fixture-v1.json"
REQUIRED_TEMPLATES = {
    "Activity Monitor",
    "Allocations",
    "Animation Hitches",
    "Audio System Trace",
    "Leaks",
    "System Trace",
    "Time Profiler",
}
SUPPORTING_TEMPLATES = {"Power Profiler"}
PHASES = {
    "idle",
    "idle_10m",
    "recording",
    "transcription",
    "model_download",
    "model_load",
    "settings_navigation",
    "history_50",
    "cycles_20",
}
DEFAULT_DIAGNOSTICS = (
    pathlib.Path.home()
    / "Library/Application Support/me.gulya.wrenflow/gpui-v1/diagnostics"
    / "events.ndjson"
)
DEFAULT_HISTORY = (
    pathlib.Path.home()
    / "Library/Application Support/me.gulya.wrenflow/gpui-v1/history.sqlite"
)


class EvidenceError(RuntimeError):
    pass


def run(argv: list[str], *, check: bool = True) -> str:
    result = subprocess.run(argv, text=True, capture_output=True, check=False)
    if check and result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "no output"
        raise EvidenceError(f"command failed ({result.returncode}): {' '.join(argv)}: {detail}")
    return result.stdout.strip()


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def write_json(path: pathlib.Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump(value, handle, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def read_json(path: pathlib.Path) -> Any:
    try:
        with path.open(encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        raise EvidenceError(f"cannot read JSON {path}: {error}") from error


def require_absolute_regular_file(path_value: str, label: str) -> pathlib.Path:
    path = pathlib.Path(path_value)
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        raise EvidenceError(f"{label} must be an absolute regular non-symlink file: {path}")
    return path


def validate_transcription_fixture(path_value: str) -> tuple[pathlib.Path, dict[str, Any]]:
    path = require_absolute_regular_file(path_value, "performance fixture")
    manifest = read_json(FIXTURE_MANIFEST)
    expected = {
        "sha256": manifest.get("sha256"),
        "bytes": manifest.get("bytes"),
    }
    if path.stat().st_size != expected["bytes"] or sha256_file(path) != expected["sha256"]:
        raise EvidenceError("performance fixture does not match its immutable SHA-256/size manifest")
    return path, manifest


def validate_empty_disposable_root(path_value: str) -> pathlib.Path:
    root = pathlib.Path(path_value)
    if not root.is_absolute() or root.is_symlink() or not root.is_dir():
        raise EvidenceError(
            f"performance data root must be an existing absolute non-symlink directory: {root}"
        )
    try:
        entries = list(root.iterdir())
    except OSError as error:
        raise EvidenceError(f"cannot inspect performance data root: {error}") from error
    if entries:
        raise EvidenceError("performance data root must be empty before the signed app starts")
    return root


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def tree_sha256(root: pathlib.Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*"), key=lambda item: item.as_posix()):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            entry = f"L\0{relative}\0{os.readlink(path)}\n".encode()
        elif path.is_file():
            entry = f"F\0{relative}\0{sha256_file(path)}\n".encode()
        elif path.is_dir():
            entry = f"D\0{relative}\n".encode()
        else:
            raise EvidenceError(f"unsupported bundle entry: {path}")
        digest.update(entry)
    return digest.hexdigest()


def parse_first(pattern: str, value: str, default: str = "unknown") -> str:
    match = re.search(pattern, value, re.MULTILINE)
    return match.group(1).strip() if match else default


def collect_power() -> dict[str, Any]:
    battery = run(["/usr/bin/pmset", "-g", "batt"], check=False)
    source = "ac" if "AC Power" in battery or "AC attached" in battery else "battery"
    percent_match = re.search(r"(\d+)%", battery)
    custom = run(["/usr/bin/pmset", "-g", "custom"], check=False)
    active_block = custom
    if source == "ac" and "AC Power:" in custom:
        active_block = custom.split("AC Power:", 1)[1]
    elif source == "battery" and "Battery Power:" in custom:
        active_block = custom.split("Battery Power:", 1)[1].split("AC Power:", 1)[0]
    low_power_match = re.search(r"^\s*lowpowermode\s+(\d+)\s*$", active_block, re.MULTILINE)
    thermal_text = run(["/usr/bin/pmset", "-g", "therm"], check=False)
    thermal_nominal = all(
        marker not in thermal_text.lower()
        for marker in ("warning level: 1", "warning level: 2", "speed limit")
    )
    return {
        "source": source,
        "battery_percent": int(percent_match.group(1)) if percent_match else None,
        "low_power_mode": bool(int(low_power_match.group(1))) if low_power_match else None,
        "thermal_nominal": thermal_nominal,
    }


def collect_host() -> dict[str, Any]:
    if sys.platform != "darwin":
        raise EvidenceError("GPUI production performance evidence is macOS-only")
    raw_hardware = json.loads(
        run(["/usr/sbin/system_profiler", "SPHardwareDataType", "-json"])
    )["SPHardwareDataType"][0]
    templates_output = run(["/usr/bin/xcrun", "xctrace", "list", "templates"])
    templates = sorted(
        line.strip()
        for line in templates_output.splitlines()
        if line.strip() and not line.startswith("==")
    )
    os_version = run(["/usr/bin/sw_vers", "-productVersion"])
    os_build = run(["/usr/bin/sw_vers", "-buildVersion"])
    memory_bytes = int(run(["/usr/sbin/sysctl", "-n", "hw.memsize"]))
    architecture = run(["/usr/bin/uname", "-m"])
    chip = raw_hardware.get("chip_type", "unknown")
    github_actions = os.environ.get("GITHUB_ACTIONS") == "true"
    os_major = int(os_version.split(".", 1)[0])
    gib = 1024**3
    physical_floor = (
        not github_actions
        and architecture == "arm64"
        and os_major == 14
        and chip == "Apple M1"
        and 7.5 * gib <= memory_bytes <= 9 * gib
    )
    constrained_ci = (
        github_actions
        and architecture == "arm64"
        and os_major == 14
        and chip.startswith("Apple M1")
        and 6.5 * gib <= memory_bytes <= 7.5 * gib
    )
    physical_interactive = (
        not github_actions
        and architecture == "arm64"
        and chip in {"Apple M1", "Apple M1 Max"}
        and os_major in {14, 26}
    )
    missing_required_templates = sorted(REQUIRED_TEMPLATES - set(templates))
    missing_supporting_templates = sorted(SUPPORTING_TEMPLATES - set(templates))
    xcode = run(["/usr/bin/xcodebuild", "-version"], check=False).splitlines()
    return {
        "os_version": os_version,
        "os_build": os_build,
        "architecture": architecture,
        "chip": chip,
        "machine_model": raw_hardware.get("machine_model", "unknown"),
        "memory_bytes": memory_bytes,
        "logical_cpu_count": int(run(["/usr/sbin/sysctl", "-n", "hw.logicalcpu"])),
        "xcode_version": xcode[0] if xcode else "unknown",
        "xcode_build": xcode[1] if len(xcode) > 1 else "unknown",
        "xctrace_version": run(["/usr/bin/xcrun", "xctrace", "version"]),
        "xctrace_templates": templates,
        "missing_required_templates": missing_required_templates,
        "missing_supporting_templates": missing_supporting_templates,
        "power": collect_power(),
        "github": {
            "actions": github_actions,
            "runner_os": os.environ.get("RUNNER_OS"),
            "runner_arch": os.environ.get("RUNNER_ARCH"),
            "runner_environment": os.environ.get("RUNNER_ENVIRONMENT"),
        },
        "evidence_eligibility": {
            "physical_base_m1_8gib_macos14": physical_floor,
            "github_m1_7gb_constrained_preflight": constrained_ci,
            "physical_supported_interactive": physical_interactive,
            "reason": (
                "physical base M1/8 GiB on macOS 14"
                if physical_floor
                else "GitHub-hosted M1/7-GB constrained non-interactive evidence"
                if constrained_ci
                else "supported physical Apple-Silicon interactive evidence"
                if physical_interactive
                else "host is outside every approved performance evidence class"
            ),
        },
    }


def collect_source() -> dict[str, Any]:
    commit = run(["/usr/bin/git", "rev-parse", "HEAD"], check=False)
    dirty = bool(run(["/usr/bin/git", "status", "--porcelain"], check=False))
    return {"commit": commit or "unknown", "dirty": dirty}


def require_app(path_value: str) -> pathlib.Path:
    path = pathlib.Path(path_value)
    if not path.is_absolute():
        raise EvidenceError("app path must be absolute")
    if path.is_symlink() or not path.is_dir() or path.suffix != ".app":
        raise EvidenceError(f"app must be a real, non-symlink .app bundle: {path}")
    return path


def collect_app(app: pathlib.Path) -> dict[str, Any]:
    info_path = app / "Contents/Info.plist"
    try:
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        raise EvidenceError(f"cannot read app Info.plist: {error}") from error
    bundle_id = info.get("CFBundleIdentifier")
    executable_name = info.get("CFBundleExecutable")
    if bundle_id != BUNDLE_ID or executable_name != EXECUTABLE_NAME:
        raise EvidenceError(
            f"unexpected candidate identity: {bundle_id!r}/{executable_name!r}"
        )
    executable = app / "Contents/MacOS" / executable_name
    if executable.is_symlink() or not executable.is_file():
        raise EvidenceError(f"candidate executable missing or symlinked: {executable}")
    verify = subprocess.run(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],
        text=True,
        capture_output=True,
        check=False,
    )
    if verify.returncode != 0:
        raise EvidenceError(f"candidate signature verification failed: {verify.stderr.strip()}")
    signing_process = subprocess.run(
        ["/usr/bin/codesign", "-dv", "--verbose=4", str(app)],
        text=True,
        capture_output=True,
        check=False,
    )
    signing = signing_process.stdout + signing_process.stderr
    authorities = re.findall(r"^Authority=(.+)$", signing, re.MULTILINE)
    team = parse_first(r"^TeamIdentifier=(.+)$", signing)
    cdhash = parse_first(r"^CDHash=(.+)$", signing)
    archs = run(["/usr/bin/lipo", "-archs", str(executable)]).split()
    return {
        "bundle_identifier": bundle_id,
        "bundle_version": str(info.get("CFBundleShortVersionString", "unknown")),
        "bundle_build": str(info.get("CFBundleVersion", "unknown")),
        "minimum_system_version": str(info.get("LSMinimumSystemVersion", "unknown")),
        "architectures": archs,
        "team_identifier": team,
        "authorities": authorities,
        "cdhash": cdhash,
        "developer_id_signed": (
            team == TEAM_ID
            and bool(authorities)
            and authorities[0].startswith("Developer ID Application:")
        ),
        "executable_sha256": sha256_file(executable),
        "bundle_tree_sha256": tree_sha256(app),
        "executable_size_bytes": executable.stat().st_size,
        "app_path": str(app),
        "executable_path": str(executable),
    }


def new_result(app: pathlib.Path) -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "budget_version": BUDGET_VERSION,
        "created_at": now_iso(),
        "updated_at": now_iso(),
        "source": collect_source(),
        "host": collect_host(),
        "candidate": collect_app(app),
        "phases": {},
        "metrics": {},
        "traces": [],
        "sealed": False,
    }


def load_result(path: pathlib.Path, app: pathlib.Path | None = None) -> dict[str, Any]:
    if path.exists():
        result = read_json(path)
        if result.get("schema_version") != SCHEMA_VERSION:
            raise EvidenceError("unsupported result schema")
        if result.get("budget_version") != BUDGET_VERSION:
            raise EvidenceError("result budget version does not match this harness")
        if result.get("sealed"):
            raise EvidenceError("result is sealed and cannot accept more evidence")
        if app is not None:
            current = collect_app(app)
            recorded = result.get("candidate", {})
            if current["bundle_tree_sha256"] != recorded.get("bundle_tree_sha256"):
                raise EvidenceError("candidate bytes changed since this result was created")
        return result
    if app is None:
        raise EvidenceError(f"result does not exist: {path}")
    return new_result(app)


def set_metric(
    result: dict[str, Any],
    key: str,
    value: float,
    sample_count: int,
    evidence: list[dict[str, str]] | None = None,
) -> None:
    result["metrics"][key] = {
        "value": round(float(value), 6),
        "sample_count": int(sample_count),
        "evidence": evidence or [],
    }


def percentile(values: Iterable[float], fraction: float = 0.95) -> float:
    ordered = sorted(float(value) for value in values)
    if not ordered:
        raise EvidenceError("cannot summarize an empty sample set")
    return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)]


def parse_memory(value: str) -> float:
    match = re.fullmatch(r"([0-9.]+)([KMGTP]?)[+-]?", value.strip())
    if not match:
        raise EvidenceError(f"cannot parse top memory value: {value!r}")
    amount = float(match.group(1))
    factor = {"": 1, "K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4}[match.group(2)]
    return amount * factor / 1024**2


def executable_for_pid(pid: int) -> str | None:
    # `command=` includes argv and therefore differs for the private signed-app
    # self-test's sole `--performance-self-test` argument. `comm=` is the
    # kernel-reported executable path on macOS and excludes argv.
    executable = run(["/bin/ps", "-p", str(pid), "-o", "comm="], check=False)
    return executable.strip() or None


def exact_pid(app_identity: dict[str, Any], *, required: bool = True) -> int | None:
    expected = app_identity["executable_path"]
    raw = run(["/usr/bin/pgrep", "-x", EXECUTABLE_NAME], check=False)
    matches = []
    for value in raw.split():
        if value.isdigit() and executable_for_pid(int(value)) == expected:
            matches.append(int(value))
    if len(matches) > 1:
        raise EvidenceError(f"multiple exact candidate processes are running: {matches}")
    if not matches:
        if required:
            raise EvidenceError("the exact candidate is not running through LaunchServices")
        return None
    return matches[0]


def count_fds(pid: int) -> int:
    output = run(
        ["/usr/sbin/lsof", "-a", "-p", str(pid), "-d", "0-999999", "-Fn"],
        check=False,
    )
    return sum(1 for line in output.splitlines() if re.fullmatch(r"f\d+", line))


def read_diagnostics(path: pathlib.Path, start_ms: int | None = None, end_ms: int | None = None) -> list[dict[str, Any]]:
    candidates = [path]
    candidates.extend(path.with_name(f"events.{index}.ndjson") for index in range(1, 4))
    records: dict[tuple[Any, ...], dict[str, Any]] = {}
    for candidate in candidates:
        if not candidate.is_file():
            continue
        with candidate.open(encoding="utf-8", errors="strict") as handle:
            for line in handle:
                try:
                    raw = json.loads(line)
                except json.JSONDecodeError:
                    continue
                timestamp = raw.get("timestamp_unix_ms")
                if not isinstance(timestamp, int):
                    continue
                if start_ms is not None and timestamp < start_ms:
                    continue
                if end_ms is not None and timestamp > end_ms:
                    continue
                sanitized = {
                    key: raw[key]
                    for key in ("timestamp_unix_ms", "session_id", "correlation_id", "category", "level", "code")
                    if key in raw
                }
                key = (
                    sanitized.get("timestamp_unix_ms"),
                    sanitized.get("session_id"),
                    sanitized.get("correlation_id"),
                    sanitized.get("code"),
                )
                records[key] = sanitized
    return sorted(records.values(), key=lambda record: record["timestamp_unix_ms"])


def wait_for_diagnostic_code(
    path: pathlib.Path,
    code: str,
    after_ms: int,
    timeout_seconds: float,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        matches = [
            record
            for record in read_diagnostics(path, after_ms - 50)
            if record.get("code") == code
        ]
        if matches:
            return matches[-1]
        time.sleep(0.05)
    raise EvidenceError(f"signed self-test did not emit {code} within {timeout_seconds:g}s")


def finite_nonnegative(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value >= 0


def validate_self_test_report(
    path: pathlib.Path,
    *,
    expected_pid: int,
    fixture_manifest: dict[str, Any],
) -> dict[str, Any]:
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        raise EvidenceError("signed self-test report is missing, relative, or symlinked")
    report = read_json(path)
    allowed_top = {
        "schema_version",
        "contract",
        "fixture",
        "process",
        "session_id",
        "model",
        "requested",
        "completed",
        "history",
        "timings",
        "quit_requested",
        "passed",
        "failure_code",
    }
    if not isinstance(report, dict) or set(report) - allowed_top:
        raise EvidenceError("signed self-test report contains unknown or potentially private fields")
    if report.get("schema_version") != 1 or report.get("contract") != SELF_TEST_CONTRACT:
        raise EvidenceError("signed self-test report uses the wrong schema or contract")
    if report.get("passed") is not True or report.get("quit_requested") is not True:
        raise EvidenceError("signed self-test did not report successful typed auto-quit")
    if report.get("failure_code") not in (None, "none"):
        raise EvidenceError("signed self-test reported a closed failure code")
    process = report.get("process")
    if process != {"pid": expected_pid}:
        raise EvidenceError("signed self-test report PID does not match the exact candidate")
    session_id = report.get("session_id")
    if not isinstance(session_id, str) or not re.fullmatch(r"s-[0-9a-f]{16}", session_id):
        raise EvidenceError("signed self-test report has an invalid bounded diagnostic session ID")

    audio = fixture_manifest.get("audio", {})
    expected_fixture = {
        "id": fixture_manifest.get("fixture_id"),
        "sha256": fixture_manifest.get("sha256"),
        "bytes": fixture_manifest.get("bytes"),
        "channels": audio.get("channels"),
        "sample_rate_hz": audio.get("sample_rate_hz"),
        "bits_per_sample": audio.get("bits_per_sample"),
        "duration_ms": int(float(audio.get("duration_seconds", 0)) * 1_000),
    }
    if report.get("fixture") != expected_fixture:
        raise EvidenceError("signed self-test report fixture identity differs from the pinned manifest")
    expected_model = {
        "id": DEFAULT_MODEL_ID,
        "revision": DEFAULT_MODEL_REVISION,
        "engine_instances": 1,
        "warmed": True,
        "downloaded": True,
    }
    if report.get("model") != expected_model:
        raise EvidenceError("signed self-test did not use one warmed pinned production model engine")
    expected_workload = {"cycles": 20, "history_rows": 50}
    if report.get("requested") != expected_workload or report.get("completed") != expected_workload:
        raise EvidenceError("signed self-test report does not prove the exact 20-cycle/50-row workload")
    if report.get("history") != {"schema_version": 1, "integrity_ok": True}:
        raise EvidenceError("signed self-test report does not prove current History integrity")

    timings = report.get("timings")
    expected_timing_keys = {
        "ready_at_unix_ms",
        "started_at_unix_ms",
        "completed_at_unix_ms",
        "model_download_ms",
        "model_cold_load_ms",
        "total_ms",
        "cycles_ms",
    }
    if not isinstance(timings, dict) or set(timings) != expected_timing_keys:
        raise EvidenceError("signed self-test timings have an unexpected shape")
    scalar_keys = expected_timing_keys - {"cycles_ms"}
    if not all(finite_nonnegative(timings.get(key)) for key in scalar_keys):
        raise EvidenceError("signed self-test timings must be finite and non-negative")
    cycles = timings.get("cycles_ms")
    if not isinstance(cycles, list) or len(cycles) != 20 or not all(finite_nonnegative(value) for value in cycles):
        raise EvidenceError("signed self-test must report exactly 20 finite cycle timings")
    if not (
        timings["ready_at_unix_ms"]
        <= timings["started_at_unix_ms"]
        <= timings["completed_at_unix_ms"]
    ):
        raise EvidenceError("signed self-test report timestamps are out of order")
    return report


def validate_interaction_report(path: pathlib.Path) -> dict[str, Any]:
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        raise EvidenceError("signed interaction report is missing, relative, or symlinked")
    report = read_json(path)
    expected_top = {
        "schema_version",
        "classification",
        "source",
        "key_code",
        "pulses",
        "hold",
        "tcc_or_microphone_evidence",
        "passed",
        "failure_code",
    }
    required_top = expected_top - {"failure_code"}
    if (
        not isinstance(report, dict)
        or not required_top.issubset(report)
        or not set(report).issubset(expected_top)
    ):
        raise EvidenceError("signed interaction report has an unexpected or private field")
    if (
        report.get("schema_version") != 1
        or report.get("classification") != "post_event_tap_synthetic"
        or report.get("source") != "signed_wrenflow_typed_hotkey_callback"
        or report.get("key_code") != 96
        or report.get("tcc_or_microphone_evidence") is not False
        or report.get("passed") is not True
        or report.get("failure_code") is not None
    ):
        raise EvidenceError("signed interaction report does not prove the closed synthetic contract")
    pulses = report.get("pulses")
    expected_pulse_fields = {
        "requested",
        "completed",
        "generation_uptime_ms",
        "overlay_ms",
        "paste_dispatch_ms",
    }
    if not isinstance(pulses, dict) or set(pulses) != expected_pulse_fields:
        raise EvidenceError("signed interaction pulse report has an unexpected shape")
    if pulses.get("requested") != 20 or pulses.get("completed") != 20:
        raise EvidenceError("signed interaction did not complete exactly 20 typed hotkey callback pulses")
    for key in ("generation_uptime_ms", "overlay_ms", "paste_dispatch_ms"):
        values = pulses.get(key)
        if (
            not isinstance(values, list)
            or len(values) != 20
            or not all(finite_nonnegative(value) and value > 0 for value in values)
        ):
            raise EvidenceError(f"signed interaction {key} is not exactly 20 positive finite samples")
    generated = pulses["generation_uptime_ms"]
    if any(current <= previous for previous, current in zip(generated, generated[1:])):
        raise EvidenceError("signed interaction generation timestamps are not strictly increasing")
    if any(paste < INTERACTION_PULSE_HOLD_MS for paste in pulses["paste_dispatch_ms"]):
        raise EvidenceError("signed interaction paste dispatch preceded its typed release")
    hold = report.get("hold")
    if not isinstance(hold, dict) or set(hold) != {
        "requested_ms",
        "observed_ms",
        "overlay_ms",
        "paste_dispatch_ms",
    }:
        raise EvidenceError("signed interaction hold report has an unexpected shape")
    if (
        hold.get("requested_ms") != 60_000
        or not finite_nonnegative(hold.get("observed_ms"))
        or not 60_000 <= hold["observed_ms"] <= 65_000
        or not finite_nonnegative(hold.get("overlay_ms"))
        or hold["overlay_ms"] <= 0
        or not finite_nonnegative(hold.get("paste_dispatch_ms"))
        or hold["paste_dispatch_ms"] <= 0
    ):
        raise EvidenceError("signed interaction did not prove one bounded 60-second hold")
    return report


def stage_verified_model_cache(cache: pathlib.Path, data_root: pathlib.Path) -> None:
    if not cache.is_absolute() or cache.is_symlink() or not cache.is_dir():
        raise EvidenceError("verified model cache must be an absolute regular directory")
    marker = cache / ".wrenflow-model-ready"
    if marker.is_symlink() or not marker.is_file():
        raise EvidenceError("verified model cache is missing its production marker")
    lines = marker.read_text(encoding="utf-8").splitlines()
    if (
        "format=2" not in lines
        or f"model_id={DEFAULT_MODEL_ID}" not in lines
        or f"revision={DEFAULT_MODEL_REVISION}" not in lines
    ):
        raise EvidenceError("verified model cache marker has the wrong identity")
    assets: dict[str, tuple[int, str]] = {}
    pattern = re.compile(r"^asset=([^ /]+) size=([0-9]+) sha256=([0-9a-f]{64}) modified_ns=[0-9]+$")
    for line in lines:
        match = pattern.fullmatch(line)
        if match:
            assets[match.group(1)] = (int(match.group(2)), match.group(3))
    expected_names = {
        "encoder-model.int8.onnx",
        "decoder_joint-model.int8.onnx",
        "nemo128.onnx",
        "vocab.txt",
        "config.json",
    }
    if set(assets) != expected_names:
        raise EvidenceError("verified model cache marker has an unexpected asset set")
    destination = data_root / CURRENT_DATA_NAMESPACE / "models/parakeet-tdt"
    if destination.exists() or destination.is_symlink():
        raise EvidenceError("performance model destination existed before cache staging")
    destination.mkdir(parents=True)
    for name in sorted(expected_names):
        source = cache / name
        size, digest = assets[name]
        if source.is_symlink() or not source.is_file() or source.stat().st_size != size:
            raise EvidenceError(f"verified model cache asset is unsafe: {name}")
        if sha256_file(source) != digest:
            raise EvidenceError(f"verified model cache asset digest differs from its marker: {name}")
        target = destination / name
        shutil.copyfile(source, target)
        with target.open("rb") as handle:
            os.fsync(handle.fileno())
    directory_fd = os.open(destination, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def validate_self_test_diagnostics(
    records: list[dict[str, Any]],
    *,
    session_id: str,
) -> None:
    session = [record for record in records if record.get("session_id") == session_id]
    codes = [record.get("code") for record in session]
    for required in (
        "performance_self_test_started",
        "performance_self_test_fixture_verified",
        "performance_self_test_ready",
        "performance_self_test_history_ready",
        "performance_self_test_completed",
    ):
        if codes.count(required) != 1:
            raise EvidenceError(f"signed self-test diagnostics require exactly one {required}")
    if any(
        code in {"performance_self_test_failed", "performance_self_test_timed_out"}
        for code in codes
    ):
        raise EvidenceError("signed self-test diagnostics contain a failure or timeout marker")
    recording_correlations = {
        record.get("correlation_id")
        for record in session
        if record.get("code") == "recording_started" and record.get("correlation_id")
    }
    starts = {
        record.get("correlation_id")
        for record in session
        if record.get("code") == "transcription_started" and record.get("correlation_id")
    } - recording_correlations
    completions = {
        record.get("correlation_id")
        for record in session
        if record.get("code") == "transcription_completed" and record.get("correlation_id")
    } - recording_correlations
    if len(starts) != 20 or completions != starts:
        raise EvidenceError("signed self-test diagnostics do not contain exactly 20 paired unique transcriptions")


def sample_phase(args: argparse.Namespace) -> None:
    app = require_app(args.app)
    output = pathlib.Path(args.output)
    result = load_result(output, app)
    identity = result["candidate"]
    pid = exact_pid(identity)
    if args.phase not in PHASES:
        raise EvidenceError(f"unknown phase: {args.phase}")
    if args.duration < args.interval * 2:
        raise EvidenceError("duration must contain at least two sample intervals")
    if args.interval < 1.0 or not args.interval.is_integer():
        raise EvidenceError("macOS top requires a whole-second sample interval of at least one second")
    sample_total = math.ceil(args.duration / args.interval) + 1
    command = [
        "/usr/bin/top",
        "-l",
        str(sample_total + 1),
        "-s",
        str(int(args.interval)),
        "-pid",
        str(pid),
        "-stats",
        "pid,cpu,rsize,threads,idlew,power",
    ]
    started_ms = int(time.time() * 1000)
    started_mono = time.monotonic()
    process = subprocess.Popen(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    completion_report_value = getattr(args, "completion_report", None)
    completion_report = pathlib.Path(completion_report_value) if completion_report_value else None
    start_signal_value = getattr(args, "start_signal", None)
    start_signal = pathlib.Path(start_signal_value) if start_signal_value else None
    expected_auto_exit = completion_report is not None
    fixture_manifest = getattr(args, "fixture_manifest", None)
    observer_settle = float(getattr(args, "observer_settle_seconds", 0.0))
    samples: list[dict[str, Any]] = []
    previous_idlew: int | None = None
    last_fd: int | None = None
    last_fd_at = 0.0
    seen_rows = 0
    assert process.stdout is not None
    try:
        for line in process.stdout:
            fields = line.split()
            if not fields or fields[0] != str(pid) or len(fields) < 6:
                if expected_auto_exit and exact_pid(identity, required=False) is None:
                    break
                continue
            seen_rows += 1
            if seen_rows == 1:
                previous_idlew = int(fields[4]) if fields[4].isdigit() else None
                if start_signal is not None:
                    if not start_signal.is_absolute() or start_signal.exists() or start_signal.is_symlink():
                        raise EvidenceError("self-test start signal path is unsafe or already exists")
                    if observer_settle > 0:
                        time.sleep(observer_settle)
                    descriptor = os.open(start_signal, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                        handle.flush()
                        os.fsync(handle.fileno())
                continue
            current_mono = time.monotonic()
            fd_measured = False
            if current_mono - last_fd_at >= args.fd_interval or last_fd is None:
                last_fd = count_fds(pid)
                last_fd_at = current_mono
                fd_measured = True
            idlew = int(fields[4]) if fields[4].isdigit() else None
            wakeups = None
            if idlew is not None and previous_idlew is not None and idlew >= previous_idlew:
                wakeups = (idlew - previous_idlew) / args.interval
            previous_idlew = idlew
            try:
                sample = {
                    "timestamp_unix_ms": int(time.time() * 1000),
                    "elapsed_seconds": round(current_mono - started_mono, 6),
                    "cpu_percent": float(fields[1]),
                    "rss_mib": round(parse_memory(fields[2]), 6),
                    "threads": int(fields[3].split("/", 1)[0]),
                    "idle_wakeups_per_s": round(wakeups, 6) if wakeups is not None else None,
                    "energy_impact": float(fields[5]),
                    "file_descriptors": last_fd,
                    "file_descriptors_measured": fd_measured,
                }
            except ValueError as error:
                raise EvidenceError(f"cannot parse top row: {line.strip()}") from error
            samples.append(sample)
            if len(samples) >= sample_total or current_mono - started_mono >= args.duration:
                break
    finally:
        if process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    current_executable = executable_for_pid(pid)
    report = None
    if expected_auto_exit:
        if current_executable is not None:
            raise EvidenceError("signed self-test did not auto-exit before the bounded sampler ended")
        if fixture_manifest is None:
            raise EvidenceError("signed self-test sampler is missing the pinned fixture manifest")
        report = validate_self_test_report(
            completion_report,
            expected_pid=pid,
            fixture_manifest=fixture_manifest,
        )
    elif current_executable != identity["executable_path"]:
        raise EvidenceError("candidate process exited or changed identity during sampling")
    minimum_samples = 20 if expected_auto_exit else math.floor(args.duration / args.interval) - 1
    if len(samples) < minimum_samples:
        stderr = process.stderr.read().strip() if process.stderr else ""
        raise EvidenceError(f"insufficient samples ({len(samples)}): {stderr}")
    ended_ms = int(time.time() * 1000)
    diagnostics_path = pathlib.Path(args.diagnostics)
    diagnostics_start_ms = int(getattr(args, "diagnostics_start_ms", started_ms))
    diagnostics = read_diagnostics(diagnostics_path, diagnostics_start_ms, ended_ms)
    if report is not None:
        validate_self_test_diagnostics(diagnostics, session_id=report["session_id"])
    active_codes = {
        "hotkey_pressed",
        "hotkey_released",
        "recording_started",
        "recording_stopped",
        "transcription_started",
        "transcription_completed",
    }
    if args.phase in {"idle", "idle_10m"} and any(
        record.get("code") in active_codes for record in diagnostics
    ):
        raise EvidenceError("idle phase contains a hotkey, recording, or transcription event")
    phase = {
        "phase": args.phase,
        "pid": pid,
        "started_at_unix_ms": started_ms,
        "ended_at_unix_ms": ended_ms,
        "requested_duration_seconds": args.duration,
        "sample_interval_seconds": args.interval,
        "samples": samples,
        "diagnostics": diagnostics,
    }
    if report is not None:
        phase["self_test_report"] = report
        phase["self_test_report_sha256"] = sha256_file(completion_report)
    result["phases"][args.phase] = phase
    cpu = [sample["cpu_percent"] for sample in samples]
    rss = [sample["rss_mib"] for sample in samples]
    threads = [sample["threads"] for sample in samples]
    fds = [sample["file_descriptors"] for sample in samples]
    fd_measurements = sum(sample["file_descriptors_measured"] for sample in samples)
    wakeups = [sample["idle_wakeups_per_s"] for sample in samples if sample["idle_wakeups_per_s"] is not None]
    energy = [sample["energy_impact"] for sample in samples]
    prefix = args.phase
    set_metric(result, f"{prefix}.duration_seconds", samples[-1]["elapsed_seconds"], 1)
    set_metric(result, f"{prefix}.cpu.avg_percent", statistics.fmean(cpu), len(cpu))
    set_metric(result, f"{prefix}.cpu.p95_percent", percentile(cpu), len(cpu))
    set_metric(result, f"{prefix}.energy.avg_impact", statistics.fmean(energy), len(energy))
    set_metric(result, f"{prefix}.energy.p95_impact", percentile(energy), len(energy))
    if wakeups:
        set_metric(result, f"{prefix}.wakeups.avg_per_s", statistics.fmean(wakeups), len(wakeups))
        set_metric(result, f"{prefix}.wakeups.p95_per_s", percentile(wakeups), len(wakeups))
    current_peak_rss = max(rss)
    prior_peak = result["metrics"].get("memory.peak_mib", {})
    if current_peak_rss >= prior_peak.get("value", -1):
        set_metric(result, "memory.peak_mib", current_peak_rss, len(rss))
    prior_fd_peak = result["metrics"].get("resources.fd.peak", {})
    if max(fds) >= prior_fd_peak.get("value", -1):
        set_metric(result, "resources.fd.peak", max(fds), fd_measurements)
    prior_thread_peak = result["metrics"].get("resources.thread.peak", {})
    if max(threads) >= prior_thread_peak.get("value", -1):
        set_metric(result, "resources.thread.peak", max(threads), len(threads))
    if args.phase in {"transcription", "cycles_20", "history_50"}:
        current_warm_p95 = percentile(rss)
        prior_warm_p95 = result["metrics"].get("memory.post_warmup.p95_mib", {}).get("value", 0)
        set_metric(
            result,
            "memory.post_warmup.p95_mib",
            max(current_warm_p95, prior_warm_p95),
            len(rss),
        )
    if args.phase == "recording":
        recording_duration = correlated_duration(diagnostics, "recording_started", "recording_stopped")
        if recording_duration is None:
            raise EvidenceError("recording phase has no correlated recording_started/recording_stopped pair")
        set_metric(result, "recording.duration_seconds", recording_duration, 1)
    if args.phase == "cycles_20":
        add_cycle_growth_metrics(result, phase)
        if report is not None:
            set_metric(result, "model.download.p95_ms", report["timings"]["model_download_ms"], 1)
            set_metric(result, "model.cold_load.p95_ms", report["timings"]["model_cold_load_ms"], 1)
    if args.phase == "history_50":
        add_history_count(result, pathlib.Path(args.history_db))
    if report is not None:
        add_history_count(result, pathlib.Path(args.history_db))
    result["updated_at"] = now_iso()
    write_json(output, result)
    print(f"recorded {len(samples)} {args.phase} samples for exact pid {pid}: {output}")


def request_exact_typed_quit(identity: dict[str, Any], pid: int) -> None:
    if executable_for_pid(pid) != identity["executable_path"]:
        return
    os.kill(pid, signal.SIGUSR1)
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if executable_for_pid(pid) is None:
            return
        time.sleep(0.05)
    raise EvidenceError("exact candidate ignored the typed SIGUSR1 quit request")


def run_signed_self_test(args: argparse.Namespace) -> None:
    app = require_app(args.app)
    fixture, fixture_manifest = validate_transcription_fixture(args.fixture)
    data_root = validate_empty_disposable_root(args.data_root)
    output = pathlib.Path(args.output)
    if not output.is_absolute() or output.is_symlink() or output.is_relative_to(data_root):
        raise EvidenceError("self-test evidence output must be absolute, non-symlinked, and outside its data root")
    report = data_root / SELF_TEST_REPORT_NAME
    interaction_report = data_root / INTERACTION_REPORT_NAME
    start_signal = data_root / SELF_TEST_START_NAME
    diagnostics = data_root / CURRENT_DATA_NAMESPACE / "diagnostics/events.ndjson"
    history_db = data_root / CURRENT_DATA_NAMESPACE / "history.sqlite"
    private_outputs = (report, start_signal, interaction_report) if args.interaction else (report, start_signal)
    for path in private_outputs:
        if path.exists() or path.is_symlink():
            raise EvidenceError(f"self-test disposable artifact already exists: {path.name}")

    result = load_result(output, app)
    identity = result["candidate"]
    if exact_pid(identity, required=False) is not None:
        raise EvidenceError("stop the exact candidate before starting its isolated self-test")
    write_json(output, result)

    launched_ms = int(time.time() * 1000)
    launch_command = [
        "/usr/bin/open",
        "-n",
        "--env",
        f"{SELF_TEST_GATE_ENV}={BUDGET_VERSION}",
        "--env",
        f"{SELF_TEST_FIXTURE_ENV}={fixture}",
        "--env",
        f"{SELF_TEST_ROOT_ENV}={data_root}",
    ]
    if args.interaction:
        launch_command.extend(["--env", f"{INTERACTION_ENV}={INTERACTION_CONTRACT}"])
    launch_command.extend([str(app), "--args", SELF_TEST_ARGUMENT])
    launch = subprocess.run(
        launch_command,
        text=True,
        capture_output=True,
        check=False,
    )
    if launch.returncode != 0:
        raise EvidenceError(f"LaunchServices rejected the signed self-test: {launch.stderr.strip()}")

    pid = None
    deadline = time.monotonic() + args.launch_timeout
    while time.monotonic() < deadline:
        pid = exact_pid(identity, required=False)
        if pid is not None:
            break
        time.sleep(0.02)
    if pid is None:
        raise EvidenceError("signed self-test did not create the exact LaunchServices process")

    try:
        app_info = run(
            [
                "/usr/bin/lsappinfo",
                "info",
                "-only",
                "bundlepath,bundleid,pid,ApplicationType",
                "-app",
                str(pid),
            ],
            check=False,
        )
        if (
            f'"CFBundleIdentifier"="{BUNDLE_ID}"' not in app_info
            or f'"LSBundlePath"="{app}"' not in app_info
            or '"ApplicationType"="UIElement"' not in app_info
        ):
            raise EvidenceError("self-test PID is not the exact LaunchServices UIElement candidate")
        ready = wait_for_diagnostic_code(
            diagnostics,
            "performance_self_test_ready",
            launched_ms,
            args.ready_timeout,
        )
        if executable_for_pid(pid) != identity["executable_path"]:
            raise EvidenceError("signed self-test exited before the observer handshake")
        if args.verified_model_cache:
            stage_verified_model_cache(pathlib.Path(args.verified_model_cache), data_root)

        sample_phase(
            argparse.Namespace(
                app=str(app),
                phase="cycles_20",
                duration=args.timeout,
                interval=args.interval,
                fd_interval=args.fd_interval,
                output=str(output),
                diagnostics=str(diagnostics),
                history_db=str(history_db),
                completion_report=str(report),
                start_signal=str(start_signal),
                fixture_manifest=fixture_manifest,
                observer_settle_seconds=args.observer_settle_seconds,
                diagnostics_start_ms=launched_ms,
            )
        )
        final_result = load_result(output)
        interaction = None
        if args.interaction:
            interaction = validate_interaction_report(interaction_report)
            evidence = [{
                "kind": "post_event_tap_synthetic",
                "name": interaction_report.name,
                "sha256": sha256_file(interaction_report),
            }]
            pulses = interaction["pulses"]
            release_to_paste_dispatch = [
                max(0.0, value - INTERACTION_PULSE_HOLD_MS)
                for value in pulses["paste_dispatch_ms"]
            ]
            set_metric(
                final_result,
                "latency.hotkey_handler_to_overlay.p95_ms",
                percentile(pulses["overlay_ms"]),
                len(pulses["overlay_ms"]),
                evidence,
            )
            set_metric(
                final_result,
                "latency.release_handler_to_paste_dispatch.p95_ms",
                percentile(release_to_paste_dispatch),
                len(release_to_paste_dispatch),
                evidence,
            )
            set_metric(
                final_result,
                "recording.duration_seconds",
                interaction["hold"]["observed_ms"] / 1_000,
                1,
                evidence,
            )
            final_result["phases"]["post_event_tap_synthetic"] = {
                "classification": "post_event_tap_synthetic",
                "source": "signed_wrenflow_typed_hotkey_callback",
                "key_code": 96,
                "pulse_samples": 20,
                "hold_seconds": round(interaction["hold"]["observed_ms"] / 1_000, 6),
                "tcc_or_microphone_evidence": False,
                "report_sha256": evidence[0]["sha256"],
            }
        final_result["phases"]["signed_self_test"] = {
            "launched_at_unix_ms": launched_ms,
            "ready_at_unix_ms": ready["timestamp_unix_ms"],
            "pid": pid,
            "fixture_manifest_sha256": sha256_file(FIXTURE_MANIFEST),
            "report_sha256": sha256_file(report),
            "auto_exit_observed": True,
            "interaction_classification": (
                "post_event_tap_synthetic" if interaction is not None else "none"
            ),
            "model_cache_staged": bool(args.verified_model_cache),
        }
        if args.verified_model_cache:
            final_result["metrics"].pop("model.download.p95_ms", None)
        current = collect_app(app)
        if current["bundle_tree_sha256"] != identity["bundle_tree_sha256"]:
            raise EvidenceError("candidate bytes changed during the signed self-test")
        final_result["updated_at"] = now_iso()
        write_json(output, final_result)
        print(f"signed LaunchServices self-test completed for exact pid {pid}: {output}")
    except BaseException:
        if pid is not None and executable_for_pid(pid) == identity["executable_path"]:
            request_exact_typed_quit(identity, pid)
        raise


def linear_slope(values: list[float]) -> float:
    if len(values) < 2:
        return 0.0
    xs = list(range(len(values)))
    x_mean = statistics.fmean(xs)
    y_mean = statistics.fmean(values)
    denominator = sum((value - x_mean) ** 2 for value in xs)
    return sum((x - x_mean) * (y - y_mean) for x, y in zip(xs, values)) / denominator


def correlated_duration(
    records: list[dict[str, Any]], start_code: str, end_code: str
) -> float | None:
    longest: float | None = None
    for start in records:
        correlation = start.get("correlation_id")
        if start.get("code") != start_code or not correlation:
            continue
        end = next(
            (
                record
                for record in records
                if record.get("code") == end_code
                and record.get("correlation_id") == correlation
                and record["timestamp_unix_ms"] >= start["timestamp_unix_ms"]
            ),
            None,
        )
        if end:
            duration = (end["timestamp_unix_ms"] - start["timestamp_unix_ms"]) / 1000
            longest = duration if longest is None else max(longest, duration)
    return longest


def monotonic_tail(values: list[float], epsilon: float) -> bool:
    tail = values[-10:]
    return len(tail) == 10 and all(right - left > epsilon for left, right in zip(tail, tail[1:]))


def add_cycle_growth_metrics(result: dict[str, Any], phase: dict[str, Any]) -> None:
    recording_correlations = {
        record.get("correlation_id")
        for record in phase["diagnostics"]
        if record.get("code") == "recording_started" and record.get("correlation_id")
    }
    completions = [
        record
        for record in phase["diagnostics"]
        if record.get("code") == "transcription_completed"
        and record.get("correlation_id")
        and record.get("correlation_id") not in recording_correlations
    ]
    samples = phase["samples"]
    snapshots = []
    for event in completions:
        later = [sample for sample in samples if sample["timestamp_unix_ms"] >= event["timestamp_unix_ms"]]
        if later:
            snapshots.append(later[0])
    snapshot_timestamps = [sample["timestamp_unix_ms"] for sample in snapshots]
    if len(snapshot_timestamps) != len(set(snapshot_timestamps)):
        raise EvidenceError(
            "multiple transcription completions mapped to one resource sample; "
            "add at least one sampler interval of settle time between fixture cycles"
        )
    count = len(snapshots)
    set_metric(result, "cycles.completed.count", count, 1)
    intervals = []
    for start in phase["diagnostics"]:
        correlation = start.get("correlation_id")
        if (
            start.get("code") != "transcription_started"
            or not correlation
            or correlation in recording_correlations
        ):
            continue
        end = next(
            (
                record
                for record in phase["diagnostics"]
                if record.get("code") == "transcription_completed"
                and record.get("correlation_id") == correlation
                and record["timestamp_unix_ms"] >= start["timestamp_unix_ms"]
            ),
            None,
        )
        if end:
            intervals.append((start["timestamp_unix_ms"], end["timestamp_unix_ms"]))
    interval_ms = int(phase["sample_interval_seconds"] * 1000)
    inference_samples = [
        sample
        for sample in samples
        if any(
            sample["timestamp_unix_ms"] - interval_ms <= end
            and sample["timestamp_unix_ms"] >= start
            for start, end in intervals
        )
    ]
    if inference_samples:
        set_metric(
            result,
            "transcription.cpu.p95_percent",
            percentile(sample["cpu_percent"] for sample in inference_samples),
            len(inference_samples),
        )
        set_metric(
            result,
            "transcription.energy.p95_impact",
            percentile(sample["energy_impact"] for sample in inference_samples),
            len(inference_samples),
        )
    if count < 2:
        return
    rss = [sample["rss_mib"] for sample in snapshots]
    fds = [float(sample["file_descriptors"]) for sample in snapshots]
    threads = [float(sample["threads"]) for sample in snapshots]
    set_metric(result, "growth.rss.delta_mib", rss[-1] - rss[0], count)
    set_metric(result, "growth.rss.slope_mib_per_cycle", linear_slope(rss), count)
    set_metric(result, "growth.fd.delta", fds[-1] - fds[0], count)
    set_metric(result, "growth.thread.delta", threads[-1] - threads[0], count)
    monotonic = sum(
        (
            monotonic_tail(rss, 1.0),
            monotonic_tail(fds, 0.0),
            monotonic_tail(threads, 0.0),
        )
    )
    set_metric(result, "growth.monotonic_tail.count", monotonic, count)


def add_history_count(result: dict[str, Any], path: pathlib.Path) -> None:
    if not path.is_absolute() or not path.is_file() or path.is_symlink():
        raise EvidenceError(f"current-format history database is missing: {path}")
    try:
        connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        integrity = connection.execute("PRAGMA integrity_check").fetchone()
        version = connection.execute("PRAGMA user_version").fetchone()
        tables = connection.execute(
            "SELECT name FROM sqlite_schema "
            "WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
        ).fetchall()
        columns = connection.execute("PRAGMA table_info('pipeline_history')").fetchall()
        row = connection.execute("SELECT COUNT(*) FROM pipeline_history").fetchone()
        connection.close()
    except sqlite3.Error as error:
        raise EvidenceError(f"cannot read current-format history row count: {error}") from error
    column_names = [column[1] for column in columns]
    expected_columns = [
        "id",
        "timestamp",
        "transcript",
        "custom_vocabulary",
        "audio_file_name",
        "metrics_json",
    ]
    if integrity != ("ok",):
        raise EvidenceError("current-format history database failed integrity_check")
    if version != (1,):
        raise EvidenceError(f"current-format history user_version is {version[0] if version else 'missing'}, expected 1")
    if tables != [("pipeline_history",)] or column_names != expected_columns:
        raise EvidenceError("history database does not have the exact current GPUI schema")
    count = int(row[0])
    if count != 50:
        raise EvidenceError(f"current-format performance History has {count} rows, expected exactly 50")
    set_metric(result, "history.rows.count", count, 1)


def launch_ready_event(path: pathlib.Path, after_ms: int) -> dict[str, Any] | None:
    records = read_diagnostics(path, after_ms - 50)
    startups = [record for record in records if record.get("code") == "startup"]
    for startup in reversed(startups):
        ready = next(
            (
                record
                for record in records
                if record.get("session_id") == startup.get("session_id")
                and record.get("code") == "shell_capabilities_observed"
                and record["timestamp_unix_ms"] >= startup["timestamp_unix_ms"]
            ),
            None,
        )
        if ready:
            return ready
    return None


def terminate_exact(identity: dict[str, Any], pid: int) -> None:
    if executable_for_pid(pid) != identity["executable_path"]:
        raise EvidenceError("refusing to terminate a process whose executable identity changed")
    os.kill(pid, signal.SIGUSR1)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if executable_for_pid(pid) is None:
            return
        time.sleep(0.05)
    raise EvidenceError(f"exact candidate pid {pid} did not complete typed SIGUSR1 shutdown")


def measure_launch(args: argparse.Namespace) -> None:
    app = require_app(args.app)
    output = pathlib.Path(args.output)
    result = load_result(output, app)
    identity = result["candidate"]
    if exact_pid(identity, required=False) is not None:
        raise EvidenceError("stop the exact candidate before launch measurement")
    if args.mode == "cold" and (not args.cold_confirmed or args.iterations != 1):
        raise EvidenceError("cold evidence requires --cold-confirmed and exactly one launch per boot/quiesced run")
    if args.malloc_stack_logging and (args.iterations != 1 or not args.leave_running):
        raise EvidenceError(
            "MallocStackLogging launch is a single retained process for paired private leak scans"
        )
    constrained_cold = (
        args.mode == "cold"
        and result.get("host", {})
        .get("evidence_eligibility", {})
        .get("github_m1_7gb_constrained_preflight")
    )
    if constrained_cold and not re.fullmatch(
        r"gh-[0-9]+-[0-9]+-cold-[1-5]", args.fresh_runner_id or ""
    ):
        raise EvidenceError(
            "constrained cold evidence requires bounded run-attempt-shard fresh runner identity"
        )
    diagnostics = pathlib.Path(args.diagnostics)
    key = f"launch_{args.mode}"
    existing = result["phases"].get(key, {}).get("samples", [])
    samples = list(existing)
    for _ in range(args.iterations):
        started_ms = int(time.time() * 1000)
        launch_command = ["/usr/bin/open", "-n"]
        if args.malloc_stack_logging:
            launch_command.extend(["--env", "MallocStackLogging=1"])
        launch_command.append(str(app))
        subprocess.run(launch_command, check=True)
        deadline = time.monotonic() + args.timeout
        pid = None
        ready = None
        while time.monotonic() < deadline:
            pid = exact_pid(identity, required=False)
            ready = launch_ready_event(diagnostics, started_ms)
            if pid is not None and ready is not None:
                info = run(
                    ["/usr/bin/lsappinfo", "info", "-only", "bundlepath,pid,ApplicationType", "-app", str(pid)],
                    check=False,
                )
                if '"ApplicationType"="UIElement"' in info:
                    break
            time.sleep(0.01)
        if pid is None or ready is None:
            raise EvidenceError("candidate did not reach diagnostic + LaunchServices ready state")
        latency = ready["timestamp_unix_ms"] - started_ms
        if latency < 0:
            raise EvidenceError("wall clock moved backwards during launch measurement")
        sample = {
            "started_at_unix_ms": started_ms,
            "ready_at_unix_ms": ready["timestamp_unix_ms"],
            "latency_ms": latency,
            "session_id": ready.get("session_id"),
        }
        if constrained_cold:
            sample["fresh_runner_id"] = args.fresh_runner_id
        samples.append(sample)
        if not args.leave_running:
            terminate_exact(identity, pid)
        if args.mode == "warm" and args.iterations > 1:
            time.sleep(args.settle_seconds)
    result["phases"][key] = {
        "phase": key,
        "definition": (
            "human-confirmed first post-boot or >=60-second quiesced LaunchServices start"
            if args.mode == "cold"
            else "LaunchServices restart after a verified exact-candidate termination"
        ),
        "samples": samples,
    }
    if args.malloc_stack_logging:
        result["phases"][key]["malloc_stack_logging"] = True
    values = [sample["latency_ms"] for sample in samples]
    set_metric(result, f"launch.{args.mode}.p95_ms", percentile(values), len(values))
    result["updated_at"] = now_iso()
    write_json(output, result)
    print(f"recorded {len(samples)} total {args.mode} launch samples: {output}")


def read_ndjson(path: pathlib.Path, event_name: str) -> list[dict[str, Any]]:
    if not path.is_file():
        raise EvidenceError(f"event evidence does not exist: {path}")
    events = []
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            try:
                event = json.loads(line)
            except json.JSONDecodeError as error:
                raise EvidenceError(f"invalid NDJSON in {path}: {error}") from error
            if event.get("event") == event_name and isinstance(event.get("timestamp_unix_ms"), int):
                events.append(event)
    return sorted(events, key=lambda event: event["timestamp_unix_ms"])


def pair_latency(starts: list[int], ends: list[int], maximum_ms: int) -> list[int]:
    remaining = list(ends)
    latencies = []
    for start in starts:
        match_index = next(
            (index for index, end in enumerate(remaining) if 0 <= end - start <= maximum_ms),
            None,
        )
        if match_index is not None:
            end = remaining.pop(match_index)
            latencies.append(end - start)
    return latencies


def correlate(args: argparse.Namespace) -> None:
    result_path = pathlib.Path(args.result)
    result = load_result(result_path)
    diagnostics = read_diagnostics(pathlib.Path(args.diagnostics))
    if args.overlay_events:
        overlays = read_ndjson(pathlib.Path(args.overlay_events), "overlay_shown")
        presses = [record["timestamp_unix_ms"] for record in diagnostics if record.get("code") == "hotkey_pressed"]
        latency = pair_latency(presses, [event["timestamp_unix_ms"] for event in overlays], 1000)
        if not latency:
            raise EvidenceError("no hotkey_pressed -> overlay_shown pairs found")
        set_metric(result, "latency.hotkey_to_overlay.p95_ms", percentile(latency), len(latency), [
            {"kind": "observer_ndjson", "name": pathlib.Path(args.overlay_events).name, "sha256": sha256_file(pathlib.Path(args.overlay_events))}
        ])
    if args.paste_events:
        pastes = read_ndjson(pathlib.Path(args.paste_events), "text_changed")
        releases = [record["timestamp_unix_ms"] for record in diagnostics if record.get("code") == "hotkey_released"]
        latency = pair_latency(releases, [event["timestamp_unix_ms"] for event in pastes], 15000)
        if not latency:
            raise EvidenceError("no hotkey_released -> controlled text_changed pairs found")
        set_metric(result, "latency.release_to_paste.p95_ms", percentile(latency), len(latency), [
            {"kind": "paste_target_ndjson", "name": pathlib.Path(args.paste_events).name, "sha256": sha256_file(pathlib.Path(args.paste_events))}
        ])
    result["updated_at"] = now_iso()
    write_json(result_path, result)
    print(f"correlated external latency evidence: {result_path}")


def record_metric(args: argparse.Namespace) -> None:
    result_path = pathlib.Path(args.result)
    result = load_result(result_path)
    evidence = []
    if args.evidence:
        path = pathlib.Path(args.evidence)
        if not path.exists() or path.is_symlink():
            raise EvidenceError(f"evidence must exist and not be a symlink: {path}")
        if path.is_dir():
            digest = tree_sha256(path)
        else:
            digest = sha256_file(path)
        evidence.append({"kind": args.evidence_kind, "name": path.name, "sha256": digest})
        result["traces"].append(evidence[-1])
    set_metric(result, args.metric, args.value, args.sample_count, evidence)
    result["updated_at"] = now_iso()
    write_json(result_path, result)
    print(f"recorded {args.metric}={args.value}: {result_path}")


def parse_leaks_summary(output: str, *, expected_pid: int) -> tuple[int, int]:
    matches = re.findall(
        rf"^Process {expected_pid}: ([0-9]+) leaks? for ([0-9]+) total leaked bytes\.$",
        output,
        re.MULTILINE,
    )
    if len(matches) != 1:
        raise EvidenceError("macOS leaks did not emit exactly one bounded process summary")
    count, leaked_bytes = (int(value) for value in matches[0])
    if (count == 0) != (leaked_bytes == 0):
        raise EvidenceError("macOS leaks summary has inconsistent leak and byte counts")
    return count, leaked_bytes


def scan_leaks(args: argparse.Namespace) -> None:
    app = require_app(args.app)
    result_path = pathlib.Path(args.result)
    result = load_result(result_path, app)
    identity = result["candidate"]
    pid = exact_pid(identity)
    command = ["/usr/bin/leaks", "-q", "--fullStacks", "--noContent", str(pid)]
    if args.sudo:
        command = ["/usr/bin/sudo", "-n", *command]
    process = subprocess.run(
        command,
        text=True,
        capture_output=True,
        check=False,
        timeout=args.timeout,
    )
    output = "\n".join(part for part in (process.stdout, process.stderr) if part)
    count, leaked_bytes = parse_leaks_summary(output, expected_pid=pid)
    if executable_for_pid(pid) != identity["executable_path"]:
        raise EvidenceError("candidate process exited or changed identity during the live leak scan")
    if process.returncode != 0 and count == 0:
        raise EvidenceError(f"macOS leaks exited {process.returncode} despite reporting zero leaks")
    canonical_summary = f"leaks-stacklogged-summary-v1\ncount={count}\nbytes={leaked_bytes}\n"
    evidence = [{
        "kind": "macos_leaks_privileged_live_attach" if args.sudo else "macos_leaks_live_attach",
        "name": "leaks-stacklogged-summary-v1",
        "sha256": hashlib.sha256(output.encode()).hexdigest(),
    }]
    phase = result["phases"].get("leaks_stacklogged")
    captured_at = int(time.time() * 1000)
    summary = {
        "count": count,
        "bytes": leaked_bytes,
        "captured_at_unix_ms": captured_at,
        "canonical_summary_sha256": hashlib.sha256(canonical_summary.encode()).hexdigest(),
        "private_raw_output_sha256": evidence[0]["sha256"],
    }
    if args.mode == "baseline":
        if phase is not None:
            raise EvidenceError("stack-logged leak baseline already exists in this result")
        result["phases"]["leaks_stacklogged"] = {
            "phase": "leaks_stacklogged",
            "pid": pid,
            "stack_logging_confirmed": True,
            "baseline": summary,
        }
    else:
        if not isinstance(phase, dict) or phase.get("pid") != pid or phase.get("stack_logging_confirmed") is not True:
            raise EvidenceError("stack-logged leak comparison requires a baseline from the same exact process")
        baseline = phase.get("baseline", {})
        if captured_at - int(baseline.get("captured_at_unix_ms", captured_at)) < args.minimum_observation_seconds * 1_000:
            raise EvidenceError("stack-logged leak observation was shorter than the declared minimum")
        diagnostics = read_diagnostics(
            pathlib.Path(args.diagnostics),
            int(baseline["captured_at_unix_ms"]),
            captured_at,
        )
        correlations: dict[str, set[str]] = {}
        required_codes = {
            "recording_started",
            "recording_stopped",
            "transcription_started",
            "transcription_completed",
        }
        for record in diagnostics:
            correlation = record.get("correlation_id")
            code = record.get("code")
            if correlation and code in required_codes:
                correlations.setdefault(correlation, set()).add(code)
        completed = [correlation for correlation, codes in correlations.items() if codes == required_codes]
        if len(completed) != args.required_cycles:
            raise EvidenceError(
                f"stack-logged leak comparison requires exactly {args.required_cycles} closed app cycles; found {len(completed)}"
            )
        phase["comparison"] = summary
        phase["closed_cycle_count"] = len(completed)
        phase["observation_seconds"] = round(
            (captured_at - int(baseline["captured_at_unix_ms"])) / 1_000,
            3,
        )
        phase["count_delta"] = count - int(baseline["count"])
        phase["bytes_delta"] = leaked_bytes - int(baseline["bytes"])
        set_metric(
            result,
            "leaks.definite.growth_count",
            max(0, phase["count_delta"]),
            len(completed),
            evidence,
        )
    result["traces"].append(evidence[0])
    result["updated_at"] = now_iso()
    write_json(result_path, result)
    print(f"recorded stack-logged leak {args.mode} count={count} bytes={leaked_bytes}: {result_path}")


def merge_cold_launch(args: argparse.Namespace) -> None:
    app = require_app(args.app)
    result_path = pathlib.Path(args.result)
    result = load_result(result_path, app)
    shards = []
    for value in args.shard:
        path = pathlib.Path(value)
        if path.is_symlink() or not path.is_file():
            raise EvidenceError(f"cold shard must be a regular non-symlink file: {path}")
        shards.append((path.name, read_json(path)))
    if len(shards) != 5:
        raise EvidenceError("cold launch aggregation requires exactly five fresh-runner shards")
    if not re.fullmatch(r"[A-Za-z0-9._+-]{1,160}", args.candidate_id):
        raise EvidenceError("candidate ID must be a bounded path-free artifact identifier")

    identity_keys = (
        "bundle_tree_sha256",
        "executable_sha256",
        "cdhash",
        "bundle_version",
        "bundle_build",
    )
    evidence_hashes: set[str] = set()
    runner_ids: set[str] = set()
    samples: list[dict[str, Any]] = []
    for label, shard in shards:
        failures = check_provenance(shard, label)
        if failures:
            raise EvidenceError("invalid cold shard provenance: " + "; ".join(failures))
        if evidence_role(shard) != "constrained_noninteractive":
            raise EvidenceError(f"cold shard is not constrained macos-14 evidence: {label}")
        if shard.get("candidate_id") != args.candidate_id:
            raise EvidenceError(f"cold shard candidate ID differs: {label}")
        for key in identity_keys:
            if shard.get("candidate", {}).get(key) != result.get("candidate", {}).get(key):
                raise EvidenceError(f"cold shard candidate {key} differs: {label}")
        if shard.get("source", {}).get("commit") != result.get("source", {}).get("commit"):
            raise EvidenceError(f"cold shard source commit differs: {label}")
        if set(shard.get("metrics", {})) != {"launch.cold.p95_ms"}:
            raise EvidenceError(f"cold shard contains unexpected metrics: {label}")
        if set(shard.get("phases", {})) != {"launch_cold"}:
            raise EvidenceError(f"cold shard contains unexpected phases: {label}")
        phase = shard["phases"]["launch_cold"]
        if phase.get("definition") != "human-confirmed first post-boot or >=60-second quiesced LaunchServices start":
            raise EvidenceError(f"cold shard does not use the cold-launch definition: {label}")
        phase_samples = phase.get("samples")
        metric = shard["metrics"]["launch.cold.p95_ms"]
        if not isinstance(phase_samples, list) or len(phase_samples) != 1 or metric.get("sample_count") != 1:
            raise EvidenceError(f"cold shard must contain exactly one sample: {label}")
        sample = phase_samples[0]
        if not isinstance(sample, dict) or set(sample) != {
            "started_at_unix_ms",
            "ready_at_unix_ms",
            "latency_ms",
            "session_id",
            "fresh_runner_id",
        }:
            raise EvidenceError(f"cold shard sample has an unexpected shape: {label}")
        started = sample.get("started_at_unix_ms")
        ready = sample.get("ready_at_unix_ms")
        latency = sample.get("latency_ms")
        if not all(isinstance(value, int) and not isinstance(value, bool) for value in (started, ready, latency)):
            raise EvidenceError(f"cold shard sample has non-integer timings: {label}")
        if started < 0 or ready < started or latency != ready - started:
            raise EvidenceError(f"cold shard sample timings are inconsistent: {label}")
        if not re.fullmatch(r"s-[0-9a-f]{16}", sample.get("session_id", "")):
            raise EvidenceError(f"cold shard sample has an invalid session ID: {label}")
        runner_id = sample.get("fresh_runner_id", "")
        if not re.fullmatch(r"gh-[0-9]+-[0-9]+-cold-[1-5]", runner_id):
            raise EvidenceError(f"cold shard sample has an invalid fresh runner ID: {label}")
        if runner_id in runner_ids:
            raise EvidenceError("cold shards reuse one fresh runner identity")
        runner_ids.add(runner_id)
        if float(metric.get("value", -1)) != float(latency):
            raise EvidenceError(f"cold shard metric differs from its sole sample: {label}")
        evidence_hash = shard.get("evidence_sha256")
        if evidence_hash in evidence_hashes:
            raise EvidenceError("cold shards contain duplicate sealed evidence")
        evidence_hashes.add(evidence_hash)
        samples.append({**sample, "shard_evidence_sha256": evidence_hash})

    result["phases"]["launch_cold"] = {
        "phase": "launch_cold",
        "definition": "one exact signed LaunchServices launch on each of five fresh GitHub-hosted macos-14 runners",
        "samples": sorted(samples, key=lambda sample: sample["shard_evidence_sha256"]),
    }
    latencies = [sample["latency_ms"] for sample in samples]
    evidence = [
        {"kind": "sealed_cold_runner_shard", "name": "cold-shard-v1", "sha256": digest}
        for digest in sorted(evidence_hashes)
    ]
    set_metric(result, "launch.cold.p95_ms", percentile(latencies), len(latencies), evidence)
    result.setdefault("aggregations", {})["launch_cold"] = {
        "contract": "five-fresh-macos14-runners-v1",
        "sealed_shard_sha256": sorted(evidence_hashes),
    }
    result["updated_at"] = now_iso()
    write_json(result_path, result)
    print(f"merged five fresh-runner cold launch samples: {result_path}")


def canonical_hash(result: dict[str, Any]) -> str:
    value = dict(result)
    value.pop("evidence_sha256", None)
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def contains_absolute_path(value: Any) -> bool:
    if isinstance(value, dict):
        return any(contains_absolute_path(item) for item in value.values())
    if isinstance(value, list):
        return any(contains_absolute_path(item) for item in value)
    if isinstance(value, str):
        return value.startswith("/") or bool(re.match(r"^[A-Za-z]:[\\/]", value))
    return False


def sanitize_result(args: argparse.Namespace) -> None:
    path = pathlib.Path(args.result)
    result = load_result(path)
    candidate = result.get("candidate", {})
    candidate.pop("app_path", None)
    candidate.pop("executable_path", None)
    result["sanitized"] = True
    result["updated_at"] = now_iso()
    if contains_absolute_path(result):
        raise EvidenceError("result still contains an absolute path after sanitization")
    write_json(path, result)
    print(f"sanitized path-free performance evidence: {path}")


def seal_result(args: argparse.Namespace) -> None:
    path = pathlib.Path(args.result)
    result = load_result(path)
    if result.get("sanitized") is not True or contains_absolute_path(result):
        raise EvidenceError("sanitize the path-free result before sealing it")
    if not re.fullmatch(r"[A-Za-z0-9._+-]{1,160}", args.candidate_id):
        raise EvidenceError("candidate ID must be a bounded path-free artifact identifier")
    result["candidate_id"] = args.candidate_id
    result["sealed"] = True
    result["sealed_at"] = now_iso()
    result["evidence_sha256"] = canonical_hash(result)
    write_json(path, result)
    print(f"sealed evidence {result['evidence_sha256']}: {path}")


def evidence_role(result: dict[str, Any]) -> str | None:
    eligibility = result.get("host", {}).get("evidence_eligibility", {})
    if eligibility.get("github_m1_7gb_constrained_preflight"):
        return "constrained_noninteractive"
    if eligibility.get("physical_supported_interactive"):
        return "physical_interactive"
    return None


def metric_evidence_role(result: dict[str, Any], key: str, metric: dict[str, Any]) -> str | None:
    synthetic_metrics = {
        "latency.hotkey_handler_to_overlay.p95_ms",
        "latency.release_handler_to_paste_dispatch.p95_ms",
        "recording.duration_seconds",
    }
    if key not in synthetic_metrics:
        return evidence_role(result)
    evidence = metric.get("evidence")
    phase = result.get("phases", {}).get("post_event_tap_synthetic")
    if (
        isinstance(evidence, list)
        and len(evidence) == 1
        and evidence[0].get("kind") == "post_event_tap_synthetic"
        and evidence[0].get("name") == INTERACTION_REPORT_NAME
        and re.fullmatch(r"[0-9a-f]{64}", evidence[0].get("sha256", ""))
        and isinstance(phase, dict)
        and phase.get("classification") == "post_event_tap_synthetic"
        and phase.get("source") == "signed_wrenflow_typed_hotkey_callback"
        and phase.get("tcc_or_microphone_evidence") is False
    ):
        return "post_event_tap_synthetic"
    return None


def check_provenance(result: dict[str, Any], label: str) -> list[str]:
    failures = []
    host = result.get("host", {})
    candidate = result.get("candidate", {})
    source = result.get("source", {})
    role = evidence_role(result)
    if role is None:
        failures.append(f"{label}: host is neither the constrained macos-14 runner nor a supported physical interactive Mac")
    if result.get("sanitized") is not True or contains_absolute_path(result):
        failures.append(f"{label}: evidence is not explicitly sanitized and path-free")
    if result.get("phases", {}).get("signed_self_test", {}).get("model_cache_staged") is True:
        failures.append(f"{label}: cache-staged functional smoke cannot become release evidence")
    if host.get("missing_required_templates"):
        failures.append(f"{label}: missing Instruments templates: {host['missing_required_templates']}")
    if role == "physical_interactive":
        power = host.get("power", {})
        if power.get("source") != "ac":
            failures.append(f"{label}: physical interaction evidence was not captured on AC power")
        if power.get("low_power_mode") is not False:
            failures.append(f"{label}: Low Power Mode was enabled or could not be proven disabled")
        if power.get("thermal_nominal") is not True:
            failures.append(f"{label}: thermal state was not nominal")
    if source.get("dirty") is not False or not re.fullmatch(r"[0-9a-f]{40}", source.get("commit", "")):
        failures.append(f"{label}: source commit is dirty or not an exact 40-character Git commit")
    if candidate.get("developer_id_signed") is not True:
        failures.append(f"{label}: candidate is not signed by the expected Developer ID team")
    if candidate.get("architectures") != ["arm64"]:
        failures.append(f"{label}: candidate architecture is not exactly arm64")
    if not re.fullmatch(r"[A-Za-z0-9._+-]{1,160}", result.get("candidate_id", "")):
        failures.append(f"{label}: candidate_id is missing or not a bounded artifact identifier")
    if not result.get("sealed"):
        failures.append(f"{label}: evidence is not sealed")
    elif canonical_hash(result) != result.get("evidence_sha256"):
        failures.append(f"{label}: sealed evidence hash does not match the result content")
    return failures


def verify(args: argparse.Namespace) -> None:
    result_paths = [pathlib.Path(args.result)] + [pathlib.Path(path) for path in args.companion_result]
    results = [(path.name, read_json(path)) for path in result_paths]
    budgets = read_json(pathlib.Path(args.budgets))
    if budgets.get("schema_version") != SCHEMA_VERSION:
        raise EvidenceError("unsupported budget schema")
    for label, result in results:
        if result.get("schema_version") != SCHEMA_VERSION:
            raise EvidenceError(f"unsupported result schema: {label}")
        if result.get("budget_version") != budgets.get("budget_version"):
            raise EvidenceError(f"result and budget versions differ: {label}")
    failures: list[str] = []
    if args.profile in {"release", "constrained"}:
        for label, result in results:
            failures.extend(check_provenance(result, label))
        roles = {evidence_role(result) for _, result in results}
        required_roles = (
            ("constrained_noninteractive", "physical_interactive")
            if args.profile == "release"
            else ("constrained_noninteractive",)
        )
        for required_role in required_roles:
            if required_role not in roles:
                failures.append(f"{args.profile} evidence is missing {required_role}")
        if args.profile == "constrained" and roles - {"constrained_noninteractive"}:
            failures.append("constrained profile contains evidence from another host class")
        reference = results[0][1]
        identity_keys = ("bundle_tree_sha256", "executable_sha256", "cdhash", "bundle_version", "bundle_build")
        for label, result in results[1:]:
            for key in identity_keys:
                if result.get("candidate", {}).get(key) != reference.get("candidate", {}).get(key):
                    failures.append(f"{label}: candidate {key} differs from the primary result")
            if result.get("source", {}).get("commit") != reference.get("source", {}).get("commit"):
                failures.append(f"{label}: source commit differs from the primary result")
            if result.get("candidate_id") != reference.get("candidate_id"):
                failures.append(f"{label}: candidate_id differs from the primary result")
    policy = budgets.get("evidence_policy", {})
    metric_roles: dict[str, str] = {}
    for role in ("constrained_noninteractive", "post_event_tap_synthetic", "physical_interactive"):
        for key in policy.get(role, []):
            if key in metric_roles:
                failures.append(f"budget evidence policy assigns {key} more than once")
            metric_roles[key] = role
    evaluated_metrics = 0
    evaluated_measurements = 0
    for budget in budgets.get("budgets", []):
        key = budget["metric"]
        required_role = metric_roles.get(key)
        if args.profile in {"release", "constrained"} and required_role is None:
            failures.append(f"budget evidence policy does not assign {key}")
            continue
        if args.profile == "constrained" and required_role != "constrained_noninteractive":
            continue
        selected = []
        for label, result in results:
            actual = result.get("metrics", {}).get(key)
            if actual is None:
                continue
            if args.profile == "smoke" or metric_evidence_role(result, key, actual) == required_role:
                selected.append((label, actual))
        if not selected:
            if args.profile in {"release", "constrained"}:
                failures.append(f"missing required {required_role} metric {key}")
            continue
        evaluated_metrics += 1
        for label, actual in selected:
            evaluated_measurements += 1
            if actual.get("sample_count", 0) < budget.get("min_samples", 1):
                failures.append(
                    f"{label}: {key} has {actual.get('sample_count', 0)} samples; requires {budget.get('min_samples', 1)}"
                )
            value = actual.get("value")
            threshold = budget["threshold"]
            comparison = budget["comparison"]
            if comparison == "<=":
                passed = value <= threshold
            elif comparison == ">=":
                passed = value >= threshold
            elif comparison == "==":
                passed = value == threshold
            else:
                failures.append(f"budget {key} uses unsupported comparison {comparison!r}")
                continue
            if not passed:
                failures.append(f"{label}: {key}={value} {budget['unit']} violates {comparison} {threshold}")
    budget_metrics = {budget["metric"] for budget in budgets.get("budgets", [])}
    unassigned = budget_metrics - set(metric_roles)
    unknown = set(metric_roles) - budget_metrics
    if args.profile in {"release", "constrained"} and unassigned:
        failures.append(f"budget evidence policy misses metrics: {sorted(unassigned)}")
    if args.profile in {"release", "constrained"} and unknown:
        failures.append(f"budget evidence policy names unknown metrics: {sorted(unknown)}")
    if args.profile == "smoke" and evaluated_metrics == 0:
        failures.append("smoke result contains no recognized budget metrics")
    report = {
        "schema_version": 1,
        "budget_version": budgets["budget_version"],
        "profile": args.profile,
        "evaluated_metrics": evaluated_metrics,
        "evaluated_measurements": evaluated_measurements,
        "evidence_sets": [
            {"name": label, "role": evidence_role(result)} for label, result in results
        ],
        "passed": not failures,
        "failures": failures,
        "verified_at": now_iso(),
    }
    if args.report:
        write_json(pathlib.Path(args.report), report)
    print(json.dumps(report, indent=2, sort_keys=True))
    if failures:
        raise EvidenceError(f"performance verification failed with {len(failures)} finding(s)")


def preflight(args: argparse.Namespace) -> None:
    result: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "captured_at": now_iso(),
        "host": collect_host(),
        "source": collect_source(),
        "documentation": {
            "github_runner_spec": "https://docs.github.com/en/actions/reference/runners/github-hosted-runners",
            "xcode_cli_reference": "https://developer.apple.com/documentation/xcode/xcode-command-line-tool-reference",
        },
    }
    if args.app:
        result["candidate"] = collect_app(require_app(args.app))
    host = result["host"]
    failures = []
    if host["missing_required_templates"]:
        failures.append(f"missing Instruments templates: {host['missing_required_templates']}")
    if args.require_minimum and not host["evidence_eligibility"]["physical_base_m1_8gib_macos14"]:
        failures.append("not the physical base-M1/8-GiB/macOS-14 support floor")
    if args.require_interactive and not host["evidence_eligibility"]["physical_supported_interactive"]:
        failures.append("not a supported physical Apple-Silicon interactive evidence host")
    if args.expect_github_macos14 and not host["evidence_eligibility"]["github_m1_7gb_constrained_preflight"]:
        failures.append("not the expected GitHub-hosted macos-14 M1/7-GB constrained runner")
    result["passed"] = not failures
    result["failures"] = failures
    write_json(pathlib.Path(args.output), result)
    print(json.dumps(result, indent=2, sort_keys=True))
    if failures:
        raise EvidenceError("preflight failed: " + "; ".join(failures))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    command = subparsers.add_parser("preflight", help="capture sanitized host/tool/candidate inventory")
    command.add_argument("--app")
    command.add_argument("--output", required=True)
    command.add_argument("--require-minimum", action="store_true")
    command.add_argument("--require-interactive", action="store_true")
    command.add_argument("--expect-github-macos14", action="store_true")
    command.set_defaults(func=preflight)

    command = subparsers.add_parser("sample", help="sample one exact running candidate phase")
    command.add_argument("--app", required=True)
    command.add_argument("--phase", required=True, choices=sorted(PHASES))
    command.add_argument("--duration", required=True, type=float)
    command.add_argument("--interval", type=float, default=1.0)
    command.add_argument("--fd-interval", type=float, default=5.0)
    command.add_argument("--output", required=True)
    command.add_argument("--diagnostics", default=str(DEFAULT_DIAGNOSTICS))
    command.add_argument("--history-db", default=str(DEFAULT_HISTORY))
    command.set_defaults(func=sample_phase)

    command = subparsers.add_parser(
        "self-test",
        help="LaunchServices-run the gated signed-app 20-cycle/50-History workload",
    )
    command.add_argument("--app", required=True)
    command.add_argument("--fixture", required=True)
    command.add_argument("--data-root", required=True)
    command.add_argument("--output", required=True)
    command.add_argument("--launch-timeout", type=float, default=20.0)
    command.add_argument("--ready-timeout", type=float, default=60.0)
    command.add_argument("--timeout", type=float, default=2_400.0)
    command.add_argument("--interval", type=float, default=1.0)
    command.add_argument("--fd-interval", type=float, default=5.0)
    command.add_argument("--observer-settle-seconds", type=float, default=2.0)
    command.add_argument(
        "--verified-model-cache",
        help="stage marker-verified immutable assets after the empty-root handshake; product re-verifies every byte",
    )
    command.add_argument(
        "--interaction",
        action="store_true",
        help="run the explicitly post-event-tap synthetic typed-callback/overlay/paste phase",
    )
    command.set_defaults(func=run_signed_self_test)

    command = subparsers.add_parser("launch", help="measure LaunchServices-to-ready latency")
    command.add_argument("--app", required=True)
    command.add_argument("--mode", required=True, choices=("cold", "warm"))
    command.add_argument("--iterations", type=int, default=1)
    command.add_argument("--cold-confirmed", action="store_true")
    command.add_argument("--fresh-runner-id")
    command.add_argument("--malloc-stack-logging", action="store_true")
    command.add_argument("--leave-running", action="store_true")
    command.add_argument("--settle-seconds", type=float, default=1.0)
    command.add_argument("--timeout", type=float, default=15.0)
    command.add_argument("--output", required=True)
    command.add_argument("--diagnostics", default=str(DEFAULT_DIAGNOSTICS))
    command.set_defaults(func=measure_launch)

    command = subparsers.add_parser("correlate", help="join private-free diagnostics to external markers")
    command.add_argument("--result", required=True)
    command.add_argument("--diagnostics", default=str(DEFAULT_DIAGNOSTICS))
    command.add_argument("--overlay-events")
    command.add_argument("--paste-events")
    command.set_defaults(func=correlate)

    command = subparsers.add_parser("record-metric", help="record an externally measured numeric metric")
    command.add_argument("--result", required=True)
    command.add_argument("--metric", required=True)
    command.add_argument("--value", required=True, type=float)
    command.add_argument("--sample-count", required=True, type=int)
    command.add_argument("--evidence")
    command.add_argument("--evidence-kind", default="instruments_trace")
    command.set_defaults(func=record_metric)

    command = subparsers.add_parser(
        "leaks",
        help="attach macOS leaks to the exact running signed candidate and record its definite count",
    )
    command.add_argument("--app", required=True)
    command.add_argument("--result", required=True)
    command.add_argument("--mode", required=True, choices=("baseline", "compare"))
    command.add_argument("--timeout", type=float, default=120.0)
    command.add_argument("--minimum-observation-seconds", type=int, default=60)
    command.add_argument("--required-cycles", type=int, default=20)
    command.add_argument("--diagnostics", default=str(DEFAULT_DIAGNOSTICS))
    command.add_argument(
        "--sudo",
        action="store_true",
        help="use non-interactive sudo when the target is not an attachable descendant",
    )
    command.set_defaults(func=scan_leaks)

    command = subparsers.add_parser(
        "merge-cold",
        help="merge exactly five sealed fresh-runner cold-launch shards into one primary result",
    )
    command.add_argument("--app", required=True)
    command.add_argument("--result", required=True)
    command.add_argument("--candidate-id", required=True)
    command.add_argument("--shard", action="append", required=True)
    command.set_defaults(func=merge_cold_launch)

    command = subparsers.add_parser("sanitize", help="remove local paths before evidence sealing/upload")
    command.add_argument("--result", required=True)
    command.set_defaults(func=sanitize_result)

    command = subparsers.add_parser("seal", help="seal an immutable-candidate result")
    command.add_argument("--result", required=True)
    command.add_argument("--candidate-id", required=True)
    command.set_defaults(func=seal_result)

    command = subparsers.add_parser("verify", help="verify collected metrics against versioned budgets")
    command.add_argument("--result", required=True)
    command.add_argument("--budgets", required=True)
    command.add_argument("--profile", choices=("smoke", "constrained", "release"), default="release")
    command.add_argument("--companion-result", action="append", default=[])
    command.add_argument("--report")
    command.set_defaults(func=verify)
    return parser


def main() -> int:
    try:
        args = build_parser().parse_args()
        args.func(args)
        return 0
    except (EvidenceError, OSError, subprocess.SubprocessError, ValueError) as error:
        print(f"performance evidence error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
