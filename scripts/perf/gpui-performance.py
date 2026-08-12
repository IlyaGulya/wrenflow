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
import queue
import re
import signal
import shutil
import sqlite3
import statistics
import subprocess
import sys
import threading
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
SELF_TEST_OBSERVER_ACK_NAME = "performance-observer-ack-v1"
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
IDLE_SAMPLING_CONTRACT = "fixed-count-monotonic-v1"
ACTIVE_SAMPLING_CONTRACT = "event-bounded-monotonic-v1"
SAMPLING_AVERAGE_GAP_MULTIPLIER = 1.25
SAMPLING_MAX_GAP_MULTIPLIER = 2.0
SAMPLING_DEADLINE_EXTRA_INTERVALS = 2.0
TOP_EVENT_COUNT_MODE = "e"
SELF_TEST_AUTO_EXIT_GRACE_SECONDS = 30.0
LSAPPINFO_TIMEOUT_SECONDS = 2.0
LAUNCH_SERVICES_DEREGISTRATION_TIMEOUT_SECONDS = 10.0
WINDOW_POLICY_APPLICATION_TYPES = {
    "window_policy_accessory_ready": "UIElement",
    "window_policy_foreground_ready": "Foreground",
}
HUMAN_COLD_DEFINITION = (
    "human-confirmed first post-boot or >=60-second quiesced LaunchServices start"
)
CONSTRAINED_COLD_DEFINITION = (
    "machine-verified exact signed LaunchServices launch on one fresh GitHub-hosted macos-14 runner"
)
WARM_LAUNCH_DEFINITION = (
    "ten measured exact signed LaunchServices restarts after one excluded route-aware priming launch"
)
WARM_PRIMING_CONTRACT = "unmeasured-route-aware-exact-candidate-v1"
MALLOC_LAUNCH_DEFINITION = "retained MallocStackLogging LaunchServices launch"
AGGREGATED_COLD_DEFINITION = (
    "one exact signed LaunchServices launch on each of five fresh GitHub-hosted macos-14 runners"
)
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


class SamplingEvidenceError(EvidenceError):
    def __init__(self, code: str, message: str, **details: Any) -> None:
        super().__init__(message)
        self.code = code
        self.details = details


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


