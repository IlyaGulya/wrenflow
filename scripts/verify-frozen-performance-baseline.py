#!/usr/bin/env python3
"""Verify the immutable beta.64 performance artifact for the first stable draft."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import pathlib
import re
import subprocess
import sys
import tempfile
import tomllib
import zipfile
from typing import Any, NoReturn


REPO = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_POLICY = REPO / "support/performance/frozen-stable-baseline-v1.json"
PERFORMANCE_TOOL = REPO / "scripts/perf/gpui-performance.py"
PERFORMANCE_BUDGETS = REPO / "support/performance/budgets-v1.json"
HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
CONTRACT = "wrenflow.frozen-stable-performance.v1"


class VerificationError(Exception):
    pass


def fail(message: str) -> NoReturn:
    raise VerificationError(message)


def duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            fail(f"duplicate JSON key: {key}")
        value[key] = item
    return value


def finite(value: str) -> float:
    parsed = float(value)
    if not math.isfinite(parsed):
        fail("non-finite JSON number")
    return parsed


def read_json(path: pathlib.Path, label: str) -> Any:
    if not path.is_absolute() or not path.is_file() or path.is_symlink():
        fail(f"{label} must be an absolute regular non-symlink file")
    try:
        return json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=duplicate_keys,
            parse_float=finite,
            parse_constant=lambda _: fail("non-finite JSON number"),
        )
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"could not read {label}: {error}")


def exact(value: Any, keys: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        actual = set(value) if isinstance(value, dict) else set()
        fail(f"{label} has missing {sorted(keys - actual)} and unknown {sorted(actual - keys)} keys")
    return value


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run_git(*arguments: str, text: bool = True) -> str | bytes:
    completed = subprocess.run(
        ["git", *arguments],
        cwd=REPO,
        capture_output=True,
        text=text,
        timeout=30,
        check=False,
    )
    if completed.returncode != 0:
        fail(f"git {' '.join(arguments)} failed")
    return completed.stdout


def git_file(commit: str, path: str) -> bytes:
    value = run_git("show", f"{commit}:{path}", text=False)
    assert isinstance(value, bytes)
    return value


def load_policy(path: pathlib.Path) -> dict[str, Any]:
    value = exact(
        read_json(path, "frozen performance policy"),
        {"schema_version", "contract", "artifact", "baseline", "stable_release"},
        "frozen performance policy",
    )
    if value["schema_version"] != 1 or value["contract"] != CONTRACT:
        fail("frozen performance policy version/contract is unsupported")
    artifact = exact(
        value["artifact"],
        {
            "repository", "run_id", "artifact_id", "name", "size_in_bytes",
            "archive_sha256", "result_name", "result_sha256", "report_name",
            "report_sha256",
        },
        "frozen performance artifact policy",
    )
    baseline = exact(
        value["baseline"],
        {
            "source_commit", "candidate_id", "dmg_sha256", "executable_sha256",
            "bundle_version", "bundle_build", "evaluated_metrics",
            "evaluated_measurements",
        },
        "frozen performance baseline policy",
    )
    stable = exact(
        value["stable_release"],
        {"source_commit", "allowed_diff"},
        "stable release source policy",
    )
    if artifact["repository"] != "IlyaGulya/wrenflow":
        fail("frozen artifact repository drifted")
    if not all(
        HEX64.fullmatch(str(value))
        for value in (
            artifact["archive_sha256"], artifact["result_sha256"],
            artifact["report_sha256"], baseline["dmg_sha256"],
            baseline["executable_sha256"],
        )
    ):
        fail("frozen performance policy contains an invalid SHA-256")
    if not HEX40.fullmatch(str(baseline["source_commit"])) or not HEX40.fullmatch(str(stable["source_commit"])):
        fail("frozen or stable source commit is invalid")
    allowed = stable["allowed_diff"]
    if not isinstance(allowed, list) or not allowed:
        fail("stable release allowed diff is empty")
    for index, entry in enumerate(allowed):
        exact(entry, {"status", "path"}, f"allowed diff entry {index}")
        if entry["status"] not in {"M", "D"} or not isinstance(entry["path"], str) or not entry["path"]:
            fail("stable release allowed diff contains an invalid entry")
    if allowed != sorted(allowed, key=lambda entry: entry["path"]):
        fail("stable release allowed diff is not path ordered")
    return value


def validate_metadata(metadata: dict[str, Any], policy: dict[str, Any]) -> None:
    artifact = policy["artifact"]
    metadata = exact(
        metadata,
        {
            "archive_download_url", "created_at", "digest", "expired", "expires_at",
            "id", "name", "node_id", "size_in_bytes", "updated_at", "url",
            "workflow_run",
        },
        "GitHub artifact metadata",
    )
    workflow = exact(
        metadata["workflow_run"],
        {"head_branch", "head_repository_id", "head_sha", "id", "repository_id"},
        "GitHub artifact workflow metadata",
    )
    expected_archive = f"https://api.github.com/repos/{artifact['repository']}/actions/artifacts/{artifact['artifact_id']}/zip"
    expected_url = f"https://api.github.com/repos/{artifact['repository']}/actions/artifacts/{artifact['artifact_id']}"
    if (
        metadata["id"] != artifact["artifact_id"]
        or metadata["name"] != artifact["name"]
        or metadata["size_in_bytes"] != artifact["size_in_bytes"]
        or metadata["digest"] != f"sha256:{artifact['archive_sha256']}"
        or metadata["expired"] is not False
        or metadata["archive_download_url"] != expected_archive
        or metadata["url"] != expected_url
        or workflow["id"] != artifact["run_id"]
        or workflow["head_sha"] != policy["baseline"]["source_commit"]
        or workflow["head_branch"] != "main"
        or workflow["repository_id"] != workflow["head_repository_id"]
    ):
        fail("GitHub artifact metadata differs from the frozen baseline")


def extract_archive(archive: pathlib.Path, policy: dict[str, Any], output: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path]:
    if not archive.is_absolute() or not archive.is_file() or archive.is_symlink():
        fail("artifact archive must be an absolute regular non-symlink file")
    artifact = policy["artifact"]
    if archive.stat().st_size != artifact["size_in_bytes"] or sha256(archive) != artifact["archive_sha256"]:
        fail("artifact archive bytes differ from the frozen digest")
    expected = sorted([artifact["report_name"], artifact["result_name"]])
    try:
        with zipfile.ZipFile(archive) as zipped:
            infos = zipped.infolist()
            if sorted(info.filename for info in infos) != expected or len(infos) != 2:
                fail("frozen artifact archive has an unexpected entry set")
            for info in infos:
                mode = (info.external_attr >> 16) & 0o170000
                if info.is_dir() or mode == 0o120000 or pathlib.PurePosixPath(info.filename).name != info.filename:
                    fail("frozen artifact archive contains an unsafe entry")
                target = output / info.filename
                target.write_bytes(zipped.read(info))
    except (OSError, zipfile.BadZipFile) as error:
        fail(f"could not extract frozen artifact: {error}")
    result = output / artifact["result_name"]
    report = output / artifact["report_name"]
    if sha256(result) != artifact["result_sha256"] or sha256(report) != artifact["report_sha256"]:
        fail("frozen result/report file digest differs")
    return result, report


def normalize_manifest(value: dict[str, Any]) -> dict[str, Any]:
    copied = json.loads(json.dumps(value))
    copied["workspace"]["package"]["version"] = "<release-version>"
    return copied


def normalize_lock(value: dict[str, Any]) -> dict[str, Any]:
    copied = json.loads(json.dumps(value))
    for package in copied.get("package", []):
        if package.get("name") in {"wrenflow-core", "wrenflow-domain", "wrenflow-gpui", "wrenflow-runtime"}:
            package["version"] = "<release-version>"
    return copied


def validate_source_diff(policy: dict[str, Any], release_source: str) -> None:
    baseline = policy["baseline"]["source_commit"]
    stable = policy["stable_release"]
    if release_source != stable["source_commit"]:
        fail("stable release source is not the approved first-release commit")
    run_git("cat-file", "-e", f"{baseline}^{{commit}}")
    run_git("cat-file", "-e", f"{release_source}^{{commit}}")
    completed = subprocess.run(
        ["git", "merge-base", "--is-ancestor", baseline, release_source],
        cwd=REPO,
        timeout=30,
        check=False,
    )
    if completed.returncode != 0:
        fail("stable release source does not descend from the frozen product source")
    name_status = str(run_git("diff", "--name-status", "--no-renames", f"{baseline}..{release_source}"))
    actual = [
        {"status": line.split("\t", 1)[0], "path": line.split("\t", 1)[1]}
        for line in name_status.splitlines()
        if line
    ]
    if actual != stable["allowed_diff"]:
        fail("stable release source diff differs from the approved non-runtime scope")
    for path in ("Cargo.toml", "native/wrenflow-gpui/Cargo.toml"):
        before = tomllib.loads(git_file(baseline, path).decode())
        after = tomllib.loads(git_file(release_source, path).decode())
        if normalize_manifest(before) != normalize_manifest(after):
            fail(f"{path} changed beyond the release version")
    for path in ("Cargo.lock", "native/wrenflow-gpui/Cargo.lock"):
        before = tomllib.loads(git_file(baseline, path).decode())
        after = tomllib.loads(git_file(release_source, path).decode())
        if normalize_lock(before) != normalize_lock(after):
            fail(f"{path} changed dependency truth beyond local package versions")
    before_budgets = json.loads(git_file(baseline, "support/performance/budgets-v1.json"))
    after_budgets = json.loads(git_file(release_source, "support/performance/budgets-v1.json"))
    numeric_keys = ("metric", "comparison", "threshold", "min_samples")
    before_numeric = [{key: item[key] for key in numeric_keys} for item in before_budgets["budgets"]]
    after_numeric = [{key: item[key] for key in numeric_keys} for item in after_budgets["budgets"]]
    if before_numeric != after_numeric:
        fail("stable release changed a performance threshold or minimum sample count")


def validate_evidence(result_path: pathlib.Path, report_path: pathlib.Path, policy: dict[str, Any], output: pathlib.Path) -> None:
    baseline = policy["baseline"]
    result = read_json(result_path.resolve(), "frozen performance result")
    report = exact(
        read_json(report_path.resolve(), "frozen performance report"),
        {
            "schema_version", "budget_version", "profile", "evaluated_metrics",
            "evaluated_measurements", "evidence_sets", "failures", "passed",
            "verified_at",
        },
        "frozen performance report",
    )
    if (
        report["schema_version"] != 1
        or report["budget_version"] != "gpui-performance-v1"
        or report["profile"] != "constrained"
        or report["evaluated_metrics"] != baseline["evaluated_metrics"]
        or report["evaluated_measurements"] != baseline["evaluated_measurements"]
        or report["evidence_sets"] != [{"name": "constrained-evidence.json", "role": "constrained_noninteractive"}]
        or report["failures"] != []
        or report["passed"] is not True
    ):
        fail("retained frozen performance report is not exact 24-of-24 evidence")
    candidate = result.get("candidate", {})
    if (
        result.get("sealed") is not True
        or result.get("sanitized") is not True
        or result.get("source") != {"commit": baseline["source_commit"], "dirty": False}
        or result.get("candidate_id") != baseline["candidate_id"]
        or not str(result.get("candidate_id", "")).endswith(baseline["dmg_sha256"])
        or candidate.get("executable_sha256") != baseline["executable_sha256"]
        or candidate.get("bundle_version") != baseline["bundle_version"]
        or str(candidate.get("bundle_build")) != baseline["bundle_build"]
    ):
        fail("frozen result differs from the exact beta.64 DMG/executable/source")
    completed = subprocess.run(
        [
            sys.executable, str(PERFORMANCE_TOOL), "verify", "--profile", "release",
            "--result", str(result_path), "--budgets", str(PERFORMANCE_BUDGETS),
            "--report", str(output),
        ],
        cwd=REPO,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    if completed.returncode != 0 or not output.is_file():
        fail("current trusted verifier rejected the frozen performance result")
    current = read_json(output.resolve(), "current frozen performance verification")
    if (
        current.get("profile") != "release"
        or current.get("passed") is not True
        or current.get("evaluated_metrics") != baseline["evaluated_metrics"]
        or current.get("evaluated_measurements") != baseline["evaluated_measurements"]
        or current.get("failures") != []
    ):
        fail("current verifier did not recompute exact 24-of-24 release evidence")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", type=pathlib.Path, default=DEFAULT_POLICY)
    parser.add_argument("--metadata", type=pathlib.Path, required=True)
    parser.add_argument("--archive", type=pathlib.Path, required=True)
    parser.add_argument("--release-source", required=True)
    parser.add_argument("--report", type=pathlib.Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        selected = load_policy(args.policy.resolve())
        validate_metadata(read_json(args.metadata.resolve(), "GitHub artifact metadata"), selected)
        validate_source_diff(selected, args.release_source)
        if not args.report.is_absolute() or args.report.exists() or args.report.is_symlink():
            fail("current verification report must be a new absolute path")
        with tempfile.TemporaryDirectory(prefix="wrenflow-frozen-performance-") as temporary:
            result, retained_report = extract_archive(args.archive.resolve(), selected, pathlib.Path(temporary))
            validate_evidence(result, retained_report, selected, args.report)
    except (OSError, KeyError, TypeError, ValueError, tomllib.TOMLDecodeError, VerificationError) as error:
        print(f"frozen performance evidence error: {error}", file=sys.stderr)
        return 1
    print("frozen beta.64 performance baseline verified at exact 24-of-24")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
