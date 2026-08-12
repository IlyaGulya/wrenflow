#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wrenflow-frozen-baseline-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

mise exec -- python3 "$REPO_DIR/scripts/fixtures/performance/generate-hybrid-verifier-fixture.py" \
    "$REPO_DIR/support/performance/budgets-v1.json" \
    "$TEST_ROOT/constrained-evidence.json" \
    "$TEST_ROOT/unused-physical.json"

mise exec -- python3 - \
    "$REPO_DIR/scripts/verify-frozen-performance-baseline.py" \
    "$REPO_DIR/scripts/perf/gpui-performance.py" \
    "$REPO_DIR/support/performance/frozen-stable-baseline-v1.json" \
    "$TEST_ROOT" <<'PY'
import copy
import hashlib
import json
import pathlib
import runpy
import subprocess
import sys
import zipfile

verifier = runpy.run_path(sys.argv[1])
performance = runpy.run_path(sys.argv[2])
production_policy = verifier["load_policy"](pathlib.Path(sys.argv[3]).resolve())
root = pathlib.Path(sys.argv[4]).resolve()
result_path = root / "constrained-evidence.json"
result = json.loads(result_path.read_text(encoding="utf-8"))
baseline = production_policy["baseline"]
result["source"] = {"commit": baseline["source_commit"], "dirty": False}
result["candidate_id"] = baseline["candidate_id"]
result["candidate"]["bundle_version"] = baseline["bundle_version"]
result["candidate"]["bundle_build"] = baseline["bundle_build"]
result["candidate"]["executable_sha256"] = baseline["executable_sha256"]
result["evidence_sha256"] = performance["canonical_hash"](result)
result_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")

retained_report = root / "constrained-verification.json"
completed = subprocess.run(
    [
        sys.executable,
        str(verifier["PERFORMANCE_TOOL"]),
        "verify",
        "--profile",
        "constrained",
        "--result",
        str(result_path),
        "--budgets",
        str(verifier["PERFORMANCE_BUDGETS"]),
        "--report",
        str(retained_report),
    ],
    check=False,
    timeout=120,
)
assert completed.returncode == 0

archive = root / "artifact.zip"
with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as zipped:
    zipped.write(result_path, result_path.name)
    zipped.write(retained_report, retained_report.name)

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

policy = copy.deepcopy(production_policy)
policy["artifact"].update({
    "run_id": 31603344709,
    "artifact_id": 123456789,
    "name": "synthetic-frozen-performance",
    "size_in_bytes": archive.stat().st_size,
    "archive_sha256": sha(archive),
    "result_sha256": sha(result_path),
    "report_sha256": sha(retained_report),
})
policy_path = root / "policy.json"
policy_path.write_text(json.dumps(policy, indent=2) + "\n", encoding="utf-8")

artifact = policy["artifact"]
metadata = {
    "archive_download_url": f"https://api.github.com/repos/{artifact['repository']}/actions/artifacts/{artifact['artifact_id']}/zip",
    "created_at": "2026-08-12T14:54:37Z",
    "digest": f"sha256:{artifact['archive_sha256']}",
    "expired": False,
    "expires_at": "2026-09-02T14:54:36Z",
    "id": artifact["artifact_id"],
    "name": artifact["name"],
    "node_id": "synthetic-node",
    "size_in_bytes": artifact["size_in_bytes"],
    "updated_at": "2026-08-12T14:54:37Z",
    "url": f"https://api.github.com/repos/{artifact['repository']}/actions/artifacts/{artifact['artifact_id']}",
    "workflow_run": {
        "head_branch": "main",
        "head_repository_id": 1169256765,
        "head_sha": baseline["source_commit"],
        "id": artifact["run_id"],
        "repository_id": 1169256765,
    },
}
metadata_path = root / "metadata.json"
metadata_path.write_text(json.dumps(metadata), encoding="utf-8")

selected = verifier["load_policy"](policy_path)
verifier["validate_metadata"](metadata, selected)
verifier["validate_source_diff"](selected, selected["stable_release"]["source_commit"])
extract_root = root / "extract"
extract_root.mkdir()
extracted_result, extracted_report = verifier["extract_archive"](archive, selected, extract_root)
current_report = root / "current-report.json"
verifier["validate_evidence"](extracted_result, extracted_report, selected, current_report)
current = json.loads(current_report.read_text(encoding="utf-8"))
assert current["profile"] == "release"
assert current["passed"] is True
assert current["evaluated_metrics"] == 24
assert current["evaluated_measurements"] == 24

