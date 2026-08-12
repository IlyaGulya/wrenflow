#!/usr/bin/env python3
"""Fail-closed validator for GPUI M13/M22 acceptance evidence."""

from __future__ import annotations

import hashlib
import json
import math
import re
import subprocess
import sys
import tempfile
from copy import deepcopy
from pathlib import Path
from typing import Any


REPO_DIR = Path(__file__).resolve().parent.parent
POLICY_PATH = REPO_DIR / "support/acceptance/endurance-v1-policy.json"
FIXTURE_DIR = REPO_DIR / "scripts/fixtures/endurance"
HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
UUID = re.compile(
    r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
)
SAFE_FILE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
UTC_TIMESTAMP = re.compile(
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"
)
PAYLOAD_FILES = [
    "Wrenflow.dmg",
    "Wrenflow.cdx.json",
    "RustThirdPartyLicenses.txt",
    "pins.json",
    "exceptions.json",
    "provenance.json",
    "artifact-provenance.json",
    "release-evidence.json",
    "SHA256SUMS",
]
SEMVER = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-((?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)"
    r"(?:\.(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*))?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
)


class EvidenceError(RuntimeError):
    pass


def reject_constant(value: str) -> None:
    raise EvidenceError(f"non-finite JSON number is forbidden: {value}")


def parse_finite_float(value: str) -> float:
    parsed = float(value)
    if not math.isfinite(parsed):
        raise EvidenceError(f"non-finite JSON number is forbidden: {value}")
    return parsed


def reject_duplicate_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise EvidenceError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json(path: Path) -> Any:
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(
                handle,
                object_pairs_hook=reject_duplicate_pairs,
                parse_constant=reject_constant,
                parse_float=parse_finite_float,
            )
    except (OSError, json.JSONDecodeError) as error:
        raise EvidenceError(f"cannot read closed JSON {path}: {error}") from error


