#!/usr/bin/env python3
"""Verify closed first-public-release lifecycle evidence without launching Wrenflow."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import pathlib
import re
import subprocess
import sys
import tempfile
from datetime import datetime
from typing import Any, NoReturn


REPO = pathlib.Path(__file__).resolve().parents[1]
POLICY_PATH = REPO / "support/acceptance/endurance-v1-policy.json"
PERFORMANCE_TOOL = REPO / "scripts/perf/gpui-performance.py"
PERFORMANCE_BUDGETS = REPO / "support/performance/budgets-v1.json"
CONTRACT = "wrenflow.gpui.first-release-lifecycle.v1"
HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
TAG = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+$")
EVIDENCE_KINDS = {
    "result-sheet",
    "lifecycle-log",
    "disposable-state-log",
    "performance-result",
    "performance-report",
}


class EvidenceError(Exception):
    pass


def fail(message: str) -> NoReturn:
    raise EvidenceError(message)


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
    except (OSError, json.JSONDecodeError) as error:
        fail(f"could not read {label}: {error}")


def obj(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{label} must be an object")
    return value


def exact(value: dict[str, Any], keys: set[str], label: str) -> dict[str, Any]:
    if set(value) != keys:
        fail(f"{label} has missing {sorted(keys - set(value))} and unknown {sorted(set(value) - keys)} keys")
    return value


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_performance_hash(value: dict[str, Any]) -> str:
    candidate_value = dict(value)
    candidate_value.pop("evidence_sha256", None)
    encoded = json.dumps(candidate_value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def policy() -> dict[str, Any]:
    value = exact(
        obj(read_json(POLICY_PATH.resolve(), "lifecycle policy"), "lifecycle policy"),
        {
            "schema_version",
            "contract",
            "identity",
            "scope",
            "performance_baseline",
            "rows",
            "deferred_nonblocking",
        },
        "lifecycle policy",
    )
    if value["schema_version"] != 1 or value["contract"] != CONTRACT:
        fail("lifecycle policy version/contract is unsupported")
    if value["identity"] != {
        "release_line": "gpui-first-public-v1",
        "bundle_id": "me.gulya.wrenflow",
        "team_id": "T4LV8K9BGV",
        "decision_owner": "Ilya Gulya",
    }:
        fail("lifecycle policy identity drifted")
    if value["scope"] != {
        "existing_users": 0,
        "clean_install_only": True,
        "legacy_migration": "excluded",
        "downgrade_or_rollback": "excluded",
        "prerelease_to_stable_update": "excluded",
        "tcc_reset": "prohibited",
    }:
        fail("lifecycle policy scope drifted")
    if value["performance_baseline"] != {
        "tag": "v0.4.0-beta.64",
        "version": "0.4.0-beta.64",
        "build_number": "305",
        "source_commit": "d3e01e0ec085121f3bd3e78038836a16608b98a0",
        "dmg_sha256": "d7a04beb4513026dda7f72847ab2c53a5c1a82861b49192c7c6ae6937b35e1a5",
        "executable_sha256": "3a2d786a31ac6491a88d3a3f9fa8b9d66f4991f5f5d32e507c0db3caf6f573af",
        "candidate_id": "d3e01e0ec085121f3bd3e78038836a16608b98a0-d7a04beb4513026dda7f72847ab2c53a5c1a82861b49192c7c6ae6937b35e1a5",
        "result_file_sha256": "ade2e5b50cdabd525eee87fc9f78f213cdf62205c70ce7b2742e05910f668553",
        "result_evidence_sha256": "3c4f2cafcf56dee043aaf70fe487f614062762a68343a4da01e78f831285c0e7",
        "run_url": "https://github.com/IlyaGulya/wrenflow/actions/runs/31603344709",
        "artifact_id": "9146492644",
    }:
        fail("lifecycle performance baseline drifted")
    rows = obj(value["rows"], "lifecycle policy rows")
    if list(rows) != ["L01", "L02", "L03"]:
        fail("lifecycle policy rows must be ordered exactly L01,L02,L03")
    for row_id, row_value in rows.items():
        row = exact(obj(row_value, row_id), {"issue", "title", "required_evidence_kinds"}, row_id)
        if row["issue"] != "wrenflow-duh.9.11":
            fail(f"{row_id} issue drifted")
        kinds = row["required_evidence_kinds"]
        if not isinstance(kinds, list) or not kinds or any(kind not in EVIDENCE_KINDS for kind in kinds):
            fail(f"{row_id} evidence kinds drifted")
    if value["deferred_nonblocking"] != [
        "exhaustive_physical_instruments_attribution",
        "updater_transaction_fault_injection",
        "prerelease_to_stable_update_compatibility",
    ]:
        fail("lifecycle deferred work drifted")
    return value


def candidate(value: Any, label: str) -> dict[str, Any]:
    value = exact(
        obj(value, label),
        {"tag", "version", "build_number", "source_commit", "dmg_sha256", "team_id", "bundle_id"},
        label,
    )
    if (
        not TAG.fullmatch(str(value["tag"]))
        or value["tag"] != f"v{value['version']}"
        or "-" in str(value["version"])
        or not str(value["build_number"]).isdigit()
        or not HEX40.fullmatch(str(value["source_commit"]))
        or not HEX64.fullmatch(str(value["dmg_sha256"]))
        or value["team_id"] != "T4LV8K9BGV"
        or value["bundle_id"] != "me.gulya.wrenflow"
    ):
        fail(f"{label} is not an exact stable signed candidate identity")
    return value


def validate_plan(value: Any) -> dict[str, Any]:
    value = exact(
        obj(value, "candidate plan"),
        {"schema_version", "contract", "verification", "candidate"},
        "candidate plan",
    )
    if value["schema_version"] != 1 or value["contract"] != CONTRACT:
        fail("candidate plan contract is unsupported")
    if value["verification"] != "exact_signed_notarized_private_stable_draft":
        fail("candidate plan verification is not closed")
    candidate(value["candidate"], "candidate plan candidate")
    return value


def root(path: pathlib.Path) -> pathlib.Path:
    if not path.is_absolute() or not path.is_dir() or path.is_symlink():
        fail("evidence root must be an absolute non-symlink directory")
    return path.resolve(strict=True)


def retained_file(evidence_root: pathlib.Path, relative: Any, label: str) -> pathlib.Path:
    if not isinstance(relative, str) or not relative or relative.startswith("/"):
        fail(f"{label} path must be relative")
    relative_path = pathlib.Path(relative)
    if any(part in {"", ".", ".."} for part in relative_path.parts):
        fail(f"{label} path is unsafe")
    current = evidence_root
    for part in relative_path.parts:
        current /= part
        if current.is_symlink():
            fail(f"{label} must not traverse a symlink")
    if not current.is_file() or current.stat().st_size == 0:
        fail(f"{label} must be a non-empty regular file")
    current.resolve(strict=True).relative_to(evidence_root)
    return current


def timestamp(value: Any, label: str) -> None:
    if not isinstance(value, str):
        fail(f"{label} must be an ISO-8601 timestamp")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        fail(f"{label} is invalid: {error}")
    if parsed.tzinfo is None:
        fail(f"{label} must include a timezone")


def validate_performance(
    result_path: pathlib.Path,
    result: dict[str, Any],
    report: dict[str, Any],
    baseline: dict[str, Any],
) -> None:
    if result.get("sealed") is not True or result.get("sanitized") is not True:
        fail("L03 performance result is not sealed and sanitized")
    if (
        not HEX64.fullmatch(str(result.get("evidence_sha256", "")))
        or canonical_performance_hash(result) != result["evidence_sha256"]
    ):
        fail("L03 performance result seal does not match its content")
    if result.get("source", {}).get("commit") != baseline["source_commit"]:
        fail("L03 performance source differs from the frozen beta.64 baseline")
    if result.get("candidate_id") != baseline["candidate_id"]:
        fail("L03 performance candidate_id differs from the frozen beta.64 DMG")
    candidate_value = result.get("candidate", {})
    if (
        candidate_value.get("bundle_version") != baseline["version"]
        or str(candidate_value.get("bundle_build")) != baseline["build_number"]
        or candidate_value.get("executable_sha256") != baseline["executable_sha256"]
    ):
        fail("L03 performance beta.64 version/build/executable differs")

    expected_report_keys = {
        "schema_version",
        "budget_version",
        "profile",
        "evaluated_metrics",
        "evaluated_measurements",
        "evidence_sets",
        "passed",
        "failures",
        "verified_at",
    }
    exact(report, expected_report_keys, "L03 performance report")
    timestamp(report["verified_at"], "L03 performance report verified_at")
    with tempfile.TemporaryDirectory(prefix="wrenflow-lifecycle-performance-") as temporary:
        recomputed_path = pathlib.Path(temporary) / "report.json"
        completed = subprocess.run(
            [
                sys.executable,
                str(PERFORMANCE_TOOL),
                "verify",
                "--profile",
                "release",
                "--result",
                str(result_path),
                "--budgets",
                str(PERFORMANCE_BUDGETS),
                "--report",
                str(recomputed_path),
            ],
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )
        if completed.returncode != 0 or not recomputed_path.is_file():
            fail("L03 performance result did not recompute as an exact passing release result")
        recomputed = obj(read_json(recomputed_path.resolve(), "recomputed L03 performance report"), "recomputed L03 performance report")
    comparable_report = dict(report)
    comparable_report.pop("verified_at")
    recomputed.pop("verified_at")
    if comparable_report != recomputed:
        fail("L03 retained performance report differs from the recomputed release result")


def verify(plan_path: pathlib.Path, manifest_path: pathlib.Path, evidence_path: pathlib.Path) -> None:
    selected_policy = policy()
    plan = validate_plan(read_json(plan_path, "candidate plan"))
    evidence_root = root(evidence_path)
    manifest = exact(
        obj(read_json(manifest_path, "lifecycle manifest"), "lifecycle manifest"),
        {"schema_version", "contract", "candidate", "owner", "executed_at", "tcc_mutated", "rows", "decision"},
        "lifecycle manifest",
    )
    if manifest["schema_version"] != 1 or manifest["contract"] != CONTRACT:
        fail("lifecycle manifest contract is unsupported")
    binding = candidate(manifest["candidate"], "manifest candidate")
    if binding != plan["candidate"]:
        fail("manifest candidate differs from the authenticated plan")
    if manifest["owner"] != "Ilya Gulya" or manifest["tcc_mutated"] is not False:
        fail("lifecycle evidence must be owner-operated without TCC mutation")
    timestamp(manifest["executed_at"], "manifest executed_at")
    rows = obj(manifest["rows"], "manifest rows")
    if list(rows) != ["L01", "L02", "L03"]:
        fail("manifest rows must be ordered exactly L01,L02,L03")
    retained: dict[str, pathlib.Path] = {}
    for row_id, row_policy_value in selected_policy["rows"].items():
        row = exact(
            obj(rows[row_id], f"manifest {row_id}"),
            {"title", "result", "notes", "evidence"},
            f"manifest {row_id}",
        )
        if row["title"] != row_policy_value["title"] or row["result"] != "pass":
            fail(f"manifest {row_id} is not an exact passing policy row")
        if not isinstance(row["notes"], str) or not row["notes"].strip():
            fail(f"manifest {row_id} needs a retained note")
        entries = row["evidence"]
        if not isinstance(entries, list) or [entry.get("kind") for entry in entries if isinstance(entry, dict)] != row_policy_value["required_evidence_kinds"]:
            fail(f"manifest {row_id} evidence kinds/order differ")
        for entry_index, entry_value in enumerate(entries):
            entry = exact(obj(entry_value, f"{row_id} evidence"), {"kind", "relative_path", "sha256"}, f"{row_id} evidence")
            path = retained_file(evidence_root, entry["relative_path"], f"{row_id} evidence {entry_index}")
            if not HEX64.fullmatch(str(entry["sha256"])) or sha256(path) != entry["sha256"]:
                fail(f"{row_id} evidence hash mismatch")
            if entry["relative_path"] in retained:
                fail("lifecycle manifest reuses an evidence path")
            retained[entry["relative_path"]] = path
    l03 = rows["L03"]["evidence"]
    performance_result = obj(read_json(retained[l03[0]["relative_path"]], "L03 performance result"), "L03 performance result")
    performance_report = obj(read_json(retained[l03[1]["relative_path"]], "L03 performance report"), "L03 performance report")
    validate_performance(
        retained[l03[0]["relative_path"]],
        performance_result,
        performance_report,
        selected_policy["performance_baseline"],
    )
    if manifest["decision"] != "passed_first_release_lifecycle":
        fail("lifecycle manifest decision is not passed")
    print(f"{CONTRACT}: passed for {binding['tag']} {binding['dmg_sha256']}")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    sub = result.add_subparsers(dest="command", required=True)
    sub.add_parser("source")
    plan = sub.add_parser("validate-plan")
    plan.add_argument("plan", type=pathlib.Path)
    check = sub.add_parser("verify")
    check.add_argument("plan", type=pathlib.Path)
    check.add_argument("manifest", type=pathlib.Path)
    check.add_argument("evidence_root", type=pathlib.Path)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        if args.command == "source":
            policy()
            print("First-release lifecycle source contract passed")
        elif args.command == "validate-plan":
            validate_plan(read_json(args.plan, "candidate plan"))
            print("First-release lifecycle candidate plan passed")
        else:
            verify(args.plan, args.manifest, args.evidence_root)
    except EvidenceError as error:
        print(f"lifecycle evidence error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
