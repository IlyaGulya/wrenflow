#!/usr/bin/env python3
"""Create and verify fail-closed first-release owner smoke manifests.

This tool only reads candidate/evidence files and writes a new manifest when
`init` is requested. It never launches Wrenflow or changes TCC, macOS settings,
accounts, login items, displays, or evidence files.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import stat
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, NoReturn


REPO_DIR = Path(__file__).resolve().parents[1]
POLICY_PATH = REPO_DIR / "support/acceptance/macos-human-v1-policy.json"
SCHEMA_PATH = REPO_DIR / "support/acceptance/macos-human-v1.schema.json"
SCHEMA_ID = "wrenflow-first-release-owner-smoke-v1"
SCHEMA_CANONICAL_SHA256 = "31b45a03b4c006af512dee172e530da6cd2ca7e7928b1427179b36a6863ac857"
TEAM_ID = "T4LV8K9BGV"
BUNDLE_ID = "me.gulya.wrenflow"
PUBLISHED_PAYLOAD = [
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
CHECKSUM_PAYLOAD = PUBLISHED_PAYLOAD[:-1]
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
SOURCE_RE = re.compile(r"^[0-9a-f]{40}$")
SEMVER_CORE = r"(?:0|[1-9][0-9]*)"
SEMVER_IDENTIFIER = r"(?:0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)"
VERSION_RE = re.compile(
    rf"^{SEMVER_CORE}\.{SEMVER_CORE}\.{SEMVER_CORE}"
    rf"(?:-{SEMVER_IDENTIFIER}(?:\.{SEMVER_IDENTIFIER})*)?$"
)
TAG_RE = re.compile(rf"^v{VERSION_RE.pattern[1:-1]}$")
UUID_RE = re.compile(
    r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
)
RESOLUTION_RE = re.compile(r"^[0-9]+x[0-9]+$")
PLACEHOLDERS = {"anonymous", "n/a", "none", "tbd", "todo", "unknown"}
EVIDENCE_KINDS = {
    "accessibility-summary",
    "artifact-verification",
    "automated-gate",
    "display-metadata",
    "permission-status",
    "result-sheet",
    "screen-recording",
    "screenshots",
}


class ValidationError(Exception):
    pass


def fail(message: str) -> NoReturn:
    raise ValidationError(message)


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def parse_finite_float(value: str, label: str) -> float:
    parsed = float(value)
    if not math.isfinite(parsed):
        fail(f"{label} contains non-finite JSON number {value}")
    return parsed


def read_json(path: Path, label: str) -> Any:
    if not path.is_absolute() or not path.is_file() or path.is_symlink():
        fail(f"{label} must be an absolute regular non-symlink file: {path}")
    try:
        return json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=lambda value: fail(
                f"{label} contains non-finite JSON number {value}"
            ),
            parse_float=lambda value: parse_finite_float(value, label),
        )
    except (OSError, json.JSONDecodeError) as error:
        fail(f"could not read {label}: {error}")


def expect_object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{label} must be an object")
    return value


def expect_list(value: Any, label: str) -> list[Any]:
    if not isinstance(value, list):
        fail(f"{label} must be an array")
    return value


def exact_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    actual = set(value)
    missing = sorted(expected - actual)
    unknown = sorted(actual - expected)
    if missing or unknown:
        fail(f"{label} has missing keys {missing} and unknown keys {unknown}")


def non_placeholder(value: Any, label: str) -> str:
    if not isinstance(value, str) or len(value.strip()) < 2:
        fail(f"{label} must be a non-empty string")
    value = value.strip()
    if value.lower() in PLACEHOLDERS:
        fail(f"{label} cannot be a placeholder")
    return value


def valid_datetime(value: Any, label: str) -> str:
    if not isinstance(value, str):
        fail(f"{label} must be an ISO-8601 timestamp")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        fail(f"{label} is not ISO-8601: {error}")
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        fail(f"{label} must include a timezone")
    return value


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        fail(f"could not hash {path}: {error}")
    return digest.hexdigest()


def require_root(path: Path, label: str) -> Path:
    if not path.is_absolute() or not path.is_dir() or path.is_symlink():
        fail(f"{label} must be an absolute existing non-symlink directory: {path}")
    return path.resolve(strict=True)


def contained_file(root: Path, relative: Any, label: str) -> Path:
    if not isinstance(relative, str) or not relative or relative.startswith("/"):
        fail(f"{label} must use a non-empty relative path")
    relative_path = Path(relative)
    if any(part in {"", ".", ".."} for part in relative_path.parts):
        fail(f"{label} contains an unsafe path component")
    current = root
    for part in relative_path.parts:
        current = current / part
        if current.is_symlink():
            fail(f"{label} must not traverse a symlink: {relative}")
    if not current.is_file():
        fail(f"{label} is not a regular file under the evidence root: {relative}")
    try:
        current.resolve(strict=True).relative_to(root)
    except ValueError:
        fail(f"{label} escapes its root: {relative}")
    try:
        if current.stat().st_size == 0:
            fail(f"{label} must not be empty: {relative}")
    except OSError as error:
        fail(f"could not inspect {label}: {error}")
    return current


def configured_schema_path() -> Path:
    override = os.environ.get("WRENFLOW_HUMAN_ACCEPTANCE_SCHEMA_PATH")
    if override is None:
        return SCHEMA_PATH
    path = Path(override)
    if not path.is_absolute():
        fail("WRENFLOW_HUMAN_ACCEPTANCE_SCHEMA_PATH must be absolute")
    return path


def validate_schema_contract() -> None:
    schema = expect_object(
        read_json(configured_schema_path(), "manifest schema"),
        "schema",
    )
    canonical = json.dumps(
        schema,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8")
    if hashlib.sha256(canonical).hexdigest() != SCHEMA_CANONICAL_SHA256:
        fail("JSON schema drifted from the verifier's exact v1 contract")


def load_policy() -> dict[str, Any]:
    policy = expect_object(read_json(POLICY_PATH.resolve(), "acceptance policy"), "policy")
    exact_keys(
        policy,
        {
            "schema_version",
            "schema_id",
            "candidate_identity",
            "candidate_artifacts",
            "execution_constraints",
            "rows",
        },
        "policy",
    )
    if policy["schema_version"] != 1 or policy["schema_id"] != SCHEMA_ID:
        fail("policy schema version/id is unsupported")
    identity = expect_object(policy["candidate_identity"], "policy.candidate_identity")
    if identity != {"bundle_id": BUNDLE_ID, "team_id": TEAM_ID}:
        fail("policy production identity drifted")
    if policy["candidate_artifacts"] != PUBLISHED_PAYLOAD:
        fail("policy candidate artifacts drifted from the exact published payload")
    if policy["execution_constraints"] != {
        "owner": "Ilya Gulya",
        "mode": "single_owner_first_public_release",
        "tcc_mutation": "prohibited",
        "existing_permission_grants": "inspect_without_reset",
        "fresh_permission_paths": "automated_state_tests",
        "data_isolation": "exact_owner_smoke_disposable_root",
    }:
        fail("policy execution constraints drifted")
    validate_schema_contract()
    rows = expect_object(policy["rows"], "policy.rows")
    expected_rows = ["S01", "S02"]
    if list(rows) != expected_rows:
        fail("policy rows must be ordered exactly S01,S02")
    for row_id, row_value in rows.items():
        row = expect_object(row_value, f"policy.rows.{row_id}")
        exact_keys(
            row,
            {"issue", "title", "automation", "required_evidence_groups"},
            f"policy.rows.{row_id}",
        )
        if row["automation"] not in {"supporting_required", "supporting_optional"}:
            fail(f"policy.rows.{row_id}.automation is invalid")
        groups = expect_list(row["required_evidence_groups"], f"policy.rows.{row_id}.groups")
        if not groups:
            fail(f"policy row {row_id} has no retained evidence requirements")
        for group in groups:
            alternatives = expect_list(group, f"policy.rows.{row_id}.evidence_group")
            if not alternatives or any(kind not in EVIDENCE_KINDS for kind in alternatives):
                fail(f"policy row {row_id} has an invalid evidence group")
    return policy


def parse_checksums(candidate_root: Path) -> dict[str, str]:
    checksum_path = contained_file(candidate_root, "SHA256SUMS", "candidate checksums")
    result: dict[str, str] = {}
    for index, line in enumerate(checksum_path.read_text(encoding="utf-8").splitlines(), start=1):
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9._-]+)", line)
        if match is None:
            fail(f"SHA256SUMS line {index} is outside the closed format")
        digest, name = match.groups()
        if name in result:
            fail(f"SHA256SUMS repeats {name}")
        result[name] = digest
    missing = sorted(set(CHECKSUM_PAYLOAD) - set(result))
    unknown = sorted(set(result) - set(CHECKSUM_PAYLOAD))
    if missing or unknown:
        fail(f"SHA256SUMS has missing entries {missing} and unknown entries {unknown}")
    return result


def validate_release_evidence(candidate_root: Path, checksums: dict[str, str]) -> dict[str, Any]:
    evidence = expect_object(
        read_json(candidate_root / "release-evidence.json", "release evidence"),
        "release evidence",
    )
    exact_keys(
        evidence,
        {"schema_version", "source", "workflow", "release", "notarization", "identity", "artifact"},
        "release evidence",
    )
    if evidence["schema_version"] != 1:
        fail("release evidence schema version is unsupported")
    source = expect_object(evidence["source"], "release evidence source")
    workflow = expect_object(evidence["workflow"], "release evidence workflow")
    release = expect_object(evidence["release"], "release evidence release")
    notarization = expect_object(evidence["notarization"], "release evidence notarization")
    identity = expect_object(evidence["identity"], "release evidence identity")
    artifact = expect_object(evidence["artifact"], "release evidence artifact")
    exact_keys(source, {"repository", "commit"}, "release evidence source")
    exact_keys(workflow, {"run_id", "attempt", "url"}, "release evidence workflow")
    exact_keys(release, {"tag", "version", "build_number"}, "release evidence release")
    exact_keys(notarization, {"submission_id", "status"}, "release evidence notarization")
    exact_keys(identity, {"bundle_id", "team_id"}, "release evidence identity")
    exact_keys(artifact, {"name", "sha256"}, "release evidence artifact")

    tag = release["tag"]
    version = release["version"]
    build_number = release["build_number"]
    source_commit = source["commit"]
    dmg_sha = artifact["sha256"]
    workflow_url = workflow["url"]
    submission_id = notarization["submission_id"]
    run_id = workflow["run_id"]
    attempt = workflow["attempt"]
    if source["repository"] != "IlyaGulya/wrenflow" or not SOURCE_RE.fullmatch(str(source_commit)):
        fail("release evidence source identity is invalid")
    if not TAG_RE.fullmatch(str(tag)) or not VERSION_RE.fullmatch(str(version)) or tag != f"v{version}":
        fail("release tag/version is invalid")
    if not isinstance(build_number, str) or not build_number.isdigit():
        fail("release build number is invalid")
    if identity != {"bundle_id": BUNDLE_ID, "team_id": TEAM_ID}:
        fail("release evidence production identity is invalid")
    if notarization["status"] != "Accepted" or not UUID_RE.fullmatch(str(submission_id)):
        fail("release evidence does not contain an Accepted Apple notarization")
    if artifact["name"] != "Wrenflow.dmg" or not SHA256_RE.fullmatch(str(dmg_sha)):
        fail("release evidence DMG identity is invalid")
    if checksums["Wrenflow.dmg"] != dmg_sha:
        fail("release evidence DMG digest does not match SHA256SUMS")
    if (
        not isinstance(run_id, str)
        or not run_id.isdigit()
        or not isinstance(attempt, str)
        or not attempt.isdigit()
    ):
        fail("release evidence workflow run/attempt is invalid")
    expected_workflow_url = (
        f"https://github.com/IlyaGulya/wrenflow/actions/runs/{run_id}/attempts/{attempt}"
    )
    if workflow_url != expected_workflow_url:
        fail("release workflow URL does not match its run and attempt")
    return evidence


def validate_artifact_provenance(
    candidate_root: Path,
    checksums: dict[str, str],
    evidence: dict[str, Any],
) -> None:
    provenance = expect_object(
        read_json(candidate_root / "artifact-provenance.json", "artifact provenance"),
        "artifact provenance",
    )
    exact_keys(provenance, {"_type", "subject", "predicateType", "predicate"}, "artifact provenance")
    if provenance["_type"] != "https://in-toto.io/Statement/v1":
        fail("artifact provenance statement type is invalid")
    if provenance["predicateType"] != "https://slsa.dev/provenance/v1":
        fail("artifact provenance predicate type is invalid")

    subjects = expect_list(provenance["subject"], "artifact provenance subjects")
    expected_subject_names = [
        "Wrenflow.app/Contents/MacOS/wrenflow",
        "Wrenflow.app/Contents/Frameworks/libWrenflowShell.dylib",
        "Wrenflow.app/Contents/MacOS/libonnxruntime.dylib",
        "Wrenflow.dmg",
    ]
    if len(subjects) != len(expected_subject_names):
        fail("artifact provenance subjects do not match the release metadata contract")
    subject_digests: dict[str, str] = {}
    for index, subject_value in enumerate(subjects):
        subject = expect_object(subject_value, f"artifact provenance subjects[{index}]")
        exact_keys(subject, {"name", "digest"}, f"artifact provenance subjects[{index}]")
        digest = expect_object(subject["digest"], f"artifact provenance subjects[{index}].digest")
        exact_keys(digest, {"sha256"}, f"artifact provenance subjects[{index}].digest")
        name = subject["name"]
        value = digest["sha256"]
        if not isinstance(name, str) or name in subject_digests:
            fail("artifact provenance contains an invalid or duplicate subject")
        if not isinstance(value, str) or not SHA256_RE.fullmatch(value):
            fail(f"artifact provenance subject {name} has an invalid digest")
        subject_digests[name] = value
    if list(subject_digests) != expected_subject_names:
        fail("artifact provenance subjects do not match the release metadata contract")
    if subject_digests["Wrenflow.dmg"] != checksums["Wrenflow.dmg"]:
        fail("artifact provenance DMG subject does not match the candidate payload")

    predicate = expect_object(provenance["predicate"], "artifact provenance predicate")
    exact_keys(
        predicate,
        {"predicateType", "buildDefinition", "runDetails"},
        "artifact provenance predicate",
    )
    if predicate["predicateType"] != provenance["predicateType"]:
        fail("artifact provenance nested predicate type is invalid")
    build = expect_object(predicate["buildDefinition"], "artifact provenance build definition")
    exact_keys(
        build,
        {"buildType", "externalParameters", "internalParameters", "resolvedDependencies"},
        "artifact provenance build definition",
    )
    if build["buildType"] != "https://github.com/ilyagulya/wrenflow/build-types/macos-gpui-v1":
        fail("artifact provenance build type is invalid")
    if build["externalParameters"] != {"target": "aarch64-apple-darwin", "locked": True}:
        fail("artifact provenance external parameters are invalid")
    internal = expect_object(build["internalParameters"], "artifact provenance internal parameters")
    exact_keys(internal, {"sourceDateEpoch"}, "artifact provenance internal parameters")
    if (
        not isinstance(internal["sourceDateEpoch"], int)
        or isinstance(internal["sourceDateEpoch"], bool)
        or internal["sourceDateEpoch"] < 0
    ):
        fail("artifact provenance source date epoch is invalid")

    dependencies = expect_list(build["resolvedDependencies"], "artifact provenance dependencies")
    expected_dependency_uris = [
        "git+https://github.com/ilyagulya/wrenflow",
        "file:Cargo.lock",
        "file:native/wrenflow-gpui/Cargo.lock",
        "file:supply-chain/pins.json",
    ]
    dependency_digests: dict[str, tuple[str, str]] = {}
    for index, dependency_value in enumerate(dependencies):
        dependency = expect_object(dependency_value, f"artifact provenance dependencies[{index}]")
        exact_keys(dependency, {"uri", "digest"}, f"artifact provenance dependencies[{index}]")
        uri = dependency["uri"]
        digest = expect_object(dependency["digest"], f"artifact provenance dependencies[{index}].digest")
        if not isinstance(uri, str) or uri in dependency_digests or len(digest) != 1:
            fail("artifact provenance contains an invalid or duplicate dependency")
        algorithm, value = next(iter(digest.items()))
        if algorithm not in {"gitCommit", "sha256"} or not isinstance(value, str):
            fail(f"artifact provenance dependency {uri} has an invalid digest")
        dependency_digests[uri] = (algorithm, value)
    if list(dependency_digests) != expected_dependency_uris:
        fail("artifact provenance dependencies do not match the release metadata contract")
    source_commit = evidence["source"]["commit"]
    if dependency_digests[expected_dependency_uris[0]] != ("gitCommit", source_commit):
        fail("artifact provenance source dependency does not match release evidence")
    for uri in expected_dependency_uris[1:3]:
        algorithm, digest = dependency_digests[uri]
        if algorithm != "sha256" or not SHA256_RE.fullmatch(digest):
            fail(f"artifact provenance dependency {uri} has an invalid digest")
    if dependency_digests[expected_dependency_uris[3]] != ("sha256", checksums["pins.json"]):
        fail("artifact provenance pins dependency does not match the candidate payload")

    run_details = expect_object(predicate["runDetails"], "artifact provenance run details")
    exact_keys(run_details, {"builder", "metadata"}, "artifact provenance run details")
    if run_details["builder"] != {"id": "mise://wrenflow/release"}:
        fail("artifact provenance builder is invalid")
    metadata = expect_object(run_details["metadata"], "artifact provenance run metadata")
    exact_keys(
        metadata,
        {"invocationId", "workflowRun", "notarySubmissionId"},
        "artifact provenance run metadata",
    )
    if metadata["invocationId"] != source_commit:
        fail("artifact provenance invocation does not match release evidence source")
    if metadata["workflowRun"] != evidence["workflow"]["url"]:
        fail("artifact provenance workflow does not match release evidence")
    if metadata["notarySubmissionId"] != evidence["notarization"]["submission_id"]:
        fail("artifact provenance notarization does not match release evidence")

    source_provenance = expect_object(
        read_json(candidate_root / "provenance.json", "source provenance"),
        "source provenance",
    )
    exact_keys(
        source_provenance,
        {"predicateType", "buildDefinition", "runDetails"},
        "source provenance",
    )
    if source_provenance["predicateType"] != provenance["predicateType"]:
        fail("artifact provenance predicate type does not match source provenance")
    if source_provenance["buildDefinition"] != build:
        fail("artifact provenance build definition does not match source provenance")
    source_run = expect_object(source_provenance["runDetails"], "source provenance run details")
    exact_keys(source_run, {"builder", "metadata"}, "source provenance run details")
    source_metadata = expect_object(source_run["metadata"], "source provenance run metadata")
    exact_keys(source_metadata, {"invocationId"}, "source provenance run metadata")
    if source_run["builder"] != run_details["builder"]:
        fail("artifact provenance builder does not match source provenance")
    if source_metadata["invocationId"] != source_commit:
        fail("source provenance invocation does not match release evidence source")


def validate_release_metadata(
    metadata_path: Path,
    *,
    tag: str,
    source_commit: str,
    payload_digests: dict[str, str],
    payload_sizes: dict[str, int],
) -> dict[str, Any]:
    try:
        metadata = metadata_path.lstat()
    except OSError as error:
        fail(f"could not inspect authenticated release metadata: {error}")
    if stat.S_IMODE(metadata.st_mode) != 0o600:
        fail("authenticated release metadata must have exact mode 0600")
    release = expect_object(read_json(metadata_path, "authenticated release metadata"), "release metadata")
    exact_keys(
        release,
        {"id", "tagName", "targetCommitish", "isDraft", "isPrerelease", "htmlUrl", "assets"},
        "release metadata",
    )
    release_id = release["id"]
    if not isinstance(release_id, int) or isinstance(release_id, bool) or release_id <= 0:
        fail("release metadata id must be a positive integer")
    if release["tagName"] != tag or release["targetCommitish"] != source_commit:
        fail("release metadata tag/source does not match the candidate payload")
    if release["isPrerelease"] is not False or not isinstance(release["isDraft"], bool):
        fail("release metadata draft/prerelease state is invalid")

    if release["isDraft"]:
        html_match = re.fullmatch(
            r"https://github\.com/IlyaGulya/wrenflow/releases/tag/(untagged-[0-9a-f]{20})",
            str(release["htmlUrl"]),
        )
        if html_match is None:
            fail("private release browser URL is not one exact authenticated tagless object")
        browser_segment = html_match.group(1)
        state = "private_draft"
    else:
        if release["htmlUrl"] != f"https://github.com/IlyaGulya/wrenflow/releases/tag/{tag}":
            fail("public release browser URL is not canonical")
        browser_segment = tag
        state = "public"

    assets = expect_list(release["assets"], "release metadata assets")
    if len(assets) != len(PUBLISHED_PAYLOAD):
        fail("release metadata must contain exactly nine assets")
    normalized: dict[str, dict[str, Any]] = {}
    asset_ids: set[int] = set()
    for index, asset_value in enumerate(assets):
        asset = expect_object(asset_value, f"release metadata assets[{index}]")
        exact_keys(
            asset,
            {
                "id", "name", "size", "digest", "state", "contentType",
                "createdAt", "updatedAt", "url", "browserDownloadUrl",
            },
            f"release metadata assets[{index}]",
        )
        asset_id = asset["id"]
        name = asset["name"]
        if (
            not isinstance(asset_id, int)
            or isinstance(asset_id, bool)
            or asset_id <= 0
            or asset_id in asset_ids
            or not isinstance(name, str)
            or name in normalized
        ):
            fail("release metadata has an invalid or duplicate asset identity")
        if name not in PUBLISHED_PAYLOAD or asset["state"] != "uploaded":
            fail("release metadata contains an unapproved or incomplete asset")
        if not isinstance(asset["size"], int) or isinstance(asset["size"], bool) or asset["size"] <= 0:
            fail("release metadata asset size is invalid")
        if asset["size"] != payload_sizes[name]:
            fail(f"release metadata asset size differs from the exact payload: {name}")
        expected_api_url = f"https://api.github.com/repos/IlyaGulya/wrenflow/releases/assets/{asset_id}"
        if asset["url"] != expected_api_url:
            fail("release metadata asset API URL does not match its immutable id")
        if not all(isinstance(asset[field], str) and asset[field] for field in ("contentType", "createdAt", "updatedAt")):
            fail("release metadata asset timestamps/content type are invalid")
        if not isinstance(asset["digest"], str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", asset["digest"]):
            fail("release metadata asset digest is invalid")
        if asset["digest"] != f"sha256:{payload_digests[name]}":
            fail(f"release metadata asset digest differs from the exact payload: {name}")
        expected_browser_url = (
            "https://github.com/IlyaGulya/wrenflow/releases/download/"
            f"{browser_segment}/{name}"
        )
        if asset["browserDownloadUrl"] != expected_browser_url:
            fail(f"release metadata asset browser URL is not canonical: {name}")
        asset_ids.add(asset_id)
        normalized[name] = asset
    if sorted(normalized) != sorted(PUBLISHED_PAYLOAD):
        fail("release metadata asset names differ from the exact payload")

    dmg = normalized["Wrenflow.dmg"]
    return {
        "state": state,
        "release_id": release_id,
        "dmg_asset_id": dmg["id"],
        "artifact_url": dmg["browserDownloadUrl"],
        "asset_ids": {name: normalized[name]["id"] for name in sorted(normalized)},
    }


def candidate_with_distribution(
    candidate_root: Path,
    release_metadata: Path,
) -> tuple[dict[str, Any], dict[str, Any]]:
    policy = load_policy()
    required = expect_list(policy["candidate_artifacts"], "policy.candidate_artifacts")
    try:
        actual_names = {entry.name for entry in candidate_root.iterdir()}
    except OSError as error:
        fail(f"could not enumerate candidate payload: {error}")
    missing_files = sorted(set(required) - actual_names)
    extra_files = sorted(actual_names - set(required))
    if missing_files or extra_files:
        fail(
            f"candidate payload has missing files {missing_files} and extra files {extra_files}"
        )
    checksums = parse_checksums(candidate_root)
    artifact_records: list[dict[str, str]] = []
    for name in required:
        path = contained_file(candidate_root, name, f"candidate artifact {name}")
        digest = sha256(path)
        if name != "SHA256SUMS" and checksums.get(name) != digest:
            fail(f"candidate artifact {name} does not match SHA256SUMS")
        artifact_records.append({"name": name, "sha256": digest})

    evidence = validate_release_evidence(candidate_root, checksums)
    validate_artifact_provenance(candidate_root, checksums, evidence)
    source = evidence["source"]
    workflow = evidence["workflow"]
    release = evidence["release"]
    notarization = evidence["notarization"]
    artifact = evidence["artifact"]
    tag = release["tag"]
    version = release["version"]
    build_number = release["build_number"]
    source_commit = source["commit"]
    dmg_sha = artifact["sha256"]
    workflow_url = workflow["url"]
    submission_id = notarization["submission_id"]

    distribution = validate_release_metadata(
        release_metadata,
        tag=tag,
        source_commit=source_commit,
        payload_digests={record["name"]: record["sha256"] for record in artifact_records},
        payload_sizes={name: (candidate_root / name).stat().st_size for name in PUBLISHED_PAYLOAD},
    )

    candidate = {
        "tag": tag,
        "version": version,
        "build_number": build_number,
        "source_commit": source_commit,
        "dmg_sha256": dmg_sha,
        "team_id": TEAM_ID,
        "bundle_id": BUNDLE_ID,
        "artifact_url": distribution["artifact_url"],
        "distribution": {
            "state": distribution["state"],
            "release_id": distribution["release_id"],
            "dmg_asset_id": distribution["dmg_asset_id"],
        },
        "workflow_url": workflow_url,
        "apple_submission_id": submission_id,
        "artifacts": artifact_records,
    }
    return candidate, distribution


def candidate_from_payload(candidate_root: Path, release_metadata: Path) -> dict[str, Any]:
    candidate, _ = candidate_with_distribution(candidate_root, release_metadata)
    return candidate


def verify_candidate_payload(args: argparse.Namespace) -> None:
    candidate_root = require_root(args.candidate_dir, "candidate directory")
    candidate = candidate_from_payload(candidate_root, args.release_metadata)
    print(json.dumps(candidate, sort_keys=True, separators=(",", ":"), allow_nan=False))


def validate_context(value: Any, label: str = "execution context") -> dict[str, Any]:
    context = expect_object(value, label)
    exact_keys(context, {"tester", "machine", "macos", "displays"}, label)

    tester = expect_object(context["tester"], f"{label}.tester")
    exact_keys(tester, {"name", "role"}, f"{label}.tester")
    if tester != {"name": "Ilya Gulya", "role": "release owner"}:
        fail(f"{label}.tester must be the exact release owner")

    machine = expect_object(context["machine"], f"{label}.machine")
    exact_keys(machine, {"model", "chip", "memory_gib"}, f"{label}.machine")
    non_placeholder(machine["model"], f"{label}.machine.model")
    non_placeholder(machine["chip"], f"{label}.machine.chip")
    if not isinstance(machine["memory_gib"], int) or isinstance(machine["memory_gib"], bool) or machine["memory_gib"] < 1:
        fail(f"{label}.machine.memory_gib must be a positive integer")

    macos = expect_object(context["macos"], f"{label}.macos")
    exact_keys(macos, {"version", "build"}, f"{label}.macos")
    non_placeholder(macos["version"], f"{label}.macos.version")
    non_placeholder(macos["build"], f"{label}.macos.build")

    displays = expect_list(context["displays"], f"{label}.displays")
    if not displays:
        fail(f"{label}.displays must name at least one display")
    for index, display_value in enumerate(displays):
        display = expect_object(display_value, f"{label}.displays[{index}]")
        exact_keys(
            display,
            {"name", "pixel_resolution", "logical_resolution", "scale"},
            f"{label}.displays[{index}]",
        )
        non_placeholder(display["name"], f"{label}.displays[{index}].name")
        for field in ["pixel_resolution", "logical_resolution"]:
            if not isinstance(display[field], str) or not RESOLUTION_RE.fullmatch(display[field]):
                fail(f"{label}.displays[{index}].{field} must be WIDTHxHEIGHT")
        if not isinstance(display["scale"], (int, float)) or isinstance(display["scale"], bool) or display["scale"] <= 0:
            fail(f"{label}.displays[{index}].scale must be positive")
    return context


def candidate_binding(candidate: dict[str, Any]) -> dict[str, str]:
    return {
        "tag": candidate["tag"],
        "source_commit": candidate["source_commit"],
        "dmg_sha256": candidate["dmg_sha256"],
        "team_id": candidate["team_id"],
        "bundle_id": candidate["bundle_id"],
        "release_id": candidate["distribution"]["release_id"],
        "dmg_asset_id": candidate["distribution"]["dmg_asset_id"],
    }


def init_manifest(args: argparse.Namespace) -> None:
    candidate_root = require_root(args.candidate_dir, "candidate directory")
    require_root(args.evidence_root, "evidence root")
    policy = load_policy()
    context = validate_context(read_json(args.context, "execution context"))
    candidate = candidate_from_payload(candidate_root, args.release_metadata)
    binding = candidate_binding(candidate)
    rows = []
    for row_id, row_policy_value in policy["rows"].items():
        row_policy = expect_object(row_policy_value, f"policy row {row_id}")
        rows.append(
            {
                "id": row_id,
                "issue": row_policy["issue"],
                "title": row_policy["title"],
                "candidate_binding": dict(binding),
                "classification": {
                    "acceptance": "owner_operated_required",
                    "automation": row_policy["automation"],
                },
                "result": "pending",
                "tester": context["tester"],
                "executed_at": None,
                "machine": context["machine"],
                "macos": context["macos"],
                "displays": context["displays"],
                "evidence": [],
                "automated_evidence": [],
                "notes": "",
            }
        )
    manifest = {
        "schema_version": 1,
        "schema_id": SCHEMA_ID,
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
        "candidate": candidate,
        "rows": rows,
    }
    write_new_json(args.output, manifest, "manifest")
    print(f"Created pending {SCHEMA_ID} manifest at {args.output}")


def write_new_json(output: Path, value: dict[str, Any], label: str) -> None:
    if not output.is_absolute() or output.exists() or output.is_symlink():
        fail(f"{label} output must be a new absolute non-symlink path")
    if not output.parent.is_dir() or output.parent.is_symlink():
        fail(f"{label} output parent must be an existing non-symlink directory")
    try:
        with output.open("x", encoding="utf-8") as destination:
            json.dump(value, destination, indent=2, sort_keys=True, allow_nan=False)
            destination.write("\n")
    except OSError as error:
        fail(f"could not create {label}: {error}")


def transition_public(args: argparse.Namespace) -> None:
    candidate_root = require_root(args.candidate_dir, "candidate directory")
    manifest = expect_object(read_json(args.manifest, "private owner smoke manifest"), "manifest")
    exact_keys(manifest, {"schema_version", "schema_id", "generated_at", "candidate", "rows"}, "manifest")
    if manifest["schema_version"] != 1 or manifest["schema_id"] != SCHEMA_ID:
        fail("manifest schema version/id is unsupported")
    private_candidate, private_distribution = candidate_with_distribution(
        candidate_root, args.private_release_metadata
    )
    public_candidate, public_distribution = candidate_with_distribution(
        candidate_root, args.public_release_metadata
    )
    if private_candidate["distribution"]["state"] != "private_draft":
        fail("transition source release metadata is not the authenticated private draft")
    if public_candidate["distribution"]["state"] != "public":
        fail("transition destination release metadata is not the authenticated public release")
    if manifest["candidate"] != private_candidate:
        fail("transition manifest does not match the authenticated private draft")
    private_binding = dict(private_candidate)
    public_binding = dict(public_candidate)
    private_binding.pop("artifact_url")
    public_binding.pop("artifact_url")
    private_binding["distribution"] = dict(private_binding["distribution"])
    public_binding["distribution"] = dict(public_binding["distribution"])
    private_binding["distribution"].pop("state")
    public_binding["distribution"].pop("state")
    if private_binding != public_binding:
        fail("public release metadata does not preserve the exact private candidate bytes and ids")
    if private_distribution["asset_ids"] != public_distribution["asset_ids"]:
        fail("public release metadata does not preserve all nine immutable asset ids")
    transitioned = dict(manifest)
    transitioned["candidate"] = public_candidate
    write_new_json(args.output, transitioned, "public manifest")
    print(f"Transitioned {SCHEMA_ID} manifest to canonical public URL at {args.output}")


def validate_artifacts(candidate: dict[str, Any], payload_candidate: dict[str, Any]) -> None:
    expected_keys = {
        "tag",
        "version",
        "build_number",
        "source_commit",
        "dmg_sha256",
        "team_id",
        "bundle_id",
        "artifact_url",
        "distribution",
        "workflow_url",
        "apple_submission_id",
        "artifacts",
    }
    exact_keys(candidate, expected_keys, "manifest.candidate")
    if candidate != payload_candidate:
        fail("manifest candidate does not exactly match the candidate payload")


def validate_evidence_entries(
    entries_value: Any,
    evidence_root: Path,
    label: str,
    automated: bool,
) -> set[str]:
    entries = expect_list(entries_value, label)
    kinds: set[str] = set()
    paths: set[str] = set()
    for index, entry_value in enumerate(entries):
        entry = expect_object(entry_value, f"{label}[{index}]")
        exact_keys(entry, {"kind", "relative_path", "sha256"}, f"{label}[{index}]")
        kind = entry["kind"]
        if kind not in EVIDENCE_KINDS:
            fail(f"{label}[{index}].kind is not allowed")
        if automated != (kind == "automated-gate"):
            fail(f"{label}[{index}] is classified in the wrong evidence channel")
        relative = entry["relative_path"]
        if relative in paths:
            fail(f"{label} repeats evidence path {relative}")
        paths.add(relative)
        path = contained_file(evidence_root, relative, f"{label}[{index}]")
        digest = entry["sha256"]
        if not isinstance(digest, str) or not SHA256_RE.fullmatch(digest):
            fail(f"{label}[{index}].sha256 is invalid")
        if sha256(path) != digest:
            fail(f"{label}[{index}] hash mismatch for {relative}")
        kinds.add(kind)
    return kinds


def verify_manifest(args: argparse.Namespace) -> None:
    policy = load_policy()
    candidate_root = require_root(args.candidate_dir, "candidate directory")
    evidence_root = require_root(args.evidence_root, "evidence root")
    manifest = expect_object(read_json(args.manifest, "acceptance manifest"), "manifest")
    exact_keys(manifest, {"schema_version", "schema_id", "generated_at", "candidate", "rows"}, "manifest")
    if manifest["schema_version"] != 1 or manifest["schema_id"] != SCHEMA_ID:
        fail("manifest schema version/id is unsupported")
    valid_datetime(manifest["generated_at"], "manifest.generated_at")
    candidate = expect_object(manifest["candidate"], "manifest.candidate")
    payload_candidate = candidate_from_payload(candidate_root, args.release_metadata)
    validate_artifacts(candidate, payload_candidate)
    binding = candidate_binding(candidate)

    rows = expect_list(manifest["rows"], "manifest.rows")
    expected_row_ids = list(policy["rows"])
    if [row.get("id") if isinstance(row, dict) else None for row in rows] != expected_row_ids:
        fail("manifest rows must appear exactly once in S01,S02 order")

    incomplete: list[str] = []
    for index, row_value in enumerate(rows):
        row = expect_object(row_value, f"manifest.rows[{index}]")
        exact_keys(
            row,
            {
                "id",
                "issue",
                "title",
                "candidate_binding",
                "classification",
                "result",
                "tester",
                "executed_at",
                "machine",
                "macos",
                "displays",
                "evidence",
                "automated_evidence",
                "notes",
            },
            f"manifest.rows[{index}]",
        )
        row_id = row["id"]
        row_policy = expect_object(policy["rows"][row_id], f"policy row {row_id}")
        if row["issue"] != row_policy["issue"] or row["title"] != row_policy["title"]:
            fail(f"{row_id} issue/title drifted from policy")
        if row["candidate_binding"] != binding:
            fail(f"{row_id} candidate binding does not exactly match the manifest candidate")
        classification = expect_object(row["classification"], f"{row_id}.classification")
        exact_keys(classification, {"acceptance", "automation"}, f"{row_id}.classification")
        if classification != {
            "acceptance": "owner_operated_required",
            "automation": row_policy["automation"],
        }:
            fail(f"{row_id} classification cannot replace owner-operated acceptance")
        validate_context(
            {
                "tester": row["tester"],
                "machine": row["machine"],
                "macos": row["macos"],
                "displays": row["displays"],
            },
            f"{row_id}.context",
        )
        result = row["result"]
        if result not in {"pending", "pass", "fail", "blocked"}:
            fail(f"{row_id}.result is invalid")
        if not isinstance(row["notes"], str):
            fail(f"{row_id}.notes must be a string")
        if result in {"fail", "blocked"} and not row["notes"].strip():
            fail(f"{row_id} {result} requires an explanatory note")

        human_kinds = validate_evidence_entries(row["evidence"], evidence_root, f"{row_id}.evidence", False)
        automated_kinds = validate_evidence_entries(
            row["automated_evidence"],
            evidence_root,
            f"{row_id}.automated_evidence",
            True,
        )
        if result == "pass":
            valid_datetime(row["executed_at"], f"{row_id}.executed_at")
            for alternatives in row_policy["required_evidence_groups"]:
                if not human_kinds.intersection(alternatives):
                    fail(f"{row_id} is missing retained human evidence from {alternatives}")
            if row_policy["automation"] == "supporting_required" and not automated_kinds:
                fail(f"{row_id} is missing required supporting automated evidence")
        else:
            incomplete.append(row_id)
            if row["executed_at"] is not None:
                valid_datetime(row["executed_at"], f"{row_id}.executed_at")

    if incomplete and not args.allow_pending:
        fail(f"final acceptance requires every row to pass; incomplete rows: {','.join(incomplete)}")
    status = "structurally valid but incomplete" if incomplete else "final owner smoke passed"
    print(f"{SCHEMA_ID}: {status}; candidate {candidate['tag']} {candidate['dmg_sha256']}")


def hash_evidence(args: argparse.Namespace) -> None:
    evidence_root = require_root(args.evidence_root, "evidence root")
    if args.kind not in EVIDENCE_KINDS:
        fail(f"unsupported evidence kind: {args.kind}")
    path = contained_file(evidence_root, args.relative_path, "evidence")
    print(
        json.dumps(
            {
                "kind": args.kind,
                "relative_path": args.relative_path,
                "sha256": sha256(path),
            },
            sort_keys=True,
            allow_nan=False,
        )
    )


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subcommands = result.add_subparsers(dest="command", required=True)

    candidate = subcommands.add_parser(
        "verify-candidate",
        help="verify the exact published payload and emit its closed candidate identity",
    )
    candidate.add_argument("--candidate-dir", type=Path, required=True)
    candidate.add_argument("--release-metadata", type=Path, required=True)
    candidate.set_defaults(handler=verify_candidate_payload)

    init = subcommands.add_parser("init", help="create a new pending manifest from an immutable candidate")
    init.add_argument("--candidate-dir", type=Path, required=True)
    init.add_argument("--evidence-root", type=Path, required=True)
    init.add_argument("--context", type=Path, required=True)
    init.add_argument("--release-metadata", type=Path, required=True)
    init.add_argument("--output", type=Path, required=True)
    init.set_defaults(handler=init_manifest)

    verify = subcommands.add_parser("verify", help="verify candidate identity and every retained evidence hash")
    verify.add_argument("--candidate-dir", type=Path, required=True)
    verify.add_argument("--evidence-root", type=Path, required=True)
    verify.add_argument("--manifest", type=Path, required=True)
    verify.add_argument("--release-metadata", type=Path, required=True)
    verify.add_argument("--allow-pending", action="store_true")
    verify.set_defaults(handler=verify_manifest)

    transition = subcommands.add_parser(
        "transition-public",
        help="bind an existing private-draft manifest to the same now-public release object",
    )
    transition.add_argument("--candidate-dir", type=Path, required=True)
    transition.add_argument("--manifest", type=Path, required=True)
    transition.add_argument("--private-release-metadata", type=Path, required=True)
    transition.add_argument("--public-release-metadata", type=Path, required=True)
    transition.add_argument("--output", type=Path, required=True)
    transition.set_defaults(handler=transition_public)

    evidence_hash = subcommands.add_parser("hash-evidence", help="emit one closed evidence descriptor")
    evidence_hash.add_argument("--evidence-root", type=Path, required=True)
    evidence_hash.add_argument("--kind", required=True)
    evidence_hash.add_argument("--relative-path", required=True)
    evidence_hash.set_defaults(handler=hash_evidence)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        args.handler(args)
    except ValidationError as error:
        print(f"human acceptance evidence error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
