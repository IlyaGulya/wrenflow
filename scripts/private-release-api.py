#!/usr/bin/env python3
"""Fail-closed GitHub Release operations for a private tagless stable draft."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from typing import Any
from urllib.parse import quote


ASSET_NAMES = (
    "RustThirdPartyLicenses.txt",
    "SHA256SUMS",
    "Wrenflow.cdx.json",
    "Wrenflow.dmg",
    "artifact-provenance.json",
    "exceptions.json",
    "pins.json",
    "provenance.json",
    "release-evidence.json",
)
RELEASE_ID_RE = re.compile(r"[1-9][0-9]*\Z")
TAG_RE = re.compile(r"v[0-9]+\.[0-9]+\.[0-9]+\Z")
SHA_RE = re.compile(r"[0-9a-f]{40}\Z")
KNOWN_INVALID_RELEASE_FINGERPRINT = (
    "086ec8d47f3582eb73b8c90eb8836676afbfaffd649bf14ea19a20ef3f65c558"
)
KNOWN_INVALID_ASSETS = {
    "RustThirdPartyLicenses.txt": (
        512243798,
        "sha256:6327d2c20456ce2e00d8783db3ab07329e68393e6dfa1486fe70da7ca96df0a2",
    ),
    "SHA256SUMS": (
        512243799,
        "sha256:0bde0034e1bd8e2463ded09454ea66d21a67b3792ec46d3c84dbd264f3546ad6",
    ),
    "Wrenflow.cdx.json": (
        512243802,
        "sha256:4f2921969154b5e57cb7e5427dd6e701100752514bacd0489ac03aa74712e74b",
    ),
    "Wrenflow.dmg": (
        512243810,
        "sha256:4a6fb5f1e23b8e39a51681d2658357028fe2e4c1668be8db43313cc6ed867e12",
    ),
    "artifact-provenance.json": (
        512243823,
        "sha256:c5c18b4630e7ae87e000b7e97f7b88c17c37abdf21fb6867f5a464bd921675a1",
    ),
    "exceptions.json": (
        512243826,
        "sha256:0333c150d3b2eb72f2a0bfa15ddbbf1ec3784a516ce1c95cae7fc7b79483db93",
    ),
    "pins.json": (
        512243831,
        "sha256:e5a998d951cb01d0d4ac2d27b42792f57719043c6c279ec39c72b0764f897dde",
    ),
    "provenance.json": (
        512243837,
        "sha256:3f72dc555397252461f1239bbd713377c51d05fe8168b01044b52940ab9ac26d",
    ),
    "release-evidence.json": (
        512243847,
        "sha256:26928282bae24b5ab237f6d4da5f347750bb3dc36e1ec81a5fa2b37c452a39be",
    ),
}


class ReleaseError(RuntimeError):
    pass


def require_release_id(value: str) -> int:
    if not RELEASE_ID_RE.fullmatch(value):
        raise ReleaseError("release_id must be a canonical positive decimal integer")
    return int(value)


def require_repo(value: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", value):
        raise ReleaseError("repository must be one canonical owner/name pair")
    return value


def require_tag(value: str) -> str:
    if not TAG_RE.fullmatch(value):
        raise ReleaseError("release tag must be canonical stable SemVer")
    return value


def require_source(value: str) -> str:
    if not SHA_RE.fullmatch(value):
        raise ReleaseError("release source must be one exact lowercase commit")
    return value


def run_gh_json(gh: str, args: list[str]) -> dict[str, Any]:
    result = subprocess.run(
        [gh, *args], check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    if result.returncode != 0:
        category = "not_found" if b"HTTP 404" in result.stderr else "api_error"
        raise ReleaseError(f"GitHub API request failed ({category})")
    try:
        value = json.loads(result.stdout)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ReleaseError("GitHub API response is not JSON") from error
    if not isinstance(value, dict):
        raise ReleaseError("GitHub API response must be one release object")
    return value


def run_gh_empty(gh: str, args: list[str]) -> None:
    result = subprocess.run(
        [gh, *args], check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    if result.returncode != 0:
        category = "not_found" if b"HTTP 404" in result.stderr else "api_error"
        raise ReleaseError(f"GitHub API mutation failed ({category})")
    if result.stdout.strip():
        raise ReleaseError("GitHub API deletion unexpectedly returned a response body")


def canonical_asset(asset: Any, repo: str) -> dict[str, Any]:
    if not isinstance(asset, dict):
        raise ReleaseError("release asset is not an object")
    asset_id = asset.get("id")
    name = asset.get("name")
    size = asset.get("size")
    state = asset.get("state")
    content_type = asset.get("content_type")
    created_at = asset.get("created_at")
    updated_at = asset.get("updated_at")
    url = asset.get("url")
    digest = asset.get("digest")
    if not isinstance(asset_id, int) or asset_id <= 0:
        raise ReleaseError("release asset id must be positive")
    if not isinstance(name, str) or name not in ASSET_NAMES:
        raise ReleaseError("release contains an unapproved asset name")
    if not isinstance(size, int) or size <= 0:
        raise ReleaseError("release asset size must be positive")
    if state != "uploaded":
        raise ReleaseError("release asset is not fully uploaded")
    if not isinstance(content_type, str) or not content_type:
        raise ReleaseError("release asset content type is missing")
    if not isinstance(created_at, str) or not created_at:
        raise ReleaseError("release asset creation timestamp is missing")
    if not isinstance(updated_at, str) or not updated_at:
        raise ReleaseError("release asset update timestamp is missing")
    expected_url = f"https://api.github.com/repos/{repo}/releases/assets/{asset_id}"
    if url != expected_url:
        raise ReleaseError("release asset API URL does not match its exact id")
    if digest is not None and (
        not isinstance(digest, str)
        or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest)
    ):
        raise ReleaseError("release asset digest has an invalid shape")
    return {
        "id": asset_id,
        "name": name,
        "size": size,
        "digest": digest,
        "state": state,
        "contentType": content_type,
        "createdAt": created_at,
        "updatedAt": updated_at,
        "url": url,
    }


def canonical_release(
    raw: dict[str, Any], *, repo: str, release_id: int, tag: str, source: str, state: str
) -> dict[str, Any]:
    if raw.get("id") != release_id:
        raise ReleaseError("release object id does not match requested release_id")
    if raw.get("tag_name") != tag or raw.get("target_commitish") != source:
        raise ReleaseError("release object tag or source does not match the request")
    expected_draft = state != "public"
    if raw.get("draft") is not expected_draft or raw.get("prerelease") is not False:
        raise ReleaseError("release object has the wrong draft/prerelease state")
    expected_upload_url = (
        f"https://uploads.github.com/repos/{repo}/releases/{release_id}/assets"
        "{?name,label}"
    )
    if raw.get("upload_url") != expected_upload_url:
        raise ReleaseError("release upload URL is not bound to the requested release_id")
    assets_raw = raw.get("assets")
    if not isinstance(assets_raw, list):
        raise ReleaseError("release assets must be an array")
    assets = [canonical_asset(asset, repo) for asset in assets_raw]
    names = [asset["name"] for asset in assets]
    ids = [asset["id"] for asset in assets]
    if len(names) != len(set(names)) or len(ids) != len(set(ids)):
        raise ReleaseError("release assets contain duplicate names or ids")
    if state == "empty":
        if assets:
            raise ReleaseError("private stable draft is not empty")
    elif sorted(names) != sorted(ASSET_NAMES) or len(assets) != len(ASSET_NAMES):
        raise ReleaseError("release does not contain the exact nine assets")
    return {
        "id": release_id,
        "tagName": tag,
        "targetCommitish": source,
        "isDraft": expected_draft,
        "isPrerelease": False,
        "assets": sorted(assets, key=lambda asset: asset["name"]),
    }


def fetch_release(args: argparse.Namespace, state: str) -> dict[str, Any]:
    raw = run_gh_json(
        args.gh,
        ["api", f"repos/{args.repo}/releases/{args.release_id_int}"],
    )
    return canonical_release(
        raw,
        repo=args.repo,
        release_id=args.release_id_int,
        tag=args.tag,
        source=args.source,
        state=state,
    )


def write_json(path: Path, value: dict[str, Any]) -> None:
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ReleaseError("output must be a regular non-symlink path")
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    if temporary.exists() or temporary.is_symlink():
        raise ReleaseError("private release output temporary path already exists")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def require_payload(path: Path) -> Path:
    if not path.is_absolute() or not path.is_dir() or path.is_symlink():
        raise ReleaseError("payload must be an absolute non-symlink directory")
    entries = sorted(item.name for item in path.iterdir())
    if entries != sorted(ASSET_NAMES):
        raise ReleaseError("payload must contain exactly the nine approved files")
    for name in ASSET_NAMES:
        item = path / name
        if not item.is_file() or item.is_symlink() or item.stat().st_size <= 0:
            raise ReleaseError(f"payload asset is not a nonempty regular file: {name}")
    return path


def command_derive_id(args: argparse.Namespace) -> None:
    repo = require_repo(args.repo)
    pattern = re.compile(
        rf"https://uploads\.github\.com/repos/{re.escape(repo)}/releases/"
        r"([1-9][0-9]*)/assets\{\?name,label\}\Z"
    )
    match = pattern.fullmatch(args.upload_url)
    if not match:
        raise ReleaseError("release-please upload_url is not one exact repository release URL")
    print(match.group(1))


def command_inspect(args: argparse.Namespace) -> None:
    write_json(args.output, fetch_release(args, args.state))


def command_derive_source(args: argparse.Namespace) -> None:
    raw = run_gh_json(args.gh, ["api", f"repos/{args.repo}/releases/{args.release_id_int}"])
    source = require_source(raw.get("target_commitish") if isinstance(raw.get("target_commitish"), str) else "")
    canonical_release(
        raw,
        repo=args.repo,
        release_id=args.release_id_int,
        tag=args.tag,
        source=source,
        state="staged",
    )
    print(source)


def command_upload(args: argparse.Namespace) -> None:
    payload = require_payload(args.payload)
    fetch_release(args, "empty")
    upload_payload(args, payload)
    write_json(args.output, fetch_release(args, "staged"))


def upload_payload(args: argparse.Namespace, payload: Path) -> None:
    for name in ASSET_NAMES:
        endpoint = (
            f"https://uploads.github.com/repos/{args.repo}/releases/{args.release_id_int}/assets"
            f"?name={quote(name, safe='')}"
        )
        uploaded = run_gh_json(
            args.gh,
            [
                "api",
                "-X",
                "POST",
                "-H",
                "Accept: application/vnd.github+json",
                "-H",
                "X-GitHub-Api-Version: 2022-11-28",
                "-H",
                "Content-Type: application/octet-stream",
                "--input",
                str(payload / name),
                endpoint,
            ],
        )
        canonical = canonical_asset(uploaded, args.repo)
        if canonical["name"] != name or canonical["size"] != (payload / name).stat().st_size:
            raise ReleaseError("uploaded asset response does not match the exact local file")


def release_fingerprint(release: dict[str, Any]) -> str:
    value = {
        "id": release["id"],
        "tag_name": release["tagName"],
        "target_commitish": release["targetCommitish"],
        "draft": release["isDraft"],
        "prerelease": release["isPrerelease"],
        "assets": [
            {
                "id": asset["id"],
                "name": asset["name"],
                "size": asset["size"],
                "digest": asset["digest"],
                "state": asset["state"],
            }
            for asset in release["assets"]
        ],
    }
    encoded = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
    return hashlib.sha256(encoded).hexdigest()


def require_known_invalid_release(
    release: dict[str, Any], expected_fingerprint: str
) -> None:
    if expected_fingerprint != KNOWN_INVALID_RELEASE_FINGERPRINT:
        raise ReleaseError("repair fingerprint does not match the reviewed invalid draft")
    actual_assets = {
        asset["name"]: (asset["id"], asset["digest"]) for asset in release["assets"]
    }
    if actual_assets != KNOWN_INVALID_ASSETS:
        raise ReleaseError("private draft is not the reviewed invalid nine-asset payload")
    if release_fingerprint(release) != KNOWN_INVALID_RELEASE_FINGERPRINT:
        raise ReleaseError("private draft canonical fingerprint changed before repair")


def command_replace_known_invalid(args: argparse.Namespace) -> None:
    payload = require_payload(args.payload)
    staged = fetch_release(args, "staged")
    require_known_invalid_release(staged, args.expected_fingerprint)
    for asset in staged["assets"]:
        run_gh_empty(
            args.gh,
            [
                "api",
                "-X",
                "DELETE",
                f"repos/{args.repo}/releases/assets/{asset['id']}",
            ],
        )
    fetch_release(args, "empty")
    upload_payload(args, payload)
    write_json(args.output, fetch_release(args, "staged"))


def require_empty_directory(path: Path) -> Path:
    if not path.is_absolute() or not path.is_dir() or path.is_symlink():
        raise ReleaseError("download destination must be an absolute non-symlink directory")
    if any(path.iterdir()):
        raise ReleaseError("download destination must be empty")
    return path


def command_download(args: argparse.Namespace) -> None:
    destination = require_empty_directory(args.directory)
    release = fetch_release(args, args.state)
    for asset in release["assets"]:
        target = destination / asset["name"]
        with target.open("xb") as output:
            result = subprocess.run(
                [
                    args.gh,
                    "api",
                    "-H",
                    "Accept: application/octet-stream",
                    f"repos/{args.repo}/releases/assets/{asset['id']}",
                ],
                check=False,
                stdout=output,
                stderr=subprocess.PIPE,
            )
        if result.returncode != 0:
            target.unlink(missing_ok=True)
            raise ReleaseError("exact release asset download failed")
        if target.stat().st_size != asset["size"]:
            raise ReleaseError("downloaded release asset size does not match metadata")


def command_publish(args: argparse.Namespace) -> None:
    if not args.approved_fingerprint.is_file() or args.approved_fingerprint.is_symlink():
        raise ReleaseError("approved fingerprint must be a regular non-symlink file")
    try:
        approved = json.loads(args.approved_fingerprint.read_text())
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ReleaseError("approved fingerprint is not JSON") from error
    immediate = fetch_release(args, "staged")
    if approved != immediate:
        raise ReleaseError("private draft changed after its approved second fingerprint")
    raw = run_gh_json(
        args.gh,
        [
            "api",
            "-X",
            "PATCH",
            f"repos/{args.repo}/releases/{args.release_id_int}",
            "-F",
            "draft=false",
            "-F",
            "prerelease=false",
            "-f",
            f"target_commitish={args.source}",
            "-f",
            "make_latest=true",
        ],
    )
    canonical_release(
        raw,
        repo=args.repo,
        release_id=args.release_id_int,
        tag=args.tag,
        source=args.source,
        state="public",
    )
    write_json(args.output, fetch_release(args, "public"))


def add_release_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    parser.add_argument("--release-id", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--gh", default="gh")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    derive = subparsers.add_parser("derive-id")
    derive.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    derive.add_argument("--upload-url", required=True)

    inspect = subparsers.add_parser("inspect")
    add_release_arguments(inspect)
    inspect.add_argument("--state", choices=("empty", "staged", "public"), required=True)
    inspect.add_argument("--output", type=Path, required=True)

    derive_source = subparsers.add_parser("derive-source")
    derive_source.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    derive_source.add_argument("--release-id", required=True)
    derive_source.add_argument("--tag", required=True)
    derive_source.add_argument("--gh", default="gh")

    upload = subparsers.add_parser("upload")
    add_release_arguments(upload)
    upload.add_argument("--payload", type=Path, required=True)
    upload.add_argument("--output", type=Path, required=True)

    replace = subparsers.add_parser("replace-known-invalid")
    add_release_arguments(replace)
    replace.add_argument("--expected-fingerprint", required=True)
    replace.add_argument("--payload", type=Path, required=True)
    replace.add_argument("--output", type=Path, required=True)

    download = subparsers.add_parser("download")
    add_release_arguments(download)
    download.add_argument("--state", choices=("staged", "public"), required=True)
    download.add_argument("--directory", type=Path, required=True)

    publish = subparsers.add_parser("publish")
    add_release_arguments(publish)
    publish.add_argument("--approved-fingerprint", type=Path, required=True)
    publish.add_argument("--output", type=Path, required=True)

    args = parser.parse_args()
    if args.command not in ("derive-id", "derive-source"):
        args.repo = require_repo(args.repo)
        args.release_id_int = require_release_id(args.release_id)
        args.tag = require_tag(args.tag)
        args.source = require_source(args.source)
    elif args.command == "derive-source":
        args.repo = require_repo(args.repo)
        args.release_id_int = require_release_id(args.release_id)
        args.tag = require_tag(args.tag)
    return args


def main() -> int:
    try:
        args = parse_args()
        {
            "derive-id": command_derive_id,
            "derive-source": command_derive_source,
            "inspect": command_inspect,
            "upload": command_upload,
            "replace-known-invalid": command_replace_known_invalid,
            "download": command_download,
            "publish": command_publish,
        }[args.command](args)
    except ReleaseError as error:
        print(f"private-release-api: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