def rejected(function, message):
    try:
        function()
    except verifier["VerificationError"]:
        return
    raise SystemExit(message)

for key, value in (
    ("expired", True),
    ("name", "wrong-artifact"),
    ("digest", "sha256:" + "0" * 64),
):
    invalid = copy.deepcopy(metadata)
    invalid[key] = value
    rejected(
        lambda invalid=invalid: verifier["validate_metadata"](invalid, selected),
        f"metadata verifier accepted {key} drift",
    )
invalid = copy.deepcopy(metadata)
invalid["workflow_run"]["head_sha"] = "0" * 40
rejected(lambda: verifier["validate_metadata"](invalid, selected), "metadata verifier accepted wrong source")

rejected(
    lambda: verifier["validate_source_diff"](selected, "0" * 40),
    "source verifier accepted an unapproved stable source",
)
invalid_policy = copy.deepcopy(selected)
invalid_policy["stable_release"]["allowed_diff"] = invalid_policy["stable_release"]["allowed_diff"][:-1]
rejected(
    lambda: verifier["validate_source_diff"](invalid_policy, selected["stable_release"]["source_commit"]),
    "source verifier accepted a missing approved diff entry",
)

original_git_file = verifier["git_file"]
source_globals = verifier["validate_source_diff"].__globals__
def budget_drift(commit, path):
    content = original_git_file(commit, path)
    if commit == selected["stable_release"]["source_commit"] and path == "support/performance/budgets-v1.json":
        value = json.loads(content)
        value["budgets"][0]["threshold"] += 1
        return json.dumps(value).encode()
    return content
source_globals["git_file"] = budget_drift
rejected(
    lambda: verifier["validate_source_diff"](selected, selected["stable_release"]["source_commit"]),
    "source verifier accepted a threshold change",
)

def dependency_drift(commit, path):
    content = original_git_file(commit, path)
    if commit == selected["stable_release"]["source_commit"] and path == "Cargo.toml":
        return content.replace(b'serde_json = "1"', b'serde_json = "2"')
    return content
source_globals["git_file"] = dependency_drift
rejected(
    lambda: verifier["validate_source_diff"](selected, selected["stable_release"]["source_commit"]),
    "source verifier accepted dependency drift",
)
source_globals["git_file"] = original_git_file

tampered_result = copy.deepcopy(result)
tampered_result["candidate"]["executable_sha256"] = "0" * 64
tampered_result["evidence_sha256"] = performance["canonical_hash"](tampered_result)
tampered_result_path = root / "tampered-result.json"
tampered_result_path.write_text(json.dumps(tampered_result), encoding="utf-8")
rejected(
    lambda: verifier["validate_evidence"](
        tampered_result_path, retained_report, selected, root / "tampered-result-report.json"
    ),
    "evidence verifier accepted a different executable",
)

missing_metric = copy.deepcopy(result)
missing_metric["metrics"].pop(next(iter(missing_metric["metrics"])))
missing_metric["evidence_sha256"] = performance["canonical_hash"](missing_metric)
missing_metric_path = root / "missing-metric.json"
missing_metric_path.write_text(json.dumps(missing_metric), encoding="utf-8")
rejected(
    lambda: verifier["validate_evidence"](
        missing_metric_path, retained_report, selected, root / "missing-metric-report.json"
    ),
    "evidence verifier accepted fewer than 24 metrics",
)

extra_archive = root / "extra.zip"
with zipfile.ZipFile(extra_archive, "w", zipfile.ZIP_DEFLATED) as zipped:
    zipped.write(result_path, result_path.name)
    zipped.write(retained_report, retained_report.name)
    zipped.writestr("extra-private.txt", "private")
extra_policy = copy.deepcopy(selected)
extra_policy["artifact"]["size_in_bytes"] = extra_archive.stat().st_size
extra_policy["artifact"]["archive_sha256"] = sha(extra_archive)
rejected(
    lambda: verifier["extract_archive"](extra_archive, extra_policy, root / "extra-extract"),
    "archive verifier accepted an extra file",
)
PY

echo "Frozen stable performance baseline verifier tests passed"
