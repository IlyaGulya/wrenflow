#!/usr/bin/env python3
"""Generate synthetic verifier-only hybrid results for harness unit tests."""

import hashlib
import json
import pathlib
import sys


def evidence_hash(result):
    encoded = json.dumps(result, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


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
    eligibility = {
        "github_m1_7gb_constrained_preflight": role == "constrained_noninteractive",
        "physical_supported_interactive": role == "physical_interactive",
        "physical_base_m1_8gib_macos14": False,
    }
    result = {
        "schema_version": 1,
        "budget_version": budgets["budget_version"],
        "source": {"commit": "a" * 40, "dirty": False},
        "host": {
            "evidence_eligibility": eligibility,
            "missing_required_templates": [],
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
        "phases": ({
            "post_event_tap_synthetic": {
                "classification": "post_event_tap_synthetic",
                "source": "signed_wrenflow_typed_hotkey_callback",
                "tcc_or_microphone_evidence": False,
            }
        } if synthetic else {}),
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