def write_private_json(path: pathlib.Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(temporary, flags, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    except BaseException:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass
        raise


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


def parse_top_counter(value: str) -> int:
    # In non-delta modes top prints the exact numeric value, then `+` when the
    # counter increased or `-` when it decreased since the previous sample:
    # https://github.com/apple-oss-distributions/top/blob/main/uinteger.c
    match = re.fullmatch(r"([0-9]+)([+-]?)", value.strip())
    if not match:
        raise EvidenceError(f"cannot parse absolute top idle-wakeup counter: {value}")
    if match.group(2) == "-":
        raise EvidenceError("top idle-wakeup counter reported a decreasing absolute value")
    return int(match.group(1))


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


SELF_TEST_ABSOLUTE_TIMING_KEYS = (
    "ready_at_unix_ms",
    "started_at_unix_ms",
    "history_ready_at_unix_ms",
    "activation_started_at_unix_ms",
    "loading_started_at_unix_ms",
    "model_ready_at_unix_ms",
    "warmup_completed_at_unix_ms",
    "completed_at_unix_ms",
)


def validate_self_test_timeline(timings: dict[str, Any]) -> None:
    absolute = [timings.get(key) for key in SELF_TEST_ABSOLUTE_TIMING_KEYS]
    if not all(isinstance(value, int) and value > 0 for value in absolute):
        raise EvidenceError("signed self-test absolute timings must be positive integer milliseconds")
    if any(current <= previous for previous, current in zip(absolute, absolute[1:])):
        raise EvidenceError("signed self-test report timestamps are out of order")
    if not all(
        finite_nonnegative(timings.get(key))
        for key in ("model_download_ms", "model_cold_load_ms", "total_ms")
    ):
        raise EvidenceError("signed self-test duration fields must be finite and non-negative")
    cycles = timings.get("cycles_ms")
    if (
        not isinstance(cycles, list)
        or len(cycles) != 20
        or not all(finite_nonnegative(value) for value in cycles)
    ):
        raise EvidenceError("signed self-test must report exactly 20 finite cycle timings")
    expected_download_ms = (
        timings["loading_started_at_unix_ms"]
        - timings["activation_started_at_unix_ms"]
    )
    expected_load_ms = (
        timings["model_ready_at_unix_ms"] - timings["loading_started_at_unix_ms"]
    )
    if abs(float(timings["model_download_ms"]) - expected_download_ms) > 100.0:
        raise EvidenceError("signed self-test download duration differs from its absolute timeline")
    if abs(float(timings["model_cold_load_ms"]) - expected_load_ms) > 100.0:
        raise EvidenceError("signed self-test cold-load duration differs from its absolute timeline")


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
        *SELF_TEST_ABSOLUTE_TIMING_KEYS,
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
    validate_self_test_timeline(timings)
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
    start_correlations = {
        record.get("correlation_id")
        for record in session
        if record.get("code") == "transcription_started"
        and isinstance(record.get("correlation_id"), str)
        and record.get("correlation_id")
        and record.get("correlation_id") not in recording_correlations
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


def validate_observer_ack_path(
    path: pathlib.Path,
    *,
    data_root: pathlib.Path,
    require_existing: bool,
) -> None:
    expected = data_root / SELF_TEST_OBSERVER_ACK_NAME
    if not path.is_absolute() or path != expected or data_root.is_symlink() or not data_root.is_dir():
        raise EvidenceError("observer ack must be the exact disposable-root child")
    if require_existing:
        if path.is_symlink() or not path.is_file() or path.stat().st_size != 0:
            raise EvidenceError("observer ack must be an existing zero-byte regular non-symlink file")
    elif path.exists() or path.is_symlink():
        raise EvidenceError("observer ack already exists before observer acceptance")


def observer_ack_readiness(
    records: list[dict[str, Any]],
    *,
    session_id: str,
    resource_row_timestamp_unix_ms: int,
) -> dict[str, Any]:
    if not re.fullmatch(r"s-[0-9a-f]{16}", session_id):
        raise EvidenceError("observer ack session ID is invalid")
    if not isinstance(resource_row_timestamp_unix_ms, int):
        raise EvidenceError("observer ack resource-row timestamp is invalid")
    session = [record for record in records if record.get("session_id") == session_id]
    recording_correlations = {
        record.get("correlation_id")
        for record in session
        if record.get("code") == "recording_started" and record.get("correlation_id")
    }
    start_correlations = {
        record.get("correlation_id")
        for record in session
        if record.get("code") == "transcription_started"
        and isinstance(record.get("correlation_id"), str)
        and record.get("correlation_id")
        and record.get("correlation_id") not in recording_correlations
    }
    completion_timestamps: dict[str, int] = {}
    for record in session:
        correlation = record.get("correlation_id")
        timestamp = record.get("timestamp_unix_ms")
        if (
            record.get("code") != "transcription_completed"
            or not isinstance(correlation, str)
            or not correlation
            or correlation in recording_correlations
            or not isinstance(timestamp, int)
        ):
            continue
        completion_timestamps[correlation] = max(
            timestamp,
            completion_timestamps.get(correlation, timestamp),
        )
    latest_completion = (
        max(completion_timestamps.values()) if completion_timestamps else None
    )
    completion_count = len(completion_timestamps)
    ready = (
        len(start_correlations) == 20
        and completion_count == 20
        and set(completion_timestamps) == start_correlations
        and latest_completion is not None
        and resource_row_timestamp_unix_ms >= latest_completion
    )
    return {
        "ready": ready,
        "started_correlation_count": len(start_correlations),
        "completion_correlation_count": completion_count,
        "latest_completion_timestamp_unix_ms": latest_completion,
        "resource_row_timestamp_unix_ms": resource_row_timestamp_unix_ms,
    }


def maybe_create_observer_ack(
    records: list[dict[str, Any]],
    *,
    session_id: str,
    resource_row_timestamp_unix_ms: int,
    path: pathlib.Path,
    data_root: pathlib.Path,
) -> dict[str, Any] | None:
    readiness = observer_ack_readiness(
        records,
        session_id=session_id,
        resource_row_timestamp_unix_ms=resource_row_timestamp_unix_ms,
    )
    if not readiness["ready"]:
        return None
    validate_observer_ack_path(path, data_root=data_root, require_existing=False)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags, 0o600)
    with os.fdopen(descriptor, "wb") as handle:
        handle.flush()
        os.fsync(handle.fileno())
    validate_observer_ack_path(path, data_root=data_root, require_existing=True)
    return {
        "name": SELF_TEST_OBSERVER_ACK_NAME,
        "bytes": 0,
        **readiness,
    }


def idle_wakeup_rate(previous: int, current: int, interval_seconds: float) -> float:
    if current < previous:
        raise EvidenceError("top idle-wakeup counter moved backwards")
    if not math.isfinite(interval_seconds) or interval_seconds <= 0:
        raise EvidenceError("top sample interval is not a positive finite value")
    return (current - previous) / interval_seconds


def sampling_summary(
    samples: list[dict[str, Any]],
    *,
    contract: str,
    baseline_elapsed_seconds: float,
    baseline_at_unix_ms: int,
    baseline_idle_wakeups: int,
    requested_duration_seconds: float,
    requested_interval_seconds: float,
) -> dict[str, Any]:
    if contract not in {IDLE_SAMPLING_CONTRACT, ACTIVE_SAMPLING_CONTRACT}:
        raise EvidenceError("sampling phase uses an unknown contract")
    fixed_count = contract == IDLE_SAMPLING_CONTRACT
    if not samples:
        raise SamplingEvidenceError(
            "no_samples",
            "sampling phase contains no samples",
            observed_sample_count=0,
        )
    numeric_inputs = (
        baseline_elapsed_seconds,
        requested_duration_seconds,
        requested_interval_seconds,
    )
    if not all(isinstance(value, (int, float)) and math.isfinite(value) for value in numeric_inputs):
        raise EvidenceError("sampling contract contains a non-finite numeric input")
    if baseline_elapsed_seconds < 0 or requested_duration_seconds <= 0 or requested_interval_seconds <= 0:
        raise EvidenceError("sampling contract contains a non-positive duration or interval")
    if not isinstance(baseline_at_unix_ms, int) or baseline_at_unix_ms <= 0:
        raise EvidenceError("sampling baseline wall timestamp is invalid")
    if not isinstance(baseline_idle_wakeups, int) or baseline_idle_wakeups < 0:
        raise EvidenceError("sampling baseline idle-wakeup counter is invalid")

    expected_count = math.ceil(requested_duration_seconds / requested_interval_seconds)
    if fixed_count and len(samples) != expected_count:
        raise SamplingEvidenceError(
            "wrong_sample_count",
            f"sampling phase has {len(samples)} rows; requires exactly {expected_count}",
            observed_sample_count=len(samples),
            required_sample_count=expected_count,
        )

    previous_elapsed = float(baseline_elapsed_seconds)
    previous_wall_ms = baseline_at_unix_ms
    previous_idle_wakeups = baseline_idle_wakeups
    observed_intervals: list[float] = []
    for index, sample in enumerate(samples):
        elapsed = sample.get("elapsed_seconds")
        wall_ms = sample.get("timestamp_unix_ms")
        observed_interval = sample.get("observed_interval_seconds")
        idle_wakeups = sample.get("idle_wakeups_counter")
        recorded_rate = sample.get("idle_wakeups_per_s")
        finite_values = (elapsed, observed_interval, recorded_rate)
        if not all(isinstance(value, (int, float)) and math.isfinite(value) for value in finite_values):
            raise EvidenceError("sampling row contains a non-finite timing or wakeup value")
        if not isinstance(wall_ms, int) or wall_ms <= previous_wall_ms:
            raise EvidenceError("sampling wall timestamps are duplicated or reordered")
        if not isinstance(idle_wakeups, int) or idle_wakeups < 0:
            raise EvidenceError("sampling row has an invalid idle-wakeup counter")
        elapsed = float(elapsed)
        observed_interval = float(observed_interval)
        recorded_rate = float(recorded_rate)
        if elapsed <= previous_elapsed:
            raise EvidenceError("sampling monotonic timestamps are duplicated or reordered")
        elapsed_delta = elapsed - previous_elapsed
        if not math.isclose(observed_interval, elapsed_delta, rel_tol=0.0, abs_tol=0.002):
            raise EvidenceError("sampling row interval differs from its monotonic timestamp delta")
        wall_delta = (wall_ms - previous_wall_ms) / 1000.0
        if abs(wall_delta - observed_interval) > 0.5:
            raise EvidenceError("sampling wall timestamp drifted from monotonic time")
        if (
            fixed_count
            and observed_interval
            > requested_interval_seconds * SAMPLING_MAX_GAP_MULTIPLIER
        ):
            raise SamplingEvidenceError(
                "overlong_collection_gap",
                "sampling phase contains an overlong collection gap",
                sample_index=index,
                observed_interval_seconds=round(observed_interval, 6),
                maximum_interval_seconds=round(
                    requested_interval_seconds * SAMPLING_MAX_GAP_MULTIPLIER,
                    6,
                ),
            )
        expected_rate = idle_wakeup_rate(
            previous_idle_wakeups,
            idle_wakeups,
            observed_interval,
        )
        if not math.isclose(recorded_rate, expected_rate, rel_tol=0.0, abs_tol=0.000002):
            raise EvidenceError("sampling row idle-wakeup rate does not match its counter delta")
        observed_intervals.append(observed_interval)
        previous_elapsed = elapsed
        previous_wall_ms = wall_ms
        previous_idle_wakeups = idle_wakeups

    coverage = float(samples[-1]["elapsed_seconds"]) - float(baseline_elapsed_seconds)
    average_gap = coverage / len(samples)
    if fixed_count and coverage + 0.002 < requested_duration_seconds:
        raise SamplingEvidenceError(
            "short_wall_coverage",
            "sampling phase does not cover the requested wall-clock duration",
            wall_coverage_seconds=round(coverage, 6),
            required_coverage_seconds=round(requested_duration_seconds, 6),
        )
    if average_gap > requested_interval_seconds * SAMPLING_AVERAGE_GAP_MULTIPLIER:
        raise SamplingEvidenceError(
            "undersampled_average_cadence",
            "sampling phase effective cadence is below the allowed bound",
            average_observed_interval_seconds=round(average_gap, 6),
            maximum_average_interval_seconds=round(
                requested_interval_seconds * SAMPLING_AVERAGE_GAP_MULTIPLIER,
                6,
            ),
        )
    maximum_coverage = requested_duration_seconds
    if fixed_count:
        maximum_coverage = (
            SAMPLING_AVERAGE_GAP_MULTIPLIER
            * expected_count
            * requested_interval_seconds
            + SAMPLING_DEADLINE_EXTRA_INTERVALS * requested_interval_seconds
        )
    if coverage > maximum_coverage + 0.002:
        raise SamplingEvidenceError(
            "hard_deadline_exceeded",
            "sampling phase exceeded its hard collection deadline",
            wall_coverage_seconds=round(coverage, 6),
            hard_deadline_seconds=round(maximum_coverage, 6),
        )

    summary = {
        "contract": contract,
        "baseline_elapsed_seconds": round(float(baseline_elapsed_seconds), 6),
        "baseline_at_unix_ms": baseline_at_unix_ms,
        "baseline_idle_wakeups": baseline_idle_wakeups,
        "observed_sample_count": len(samples),
        "wall_coverage_seconds": round(coverage, 6),
        "average_observed_interval_seconds": round(average_gap, 6),
        "maximum_observed_interval_seconds": round(max(observed_intervals), 6),
        "effective_samples_per_second": round(len(samples) / coverage, 6),
        "average_gap_multiplier_limit": SAMPLING_AVERAGE_GAP_MULTIPLIER,
    }
    if fixed_count:
        summary.update(
            {
                "target_sample_count": expected_count,
                "maximum_gap_multiplier_limit": SAMPLING_MAX_GAP_MULTIPLIER,
            }
        )
    else:
        summary.update(
            {
                "minimum_sample_count": 20,
                "hard_deadline_seconds": round(requested_duration_seconds, 6),
            }
        )
    return summary


def time_weighted_mean(samples: list[dict[str, Any]], key: str) -> float:
    weighted = sum(
        float(sample[key]) * float(sample["observed_interval_seconds"])
        for sample in samples
    )
    duration = sum(float(sample["observed_interval_seconds"]) for sample in samples)
    if duration <= 0 or not math.isfinite(weighted):
        raise EvidenceError(f"cannot calculate time-weighted {key}")
    return weighted / duration


def direct_completion_timestamps(
    records: list[dict[str, Any]], session_id: str
) -> dict[str, int]:
    session = [record for record in records if record.get("session_id") == session_id]
    recording_correlations = {
        record.get("correlation_id")
        for record in session
        if record.get("code") == "recording_started" and record.get("correlation_id")
    }
    completions: dict[str, int] = {}
    for record in session:
        correlation = record.get("correlation_id")
        timestamp = record.get("timestamp_unix_ms")
        if (
            record.get("code") == "transcription_completed"
            and isinstance(correlation, str)
            and correlation
            and correlation not in recording_correlations
            and isinstance(timestamp, int)
        ):
            completions[correlation] = max(timestamp, completions.get(correlation, timestamp))
    return completions


def direct_cycle_pairs(
    records: list[dict[str, Any]], session_id: str
) -> list[dict[str, Any]]:
    session = [record for record in records if record.get("session_id") == session_id]
    recording_correlations = {
        record.get("correlation_id")
        for record in session
        if record.get("code") == "recording_started" and record.get("correlation_id")
    }
    starts = [
        record
        for record in session
        if record.get("code") == "transcription_started"
        and isinstance(record.get("correlation_id"), str)
        and record.get("correlation_id")
        and record.get("correlation_id") not in recording_correlations
    ]
    completions = [
        record
        for record in session
        if record.get("code") == "transcription_completed"
        and isinstance(record.get("correlation_id"), str)
        and record.get("correlation_id")
        and record.get("correlation_id") not in recording_correlations
    ]
    if len(starts) != 20 or len(completions) != 20:
        raise EvidenceError("active diagnostics require exactly 20 direct start/completion pairs")
    start_ids = [record["correlation_id"] for record in starts]
    completion_ids = [record["correlation_id"] for record in completions]
    if len(set(start_ids)) != 20 or len(set(completion_ids)) != 20 or start_ids != completion_ids:
        raise EvidenceError("active diagnostic correlations are duplicated, rogue, or reordered")
    pairs = []
    previous_completion = None
    for index, (start, completion) in enumerate(zip(starts, completions)):
        started_at = start.get("timestamp_unix_ms")
        completed_at = completion.get("timestamp_unix_ms")
        if (
            not isinstance(started_at, int)
            or not isinstance(completed_at, int)
            or completed_at <= started_at
            or (previous_completion is not None and started_at <= previous_completion)
        ):
            raise EvidenceError("active diagnostic pairs are not strictly ordered")
        pairs.append(
            {
                "cycle_index": index,
                "correlation_id": start["correlation_id"],
                "started_at_unix_ms": started_at,
                "completed_at_unix_ms": completed_at,
            }
        )
        previous_completion = completed_at
    return pairs


def sample_observation_window(sample: dict[str, Any]) -> tuple[float, float]:
    end = float(sample["timestamp_unix_ms"])
    start = end - float(sample["observed_interval_seconds"]) * 1_000.0
    return start, end


def interval_overlaps_sample(
    sample: dict[str, Any], started_at_unix_ms: int, completed_at_unix_ms: int
) -> bool:
    sample_start, sample_end = sample_observation_window(sample)
    return sample_start <= completed_at_unix_ms and sample_end >= started_at_unix_ms


def active_cycle_evidence(phase: dict[str, Any]) -> dict[str, Any]:
    report = phase.get("self_test_report")
    samples = phase.get("samples")
    diagnostics = phase.get("diagnostics")
    sampling = phase.get("sampling")
    observer_ack = phase.get("observer_ack")
    if not all(isinstance(value, dict) for value in (report, sampling, observer_ack)):
        raise EvidenceError("active phase is missing its report, cadence, or observer ack")
    if not isinstance(samples, list) or not isinstance(diagnostics, list):
        raise EvidenceError("active phase is missing raw samples or diagnostics")
    timings = report.get("timings")
    session_id = report.get("session_id")
    if not isinstance(timings, dict) or not isinstance(session_id, str):
        raise EvidenceError("active phase has an invalid self-test timeline")
    validate_self_test_timeline(timings)
    if sampling.get("baseline_at_unix_ms", 0) > timings["started_at_unix_ms"]:
        raise EvidenceError("active top baseline was captured after the signed workload started")

    pairs = direct_cycle_pairs(diagnostics, session_id)
    history_markers = [
        record
        for record in diagnostics
        if record.get("session_id") == session_id
        and record.get("code") == "performance_self_test_history_ready"
        and isinstance(record.get("timestamp_unix_ms"), int)
    ]
    if (
        len(history_markers) != 1
        or abs(
            history_markers[0]["timestamp_unix_ms"]
            - timings["history_ready_at_unix_ms"]
        )
        > 100
    ):
        raise EvidenceError("History-ready timing differs from its closed diagnostic marker")
    cycle_durations = timings.get("cycles_ms")
    if not isinstance(cycle_durations, list) or len(cycle_durations) != 20:
        raise EvidenceError("active report is missing its exact cycle durations")
    if any(
        abs(float(duration) - (pair["completed_at_unix_ms"] - pair["started_at_unix_ms"]))
        > 100.0
        for duration, pair in zip(cycle_durations, pairs)
    ):
        raise EvidenceError("direct cycle duration differs from its diagnostic pair")
    if timings["warmup_completed_at_unix_ms"] > pairs[0]["started_at_unix_ms"]:
        raise EvidenceError("direct transcription cycles started before warmup completed")
    if pairs[-1]["completed_at_unix_ms"] > timings["completed_at_unix_ms"]:
        raise EvidenceError("direct transcription cycles completed after the signed report")

    mappings = []
    used_indexes: set[int] = set()
    for pair in pairs:
        sample_index = next(
            (
                index
                for index, sample in enumerate(samples)
                if sample.get("timestamp_unix_ms", -1) >= pair["completed_at_unix_ms"]
            ),
            None,
        )
        if sample_index is None or sample_index in used_indexes:
            raise EvidenceError("direct completions do not map to 20 distinct first-later rows")
        sample = samples[sample_index]
        if not interval_overlaps_sample(
            sample,
            pair["started_at_unix_ms"],
            pair["completed_at_unix_ms"],
        ):
            raise EvidenceError("mapped resource row does not overlap its direct transcription")
        if sample.get("file_descriptors_measured") is not True:
            raise EvidenceError("mapped resource row lacks an exact boundary FD measurement")
        used_indexes.add(sample_index)
        mappings.append(
            {
                **pair,
                "sample_index": sample_index,
                "sample_timestamp_unix_ms": sample["timestamp_unix_ms"],
                "sample_observed_interval_seconds": sample["observed_interval_seconds"],
            }
        )

    stage_intervals = {
        "model_download": (
            timings["activation_started_at_unix_ms"],
            timings["loading_started_at_unix_ms"],
        ),
        "model_load": (
            timings["loading_started_at_unix_ms"],
            timings["model_ready_at_unix_ms"],
        ),
        "post_warmup": (
            timings["warmup_completed_at_unix_ms"],
            pairs[-1]["completed_at_unix_ms"],
        ),
    }
    stage_coverage: dict[str, list[int]] = {}
    for name, (started_at, completed_at) in stage_intervals.items():
        indexes = [
            index
            for index, sample in enumerate(samples)
            if interval_overlaps_sample(sample, started_at, completed_at)
        ]
        if not indexes:
            raise EvidenceError(f"active resource rows do not cover {name}")
        stage_coverage[name] = indexes

    final_mapping = mappings[-1]
    if (
        observer_ack.get("resource_row_timestamp_unix_ms")
        != final_mapping["sample_timestamp_unix_ms"]
        or observer_ack.get("latest_completion_timestamp_unix_ms")
        != pairs[-1]["completed_at_unix_ms"]
        or observer_ack.get("started_correlation_count") != 20
        or observer_ack.get("completion_correlation_count") != 20
    ):
        raise EvidenceError("observer ack does not match the final direct-cycle boundary row")

    return {
        "contract": "first-post-completion-observer-v1",
        "pairs": mappings,
        "stage_sample_indexes": stage_coverage,
        "final_observer_sample_index": final_mapping["sample_index"],
    }


def start_line_reader(stream: Any) -> queue.Queue[tuple[str, float, int] | None]:
    lines: queue.Queue[tuple[str, float, int] | None] = queue.Queue()

    def read_lines() -> None:
        try:
            for output_line in stream:
                lines.put((output_line, time.monotonic(), int(time.time() * 1000)))
        finally:
            lines.put(None)

    threading.Thread(target=read_lines, name="wrenflow-top-reader", daemon=True).start()
    return lines


def top_stderr_category(value: str) -> str:
    lowered = value.lower()
    if not value.strip():
        return "empty"
    if "permission" in lowered or "operation not permitted" in lowered:
        return "permission_denied"
    if "terminated" in lowered or "killed" in lowered:
        return "terminated"
    return "other"


def sampling_failure_details(
    samples: list[dict[str, Any]],
    *,
    contract: str,
    process_returncode: int | None,
    process_stderr: str,
    diagnostics: list[dict[str, Any]],
    session_id: str | None,
    existing: dict[str, Any] | None = None,
) -> dict[str, Any]:
    details = dict(existing or {})
    if "sample_index" in details:
        details["first_bad_index"] = details.pop("sample_index")
    if "observed_interval_seconds" in details:
        details["first_bad_gap_seconds"] = details["observed_interval_seconds"]
    gaps = [
        float(sample["observed_interval_seconds"])
        for sample in samples
        if isinstance(sample.get("observed_interval_seconds"), (int, float))
        and math.isfinite(float(sample["observed_interval_seconds"]))
    ]
    delivery_lags = [
        float(sample["observer_delivery_delay_seconds"])
        for sample in samples
        if isinstance(sample.get("observer_delivery_delay_seconds"), (int, float))
        and math.isfinite(float(sample["observer_delivery_delay_seconds"]))
    ]
    details.update(
        {
            "sampling_contract": contract,
            "row_count": len(samples),
            "top_returncode": process_returncode,
            "top_stderr_category": top_stderr_category(process_stderr),
            "top_stderr_sha256": hashlib.sha256(process_stderr.encode()).hexdigest(),
        }
    )
    if gaps:
        details.update(
            {
                "gap_p50_seconds": round(percentile(gaps, 0.50), 6),
                "gap_p95_seconds": round(percentile(gaps, 0.95), 6),
                "gap_p99_seconds": round(percentile(gaps, 0.99), 6),
                "gap_max_seconds": round(max(gaps), 6),
            }
        )
    if delivery_lags:
        details.update(
            {
                "reader_lag_p95_seconds": round(percentile(delivery_lags, 0.95), 6),
                "reader_lag_max_seconds": round(max(delivery_lags), 6),
            }
        )
    if isinstance(session_id, str):
        session = [record for record in diagnostics if record.get("session_id") == session_id]
        recording = {
            record.get("correlation_id")
            for record in session
            if record.get("code") == "recording_started" and record.get("correlation_id")
        }
        details["history_ready_count"] = sum(
            record.get("code") == "performance_self_test_history_ready" for record in session
        )
        details["direct_start_count"] = sum(
            record.get("code") == "transcription_started"
            and record.get("correlation_id") not in recording
            for record in session
        )
        details["direct_completion_count"] = sum(
            record.get("code") == "transcription_completed"
            and record.get("correlation_id") not in recording
            for record in session
        )
    return details


def replace_sampling_failure_context(
    owner: argparse.Namespace | None,
    details: dict[str, Any] | None,
) -> None:
    if owner is not None:
        owner._sampling_failure_context = details


def failure_summary_error(
    error: BaseException,
    context: Any,
) -> BaseException:
    if not isinstance(error, SamplingEvidenceError) and isinstance(context, dict):
        return SamplingEvidenceError(
            "closed_evidence_failure",
            "closed performance evidence failure",
            **context,
        )
    return error


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
    # macOS top treats -s as a delay after each collection pass. Idle evidence
    # therefore collects its exact budget row count; the active signed workload
    # instead ends on its exact observer ack/auto-exit inside the independent
    # 2,400-second bound. Both modes validate actual observer-delivery cadence.
    target_sample_count = math.ceil(args.duration / args.interval)
    command = [
        "/usr/bin/top",
        "-c",
        TOP_EVENT_COUNT_MODE,
        "-l",
        str(target_sample_count + 1),
        "-s",
        str(int(args.interval)),
        "-pid",
        str(pid),
        "-stats",
        "pid,cpu,rsize,threads,idlew,power",
    ]
    completion_report_value = getattr(args, "completion_report", None)
    completion_report = pathlib.Path(completion_report_value) if completion_report_value else None
    start_signal_value = getattr(args, "start_signal", None)
    start_signal = pathlib.Path(start_signal_value) if start_signal_value else None
    expected_auto_exit = completion_report is not None
    sampling_contract = (
        ACTIVE_SAMPLING_CONTRACT if expected_auto_exit else IDLE_SAMPLING_CONTRACT
    )
    failure_context_owner = getattr(args, "failure_context", None)
    replace_sampling_failure_context(failure_context_owner, None)
    fixture_manifest = getattr(args, "fixture_manifest", None)
    observer_settle = float(getattr(args, "observer_settle_seconds", 0.0))
    observer_ack_value = getattr(args, "observer_ack", None)
    observer_ack = pathlib.Path(observer_ack_value) if observer_ack_value else None
    observer_session_id = getattr(args, "observer_session_id", None)
    observer_ack_evidence: dict[str, Any] | None = None
    if expected_auto_exit:
        if observer_ack is None or not isinstance(observer_session_id, str):
            raise EvidenceError("signed self-test sampler requires its observer ack contract")
        assert completion_report is not None
        validate_observer_ack_path(
            observer_ack,
            data_root=completion_report.parent,
            require_existing=False,
        )
    elif observer_ack is not None or observer_session_id is not None:
        raise EvidenceError("observer ack is valid only for the signed self-test sampler")
    if expected_auto_exit:
        command[4] = str(
            target_sample_count
            + math.ceil(SELF_TEST_AUTO_EXIT_GRACE_SECONDS / args.interval)
            + 1
        )
    diagnostics_path = pathlib.Path(args.diagnostics)
    started_ms = int(time.time() * 1000)
    started_mono = time.monotonic()
    diagnostics_start_ms = int(getattr(args, "diagnostics_start_ms", started_ms))
    process = subprocess.Popen(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    samples: list[dict[str, Any]] = []
    previous_idlew: int | None = None
    previous_row_mono: float | None = None
    baseline_elapsed_seconds: float | None = None
    baseline_at_unix_ms: int | None = None
    baseline_idle_wakeups: int | None = None
    collection_deadline: float | None = None
    last_fd: int | None = None
    last_fd_at = 0.0
    boundary_correlations: set[str] = set()
    seen_rows = 0
    assert process.stdout is not None
    line_queue = start_line_reader(process.stdout)
    sampling_loop_error: EvidenceError | None = None
    try:
        while True:
            wait_deadline = collection_deadline
            if wait_deadline is None:
                wait_deadline = started_mono + max(30.0, args.interval * 2.0)
            remaining = wait_deadline - time.monotonic()
            if remaining <= 0:
                raise EvidenceError("top exceeded the bounded sampling deadline")
            try:
                queued_line = line_queue.get(timeout=remaining)
            except queue.Empty as error:
                raise EvidenceError("top exceeded the bounded sampling deadline") from error
            if queued_line is None:
                break
            line, current_mono, current_wall_ms = queued_line
            if collection_deadline is not None and (
                current_mono > collection_deadline or time.monotonic() > collection_deadline
            ):
                raise EvidenceError("top exceeded the bounded sampling deadline")
            if not line:
                raise EvidenceError("top exceeded the bounded sampling deadline")
            fields = line.split()
            if not fields or fields[0] != str(pid) or len(fields) < 6:
                if expected_auto_exit and exact_pid(identity, required=False) is None:
                    break
                continue
            seen_rows += 1
            idlew = parse_top_counter(fields[4])
            if seen_rows == 1:
                previous_idlew = idlew
                previous_row_mono = current_mono
                baseline_elapsed_seconds = current_mono - started_mono
                baseline_at_unix_ms = current_wall_ms
                baseline_idle_wakeups = idlew
                if expected_auto_exit:
                    collection_deadline = current_mono + args.duration
                else:
                    collection_deadline = (
                        current_mono
                        + SAMPLING_AVERAGE_GAP_MULTIPLIER
                        * target_sample_count
                        * args.interval
                        + SAMPLING_DEADLINE_EXTRA_INTERVALS * args.interval
                    )
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
            if previous_idlew is None or previous_row_mono is None:
                raise EvidenceError("top sampling baseline was not captured")
            observed_interval = current_mono - previous_row_mono
            persisted_interval = round(observed_interval, 6)
            wakeups = idle_wakeup_rate(previous_idlew, idlew, persisted_interval)
            previous_idlew = idlew
            previous_row_mono = current_mono
            reader_delivery_delay = max(0.0, time.monotonic() - current_mono)
            row_diagnostics: list[dict[str, Any]] | None = None
            new_boundary_correlations: set[str] = set()
            if expected_auto_exit:
                row_diagnostics = read_diagnostics(
                    diagnostics_path,
                    diagnostics_start_ms,
                    current_wall_ms,
                )
                direct_completions = direct_completion_timestamps(
                    row_diagnostics,
                    observer_session_id,
                )
                new_boundary_correlations = {
                    correlation
                    for correlation, completed_at in direct_completions.items()
                    if completed_at <= current_wall_ms
                    and correlation not in boundary_correlations
                }
            fd_measured = False
            if (
                new_boundary_correlations
                or current_mono - last_fd_at >= args.fd_interval
                or last_fd is None
            ):
                last_fd = count_fds(pid)
                last_fd_at = current_mono
                fd_measured = True
            boundary_correlations.update(new_boundary_correlations)
            try:
                sample = {
                    "timestamp_unix_ms": current_wall_ms,
                    "elapsed_seconds": round(current_mono - started_mono, 6),
                    "observed_interval_seconds": persisted_interval,
                    "cpu_percent": float(fields[1]),
                    "rss_mib": round(parse_memory(fields[2]), 6),
                    "threads": int(fields[3].split("/", 1)[0]),
                    "idle_wakeups_counter": idlew,
                    "idle_wakeups_per_s": round(wakeups, 6),
                    "energy_impact": float(fields[5]),
                    "file_descriptors": last_fd,
                    "file_descriptors_measured": fd_measured,
                    "observer_delivery_delay_seconds": round(reader_delivery_delay, 6),
                }
            except ValueError as error:
                raise EvidenceError(f"cannot parse top row: {line.strip()}") from error
            samples.append(sample)
            if observer_ack is not None and observer_ack_evidence is None:
                assert completion_report is not None
                observer_ack_evidence = maybe_create_observer_ack(
                    row_diagnostics or [],
                    session_id=observer_session_id,
                    resource_row_timestamp_unix_ms=sample["timestamp_unix_ms"],
                    path=observer_ack,
                    data_root=completion_report.parent,
                )
            if len(samples) >= target_sample_count and not expected_auto_exit:
                break
    except EvidenceError as error:
        sampling_loop_error = error
    finally:
        if process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    process_stderr = process.stderr.read() if process.stderr else ""
    ended_ms = int(time.time() * 1000)
    diagnostics = read_diagnostics(diagnostics_path, diagnostics_start_ms, ended_ms)
    current_failure_context = sampling_failure_details(
        samples,
        contract=sampling_contract,
        process_returncode=process.returncode,
        process_stderr=process_stderr,
        diagnostics=diagnostics,
        session_id=observer_session_id,
    )
    replace_sampling_failure_context(failure_context_owner, current_failure_context)
    if sampling_loop_error is not None:
        code = (
            sampling_loop_error.code
            if isinstance(sampling_loop_error, SamplingEvidenceError)
            else "collection_failed"
        )
        existing = (
            sampling_loop_error.details
            if isinstance(sampling_loop_error, SamplingEvidenceError)
            else None
        )
        raise SamplingEvidenceError(
            code,
            str(sampling_loop_error),
            **sampling_failure_details(
                samples,
                contract=sampling_contract,
                process_returncode=process.returncode,
                process_stderr=process_stderr,
                diagnostics=diagnostics,
                session_id=observer_session_id,
                existing=existing,
            ),
        ) from sampling_loop_error
    current_executable = executable_for_pid(pid)
    report = None
    if expected_auto_exit:
        if observer_ack is None or observer_ack_evidence is None:
            raise EvidenceError("signed self-test sampler never reached observer ack acceptance")
        assert completion_report is not None
        validate_observer_ack_path(
            observer_ack,
            data_root=completion_report.parent,
            require_existing=True,
        )
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
    minimum_samples = 20 if expected_auto_exit else target_sample_count
    if len(samples) < minimum_samples:
        raise SamplingEvidenceError(
            "insufficient_samples",
            f"insufficient samples ({len(samples)})",
            **sampling_failure_details(
                samples,
                contract=sampling_contract,
                process_returncode=process.returncode,
                process_stderr=process_stderr,
                diagnostics=diagnostics,
                session_id=observer_session_id,
                existing={
                    "observed_sample_count": len(samples),
                    "required_sample_count": minimum_samples,
                },
            ),
        )
    if (
        baseline_elapsed_seconds is None
        or baseline_at_unix_ms is None
        or baseline_idle_wakeups is None
    ):
        raise EvidenceError("sampling baseline is missing")
    try:
        sampling = sampling_summary(
            samples,
            contract=sampling_contract,
            baseline_elapsed_seconds=baseline_elapsed_seconds,
            baseline_at_unix_ms=baseline_at_unix_ms,
            baseline_idle_wakeups=baseline_idle_wakeups,
            requested_duration_seconds=args.duration,
            requested_interval_seconds=args.interval,
        )
    except SamplingEvidenceError as error:
        raise SamplingEvidenceError(
            error.code,
            str(error),
            **sampling_failure_details(
                samples,
                contract=sampling_contract,
                process_returncode=process.returncode,
                process_stderr=process_stderr,
                diagnostics=diagnostics,
                session_id=observer_session_id,
                existing=error.details,
            ),
        ) from error
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
        "sampling": sampling,
        "samples": samples,
        "diagnostics": diagnostics,
    }
    if report is not None:
        phase["self_test_report"] = report
        phase["self_test_report_sha256"] = sha256_file(completion_report)
        phase["observer_ack"] = observer_ack_evidence
    result["phases"][args.phase] = phase
    cpu = [sample["cpu_percent"] for sample in samples]
    wakeups = [sample["idle_wakeups_per_s"] for sample in samples if sample["idle_wakeups_per_s"] is not None]
    energy = [sample["energy_impact"] for sample in samples]
    prefix = args.phase
    set_metric(result, f"{prefix}.duration_seconds", sampling["wall_coverage_seconds"], 1)
    set_metric(result, f"{prefix}.cpu.avg_percent", time_weighted_mean(samples, "cpu_percent"), len(cpu))
    set_metric(result, f"{prefix}.cpu.p95_percent", percentile(cpu), len(cpu))
    set_metric(result, f"{prefix}.energy.avg_impact", time_weighted_mean(samples, "energy_impact"), len(energy))
    set_metric(result, f"{prefix}.energy.p95_impact", percentile(energy), len(energy))
    if wakeups:
        set_metric(
            result,
            f"{prefix}.wakeups.avg_per_s",
            time_weighted_mean(samples, "idle_wakeups_per_s"),
            len(wakeups),
        )
        set_metric(result, f"{prefix}.wakeups.p95_per_s", percentile(wakeups), len(wakeups))
    update_global_resource_metrics(result)
    if args.phase == "cycles_20" and report is not None:
        warmup_completed_at = report["timings"]["warmup_completed_at_unix_ms"]
        post_warm_samples = [
            sample
            for sample in samples
            if sample["timestamp_unix_ms"] >= warmup_completed_at
        ]
        if len(post_warm_samples) < 20:
            raise EvidenceError("active phase has fewer than 20 post-warm resource rows")
        set_metric(
            result,
            "memory.post_warmup.p95_mib",
            percentile(sample["rss_mib"] for sample in post_warm_samples),
            len(post_warm_samples),
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


def _run_signed_self_test(args: argparse.Namespace) -> None:
    args._sampling_failure_context = None
    args._failure_stage = "preflight"
    app = require_app(args.app)
    fixture, fixture_manifest = validate_transcription_fixture(args.fixture)
    data_root = validate_empty_disposable_root(args.data_root)
    output = pathlib.Path(args.output)
    if not output.is_absolute() or output.is_symlink() or output.is_relative_to(data_root):
        raise EvidenceError("self-test evidence output must be absolute, non-symlinked, and outside its data root")
    report = data_root / SELF_TEST_REPORT_NAME
    interaction_report = data_root / INTERACTION_REPORT_NAME
    start_signal = data_root / SELF_TEST_START_NAME
    observer_ack = data_root / SELF_TEST_OBSERVER_ACK_NAME
    diagnostics = data_root / CURRENT_DATA_NAMESPACE / "diagnostics/events.ndjson"
    history_db = data_root / CURRENT_DATA_NAMESPACE / "history.sqlite"
    private_outputs = (report, start_signal, interaction_report) if args.interaction else (report, start_signal)
    for path in private_outputs:
        if path.exists() or path.is_symlink():
            raise EvidenceError(f"self-test disposable artifact already exists: {path.name}")
    validate_observer_ack_path(observer_ack, data_root=data_root, require_existing=False)

    result = load_result(output, app)
    identity = result["candidate"]
    if exact_pid(identity, required=False) is not None:
        raise EvidenceError("stop the exact candidate before starting its isolated self-test")
    write_json(output, result)

    args._failure_stage = "launch"
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
    try:
        launch_observation = wait_for_route_aware_launch(
            app=app,
            identity=identity,
            diagnostics=diagnostics,
            started_ms=launched_ms,
            timeout_seconds=args.launch_timeout,
        )
        pid = launch_observation["pid"]
        validate_initial_self_test_accessory(
            observation=launch_observation,
            start_signal=start_signal,
        )
        ready = wait_for_diagnostic_code(
            diagnostics,
            "performance_self_test_ready",
            launched_ms,
            args.ready_timeout,
        )
        if ready.get("session_id") != launch_observation["terminal"].get("session_id"):
            raise EvidenceError("signed self-test readiness belongs to another launch session")
        if executable_for_pid(pid) != identity["executable_path"]:
            raise EvidenceError("signed self-test exited before the observer handshake")
        if args.verified_model_cache:
            stage_verified_model_cache(pathlib.Path(args.verified_model_cache), data_root)

        args._sampling_failure_context = None
        args._failure_stage = "idle"
        sample_phase(
            argparse.Namespace(
                app=str(app),
                phase="idle",
                duration=args.idle_duration,
                interval=args.interval,
                fd_interval=args.fd_interval,
                output=str(output),
                diagnostics=str(diagnostics),
                history_db=str(history_db),
                diagnostics_start_ms=launched_ms,
                failure_context=args,
            )
        )
        if exact_pid(identity, required=False) != pid:
            raise EvidenceError("signed self-test PID changed between idle and cycle sampling")
        idle_result = load_result(output)
        idle_phase = idle_result.get("phases", {}).get("idle")
        if not isinstance(idle_phase, dict):
            raise EvidenceError("signed self-test idle evidence is missing after sampling")
        post_idle_state = query_launch_services_state(app=app, pid=pid)
        post_idle_observation = validate_post_idle_self_test_observation(
            idle_phase=idle_phase,
            session_id=launch_observation["terminal"]["session_id"],
            state=post_idle_state,
            observed_at_unix_ms=int(time.time() * 1000),
            start_signal=start_signal,
        )
        idle_phase["post_idle_launch_services"] = post_idle_observation
        idle_result["updated_at"] = now_iso()
        write_json(output, idle_result)

        args._sampling_failure_context = None
        args._failure_stage = "cycles_20"
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
                observer_ack=str(observer_ack),
                observer_session_id=ready["session_id"],
                fixture_manifest=fixture_manifest,
                observer_settle_seconds=args.observer_settle_seconds,
                diagnostics_start_ms=launched_ms,
                failure_context=args,
            )
        )
        args._failure_stage = "finalize"
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
            "menu_bar_ready_at_unix_ms": launch_observation["ready"]["timestamp_unix_ms"],
            "terminal_policy_ready_at_unix_ms": launch_observation["terminal"][
                "timestamp_unix_ms"
            ],
            "launch_services_observed_at_unix_ms": launch_observation[
                "launch_services_observed_at_unix_ms"
            ],
            "terminal_application_type": WINDOW_POLICY_APPLICATION_TYPES[
                launch_observation["terminal"]["code"]
            ],
            "post_idle_launch_services": post_idle_observation,
            "observer_ack": final_result["phases"]["cycles_20"]["observer_ack"],
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


def failure_summary_path(args: argparse.Namespace) -> pathlib.Path | None:
    value = getattr(args, "failure_summary", None)
    if value is None:
        return None
    path = pathlib.Path(value)
    output = pathlib.Path(args.output)
    if (
        not path.is_absolute()
        or not output.is_absolute()
        or path.name != "constrained-failure-summary.json"
        or path.parent != output.parent
        or path.parent.is_symlink()
        or not path.parent.is_dir()
        or path.is_symlink()
    ):
        raise EvidenceError(
            "failure summary must be the exact absolute constrained result sibling"
        )
    return path


def write_failure_summary(
    path: pathlib.Path,
    *,
    phase: str,
    error: BaseException,
) -> None:
    if path.exists() or path.is_symlink():
        raise EvidenceError("failure summary path existed before this collection attempt")
    code = "unexpected_failure"
    details: dict[str, Any] = {}
    if isinstance(error, SamplingEvidenceError):
        if re.fullmatch(r"[a-z][a-z0-9_]{0,47}", error.code):
            code = error.code
        numeric_keys = {
            "first_bad_index",
            "first_bad_gap_seconds",
            "maximum_interval_seconds",
            "maximum_average_interval_seconds",
            "wall_coverage_seconds",
            "required_coverage_seconds",
            "hard_deadline_seconds",
            "observed_sample_count",
            "required_sample_count",
            "row_count",
            "gap_p50_seconds",
            "gap_p95_seconds",
            "gap_p99_seconds",
            "gap_max_seconds",
            "reader_lag_p95_seconds",
            "reader_lag_max_seconds",
            "history_ready_count",
            "direct_start_count",
            "direct_completion_count",
        }
        for key in numeric_keys:
            value = error.details.get(key)
            if (
                isinstance(value, (int, float))
                and not isinstance(value, bool)
                and math.isfinite(value)
            ):
                details[key] = value
        sampling_contract = error.details.get("sampling_contract")
        if sampling_contract in {IDLE_SAMPLING_CONTRACT, ACTIVE_SAMPLING_CONTRACT}:
            details["contract"] = sampling_contract
        returncode = error.details.get("top_returncode")
        if returncode is None or isinstance(returncode, int):
            details["top_returncode"] = returncode
        stderr_category = error.details.get("top_stderr_category")
        if stderr_category in {"empty", "permission_denied", "terminated", "other"}:
            details["top_stderr_category"] = stderr_category
        stderr_hash = error.details.get("top_stderr_sha256")
        if isinstance(stderr_hash, str) and re.fullmatch(r"[0-9a-f]{64}", stderr_hash):
            details["top_stderr_sha256"] = stderr_hash
    elif isinstance(error, EvidenceError):
        code = "closed_evidence_failure"
    safe_phase = phase if phase in {"preflight", "launch", "idle", "cycles_20", "finalize"} else "unknown"
    write_private_json(
        path,
        {
            "schema_version": 1,
            "contract": "gpui-performance-failure-v1",
            "phase": safe_phase,
            "code": code,
            "sampling": details,
            "passed": False,
        },
    )


def run_signed_self_test(args: argparse.Namespace) -> None:
    summary_path = failure_summary_path(args)
    if summary_path is not None and (summary_path.exists() or summary_path.is_symlink()):
        raise EvidenceError("failure summary path must be absent before collection")
    try:
        _run_signed_self_test(args)
    except BaseException as error:
        if summary_path is not None:
            context = getattr(args, "_sampling_failure_context", None)
            summary_error = failure_summary_error(error, context)
            write_failure_summary(
                summary_path,
                phase=getattr(args, "_failure_stage", "unknown"),
                error=summary_error,
            )
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
    mapping = active_cycle_evidence(phase)
    phase["cycle_resource_mapping"] = mapping
    samples = phase["samples"]
    snapshots = [samples[pair["sample_index"]] for pair in mapping["pairs"]]
    count = len(snapshots)
    set_metric(result, "cycles.completed.count", count, 1)
    set_metric(
        result,
        "transcription.cpu.p95_percent",
        percentile(sample["cpu_percent"] for sample in snapshots),
        count,
    )
    set_metric(
        result,
        "transcription.energy.p95_impact",
        percentile(sample["energy_impact"] for sample in snapshots),
        count,
    )
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


def all_resource_samples(result: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        sample
        for phase in result.get("phases", {}).values()
        if isinstance(phase, dict) and isinstance(phase.get("samples"), list)
        for sample in phase["samples"]
        if isinstance(sample, dict)
        and all(
            key in sample
            for key in (
                "rss_mib",
                "threads",
                "file_descriptors",
                "file_descriptors_measured",
            )
        )
    ]


def update_global_resource_metrics(result: dict[str, Any]) -> None:
    phase_samples = all_resource_samples(result)
    if not phase_samples:
        return
    measured_fds = [
        sample
        for sample in phase_samples
        if sample.get("file_descriptors_measured") is True
    ]
    set_metric(
        result,
        "memory.peak_mib",
        max(float(sample["rss_mib"]) for sample in phase_samples),
        len(phase_samples),
    )
    set_metric(
        result,
        "resources.thread.peak",
        max(int(sample["threads"]) for sample in phase_samples),
        len(phase_samples),
    )
    if measured_fds:
        set_metric(
            result,
            "resources.fd.peak",
            max(int(sample["file_descriptors"]) for sample in measured_fds),
            len(measured_fds),
        )


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


def launch_diagnostic_state(
    path: pathlib.Path, after_ms: int
) -> tuple[
    dict[str, Any] | None,
    dict[str, Any] | None,
    dict[str, Any] | None,
]:
    records = read_diagnostics(path, after_ms)
    startups = [
        record
        for record in records
        if record.get("code") == "startup"
        and record.get("timestamp_unix_ms", -1) >= after_ms
    ]
    for startup in reversed(startups):
        ready = next(
            (
                record
                for record in records
                if record.get("session_id") == startup.get("session_id")
                and record.get("code") == "menu_bar_ready"
                and record["timestamp_unix_ms"] >= startup["timestamp_unix_ms"]
            ),
            None,
        )
        if not ready:
            continue
        terminal = next(
            (
                record
                for record in records
                if record.get("session_id") == startup.get("session_id")
                and record.get("code") in WINDOW_POLICY_APPLICATION_TYPES
                and record["timestamp_unix_ms"] >= ready["timestamp_unix_ms"]
            ),
            None,
        )
        return startup, ready, terminal
    return (startups[-1] if startups else None), None, None


def sanitized_launch_services_state(
    output: str,
    *,
    expected_app: pathlib.Path,
    expected_pid: int,
    returncode: int | None = 0,
    stderr: str = "",
    timed_out: bool = False,
    invocation_failed: bool = False,
) -> dict[str, Any]:
    expected_fields = {
        "LSBundlePath": r'"LSBundlePath"="([^"]*)"',
        "CFBundleIdentifier": r'"CFBundleIdentifier"="([^"]*)"',
        "pid": r'"pid"=([0-9]+)',
        "ApplicationType": r'"ApplicationType"="([^"]*)"',
    }
    values: dict[str, str] = {}
    match_counts: dict[str, int] = {}
    for key, pattern in expected_fields.items():
        matches = re.findall(rf"(?m)^{pattern}$", output.strip())
        match_counts[key] = len(matches)
        if len(matches) == 1:
            values[key] = matches[0]
    nonempty_lines = [line for line in output.splitlines() if line.strip()]
    null_field_count = sum(
        len(re.findall(rf'(?m)^"{re.escape(key)}"=\[ NULL \]\s*$', output.strip()))
        for key in expected_fields
    )
    if not nonempty_lines:
        stdout_shape = "empty"
    elif null_field_count == len(expected_fields) and len(nonempty_lines) == len(expected_fields):
        stdout_shape = "null_fields"
    elif any(count > 1 for count in match_counts.values()):
        stdout_shape = "duplicate_fields"
    elif any(count == 0 for count in match_counts.values()):
        stdout_shape = "missing_fields"
    elif len(nonempty_lines) != len(expected_fields):
        stdout_shape = "unexpected_lines"
    else:
        stdout_shape = "exact_fields"
    if timed_out:
        stderr_category = "timeout"
    elif invocation_failed:
        stderr_category = "invocation_failed"
    else:
        normalized_stderr = stderr.strip().casefold()
        if not normalized_stderr:
            stderr_category = "empty"
        elif "not found" in normalized_stderr or "no such process" in normalized_stderr:
            stderr_category = "not_found"
        elif "permission" in normalized_stderr or "not permitted" in normalized_stderr:
            stderr_category = "permission_denied"
        else:
            stderr_category = "other"
    application_type = values.get("ApplicationType")
    if application_type not in WINDOW_POLICY_APPLICATION_TYPES.values():
        application_type = "other" if application_type is not None else "missing"
    return {
        "returncode": returncode,
        "stdout_shape": stdout_shape,
        "stderr_category": stderr_category,
        "bundle_id_matches": values.get("CFBundleIdentifier") == BUNDLE_ID,
        "bundle_path_matches": values.get("LSBundlePath") == str(expected_app),
        "pid_matches": values.get("pid") == str(expected_pid),
        "application_type": application_type,
    }


def query_launch_services_state(
    *,
    app: pathlib.Path,
    pid: int,
) -> dict[str, Any]:
    command = [
        "/usr/bin/lsappinfo",
        "info",
        "-only",
        "bundlepath,bundleid,pid,ApplicationType",
        "-app",
        str(pid),
    ]
    try:
        completed = subprocess.run(
            command,
            text=True,
            capture_output=True,
            check=False,
            timeout=LSAPPINFO_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        return sanitized_launch_services_state(
            "",
            expected_app=app,
            expected_pid=pid,
            returncode=None,
            timed_out=True,
        )
    except OSError:
        return sanitized_launch_services_state(
            "",
            expected_app=app,
            expected_pid=pid,
            returncode=None,
            invocation_failed=True,
        )
    return sanitized_launch_services_state(
        completed.stdout,
        expected_app=app,
        expected_pid=pid,
        returncode=completed.returncode,
        stderr=completed.stderr,
    )


def launch_services_state_matches(
    state: dict[str, Any], terminal: dict[str, Any]
) -> bool:
    expected_type = WINDOW_POLICY_APPLICATION_TYPES.get(terminal.get("code"))
    return (
        expected_type is not None
        and state.get("returncode") == 0
        and state.get("stdout_shape") == "exact_fields"
        and state.get("stderr_category") == "empty"
        and state.get("bundle_id_matches") is True
        and state.get("bundle_path_matches") is True
        and state.get("pid_matches") is True
        and state.get("application_type") == expected_type
    )


def launch_services_record_absent(state: dict[str, Any]) -> bool:
    return (
        state.get("application_type") == "missing"
        and state.get("bundle_id_matches") is False
        and state.get("bundle_path_matches") is False
        and state.get("pid_matches") is False
        and (
            (
                state.get("stdout_shape") == "null_fields"
                and state.get("returncode") == 0
                and state.get("stderr_category") == "empty"
            )
            or (
                state.get("stdout_shape") == "empty"
                and isinstance(state.get("returncode"), int)
                and state.get("returncode") != 0
                and state.get("stderr_category") == "not_found"
            )
        )
    )


def wait_for_launch_services_deregistration(
    *,
    app: pathlib.Path,
    pid: int,
    timeout_seconds: float = LAUNCH_SERVICES_DEREGISTRATION_TIMEOUT_SECONDS,
) -> int:
    deadline = time.monotonic() + timeout_seconds
    last_state: dict[str, Any] | None = None
    while time.monotonic() < deadline:
        last_state = query_launch_services_state(app=app, pid=pid)
        if launch_services_record_absent(last_state):
            return int(time.time() * 1000)
        if last_state.get("stderr_category") in {
            "permission_denied",
            "invocation_failed",
            "other",
        }:
            break
        time.sleep(0.05)
    sanitized = json.dumps(last_state, sort_keys=True, separators=(",", ":"))
    raise EvidenceError(
        "typed shutdown completed but LaunchServices did not prove exact PID deregistration; "
        f"sanitized state={sanitized}"
    )


def validate_post_idle_self_test_observation(
    *,
    idle_phase: dict[str, Any],
    session_id: str,
    state: dict[str, Any],
    observed_at_unix_ms: int,
    start_signal: pathlib.Path,
) -> dict[str, Any]:
    if not start_signal.is_absolute() or start_signal.exists() or start_signal.is_symlink():
        raise EvidenceError("self-test workload start signal exists before post-idle verification")
    started_at = idle_phase.get("started_at_unix_ms")
    ended_at = idle_phase.get("ended_at_unix_ms")
    diagnostics = idle_phase.get("diagnostics")
    if (
        not isinstance(started_at, int)
        or not isinstance(ended_at, int)
        or ended_at < started_at
        or not isinstance(diagnostics, list)
        or not isinstance(observed_at_unix_ms, int)
        or observed_at_unix_ms < ended_at
    ):
        raise EvidenceError("idle phase cannot support a bounded post-idle verification")
    if any(
        record.get("session_id") == session_id
        and record.get("code") == "window_policy_apply_failed"
        and started_at <= record.get("timestamp_unix_ms", -1) <= ended_at
        for record in diagnostics
    ):
        raise EvidenceError("idle phase contains a same-session window policy failure")
    accessory = {"code": "window_policy_accessory_ready"}
    if not launch_services_state_matches(state, accessory):
        sanitized = json.dumps(state, sort_keys=True, separators=(",", ":"))
        raise EvidenceError(
            "post-idle self-test requires exact Accessory/UIElement LaunchServices state; "
            f"sanitized state={sanitized}"
        )
    return {
        "observed_at_unix_ms": observed_at_unix_ms,
        **state,
    }


def validate_initial_self_test_accessory(
    *,
    observation: dict[str, Any],
    start_signal: pathlib.Path,
) -> None:
    if not start_signal.is_absolute() or start_signal.exists() or start_signal.is_symlink():
        raise EvidenceError("self-test workload start signal exists before launch verification")
    terminal = observation.get("terminal")
    state = observation.get("launch_services_state")
    accessory = {"code": "window_policy_accessory_ready"}
    if (
        not isinstance(terminal, dict)
        or terminal.get("code") != accessory["code"]
        or not isinstance(state, dict)
        or not launch_services_state_matches(state, accessory)
    ):
        sanitized = (
            json.dumps(state, sort_keys=True, separators=(",", ":"))
            if isinstance(state, dict)
            else "missing"
        )
        raise EvidenceError(
            "signed self-test launch requires terminal Accessory/UIElement policy; "
            f"sanitized state={sanitized}"
        )


def launch_failure_message(
    *,
    saw_exact_pid: bool,
    exact_pid_running: bool,
    startup_observed: bool,
    ready_observed: bool,
    terminal_observed: bool,
    expected_application_type: str | None,
    launch_services_observations: dict[str, Any] | None,
) -> str:
    if not saw_exact_pid:
        return "LaunchServices did not expose the exact candidate process"
    if not exact_pid_running:
        return "exact candidate exited before reaching the readiness contract"
    if not startup_observed:
        return "exact candidate started but did not emit the startup diagnostic"
    if not ready_observed:
        return "exact candidate emitted startup but not menu_bar_ready"
    if not terminal_observed:
        return "exact candidate emitted menu_bar_ready but no terminal window policy diagnostic"
    if launch_services_observations is None:
        return "exact candidate emitted terminal window policy but LaunchServices returned no state"
    expected = expected_application_type or "unknown"
    observations = json.dumps(
        launch_services_observations,
        sort_keys=True,
        separators=(",", ":"),
    )
    return (
        f"exact candidate terminal window policy expected ApplicationType={expected}; "
        f"sanitized LaunchServices observations={observations}"
    )


def launch_ready_at_ms(
    terminal_policy_ready_ms: int,
    launch_services_observed_ms: int,
) -> int:
    return max(terminal_policy_ready_ms, launch_services_observed_ms)


def launch_stage_durations(sample: dict[str, Any]) -> dict[str, int]:
    started = sample["started_at_unix_ms"]
    startup = sample["startup_diagnostic_at_unix_ms"]
    menu = sample["menu_bar_ready_at_unix_ms"]
    terminal = sample["terminal_policy_ready_at_unix_ms"]
    launch_services = sample["launch_services_observed_at_unix_ms"]
    return {
        "external_open_to_startup_ms": startup - started,
        "startup_to_menu_bar_ms": menu - startup,
        "menu_bar_to_terminal_policy_ms": terminal - menu,
        "terminal_policy_to_launch_services_ms": launch_services - terminal,
        "total_ms": sample["ready_at_unix_ms"] - started,
    }


LAUNCH_SAMPLE_KEYS = {
    "started_at_unix_ms",
    "startup_diagnostic_at_unix_ms",
    "ready_at_unix_ms",
    "menu_bar_ready_at_unix_ms",
    "terminal_policy_ready_at_unix_ms",
    "launch_services_observed_at_unix_ms",
    "terminal_application_type",
    "latency_ms",
    "session_id",
    "stages_ms",
}
LAUNCH_SHUTDOWN_KEYS = {
    "typed_shutdown_requested_at_unix_ms",
    "process_terminated_at_unix_ms",
    "launch_services_deregistered_at_unix_ms",
}
LAUNCH_STAGE_KEYS = {
    "external_open_to_startup_ms",
    "startup_to_menu_bar_ms",
    "menu_bar_to_terminal_policy_ms",
    "terminal_policy_to_launch_services_ms",
    "total_ms",
}


def validate_launch_sample(
    sample: Any,
    *,
    expected_keys: set[str],
    require_shutdown: bool,
) -> None:
    if not isinstance(sample, dict) or set(sample) != expected_keys:
        raise EvidenceError("launch sample has an unexpected closed shape")
    timestamp_keys = (
        "started_at_unix_ms",
        "startup_diagnostic_at_unix_ms",
        "menu_bar_ready_at_unix_ms",
        "terminal_policy_ready_at_unix_ms",
        "launch_services_observed_at_unix_ms",
        "ready_at_unix_ms",
        "latency_ms",
    )
    values = [sample.get(key) for key in timestamp_keys]
    if not all(isinstance(value, int) and not isinstance(value, bool) for value in values):
        raise EvidenceError("launch sample timings are not exact integers")
    started, startup, menu, terminal, launch_services, ready, latency = values
    if (
        started < 0
        or startup < started
        or menu < startup
        or terminal < menu
        or launch_services < terminal
        or ready != launch_ready_at_ms(terminal, launch_services)
        or latency != ready - started
    ):
        raise EvidenceError("launch sample timestamps are inconsistent")
    if sample.get("terminal_application_type") not in WINDOW_POLICY_APPLICATION_TYPES.values():
        raise EvidenceError("launch sample has an invalid terminal ApplicationType")
    if not re.fullmatch(r"s-[0-9a-f]{16}", sample.get("session_id", "")):
        raise EvidenceError("launch sample has an invalid session ID")
    stages = sample.get("stages_ms")
    if not isinstance(stages, dict) or set(stages) != LAUNCH_STAGE_KEYS:
        raise EvidenceError("launch sample stages have an unexpected closed shape")
    if stages != launch_stage_durations(sample):
        raise EvidenceError("launch sample stages differ from their timestamps")
    if require_shutdown:
        shutdown_values = [
            sample.get("typed_shutdown_requested_at_unix_ms"),
            sample.get("process_terminated_at_unix_ms"),
            sample.get("launch_services_deregistered_at_unix_ms"),
        ]
        if not all(
            isinstance(value, int) and not isinstance(value, bool)
            for value in shutdown_values
        ):
            raise EvidenceError("launch shutdown proof is not exact integer evidence")
        shutdown_requested, process_terminated, deregistered = shutdown_values
        if not (
            ready <= shutdown_requested <= process_terminated <= deregistered
        ):
            raise EvidenceError("launch shutdown proof is not ordered after readiness")


def check_launch_sampling(result: dict[str, Any], label: str) -> list[str]:
    try:
        phases = result.get("phases", {})
        metrics = result.get("metrics", {})
        warm = phases.get("launch_warm")
        if (warm is None) != (metrics.get("launch.warm.p95_ms") is None):
            raise EvidenceError("warm launch phase and metric presence differ")
        if warm is not None:
            if warm.get("malloc_stack_logging") is True:
                if (
                    set(warm)
                    != {
                        "phase",
                        "definition",
                        "samples",
                        "malloc_stack_logging",
                    }
                    or warm.get("phase") != "launch_warm"
                    or warm.get("definition") != MALLOC_LAUNCH_DEFINITION
                ):
                    raise EvidenceError("stack-logged launch has an invalid closed shape")
                samples = warm.get("samples")
                if not isinstance(samples, list) or len(samples) != 1:
                    raise EvidenceError("stack-logged launch requires exactly one retained sample")
                validate_launch_sample(
                    samples[0],
                    expected_keys=LAUNCH_SAMPLE_KEYS,
                    require_shutdown=False,
                )
                metric = metrics.get("launch.warm.p95_ms")
                if (
                    not isinstance(metric, dict)
                    or metric.get("sample_count") != 1
                    or float(metric.get("value", -1))
                    != float(samples[0]["latency_ms"])
                ):
                    raise EvidenceError("stack-logged launch metric differs from its retained sample")
            else:
                if set(warm) != {"phase", "definition", "priming", "samples"}:
                    raise EvidenceError("warm launch phase has an unexpected closed shape")
                if warm.get("phase") != "launch_warm" or warm.get("definition") != WARM_LAUNCH_DEFINITION:
                    raise EvidenceError("warm launch phase has an invalid definition")
                priming = warm.get("priming")
                priming_keys = LAUNCH_SAMPLE_KEYS | LAUNCH_SHUTDOWN_KEYS | {
                    "contract",
                    "metric_contribution",
                }
                validate_launch_sample(
                    priming,
                    expected_keys=priming_keys,
                    require_shutdown=True,
                )
                if (
                    priming.get("contract") != WARM_PRIMING_CONTRACT
                    or priming.get("metric_contribution") is not False
                ):
                    raise EvidenceError("warm priming proof can contribute to the metric")
                samples = warm.get("samples")
                if not isinstance(samples, list) or len(samples) != 10:
                    raise EvidenceError("warm launch requires exactly ten measured restarts")
                previous = priming
                sessions = {priming["session_id"]}
                for sample in samples:
                    validate_launch_sample(
                        sample,
                        expected_keys=LAUNCH_SAMPLE_KEYS | LAUNCH_SHUTDOWN_KEYS,
                        require_shutdown=True,
                    )
                    if sample["session_id"] in sessions:
                        raise EvidenceError("warm launch reuses a diagnostic session")
                    if sample["started_at_unix_ms"] < previous["launch_services_deregistered_at_unix_ms"]:
                        raise EvidenceError("warm restart began before prior LaunchServices deregistration")
                    sessions.add(sample["session_id"])
                    previous = sample
                metric = metrics.get("launch.warm.p95_ms")
                expected_value = percentile(sample["latency_ms"] for sample in samples)
                if (
                    not isinstance(metric, dict)
                    or metric.get("sample_count") != 10
                    or float(metric.get("value", -1)) != float(expected_value)
                ):
                    raise EvidenceError("warm launch metric differs from its ten measured restarts")

        cold = phases.get("launch_cold")
        if (cold is None) != (metrics.get("launch.cold.p95_ms") is None):
            raise EvidenceError("cold launch phase and metric presence differ")
        if cold is not None:
            if set(cold) != {"phase", "definition", "samples"} or cold.get("phase") != "launch_cold":
                raise EvidenceError("cold launch phase has an unexpected closed shape")
            definition = cold.get("definition")
            samples = cold.get("samples")
            if not isinstance(samples, list):
                raise EvidenceError("cold launch samples are missing")
            if definition == CONSTRAINED_COLD_DEFINITION:
                expected_count = 1
                extra_keys = {"fresh_runner_id"}
            elif definition == AGGREGATED_COLD_DEFINITION:
                expected_count = 5
                extra_keys = {"fresh_runner_id", "shard_evidence_sha256"}
            elif definition == HUMAN_COLD_DEFINITION:
                expected_count = 1
                extra_keys = set()
            else:
                raise EvidenceError("cold launch phase has an invalid definition")
            if len(samples) != expected_count:
                raise EvidenceError("cold launch sample count differs from its definition")
            runner_ids: set[str] = set()
            for sample in samples:
                validate_launch_sample(
                    sample,
                    expected_keys=LAUNCH_SAMPLE_KEYS | extra_keys,
                    require_shutdown=False,
                )
                if "fresh_runner_id" in extra_keys:
                    runner_id = sample.get("fresh_runner_id", "")
                    if not re.fullmatch(r"gh-[0-9]+-[0-9]+-cold-[1-5]", runner_id):
                        raise EvidenceError("cold launch has an invalid fresh runner ID")
                    if runner_id in runner_ids:
                        raise EvidenceError("cold launch reuses a fresh runner ID")
                    runner_ids.add(runner_id)
                if "shard_evidence_sha256" in extra_keys and not re.fullmatch(
                    r"[0-9a-f]{64}", sample.get("shard_evidence_sha256", "")
                ):
                    raise EvidenceError("aggregated cold launch has an invalid shard digest")
            metric = metrics.get("launch.cold.p95_ms")
            expected_value = percentile(sample["latency_ms"] for sample in samples)
            if (
                not isinstance(metric, dict)
                or metric.get("sample_count") != expected_count
                or float(metric.get("value", -1)) != float(expected_value)
            ):
                raise EvidenceError("cold launch metric differs from its raw samples")
    except (EvidenceError, KeyError, TypeError, ValueError) as error:
        return [f"{label}: {error}"]
    return []


def observe_launch_sample(
    *,
    app: pathlib.Path,
    identity: dict[str, Any],
    diagnostics: pathlib.Path,
    timeout_seconds: float,
    malloc_stack_logging: bool = False,
) -> tuple[dict[str, Any], int]:
    started_ms = int(time.time() * 1000)
    launch_command = ["/usr/bin/open", "-n"]
    if malloc_stack_logging:
        launch_command.extend(["--env", "MallocStackLogging=1"])
    launch_command.append(str(app))
    subprocess.run(launch_command, check=True)
    observation = wait_for_route_aware_launch(
        app=app,
        identity=identity,
        diagnostics=diagnostics,
        started_ms=started_ms,
        timeout_seconds=timeout_seconds,
    )
    startup = observation["startup"]
    ready = observation["ready"]
    terminal = observation["terminal"]
    launch_services_observed_ms = observation["launch_services_observed_at_unix_ms"]
    ready_at_ms = launch_ready_at_ms(
        terminal["timestamp_unix_ms"], launch_services_observed_ms
    )
    latency = ready_at_ms - started_ms
    if latency < 0:
        raise EvidenceError("wall clock moved backwards during launch measurement")
    sample = {
        "started_at_unix_ms": started_ms,
        "startup_diagnostic_at_unix_ms": startup["timestamp_unix_ms"],
        "ready_at_unix_ms": ready_at_ms,
        "menu_bar_ready_at_unix_ms": ready["timestamp_unix_ms"],
        "terminal_policy_ready_at_unix_ms": terminal["timestamp_unix_ms"],
        "launch_services_observed_at_unix_ms": launch_services_observed_ms,
        "terminal_application_type": WINDOW_POLICY_APPLICATION_TYPES[terminal["code"]],
        "latency_ms": latency,
        "session_id": ready.get("session_id"),
    }
    sample["stages_ms"] = launch_stage_durations(sample)
    return sample, observation["pid"]


def terminate_and_deregister_launch(
    *, app: pathlib.Path, identity: dict[str, Any], pid: int
) -> dict[str, int]:
    shutdown_requested, terminated = terminate_exact(identity, pid)
    deregistered = wait_for_launch_services_deregistration(app=app, pid=pid)
    return {
        "typed_shutdown_requested_at_unix_ms": shutdown_requested,
        "process_terminated_at_unix_ms": terminated,
        "launch_services_deregistered_at_unix_ms": deregistered,
    }


def wait_for_route_aware_launch(
    *,
    app: pathlib.Path,
    identity: dict[str, Any],
    diagnostics: pathlib.Path,
    started_ms: int,
    timeout_seconds: float,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout_seconds
    pid: int | None = None
    observed_pid: int | None = None
    ready: dict[str, Any] | None = None
    terminal: dict[str, Any] | None = None
    saw_exact_pid = False
    startup_observed = False
    last_launch_services_state: dict[str, Any] | None = None
    first_launch_services_state: dict[str, Any] | None = None
    launch_services_observation_count = 0
    while time.monotonic() < deadline:
        pid = exact_pid(identity, required=False)
        saw_exact_pid |= pid is not None
        if pid is not None:
            if observed_pid is None:
                observed_pid = pid
            elif pid != observed_pid:
                try:
                    terminate_exact(identity, pid)
                except EvidenceError as shutdown_error:
                    raise EvidenceError(
                        "exact candidate PID changed during launch readiness observation; "
                        f"{shutdown_error}"
                    ) from shutdown_error
                raise EvidenceError("exact candidate PID changed during launch readiness observation")
        current_startup, ready, terminal = launch_diagnostic_state(diagnostics, started_ms)
        startup_observed |= current_startup is not None
        if pid is not None and ready is not None and terminal is not None:
            last_launch_services_state = query_launch_services_state(app=app, pid=pid)
            launch_services_observation_count += 1
            if first_launch_services_state is None:
                first_launch_services_state = last_launch_services_state
            if launch_services_state_matches(last_launch_services_state, terminal):
                observed_at_ms = int(time.time() * 1000)
                return {
                    "pid": pid,
                    "startup": current_startup,
                    "ready": ready,
                    "terminal": terminal,
                    "launch_services_state": last_launch_services_state,
                    "launch_services_observed_at_unix_ms": observed_at_ms,
                }
        time.sleep(0.01)

    expected_type = (
        WINDOW_POLICY_APPLICATION_TYPES.get(terminal.get("code"))
        if terminal is not None
        else None
    )
    launch_services_observations = None
    if first_launch_services_state is not None and last_launch_services_state is not None:
        launch_services_observations = {
            "count": launch_services_observation_count,
            "first": first_launch_services_state,
            "last": last_launch_services_state,
        }
    failure = launch_failure_message(
        saw_exact_pid=saw_exact_pid,
        exact_pid_running=pid is not None,
        startup_observed=startup_observed,
        ready_observed=ready is not None,
        terminal_observed=terminal is not None,
        expected_application_type=expected_type,
        launch_services_observations=launch_services_observations,
    )
    if pid is not None:
        try:
            terminate_exact(identity, pid)
        except EvidenceError as shutdown_error:
            raise EvidenceError(f"{failure}; {shutdown_error}") from shutdown_error
    raise EvidenceError(failure)


def terminate_exact(identity: dict[str, Any], pid: int) -> tuple[int, int]:
    if executable_for_pid(pid) != identity["executable_path"]:
        raise EvidenceError("refusing to terminate a process whose executable identity changed")
    shutdown_requested_at_ms = int(time.time() * 1000)
    os.kill(pid, signal.SIGUSR1)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if executable_for_pid(pid) is None:
            return shutdown_requested_at_ms, int(time.time() * 1000)
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
    if args.mode == "warm" and not args.malloc_stack_logging:
        if args.iterations != 10 or args.leave_running:
            raise EvidenceError(
                "warm evidence requires one excluded priming launch followed by exactly ten terminated restart samples"
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
    if key in result["phases"] or f"launch.{args.mode}.p95_ms" in result["metrics"]:
        raise EvidenceError(f"{key} evidence already exists; launch epochs cannot be appended or mixed")
    samples: list[dict[str, Any]] = []
    priming: dict[str, Any] | None = None
    if args.mode == "warm" and not args.malloc_stack_logging:
        prime_sample, prime_pid = observe_launch_sample(
            app=app,
            identity=identity,
            diagnostics=diagnostics,
            timeout_seconds=args.timeout,
        )
        priming = {
            "contract": WARM_PRIMING_CONTRACT,
            "metric_contribution": False,
            **prime_sample,
            **terminate_and_deregister_launch(
                app=app, identity=identity, pid=prime_pid
            ),
        }
        time.sleep(args.settle_seconds)
    for _ in range(args.iterations):
        if exact_pid(identity, required=False) is not None:
            raise EvidenceError("exact candidate is still running before the next launch")
        sample, pid = observe_launch_sample(
            app=app,
            identity=identity,
            diagnostics=diagnostics,
            timeout_seconds=args.timeout,
            malloc_stack_logging=args.malloc_stack_logging,
        )
        if constrained_cold:
            sample["fresh_runner_id"] = args.fresh_runner_id
        if not args.leave_running:
            if args.mode == "warm":
                sample.update(
                    terminate_and_deregister_launch(app=app, identity=identity, pid=pid)
                )
            else:
                terminate_exact(identity, pid)
        samples.append(sample)
        if args.mode == "warm" and args.iterations > 1:
            time.sleep(args.settle_seconds)
    result["phases"][key] = {
        "phase": key,
        "definition": (
            CONSTRAINED_COLD_DEFINITION
            if constrained_cold
            else HUMAN_COLD_DEFINITION
            if args.mode == "cold"
            else MALLOC_LAUNCH_DEFINITION
            if args.malloc_stack_logging
            else WARM_LAUNCH_DEFINITION
        ),
        "samples": samples,
    }
    if priming is not None:
        result["phases"][key]["priming"] = priming
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
        if phase.get("definition") != CONSTRAINED_COLD_DEFINITION:
            raise EvidenceError(f"cold shard does not use the cold-launch definition: {label}")
        phase_samples = phase.get("samples")
        metric = shard["metrics"]["launch.cold.p95_ms"]
        if not isinstance(phase_samples, list) or len(phase_samples) != 1 or metric.get("sample_count") != 1:
            raise EvidenceError(f"cold shard must contain exactly one sample: {label}")
        sample = phase_samples[0]
        validate_launch_sample(
            sample,
            expected_keys=LAUNCH_SAMPLE_KEYS | {"fresh_runner_id"},
            require_shutdown=False,
        )
        latency = sample["latency_ms"]
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
        "definition": AGGREGATED_COLD_DEFINITION,
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


def check_idle_sampling(result: dict[str, Any], label: str) -> list[str]:
    failures: list[str] = []
    phase = result.get("phases", {}).get("idle")
    idle_metric_keys = {
        "idle.duration_seconds",
        "idle.cpu.avg_percent",
        "idle.cpu.p95_percent",
        "idle.wakeups.avg_per_s",
        "idle.wakeups.p95_per_s",
        "idle.energy.avg_impact",
        "idle.energy.p95_impact",
    }
    if phase is None:
        if idle_metric_keys & set(result.get("metrics", {})):
            failures.append(f"{label}: idle metrics have no raw idle sampling phase")
        return failures
    if not isinstance(phase, dict) or phase.get("phase") != "idle":
        return [f"{label}: idle sampling phase has an invalid shape"]
    samples = phase.get("samples")
    sampling = phase.get("sampling")
    if not isinstance(samples, list) or not isinstance(sampling, dict):
        return [f"{label}: idle sampling phase is missing raw samples or cadence summary"]
    try:
        recomputed = sampling_summary(
            samples,
            contract=IDLE_SAMPLING_CONTRACT,
            baseline_elapsed_seconds=sampling.get("baseline_elapsed_seconds"),
            baseline_at_unix_ms=sampling.get("baseline_at_unix_ms"),
            baseline_idle_wakeups=sampling.get("baseline_idle_wakeups"),
            requested_duration_seconds=phase.get("requested_duration_seconds"),
            requested_interval_seconds=phase.get("sample_interval_seconds"),
        )
        if sampling != recomputed:
            raise EvidenceError("stored cadence summary differs from raw idle samples")
        for sample in samples:
            for key in ("cpu_percent", "energy_impact"):
                value = sample.get(key)
                if not isinstance(value, (int, float)) or not math.isfinite(value):
                    raise EvidenceError(f"idle sample has invalid {key}")
        cpu = [float(sample["cpu_percent"]) for sample in samples]
        energy = [float(sample["energy_impact"]) for sample in samples]
        wakeups = [float(sample["idle_wakeups_per_s"]) for sample in samples]
        expected = {
            "idle.duration_seconds": (recomputed["wall_coverage_seconds"], 1),
            "idle.cpu.avg_percent": (time_weighted_mean(samples, "cpu_percent"), len(samples)),
            "idle.cpu.p95_percent": (percentile(cpu), len(samples)),
            "idle.wakeups.avg_per_s": (
                time_weighted_mean(samples, "idle_wakeups_per_s"),
                len(samples),
            ),
            "idle.wakeups.p95_per_s": (percentile(wakeups), len(samples)),
            "idle.energy.avg_impact": (
                time_weighted_mean(samples, "energy_impact"),
                len(samples),
            ),
            "idle.energy.p95_impact": (percentile(energy), len(samples)),
        }
        for key, (value, sample_count) in expected.items():
            actual = result.get("metrics", {}).get(key)
            if not isinstance(actual, dict):
                raise EvidenceError(f"idle sampling phase is missing derived metric {key}")
            if actual.get("sample_count") != sample_count or actual.get("value") != round(float(value), 6):
                raise EvidenceError(f"derived metric {key} differs from raw idle samples")
    except (EvidenceError, TypeError, ValueError) as error:
        failures.append(f"{label}: {error}")
    return failures


def require_derived_metric(
    result: dict[str, Any], key: str, value: float, sample_count: int
) -> None:
    actual = result.get("metrics", {}).get(key)
    if (
        not isinstance(actual, dict)
        or actual.get("sample_count") != sample_count
        or actual.get("value") != round(float(value), 6)
    ):
        raise EvidenceError(f"derived metric {key} differs from raw sampling evidence")


def check_active_sampling(result: dict[str, Any], label: str) -> list[str]:
    phase = result.get("phases", {}).get("cycles_20")
    if phase is None:
        return []
    if not isinstance(phase, dict) or phase.get("phase") != "cycles_20":
        return [f"{label}: active sampling phase has an invalid shape"]
    samples = phase.get("samples")
    sampling = phase.get("sampling")
    report = phase.get("self_test_report")
    if not isinstance(samples, list) or not isinstance(sampling, dict) or not isinstance(report, dict):
        return [f"{label}: active sampling phase is missing raw evidence"]
    try:
        fixture_manifest = read_json(FIXTURE_MANIFEST)
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
        expected_model = {
            "id": DEFAULT_MODEL_ID,
            "revision": DEFAULT_MODEL_REVISION,
            "engine_instances": 1,
            "warmed": True,
            "downloaded": True,
        }
        expected_workload = {"cycles": 20, "history_rows": 50}
        allowed_report_keys = {
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
        required_report_keys = allowed_report_keys - {"failure_code"}
        expected_timing_keys = {
            *SELF_TEST_ABSOLUTE_TIMING_KEYS,
            "model_download_ms",
            "model_cold_load_ms",
            "total_ms",
            "cycles_ms",
        }
        if (
            not required_report_keys.issubset(report)
            or not set(report).issubset(allowed_report_keys)
            or report.get("schema_version") != 1
            or report.get("contract") != SELF_TEST_CONTRACT
            or report.get("fixture") != expected_fixture
            or report.get("process") != {"pid": phase.get("pid")}
            or report.get("model") != expected_model
            or report.get("requested") != expected_workload
            or report.get("completed") != expected_workload
            or report.get("history") != {"schema_version": 1, "integrity_ok": True}
            or report.get("quit_requested") is not True
            or report.get("passed") is not True
            or report.get("failure_code") not in (None, "none")
            or not isinstance(report.get("timings"), dict)
            or set(report["timings"]) != expected_timing_keys
            or not re.fullmatch(r"s-[0-9a-f]{16}", report.get("session_id", ""))
        ):
            raise EvidenceError("stored self-test report differs from the closed product contract")
        recomputed = sampling_summary(
            samples,
            contract=ACTIVE_SAMPLING_CONTRACT,
            baseline_elapsed_seconds=sampling.get("baseline_elapsed_seconds"),
            baseline_at_unix_ms=sampling.get("baseline_at_unix_ms"),
            baseline_idle_wakeups=sampling.get("baseline_idle_wakeups"),
            requested_duration_seconds=phase.get("requested_duration_seconds"),
            requested_interval_seconds=phase.get("sample_interval_seconds"),
        )
        if sampling != recomputed:
            raise EvidenceError("stored cadence summary differs from raw active samples")
        for sample in samples:
            for key in (
                "cpu_percent",
                "rss_mib",
                "energy_impact",
                "observer_delivery_delay_seconds",
            ):
                value = sample.get(key)
                if not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
                    raise EvidenceError(f"active sample has invalid {key}")
            if (
                not isinstance(sample.get("threads"), int)
                or sample["threads"] < 0
                or not isinstance(sample.get("file_descriptors"), int)
                or sample["file_descriptors"] < 0
                or not isinstance(sample.get("file_descriptors_measured"), bool)
            ):
                raise EvidenceError("active sample has invalid resource counters")

        mapping = active_cycle_evidence(phase)
        if phase.get("cycle_resource_mapping") != mapping:
            raise EvidenceError("stored cycle mapping differs from raw active evidence")
        mapped = [samples[pair["sample_index"]] for pair in mapping["pairs"]]
        timings = report["timings"]
        post_warm = [
            sample
            for sample in samples
            if sample["timestamp_unix_ms"] >= timings["warmup_completed_at_unix_ms"]
        ]
        if len(post_warm) < 20:
            raise EvidenceError("active phase has fewer than 20 post-warm resource rows")
        cpu = [float(sample["cpu_percent"]) for sample in samples]
        energy = [float(sample["energy_impact"]) for sample in samples]
        wakeups = [float(sample["idle_wakeups_per_s"]) for sample in samples]
        require_derived_metric(result, "cycles_20.duration_seconds", recomputed["wall_coverage_seconds"], 1)
        require_derived_metric(
            result,
            "cycles_20.cpu.avg_percent",
            time_weighted_mean(samples, "cpu_percent"),
            len(samples),
        )
        require_derived_metric(result, "cycles_20.cpu.p95_percent", percentile(cpu), len(samples))
        require_derived_metric(
            result,
            "cycles_20.energy.avg_impact",
            time_weighted_mean(samples, "energy_impact"),
            len(samples),
        )
        require_derived_metric(result, "cycles_20.energy.p95_impact", percentile(energy), len(samples))
        require_derived_metric(
            result,
            "cycles_20.wakeups.avg_per_s",
            time_weighted_mean(samples, "idle_wakeups_per_s"),
            len(samples),
        )
        require_derived_metric(result, "cycles_20.wakeups.p95_per_s", percentile(wakeups), len(samples))
        require_derived_metric(result, "cycles.completed.count", 20, 1)
        require_derived_metric(
            result,
            "transcription.cpu.p95_percent",
            percentile(sample["cpu_percent"] for sample in mapped),
            20,
        )
        require_derived_metric(
            result,
            "transcription.energy.p95_impact",
            percentile(sample["energy_impact"] for sample in mapped),
            20,
        )
        require_derived_metric(
            result,
            "memory.post_warmup.p95_mib",
            percentile(sample["rss_mib"] for sample in post_warm),
            len(post_warm),
        )
        require_derived_metric(result, "model.download.p95_ms", timings["model_download_ms"], 1)
        require_derived_metric(result, "model.cold_load.p95_ms", timings["model_cold_load_ms"], 1)
        require_derived_metric(result, "history.rows.count", 50, 1)

        rss = [float(sample["rss_mib"]) for sample in mapped]
        fds = [float(sample["file_descriptors"]) for sample in mapped]
        threads = [float(sample["threads"]) for sample in mapped]
        require_derived_metric(result, "growth.rss.delta_mib", rss[-1] - rss[0], 20)
        require_derived_metric(result, "growth.rss.slope_mib_per_cycle", linear_slope(rss), 20)
        require_derived_metric(result, "growth.fd.delta", fds[-1] - fds[0], 20)
        require_derived_metric(result, "growth.thread.delta", threads[-1] - threads[0], 20)
        monotonic = sum(
            (
                monotonic_tail(rss, 1.0),
                monotonic_tail(fds, 0.0),
                monotonic_tail(threads, 0.0),
            )
        )
        require_derived_metric(result, "growth.monotonic_tail.count", monotonic, 20)

        all_samples = all_resource_samples(result)
        measured_fds = [
            sample for sample in all_samples if sample.get("file_descriptors_measured") is True
        ]
        require_derived_metric(
            result,
            "memory.peak_mib",
            max(float(sample["rss_mib"]) for sample in all_samples),
            len(all_samples),
        )
        require_derived_metric(
            result,
            "resources.thread.peak",
            max(int(sample["threads"]) for sample in all_samples),
            len(all_samples),
        )
        require_derived_metric(
            result,
            "resources.fd.peak",
            max(int(sample["file_descriptors"]) for sample in measured_fds),
            len(measured_fds),
        )
    except (EvidenceError, KeyError, TypeError, ValueError) as error:
        return [f"{label}: {error}"]
    return []


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
    failures.extend(check_idle_sampling(result, label))
    failures.extend(check_active_sampling(result, label))
    failures.extend(check_launch_sampling(result, label))
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
        help="LaunchServices-run gated signed-app idle and 20-cycle/50-History workloads",
    )
    command.add_argument("--app", required=True)
    command.add_argument("--fixture", required=True)
    command.add_argument("--data-root", required=True)
    command.add_argument("--output", required=True)
    command.add_argument(
        "--failure-summary",
        help="exact private-free constrained failure summary sibling (failure only)",
    )
    command.add_argument("--launch-timeout", type=float, default=20.0)
    command.add_argument("--ready-timeout", type=float, default=60.0)
    command.add_argument(
        "--idle-duration",
        type=float,
        default=1_800.0,
        help="fixed-count idle sampling duration before releasing the workload start gate",
    )
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
    command.add_argument(
        "--iterations",
        type=int,
        default=1,
        help="number of measured samples; warm mode first performs one excluded verified priming launch",
    )
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