def exact_keys(value: Any, expected: set[str], where: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise EvidenceError(f"{where} must be an object")
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        unknown = sorted(actual - expected)
        raise EvidenceError(f"{where} keys differ; missing={missing}, unknown={unknown}")
    return value


def exact_list(value: Any, expected_length: int, where: str) -> list[Any]:
    if not isinstance(value, list) or len(value) != expected_length:
        raise EvidenceError(f"{where} must contain exactly {expected_length} items")
    return value


def exact_string(value: Any, expected: str, where: str) -> None:
    if value != expected:
        raise EvidenceError(f"{where} must be {expected!r}")


def require_pattern(value: Any, pattern: re.Pattern[str], where: str) -> str:
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        raise EvidenceError(f"{where} has invalid format")
    return value


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(block)
    except OSError as error:
        raise EvidenceError(f"cannot hash evidence file {path}: {error}") from error
    return digest.hexdigest()


def validate_policy(policy: Any) -> dict[str, Any]:
    policy = exact_keys(
        policy,
        {
            "schema_version",
            "contract",
            "identity",
            "automated_update_fixtures",
            "manual_m13_pre_promotion",
            "post_promotion_stable",
            "manual_m22",
        },
        "policy",
    )
    if policy["schema_version"] != 1:
        raise EvidenceError("policy.schema_version must be 1")
    exact_string(
        policy["contract"],
        "wrenflow.gpui.endurance.update-evidence.v1",
        "policy.contract",
    )
    identity = exact_keys(
        policy["identity"],
        {"release_line", "bundle_id", "team_id", "decision_owner"},
        "policy.identity",
    )
    exact_string(identity["release_line"], "gpui-v1", "policy.identity.release_line")
    exact_string(identity["bundle_id"], "me.gulya.wrenflow", "policy.identity.bundle_id")
    exact_string(identity["team_id"], "T4LV8K9BGV", "policy.identity.team_id")
    exact_string(identity["decision_owner"], "Ilya Gulya", "policy.identity.decision_owner")
    automated = exact_keys(
        policy["automated_update_fixtures"],
        {"source_path", "verifier_path", "cycles", "cases", "other_cases"},
        "policy.automated_update_fixtures",
    )
    exact_string(
        automated["source_path"],
        "core/wrenflow-runtime/src/update.rs",
        "policy.automated_update_fixtures.source_path",
    )
    exact_string(
        automated["verifier_path"],
        "scripts/gpui-endurance-evidence.py",
        "policy.automated_update_fixtures.verifier_path",
    )
    if automated["cycles"] != 20:
        raise EvidenceError("policy automated cycles must be 20")
    cases = exact_list(automated["cases"], 7, "policy automated cases")
    expected_case_ids = [
        "stable_beta_channel_selection",
        "offline",
        "rate_limit",
        "malformed_metadata",
        "duplicate_release",
        "partial_transfer",
        "transaction_recovery_cycles",
    ]
    for index, (case, case_id) in enumerate(zip(cases, expected_case_ids, strict=True)):
        case = exact_keys(case, {"id", "test"}, f"policy case {index}")
        exact_string(case["id"], case_id, f"policy case {index}.id")
        if not isinstance(case["test"], str) or not case["test"].startswith("update::tests::"):
            raise EvidenceError(f"policy case {index}.test is not an exact update unit test")
    other_cases = exact_list(automated["other_cases"], 2, "policy other automated cases")
    expected_other_cases = [
        (
            "current_line_relaunch",
            "core/wrenflow-runtime/src/data_paths.rs",
            "data_paths::tests::twenty_current_line_relaunches_preserve_only_gpui_v1_state",
        ),
        (
            "interrupted_write_cleanup",
            "core/wrenflow-runtime/src/recovery.rs",
            "recovery::tests::twenty_interrupted_launches_clean_only_bounded_temporary_state",
        ),
    ]
    for index, (case, expected) in enumerate(
        zip(other_cases, expected_other_cases, strict=True)
    ):
        case = exact_keys(
            case, {"id", "source_path", "test"}, f"policy other case {index}"
        )
        if tuple(case[key] for key in ("id", "source_path", "test")) != expected:
            raise EvidenceError(f"policy other case {index} differs")
    m13 = exact_keys(
        policy["manual_m13_pre_promotion"],
        {"feed_url", "target_selected", "target_operations", "beta_outcomes"},
        "policy.manual_m13_pre_promotion",
    )
    exact_string(
        m13["feed_url"],
        "https://api.github.com/repos/IlyaGulya/wrenflow/releases?per_page=20",
        "policy.manual_m13_pre_promotion.feed_url",
    )
    if m13["target_operations"] != ["authenticated_target_artifact", "target_install"]:
        raise EvidenceError("policy pre-promotion M13 target operations differ")
    if m13["target_selected"] is not False:
        raise EvidenceError("policy pre-promotion M13 must keep the private target unselected")
    if m13["beta_outcomes"] != ["available", "up_to_date"]:
        raise EvidenceError("policy pre-promotion beta outcomes differ")
    post_stable = exact_keys(
        policy["post_promotion_stable"],
        {"feed_url", "operations"},
        "policy.post_promotion_stable",
    )
    exact_string(post_stable["feed_url"], m13["feed_url"], "policy post-promotion feed URL")
    if post_stable["operations"] != ["discovery", "authenticated_download"]:
        raise EvidenceError("policy post-promotion stable operations differ")
    m22 = exact_keys(policy["manual_m22"], {"stages"}, "policy.manual_m22")
    stages = exact_list(m22["stages"], 4, "policy M22 stages")
    expected_stages = [
        ("update_staging", "staging", "baseline_launchable"),
        ("update_prepared", "prepared", "baseline_launchable"),
        ("update_swapped", "swapped", "target_launchable"),
        ("before_ready_finalization", "swapped", "target_launchable"),
    ]
    for index, (stage, expected) in enumerate(zip(stages, expected_stages, strict=True)):
        stage = exact_keys(
            stage, {"id", "journal_phase", "installed_result"}, f"policy stage {index}"
        )
        if tuple(stage[key] for key in ("id", "journal_phase", "installed_result")) != expected:
            raise EvidenceError(f"policy M22 stage {index} differs")
    return policy


def semver_key(value: str, where: str) -> tuple[Any, ...]:
    match = SEMVER.fullmatch(value) if isinstance(value, str) else None
    if match is None:
        raise EvidenceError(f"{where} is not canonical SemVer")
    major, minor, patch = (int(match.group(index)) for index in (1, 2, 3))
    prerelease = match.group(4)
    if prerelease is None:
        pre_key: tuple[Any, ...] = (1,)
    else:
        parts: list[tuple[int, Any]] = []
        for item in prerelease.split("."):
            parts.append((0, int(item)) if item.isdigit() else (1, item))
        pre_key = (0, *parts)
    return major, minor, patch, pre_key


def validate_candidate(value: Any, policy: dict[str, Any], where: str) -> dict[str, Any]:
    value = exact_keys(
        value,
        {
            "release_line",
            "version",
            "tag",
            "build_number",
            "source_commit",
            "bundle_id",
            "team_id",
            "dmg_sha256",
            "release_evidence_sha256",
            "artifact_provenance_sha256",
            "checksum_set_sha256",
            "notarization_submission_id",
            "app_cdhash",
            "payload_files",
        },
        where,
    )
    identity = policy["identity"]
    exact_string(value["release_line"], identity["release_line"], f"{where}.release_line")
    exact_string(value["bundle_id"], identity["bundle_id"], f"{where}.bundle_id")
    exact_string(value["team_id"], identity["team_id"], f"{where}.team_id")
    version = value["version"]
    semver_key(version, f"{where}.version")
    exact_string(value["tag"], f"v{version}", f"{where}.tag")
    if not isinstance(value["build_number"], str) or not value["build_number"].isdigit():
        raise EvidenceError(f"{where}.build_number must be a decimal string")
    require_pattern(value["source_commit"], HEX40, f"{where}.source_commit")
    require_pattern(value["dmg_sha256"], HEX64, f"{where}.dmg_sha256")
    require_pattern(
        value["release_evidence_sha256"], HEX64, f"{where}.release_evidence_sha256"
    )
    require_pattern(
        value["artifact_provenance_sha256"], HEX64, f"{where}.artifact_provenance_sha256"
    )
    require_pattern(value["checksum_set_sha256"], HEX64, f"{where}.checksum_set_sha256")
    require_pattern(
        value["notarization_submission_id"], UUID, f"{where}.notarization_submission_id"
    )
    require_pattern(value["app_cdhash"], HEX40, f"{where}.app_cdhash")
    payload_files = exact_list(value["payload_files"], len(PAYLOAD_FILES), f"{where}.payload_files")
    for index, (record, expected_name) in enumerate(
        zip(payload_files, PAYLOAD_FILES, strict=True)
    ):
        record = exact_keys(record, {"name", "sha256"}, f"{where}.payload_files[{index}]")
        exact_string(record["name"], expected_name, f"{where}.payload_files[{index}].name")
        require_pattern(record["sha256"], HEX64, f"{where}.payload_files[{index}].sha256")
    payload_by_name = {record["name"]: record["sha256"] for record in payload_files}
    exact_string(payload_by_name["Wrenflow.dmg"], value["dmg_sha256"], f"{where}.payload DMG")
    exact_string(
        payload_by_name["release-evidence.json"],
        value["release_evidence_sha256"],
        f"{where}.payload release evidence",
    )
    exact_string(
        payload_by_name["artifact-provenance.json"],
        value["artifact_provenance_sha256"],
        f"{where}.payload provenance",
    )
    exact_string(
        payload_by_name["SHA256SUMS"], value["checksum_set_sha256"], f"{where}.payload checksums"
    )
    return value


def validate_candidate_pair(value: Any, policy: dict[str, Any]) -> dict[str, Any]:
    value = exact_keys(
        value,
        {"schema_version", "contract", "verification", "baseline", "target", "rows"},
        "candidate plan",
    )
    if value["schema_version"] != 1:
        raise EvidenceError("candidate plan schema_version must be 1")
    exact_string(
        value["contract"],
        "wrenflow.gpui.endurance.candidate-pair.v1",
        "candidate plan contract",
    )
    exact_string(
        value["verification"], "exact_notarized_candidate_pair_passed", "candidate verification"
    )
    baseline = validate_candidate(value["baseline"], policy, "candidate plan baseline")
    target = validate_candidate(value["target"], policy, "candidate plan target")
    target_match = SEMVER.fullmatch(target["version"])
    if target_match is None or target_match.group(4) is not None:
        raise EvidenceError("target version must be a final stable SemVer without prerelease")
    if baseline["source_commit"] == target["source_commit"]:
        raise EvidenceError("baseline and target must retain distinct source identities")
    if semver_key(baseline["version"], "baseline version") >= semver_key(
        target["version"], "target version"
    ):
        raise EvidenceError("baseline version must be lower than target version")
    if baseline["version"].split(".", 1)[0] != target["version"].split(".", 1)[0]:
        raise EvidenceError("baseline and target must stay on one GPUI major line")
    rows = exact_keys(value["rows"], {"M13", "M22"}, "candidate plan rows")
    if rows != {"M13": "pending_signed_manual", "M22": "pending_signed_manual"}:
        raise EvidenceError("candidate plan cannot claim manual M13/M22 results")
    return value


def git_output(arguments: list[str]) -> str:
    return subprocess.run(
        ["git", "-C", str(REPO_DIR), *arguments],
        check=True,
        capture_output=True,
        text=True,
    ).stdout


def git_head_sha256(relative: str) -> str:
    subprocess.run(
        ["git", "-C", str(REPO_DIR), "ls-files", "--error-unmatch", relative],
        check=True,
        capture_output=True,
    )
    payload = subprocess.run(
        ["git", "-C", str(REPO_DIR), "show", f"HEAD:{relative}"],
        check=True,
        capture_output=True,
    ).stdout
    return hashlib.sha256(payload).hexdigest()


def validate_automated(
    value: Any,
    policy: dict[str, Any],
    bind_source: bool,
    evidence_root: Path | None = None,
) -> dict[str, Any]:
    value = exact_keys(
        value,
        {
            "schema_version",
            "contract",
            "source",
            "cycles",
            "automated_update_fixtures",
            "other_automated",
            "candidate",
            "manual_candidate_rows",
        },
        "automated evidence",
    )
    if value["schema_version"] != 1:
        raise EvidenceError("automated evidence schema_version must be 1")
    exact_string(value["contract"], policy["contract"], "automated evidence contract")
    if value["cycles"] != policy["automated_update_fixtures"]["cycles"]:
        raise EvidenceError("automated evidence cycle count differs")
    source = exact_keys(
        value["source"],
        {
            "commit",
            "tree_state",
            "update_source_path",
            "update_source_sha256",
            "verifier_source_path",
            "verifier_source_sha256",
            "policy_sha256",
        },
        "automated source",
    )
    commit = require_pattern(source["commit"], HEX40, "automated source commit")
    if source["tree_state"] not in {"clean", "dirty"}:
        raise EvidenceError("automated source tree_state differs")
    exact_string(
        source["update_source_path"],
        policy["automated_update_fixtures"]["source_path"],
        "automated update source path",
    )
    update_sha = require_pattern(
        source["update_source_sha256"], HEX64, "automated update source SHA-256"
    )
    exact_string(
        source["verifier_source_path"],
        policy["automated_update_fixtures"]["verifier_path"],
        "automated verifier source path",
    )
    verifier_sha = require_pattern(
        source["verifier_source_sha256"], HEX64, "automated verifier source SHA-256"
    )
    policy_sha = require_pattern(source["policy_sha256"], HEX64, "automated policy SHA-256")
    fixture = exact_keys(
        value["automated_update_fixtures"],
        {"status", "log", "cases"},
        "automated update fixtures",
    )
    exact_string(fixture["status"], "passed", "automated fixture status")
    log_ref = exact_keys(fixture["log"], {"file", "sha256"}, "automated fixture log")
    log_name = require_pattern(log_ref["file"], SAFE_FILE, "automated fixture log file")
    log_sha = require_pattern(log_ref["sha256"], HEX64, "automated fixture log SHA-256")
    log_text: str | None = None
    if evidence_root is not None:
        log_path = evidence_root / log_name
        if log_path.is_symlink() or not log_path.is_file() or log_path.parent.resolve() != evidence_root.resolve():
            raise EvidenceError("automated fixture log is not a retained regular file")
        if sha256_file(log_path) != log_sha:
            raise EvidenceError("automated fixture log SHA-256 differs")
        try:
            log_text = log_path.read_text(encoding="utf-8")
        except OSError as error:
            raise EvidenceError(f"cannot read automated fixture log: {error}") from error
    expected_cases = policy["automated_update_fixtures"]["cases"]
    cases = exact_list(fixture["cases"], len(expected_cases), "automated fixture cases")
    for index, (case, expected) in enumerate(zip(cases, expected_cases, strict=True)):
        case = exact_keys(
            case,
            {"id", "test", "status", "source_sha256", "log_sha256"},
            f"automated fixture case {index}",
        )
        exact_string(case["id"], expected["id"], f"automated fixture case {index}.id")
        exact_string(case["test"], expected["test"], f"automated fixture case {index}.test")
        exact_string(case["status"], "passed", f"automated fixture case {index}.status")
        exact_string(case["source_sha256"], update_sha, f"automated fixture case {index}.source")
        exact_string(case["log_sha256"], log_sha, f"automated fixture case {index}.log")
        if log_text is not None and f"test {expected['test']} ... ok" not in log_text:
            raise EvidenceError(f"automated fixture log omits passing test {expected['test']}")
    other = exact_keys(
        value["other_automated"],
        {"current_line_relaunch", "interrupted_write_cleanup"},
        "other automated evidence",
    )
    for expected in policy["automated_update_fixtures"]["other_cases"]:
        case = exact_keys(
            other[expected["id"]],
            {"id", "test", "source_path", "source_sha256", "status", "log_sha256"},
            f"other automated evidence {expected['id']}",
        )
        exact_string(case["id"], expected["id"], f"other automated {expected['id']}.id")
        exact_string(case["test"], expected["test"], f"other automated {expected['id']}.test")
        exact_string(
            case["source_path"],
            expected["source_path"],
            f"other automated {expected['id']}.source_path",
        )
        source_sha = require_pattern(
            case["source_sha256"], HEX64, f"other automated {expected['id']}.source_sha256"
        )
        exact_string(case["status"], "passed", f"other automated {expected['id']}.status")
        exact_string(case["log_sha256"], log_sha, f"other automated {expected['id']}.log")
        if log_text is not None and f"test {expected['test']} ... ok" not in log_text:
            raise EvidenceError(f"automated fixture log omits passing test {expected['test']}")
        if bind_source:
            source_path = REPO_DIR / expected["source_path"]
            if (
                sha256_file(source_path) != source_sha
                or git_head_sha256(expected["source_path"]) != source_sha
            ):
                raise EvidenceError(
                    f"other automated {expected['id']} source hash differs from checkout"
                )
    exact_string(
        value["candidate"],
        "blocked_pending_immutable_notarized_artifacts",
        "automated candidate status",
    )
    rows = exact_keys(
        value["manual_candidate_rows"],
        {"M13", "M14", "M15", "M16", "M21", "M22"},
        "automated manual rows",
    )
    if rows != {
        "M13": "pending_signed_manual",
        "M14": "pending",
        "M15": "pending",
        "M16": "pending",
        "M21": "pending_instruments_budget",
        "M22": "pending_signed_manual",
    }:
        raise EvidenceError("automated evidence claimed or omitted a manual row")
    if bind_source:
        head = git_output(["rev-parse", "HEAD"]).strip()
        if commit != head or source["tree_state"] != "clean":
            raise EvidenceError("candidate evidence requires the exact clean source commit")
        if git_output(["status", "--porcelain=v1", "--untracked-files=all"]).strip():
            raise EvidenceError("candidate evidence verification requires a completely clean source tree")
        update_path = REPO_DIR / source["update_source_path"]
        if sha256_file(update_path) != update_sha or git_head_sha256(source["update_source_path"]) != update_sha:
            raise EvidenceError("automated update source hash differs from checkout")
        policy_relative = str(POLICY_PATH.relative_to(REPO_DIR))
        if sha256_file(POLICY_PATH) != policy_sha or git_head_sha256(policy_relative) != policy_sha:
            raise EvidenceError("automated policy hash differs from checkout")
        verifier_path = REPO_DIR / source["verifier_source_path"]
        if sha256_file(verifier_path) != verifier_sha or git_head_sha256(source["verifier_source_path"]) != verifier_sha:
            raise EvidenceError("automated verifier source hash differs from checkout")
    return value


def evidence_ref(value: Any, root: Path | None, where: str, seen_files: set[str]) -> dict[str, Any]:
    value = exact_keys(value, {"file", "sha256"}, where)
    filename = require_pattern(value["file"], SAFE_FILE, f"{where}.file")
    digest = require_pattern(value["sha256"], HEX64, f"{where}.sha256")
    if filename in seen_files:
        raise EvidenceError(f"duplicate retained evidence filename: {filename}")
    seen_files.add(filename)
    if root is not None:
        path = root / filename
        if path.is_symlink() or not path.is_file() or path.parent.resolve() != root.resolve():
            raise EvidenceError(f"{where} is not a retained regular file")
        if sha256_file(path) != digest:
            raise EvidenceError(f"{where} SHA-256 differs")
    return value


def validate_manifest(
    value: Any,
    policy: dict[str, Any],
    automated: dict[str, Any],
    candidate_plan: dict[str, Any],
    root: Path | None,
    automated_path: Path | None,
    candidate_plan_path: Path | None,
) -> dict[str, Any]:
    value = exact_keys(
        value,
        {"schema_version", "contract", "source", "M13", "M22", "decision"},
        "manifest",
    )
    if value["schema_version"] != 1:
        raise EvidenceError("manifest schema_version must be 1")
    exact_string(value["contract"], policy["contract"], "manifest contract")
    source = exact_keys(
        value["source"],
        {
            "commit",
            "update_source_sha256",
            "verifier_source_sha256",
            "policy_sha256",
            "automated_evidence_sha256",
            "candidate_plan_sha256",
        },
        "manifest source",
    )
    for field in source:
        require_pattern(source[field], HEX40 if field == "commit" else HEX64, f"manifest source {field}")
    exact_string(source["commit"], automated["source"]["commit"], "manifest source commit")
    exact_string(
        source["update_source_sha256"],
        automated["source"]["update_source_sha256"],
        "manifest update source SHA-256",
    )
    exact_string(
        source["policy_sha256"], automated["source"]["policy_sha256"], "manifest policy SHA-256"
    )
    exact_string(
        source["verifier_source_sha256"],
        automated["source"]["verifier_source_sha256"],
        "manifest verifier source SHA-256",
    )
    if automated_path is not None and sha256_file(automated_path) != source["automated_evidence_sha256"]:
        raise EvidenceError("manifest automated evidence SHA-256 differs")
    if candidate_plan_path is not None and sha256_file(candidate_plan_path) != source["candidate_plan_sha256"]:
        raise EvidenceError("manifest candidate plan SHA-256 differs")
    baseline = candidate_plan["baseline"]
    target = candidate_plan["target"]
    exact_string(
        source["commit"], target["source_commit"], "manifest source/target commit binding"
    )
    seen_files: set[str] = set()
    m13 = exact_keys(
        value["M13"],
        {"status", "target_artifact", "target_install", "beta_selector", "result"},
        "manifest M13",
    )
    exact_string(m13["status"], "passed_pre_promotion", "manifest M13 status")
    exact_string(
        m13["result"],
        "conditional_pass_pending_post_promotion_stable",
        "manifest M13 result",
    )
    target_artifact = evidence_ref(
        m13["target_artifact"], root, "manifest M13 target artifact", seen_files
    )
    target_install = evidence_ref(
        m13["target_install"], root, "manifest M13 target install", seen_files
    )
    beta_selector = evidence_ref(
        m13["beta_selector"], root, "manifest M13 beta selector", seen_files
    )
    exact_string(
        target_artifact["sha256"], target["dmg_sha256"], "manifest M13 target artifact DMG"
    )
    if root is not None:
        installed = exact_keys(
            load_json(root / target_install["file"]),
            {
                "schema_version",
                "version",
                "bundle_id",
                "team_id",
                "app_cdhash",
                "notarization",
                "gatekeeper",
                "result",
            },
            "retained M13 target install",
        )
        if installed != {
            "schema_version": 1,
            "version": target["version"],
            "bundle_id": target["bundle_id"],
            "team_id": target["team_id"],
            "app_cdhash": target["app_cdhash"],
            "notarization": "accepted",
            "gatekeeper": "accepted",
            "result": "target_launchable",
        }:
            raise EvidenceError("retained M13 target install differs")
        beta = exact_keys(
            load_json(root / beta_selector["file"]),
            {
                "schema_version",
                "channel",
                "feed_url",
                "transport",
                "http_status",
                "baseline_version",
                "outcome",
                "selected_version",
                "selected_dmg_sha256",
                "selected_asset_url",
                "target_selected",
                "response_url_opened",
            },
            "retained M13 beta selector",
        )
        if (
            beta["schema_version"] != 1
            or beta["channel"] != "beta"
            or beta["feed_url"] != policy["manual_m13_pre_promotion"]["feed_url"]
            or beta["transport"] != "https"
            or beta["http_status"] != 200
            or beta["baseline_version"] != baseline["version"]
            or beta["outcome"] not in policy["manual_m13_pre_promotion"]["beta_outcomes"]
            or beta["target_selected"] is not policy["manual_m13_pre_promotion"]["target_selected"]
            or beta["response_url_opened"] is not False
        ):
            raise EvidenceError("retained M13 beta selector differs")
        if beta["outcome"] == "up_to_date":
            if any(
                beta[field] is not None
                for field in ("selected_version", "selected_dmg_sha256", "selected_asset_url")
            ) or beta["target_selected"]:
                raise EvidenceError("retained M13 beta up-to-date result has a selected asset")
        else:
            selected_version = beta["selected_version"]
            if semver_key(
                selected_version, "retained M13 beta selected version"
            ) <= semver_key(baseline["version"], "retained M13 beta baseline version"):
                raise EvidenceError("retained M13 beta selected version is not newer than baseline")
            selected_sha = require_pattern(
                beta["selected_dmg_sha256"], HEX64, "retained M13 beta selected DMG"
            )
            expected_url = (
                "https://github.com/IlyaGulya/wrenflow/releases/download/"
                f"v{selected_version}/Wrenflow.dmg"
            )
            exact_string(beta["selected_asset_url"], expected_url, "retained M13 beta asset URL")
            if selected_version == target["version"] and selected_sha == target["dmg_sha256"]:
                raise EvidenceError(
                    "retained pre-promotion beta selector exposed the private stable target"
                )
    m22 = exact_keys(value["M22"], {"status", "stages"}, "manifest M22")
    exact_string(m22["status"], "passed", "manifest M22 status")
    stages = exact_list(m22["stages"], 4, "manifest M22 stages")
    for index, (stage, expected) in enumerate(
        zip(stages, policy["manual_m22"]["stages"], strict=True)
    ):
        stage = exact_keys(
            stage,
            {"stage", "journal_phase", "journal", "sigkill", "recovery", "installed_identity", "installed_version", "result"},
            f"manifest M22 stage {index}",
        )
        exact_string(stage["stage"], expected["id"], f"manifest M22 stage {index}.stage")
        exact_string(
            stage["journal_phase"], expected["journal_phase"], f"manifest M22 stage {index}.phase"
        )
        exact_string(stage["result"], expected["installed_result"], f"manifest M22 stage {index}.result")
        expected_version = (
            baseline["version"] if expected["installed_result"] == "baseline_launchable" else target["version"]
        )
        exact_string(stage["installed_version"], expected_version, f"manifest M22 stage {index}.version")
        refs = {
            field: evidence_ref(stage[field], root, f"manifest M22 {expected['id']}.{field}", seen_files)
            for field in ("journal", "sigkill", "recovery", "installed_identity")
        }
        if root is not None:
            journal = load_json(root / refs["journal"]["file"])
            journal = exact_keys(
                journal,
                {"schema_version", "token", "from_version", "version", "sha256", "install_root", "phase"},
                f"retained M22 journal {expected['id']}",
            )
            if (
                journal["schema_version"] != 1
                or not isinstance(journal["token"], str)
                or len(journal["token"]) > 96
                or re.fullmatch(r"[A-Za-z0-9-]+", journal["token"]) is None
                or journal["from_version"] != baseline["version"]
                or journal["version"] != target["version"]
                or journal["sha256"] != target["dmg_sha256"]
                or journal["install_root"] not in {"system_applications", "user_applications"}
                or journal["phase"] != expected["journal_phase"]
            ):
                raise EvidenceError(f"retained M22 journal {expected['id']} differs")
            kill = load_json(root / refs["sigkill"]["file"])
            kill = exact_keys(
                kill,
                {
                    "schema_version",
                    "stage",
                    "signal",
                    "candidate_plan_sha256",
                    "journal_sha256",
                    "journal_phase",
                    "app_version",
                    "process_role",
                    "pre_signal_state",
                    "recovery_result",
                },
                f"retained M22 SIGKILL {expected['id']}",
            )
            expected_app_version = baseline["version"] if expected["journal_phase"] != "swapped" else target["version"]
            expected_process_role = {
                "update_staging": "baseline_app",
                "update_prepared": "baseline_app",
                "update_swapped": "update_helper",
                "before_ready_finalization": "target_app",
            }[expected["id"]]
            if kill != {
                "schema_version": 1,
                "stage": expected["id"],
                "signal": "SIGKILL",
                "candidate_plan_sha256": source["candidate_plan_sha256"],
                "journal_sha256": refs["journal"]["sha256"],
                "journal_phase": expected["journal_phase"],
                "app_version": expected_app_version,
                "process_role": expected_process_role,
                "pre_signal_state": "stopped",
                "recovery_result": "pending_next_launch",
            }:
                raise EvidenceError(f"retained M22 SIGKILL {expected['id']} differs")
            recovery = exact_keys(
                load_json(root / refs["recovery"]["file"]),
                {"schema_version", "stage", "result", "journal_present"},
                f"retained M22 recovery {expected['id']}",
            )
            if recovery != {
                "schema_version": 1,
                "stage": expected["id"],
                "result": expected["installed_result"],
                "journal_present": False,
            }:
                raise EvidenceError(f"retained M22 recovery {expected['id']} differs")
            expected_candidate = baseline if expected["installed_result"] == "baseline_launchable" else target
            installed = exact_keys(
                load_json(root / refs["installed_identity"]["file"]),
                {"schema_version", "stage", "version", "bundle_id", "team_id", "app_cdhash", "codesign", "gatekeeper"},
                f"retained M22 identity {expected['id']}",
            )
            if installed != {
                "schema_version": 1,
                "stage": expected["id"],
                "version": expected_candidate["version"],
                "bundle_id": expected_candidate["bundle_id"],
                "team_id": expected_candidate["team_id"],
                "app_cdhash": expected_candidate["app_cdhash"],
                "codesign": "valid",
                "gatekeeper": "accepted",
            }:
                raise EvidenceError(f"retained M22 identity {expected['id']} differs")
    decision = exact_keys(value["decision"], {"status", "owner", "signed_at_utc"}, "manifest decision")
    exact_string(decision["status"], "passed", "manifest decision status")
    exact_string(decision["owner"], policy["identity"]["decision_owner"], "manifest decision owner")
    if not isinstance(decision["signed_at_utc"], str) or UTC_TIMESTAMP.fullmatch(
        decision["signed_at_utc"]
    ) is None:
        raise EvidenceError("manifest decision timestamp is not canonical UTC")
    return value


def validate_post_promotion(
    value: Any,
    policy: dict[str, Any],
    candidate_plan: dict[str, Any],
    candidate_plan_path: Path,
    root: Path,
) -> dict[str, Any]:
    value = exact_keys(
        value,
        {
            "schema_version",
            "contract",
            "candidate_plan_sha256",
            "stable",
            "decision",
        },
        "post-promotion observation",
    )
    if value["schema_version"] != 1:
        raise EvidenceError("post-promotion observation schema_version must be 1")
    exact_string(value["contract"], policy["contract"], "post-promotion contract")
    plan_sha = require_pattern(
        value["candidate_plan_sha256"], HEX64, "post-promotion candidate plan SHA-256"
    )
    if sha256_file(candidate_plan_path) != plan_sha:
        raise EvidenceError("post-promotion candidate plan SHA-256 differs")
    target = candidate_plan["target"]
    stable = exact_keys(
        value["stable"],
        {"status", "discovery", "authenticated_download", "result"},
        "post-promotion stable observation",
    )
    exact_string(stable["status"], "passed", "post-promotion stable status")
    exact_string(
        stable["result"],
        "exact_target_selected_and_downloaded",
        "post-promotion stable result",
    )
    seen_files: set[str] = set()
    discovery_ref = evidence_ref(
        stable["discovery"], root, "post-promotion stable discovery", seen_files
    )
    download_ref = evidence_ref(
        stable["authenticated_download"],
        root,
        "post-promotion stable authenticated download",
        seen_files,
    )
    exact_string(
        download_ref["sha256"], target["dmg_sha256"], "post-promotion stable target DMG"
    )
    discovery = exact_keys(
        load_json(root / discovery_ref["file"]),
        {
            "schema_version",
            "channel",
            "feed_url",
            "transport",
            "http_status",
            "selected_version",
            "selected_dmg_sha256",
            "selected_asset_url",
            "response_url_opened",
        },
        "retained post-promotion stable discovery",
    )
    expected_asset_url = (
        "https://github.com/IlyaGulya/wrenflow/releases/download/"
        f"v{target['version']}/Wrenflow.dmg"
    )
    if discovery != {
        "schema_version": 1,
        "channel": "stable",
        "feed_url": policy["post_promotion_stable"]["feed_url"],
        "transport": "https",
        "http_status": 200,
        "selected_version": target["version"],
        "selected_dmg_sha256": target["dmg_sha256"],
        "selected_asset_url": expected_asset_url,
        "response_url_opened": False,
    }:
        raise EvidenceError("retained post-promotion stable discovery differs")
    decision = exact_keys(
        value["decision"], {"status", "owner", "observed_at_utc"}, "post-promotion decision"
    )
    exact_string(decision["status"], "passed", "post-promotion decision status")
    exact_string(
        decision["owner"], policy["identity"]["decision_owner"], "post-promotion decision owner"
    )
    if not isinstance(decision["observed_at_utc"], str) or UTC_TIMESTAMP.fullmatch(
        decision["observed_at_utc"]
    ) is None:
        raise EvidenceError("post-promotion decision timestamp is not canonical UTC")
    return value


def fixture_test(policy: dict[str, Any]) -> None:
    automated = validate_automated(load_json(FIXTURE_DIR / "automated-pass.json"), policy, False)
    candidate = validate_candidate_pair(load_json(FIXTURE_DIR / "candidate-plan-pass.json"), policy)
    passing_manifest = load_json(FIXTURE_DIR / "manifest-pass.json")
    validate_manifest(
        passing_manifest,
        policy,
        automated,
        candidate,
        None,
        None,
        None,
    )
    with tempfile.TemporaryDirectory(prefix="wrenflow-endurance-evidence-test.") as temporary:
        root = Path(temporary)
        retained_automated = deepcopy(automated)
        all_automated_cases = [
            *policy["automated_update_fixtures"]["cases"],
            *policy["automated_update_fixtures"]["other_cases"],
        ]
        log_lines = "\n".join(f"test {case['test']} ... ok" for case in all_automated_cases) + "\n"
        log_path = root / retained_automated["automated_update_fixtures"]["log"]["file"]
        log_path.write_text(log_lines, encoding="utf-8")
        retained_log_sha = sha256_file(log_path)
        retained_automated["automated_update_fixtures"]["log"]["sha256"] = retained_log_sha
        for case in retained_automated["automated_update_fixtures"]["cases"]:
            case["log_sha256"] = retained_log_sha
        for case in retained_automated["other_automated"].values():
            case["log_sha256"] = retained_log_sha
        validate_automated(retained_automated, policy, False, root)
        missing_other = deepcopy(retained_automated)
        del missing_other["other_automated"]["interrupted_write_cleanup"]
        try:
            validate_automated(missing_other, policy, False, root)
        except EvidenceError:
            pass
        else:
            raise EvidenceError("omitted other automated evidence row unexpectedly passed")
        omitted_other_log = "\n".join(
            f"test {case['test']} ... ok" for case in all_automated_cases[:-1]
        ) + "\n"
        log_path.write_text(omitted_other_log, encoding="utf-8")
        omitted_log_sha = sha256_file(log_path)
        retained_automated["automated_update_fixtures"]["log"]["sha256"] = omitted_log_sha
        for case in retained_automated["automated_update_fixtures"]["cases"]:
            case["log_sha256"] = omitted_log_sha
        for case in retained_automated["other_automated"].values():
            case["log_sha256"] = omitted_log_sha
        try:
            validate_automated(retained_automated, policy, False, root)
        except EvidenceError:
            pass
        else:
            raise EvidenceError("omitted named other automated test unexpectedly passed")
        log_path.write_text(log_lines, encoding="utf-8")
        retained_automated["automated_update_fixtures"]["log"]["sha256"] = retained_log_sha
        for case in retained_automated["automated_update_fixtures"]["cases"]:
            case["log_sha256"] = retained_log_sha
        for case in retained_automated["other_automated"].values():
            case["log_sha256"] = retained_log_sha
        log_path.write_text("tampered\n", encoding="utf-8")
        try:
            validate_automated(retained_automated, policy, False, root)
        except EvidenceError:
            pass
        else:
            raise EvidenceError("tampered retained automated log unexpectedly passed")
        log_path.write_text(log_lines, encoding="utf-8")
        retained_manifest = deepcopy(passing_manifest)
        retained_candidate = deepcopy(candidate)
        target_bytes = b"exact signed target DMG fixture"
        target_sha = hashlib.sha256(target_bytes).hexdigest()
        retained_candidate["target"]["dmg_sha256"] = target_sha
        for record in retained_candidate["target"]["payload_files"]:
            if record["name"] == "Wrenflow.dmg":
                record["sha256"] = target_sha
        def retain(reference: dict[str, Any], payload: bytes | dict[str, Any]) -> None:
            data = payload if isinstance(payload, bytes) else (
                json.dumps(
                    payload, sort_keys=True, separators=(",", ":"), allow_nan=False
                ).encode("utf-8")
                + b"\n"
            )
            path = root / reference["file"]
            path.write_bytes(data)
            reference["sha256"] = hashlib.sha256(data).hexdigest()

        target = retained_candidate["target"]
        baseline = retained_candidate["baseline"]
        retained_manifest["M13"]["target_artifact"]["sha256"] = target_sha
        retain(retained_manifest["M13"]["target_artifact"], target_bytes)
        retain(
            retained_manifest["M13"]["target_install"],
            {
                "schema_version": 1,
                "version": target["version"],
                "bundle_id": target["bundle_id"],
                "team_id": target["team_id"],
                "app_cdhash": target["app_cdhash"],
                "notarization": "accepted",
                "gatekeeper": "accepted",
                "result": "target_launchable",
            },
        )
        retained_beta = {
            "schema_version": 1,
            "channel": "beta",
            "feed_url": policy["manual_m13_pre_promotion"]["feed_url"],
            "transport": "https",
            "http_status": 200,
            "baseline_version": baseline["version"],
            "outcome": "available",
            "selected_version": "0.5.0-beta.2",
            "selected_dmg_sha256": "7" * 64,
            "selected_asset_url": "https://github.com/IlyaGulya/wrenflow/releases/download/v0.5.0-beta.2/Wrenflow.dmg",
            "target_selected": False,
            "response_url_opened": False,
        }
        retain(retained_manifest["M13"]["beta_selector"], retained_beta)
        for stage, expected in zip(
            retained_manifest["M22"]["stages"], policy["manual_m22"]["stages"], strict=True
        ):
            retain(
                stage["journal"],
                {
                    "schema_version": 1,
                    "token": "1-2-abcdef123456",
                    "from_version": baseline["version"],
                    "version": target["version"],
                    "sha256": target_sha,
                    "install_root": "user_applications",
                    "phase": expected["journal_phase"],
                },
            )
            expected_app = baseline if expected["journal_phase"] != "swapped" else target
            process_role = {
                "update_staging": "baseline_app",
                "update_prepared": "baseline_app",
                "update_swapped": "update_helper",
                "before_ready_finalization": "target_app",
            }[expected["id"]]
            retain(
                stage["sigkill"],
                {
                    "schema_version": 1,
                    "stage": expected["id"],
                    "signal": "SIGKILL",
                    "candidate_plan_sha256": retained_manifest["source"]["candidate_plan_sha256"],
                    "journal_sha256": stage["journal"]["sha256"],
                    "journal_phase": expected["journal_phase"],
                    "app_version": expected_app["version"],
                    "process_role": process_role,
                    "pre_signal_state": "stopped",
                    "recovery_result": "pending_next_launch",
                },
            )
            retain(
                stage["recovery"],
                {
                    "schema_version": 1,
                    "stage": expected["id"],
                    "result": expected["installed_result"],
                    "journal_present": False,
                },
            )
            installed_candidate = (
                baseline if expected["installed_result"] == "baseline_launchable" else target
            )
            retain(
                stage["installed_identity"],
                {
                    "schema_version": 1,
                    "stage": expected["id"],
                    "version": installed_candidate["version"],
                    "bundle_id": installed_candidate["bundle_id"],
                    "team_id": installed_candidate["team_id"],
                    "app_cdhash": installed_candidate["app_cdhash"],
                    "codesign": "valid",
                    "gatekeeper": "accepted",
                },
            )
        validate_manifest(
            retained_manifest,
            policy,
            automated,
            retained_candidate,
            root,
            None,
            None,
        )
        public_target = {
            **retained_beta,
            "selected_version": target["version"],
            "selected_dmg_sha256": target_sha,
            "selected_asset_url": (
                "https://github.com/IlyaGulya/wrenflow/releases/download/"
                f"v{target['version']}/Wrenflow.dmg"
            ),
            "target_selected": True,
        }
        retain(retained_manifest["M13"]["beta_selector"], public_target)
        try:
            validate_manifest(
                retained_manifest,
                policy,
                automated,
                retained_candidate,
                root,
                None,
                None,
            )
        except EvidenceError:
            pass
        else:
            raise EvidenceError("pre-promotion public exact target unexpectedly passed")
        retain(retained_manifest["M13"]["beta_selector"], retained_beta)
        candidate_path = root / "candidate-plan.json"
        candidate_path.write_text(
            json.dumps(
                retained_candidate,
                sort_keys=True,
                separators=(",", ":"),
                allow_nan=False,
            )
            + "\n",
            encoding="utf-8",
        )
        post = {
            "schema_version": 1,
            "contract": policy["contract"],
            "candidate_plan_sha256": sha256_file(candidate_path),
            "stable": {
                "status": "passed",
                "discovery": {"file": "post-stable-discovery.json", "sha256": "0" * 64},
                "authenticated_download": {
                    "file": "post-stable-Wrenflow.dmg",
                    "sha256": target_sha,
                },
                "result": "exact_target_selected_and_downloaded",
            },
            "decision": {
                "status": "passed",
                "owner": policy["identity"]["decision_owner"],
                "observed_at_utc": "2026-08-11T12:00:00Z",
            },
        }
        retain(
            post["stable"]["discovery"],
            {
                "schema_version": 1,
                "channel": "stable",
                "feed_url": policy["post_promotion_stable"]["feed_url"],
                "transport": "https",
                "http_status": 200,
                "selected_version": target["version"],
                "selected_dmg_sha256": target_sha,
                "selected_asset_url": f"https://github.com/IlyaGulya/wrenflow/releases/download/v{target['version']}/Wrenflow.dmg",
                "response_url_opened": False,
            },
        )
        retain(post["stable"]["authenticated_download"], target_bytes)
        validate_post_promotion(post, policy, retained_candidate, candidate_path, root)
        post["stable"]["discovery"]["sha256"] = "0" * 64
        try:
            validate_post_promotion(post, policy, retained_candidate, candidate_path, root)
        except EvidenceError:
            pass
        else:
            raise EvidenceError("tampered post-promotion observation unexpectedly passed")
    negative = sorted(FIXTURE_DIR.glob("negative-*.json"))
    if len(negative) < 4:
        raise EvidenceError("at least four checked-in negative manifests are required")
    for path in negative:
        descriptor = exact_keys(load_json(path), {"id", "operation", "path", "value"}, path.name)
        if not isinstance(descriptor["id"], str) or not descriptor["id"]:
            raise EvidenceError(f"negative fixture has no id: {path.name}")
        if descriptor["operation"] not in {"set", "delete"}:
            raise EvidenceError(f"negative fixture operation differs: {path.name}")
        segments = descriptor["path"]
        if not isinstance(segments, list) or not segments:
            raise EvidenceError(f"negative fixture path differs: {path.name}")
        mutated = deepcopy(load_json(FIXTURE_DIR / "manifest-pass.json"))
        parent: Any = mutated
        for segment in segments[:-1]:
            if isinstance(parent, list) and isinstance(segment, int):
                parent = parent[segment]
            elif isinstance(parent, dict) and isinstance(segment, str) and segment in parent:
                parent = parent[segment]
            else:
                raise EvidenceError(f"negative fixture path is not exact: {path.name}")
        leaf = segments[-1]
        if descriptor["operation"] == "set":
            if isinstance(parent, list) and isinstance(leaf, int) and 0 <= leaf < len(parent):
                parent[leaf] = descriptor["value"]
            elif isinstance(parent, dict) and isinstance(leaf, str):
                parent[leaf] = descriptor["value"]
            else:
                raise EvidenceError(f"negative fixture set path differs: {path.name}")
        elif isinstance(parent, list) and isinstance(leaf, int) and 0 <= leaf < len(parent):
            del parent[leaf]
        elif isinstance(parent, dict) and isinstance(leaf, str) and leaf in parent:
            del parent[leaf]
        else:
            raise EvidenceError(f"negative fixture delete path differs: {path.name}")
        try:
            validate_manifest(mutated, policy, automated, candidate, None, None, None)
        except EvidenceError:
            continue
        raise EvidenceError(f"negative fixture unexpectedly passed: {path.name}")
    prerelease_target = deepcopy(candidate)
    prerelease_target["target"]["version"] = "0.4.0-rc.1"
    prerelease_target["target"]["tag"] = "v0.4.0-rc.1"
    try:
        validate_candidate_pair(prerelease_target, policy)
    except EvidenceError:
        pass
    else:
        raise EvidenceError("prerelease stable target unexpectedly passed")
    with tempfile.TemporaryDirectory(prefix="wrenflow-endurance-json-test.") as temporary:
        duplicate = Path(temporary) / "duplicate.json"
        duplicate.write_text('{"schema_version":1,"schema_version":1}\n', encoding="utf-8")
        try:
            load_json(duplicate)
        except EvidenceError:
            pass
        else:
            raise EvidenceError("duplicate JSON object key unexpectedly passed")
        nonfinite = Path(temporary) / "nonfinite.json"
        nonfinite.write_text('{"value":NaN}\n', encoding="utf-8")
        try:
            load_json(nonfinite)
        except EvidenceError:
            pass
        else:
            raise EvidenceError("non-finite JSON number unexpectedly passed")
        overflow = Path(temporary) / "overflow.json"
        overflow.write_text('{"value":1e400}\n', encoding="utf-8")
        try:
            load_json(overflow)
        except EvidenceError:
            pass
        else:
            raise EvidenceError("exponent-overflow JSON number unexpectedly passed")


def main(arguments: list[str]) -> int:
    policy = validate_policy(load_json(POLICY_PATH))
    if arguments == ["source"]:
        print("GPUI endurance evidence policy source passed")
        return 0
    if arguments == ["test-fixtures"]:
        fixture_test(policy)
        print("GPUI endurance evidence positive and negative fixtures passed")
        return 0
    if len(arguments) == 2 and arguments[0] == "validate-plan":
        path = Path(arguments[1])
        if not path.is_absolute() or path.is_symlink() or not path.is_file():
            raise EvidenceError("candidate plan must be an absolute regular file")
        validate_candidate_pair(load_json(path), policy)
        print("Exact signed GPUI baseline/target plan passed")
        return 0
    if len(arguments) == 4 and arguments[0] == "verify":
        raw_paths = [Path(value) for value in arguments[1:]]
        for path in raw_paths:
            if not path.is_absolute() or path.is_symlink() or not path.is_file():
                raise EvidenceError(f"verification input must be an absolute regular file: {path}")
        automated_path, candidate_path, manifest_path = [path.resolve() for path in raw_paths]
        automated = validate_automated(
            load_json(automated_path), policy, True, automated_path.parent
        )
        candidate = validate_candidate_pair(load_json(candidate_path), policy)
        manifest = load_json(manifest_path)
        root = manifest_path.parent
        validate_manifest(
            manifest,
            policy,
            automated,
            candidate,
            root,
            automated_path,
            candidate_path,
        )
        print("Exact-source GPUI M13/M22 evidence passed")
        return 0
    if len(arguments) == 3 and arguments[0] == "verify-post-promotion":
        candidate_path = Path(arguments[1])
        observation_path = Path(arguments[2])
        for path in (candidate_path, observation_path):
            if not path.is_absolute() or path.is_symlink() or not path.is_file():
                raise EvidenceError(f"verification input must be an absolute regular file: {path}")
        candidate_path = candidate_path.resolve()
        observation_path = observation_path.resolve()
        candidate = validate_candidate_pair(load_json(candidate_path), policy)
        validate_post_promotion(
            load_json(observation_path),
            policy,
            candidate,
            candidate_path,
            observation_path.parent,
        )
        print("Exact-target post-promotion stable observation passed")
        return 0
    raise EvidenceError(
        "usage: gpui-endurance-evidence.py source | test-fixtures | "
        "validate-plan <candidate-plan.json> | "
        "verify <automated.json> <candidate-plan.json> <manifest.json> | "
        "verify-post-promotion <candidate-plan.json> <observation.json>"
    )


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (EvidenceError, subprocess.CalledProcessError) as error:
        print(f"GPUI endurance evidence rejected: {error}", file=sys.stderr)
        raise SystemExit(65) from error
