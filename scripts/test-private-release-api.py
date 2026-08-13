#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).with_name("private-release-api.py")
SPEC = importlib.util.spec_from_file_location("private_release_api", SCRIPT)
assert SPEC and SPEC.loader
API = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(API)

REPO = "IlyaGulya/wrenflow"
RELEASE_ID = 369445618
TAG = "v0.4.0"
SOURCE = "7e0e698191d003fe507b0729265cafceaf640c1e"
INVALID_SIZES = {
    "RustThirdPartyLicenses.txt": 71579,
    "SHA256SUMS": 675,
    "Wrenflow.cdx.json": 781333,
    "Wrenflow.dmg": 21487802,
    "artifact-provenance.json": 2372,
    "exceptions.json": 1163,
    "pins.json": 4096,
    "provenance.json": 1254,
    "release-evidence.json": 718,
}


def raw_asset(name: str, asset_id: int, size: int = 1) -> dict[str, object]:
    return {
        "id": asset_id,
        "name": name,
        "size": size,
        "digest": f"sha256:{asset_id:064x}"[-71:],
        "state": "uploaded",
        "content_type": "application/octet-stream",
        "created_at": "2026-08-13T00:00:00Z",
        "updated_at": "2026-08-13T00:00:01Z",
        "url": f"https://api.github.com/repos/{REPO}/releases/assets/{asset_id}",
    }


def raw_release(*, assets: list[dict[str, object]] | None = None, draft: bool = True) -> dict[str, object]:
    return {
        "id": RELEASE_ID,
        "tag_name": TAG,
        "target_commitish": SOURCE,
        "draft": draft,
        "prerelease": False,
        "upload_url": f"https://uploads.github.com/repos/{REPO}/releases/{RELEASE_ID}/assets{{?name,label}}",
        "assets": assets or [],
    }


def known_invalid_assets() -> list[dict[str, object]]:
    return [
        {
            **raw_asset(name, asset_id, INVALID_SIZES[name]),
            "digest": digest,
        }
        for name, (asset_id, digest) in API.KNOWN_INVALID_ASSETS.items()
    ]


class PrivateReleaseApiTests(unittest.TestCase):
    def test_derives_exact_official_upload_url(self) -> None:
        completed = subprocess.run(
            [
                "python3",
                str(SCRIPT),
                "derive-id",
                "--repo",
                REPO,
                "--upload-url",
                f"https://uploads.github.com/repos/{REPO}/releases/{RELEASE_ID}/assets{{?name,label}}",
            ],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
        )
        self.assertEqual(completed.stdout, f"{RELEASE_ID}\n")

    def test_rejects_noncanonical_ids_and_upload_urls(self) -> None:
        for value in ("", "0", "01", "-1", "1.0", " 1", "1 "):
            with self.assertRaises(API.ReleaseError):
                API.require_release_id(value)
        for url in (
            f"https://uploads.github.com/repos/other/repo/releases/{RELEASE_ID}/assets{{?name,label}}",
            f"https://uploads.github.com/repos/{REPO}/releases/0/assets{{?name,label}}",
            f"https://uploads.github.com/repos/{REPO}/releases/{RELEASE_ID}/assets",
        ):
            completed = subprocess.run(
                ["python3", str(SCRIPT), "derive-id", "--repo", REPO, "--upload-url", url],
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            self.assertNotEqual(completed.returncode, 0)

    def test_closes_release_and_asset_identity(self) -> None:
        assets = [raw_asset(name, index + 10) for index, name in enumerate(API.ASSET_NAMES)]
        canonical = API.canonical_release(
            raw_release(assets=assets),
            repo=REPO,
            release_id=RELEASE_ID,
            tag=TAG,
            source=SOURCE,
            state="staged",
        )
        self.assertEqual(canonical["id"], RELEASE_ID)
        self.assertEqual([asset["name"] for asset in canonical["assets"]], sorted(API.ASSET_NAMES))

        mutations = []
        wrong_id = raw_release(assets=assets)
        wrong_id["id"] = RELEASE_ID + 1
        mutations.append(wrong_id)
        duplicate_id = raw_release(assets=assets)
        duplicate_id["assets"] = [*assets[:-1], {**assets[-1], "id": assets[0]["id"]}]
        mutations.append(duplicate_id)
        duplicate_name = raw_release(assets=assets)
        duplicate_name["assets"] = [*assets[:-1], {**assets[-1], "name": assets[0]["name"]}]
        mutations.append(duplicate_name)
        wrong_upload = raw_release(assets=assets)
        wrong_upload["upload_url"] = "https://uploads.github.com/repos/other/repo/releases/1/assets{?name,label}"
        mutations.append(wrong_upload)
        for mutation in mutations:
            with self.assertRaises(API.ReleaseError):
                API.canonical_release(
                    mutation,
                    repo=REPO,
                    release_id=RELEASE_ID,
                    tag=TAG,
                    source=SOURCE,
                    state="staged",
                )

    def test_derive_source_requires_the_exact_staged_object(self) -> None:
        args = mock.Mock(
            repo=REPO,
            release_id_int=RELEASE_ID,
            tag=TAG,
            gh="gh",
        )
        with mock.patch.object(API, "run_gh_json", return_value=raw_release(
            assets=[raw_asset(name, index + 50) for index, name in enumerate(API.ASSET_NAMES)]
        )):
            with mock.patch("builtins.print") as output:
                API.command_derive_source(args)
        output.assert_called_once_with(SOURCE)

        wrong = raw_release(
            assets=[raw_asset(name, index + 50) for index, name in enumerate(API.ASSET_NAMES)]
        )
        wrong["id"] = RELEASE_ID + 1
        with mock.patch.object(API, "run_gh_json", return_value=wrong), self.assertRaises(API.ReleaseError):
            API.command_derive_source(args)

    def test_upload_uses_exact_id_endpoint_and_refetches_closed_release(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payload = root / "payload"
            payload.mkdir()
            for name in API.ASSET_NAMES:
                (payload / name).write_bytes(name.encode())
            output = root / "release.json"
            args = mock.Mock(
                repo=REPO,
                release_id_int=RELEASE_ID,
                tag=TAG,
                source=SOURCE,
                gh="gh",
                payload=payload,
                output=output,
            )
            staged = API.canonical_release(
                raw_release(
                    assets=[
                        raw_asset(name, index + 100, len(name.encode()))
                        for index, name in enumerate(API.ASSET_NAMES)
                    ]
                ),
                repo=REPO,
                release_id=RELEASE_ID,
                tag=TAG,
                source=SOURCE,
                state="staged",
            )
            calls: list[list[str]] = []

            def fake_run_gh(_gh: str, command: list[str]) -> dict[str, object]:
                calls.append(command)
                name = Path(command[command.index("--input") + 1]).name
                return raw_asset(name, API.ASSET_NAMES.index(name) + 100, len(name.encode()))

            with mock.patch.object(API, "fetch_release", side_effect=[raw_release(), staged]), mock.patch.object(
                API, "run_gh_json", side_effect=fake_run_gh
            ):
                API.command_upload(args)
            self.assertEqual(len(calls), 9)
            for name, command in zip(API.ASSET_NAMES, calls, strict=True):
                self.assertIn(
                    f"https://uploads.github.com/repos/{REPO}/releases/{RELEASE_ID}/assets?name={name}",
                    command,
                )
            self.assertEqual(json.loads(output.read_text())["id"], RELEASE_ID)

    def test_download_uses_only_asset_ids(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            assets = [
                {
                    **API.canonical_asset(raw_asset(name, index + 200, len(name.encode())), REPO),
                }
                for index, name in enumerate(API.ASSET_NAMES)
            ]
            args = mock.Mock(
                repo=REPO,
                release_id_int=RELEASE_ID,
                tag=TAG,
                source=SOURCE,
                gh="gh",
                directory=directory,
                state="staged",
            )

            def fake_subprocess(command: list[str], **kwargs: object) -> mock.Mock:
                endpoint = command[-1]
                asset_id = int(endpoint.rsplit("/", 1)[1])
                name = API.ASSET_NAMES[asset_id - 200]
                kwargs["stdout"].write(name.encode())  # type: ignore[union-attr]
                return mock.Mock(returncode=0, stderr=b"")

            with mock.patch.object(API, "fetch_release", return_value={"assets": assets}), mock.patch.object(
                API.subprocess, "run", side_effect=fake_subprocess
            ) as run:
                API.command_download(args)
            self.assertEqual(run.call_count, 9)
            for call in run.call_args_list:
                self.assertIn(f"repos/{REPO}/releases/assets/", call.args[0][-1])
                self.assertNotIn(TAG, " ".join(call.args[0]))

    def test_replaces_only_the_exact_known_invalid_private_payload(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payload = root / "payload"
            payload.mkdir()
            for name in API.ASSET_NAMES:
                (payload / name).write_bytes(name.encode())
            output = root / "release.json"
            args = mock.Mock(
                repo=REPO,
                release_id_int=RELEASE_ID,
                tag=TAG,
                source=SOURCE,
                gh="gh",
                expected_fingerprint=API.KNOWN_INVALID_RELEASE_FINGERPRINT,
                payload=payload,
                output=output,
            )
            invalid = API.canonical_release(
                raw_release(assets=known_invalid_assets()),
                repo=REPO,
                release_id=RELEASE_ID,
                tag=TAG,
                source=SOURCE,
                state="staged",
            )
            empty = API.canonical_release(
                raw_release(),
                repo=REPO,
                release_id=RELEASE_ID,
                tag=TAG,
                source=SOURCE,
                state="empty",
            )
            replacement_raw = [
                raw_asset(name, index + 900, len(name.encode()))
                for index, name in enumerate(API.ASSET_NAMES)
            ]
            replacement = API.canonical_release(
                raw_release(assets=replacement_raw),
                repo=REPO,
                release_id=RELEASE_ID,
                tag=TAG,
                source=SOURCE,
                state="staged",
            )
            upload_calls: list[list[str]] = []

            def fake_upload(_gh: str, command: list[str]) -> dict[str, object]:
                upload_calls.append(command)
                name = Path(command[command.index("--input") + 1]).name
                return replacement_raw[API.ASSET_NAMES.index(name)]

            with mock.patch.object(
                API, "fetch_release", side_effect=[invalid, empty, replacement]
            ), mock.patch.object(API, "run_gh_empty") as delete, mock.patch.object(
                API, "run_gh_json", side_effect=fake_upload
            ):
                API.command_replace_known_invalid(args)

            self.assertEqual(API.release_fingerprint(invalid), API.KNOWN_INVALID_RELEASE_FINGERPRINT)
            self.assertEqual(delete.call_count, 9)
            self.assertEqual(len(upload_calls), 9)
            deleted_ids = [
                int(call.args[1][-1].rsplit("/", 1)[1]) for call in delete.call_args_list
            ]
            self.assertEqual(deleted_ids, [asset["id"] for asset in invalid["assets"]])
            self.assertEqual(json.loads(output.read_text()), replacement)

    def test_repair_rejects_fingerprint_or_asset_drift_before_deletion(self) -> None:
        invalid = API.canonical_release(
            raw_release(assets=known_invalid_assets()),
            repo=REPO,
            release_id=RELEASE_ID,
            tag=TAG,
            source=SOURCE,
            state="staged",
        )
        with self.assertRaises(API.ReleaseError):
            API.require_known_invalid_release(invalid, "0" * 64)

        changed = json.loads(json.dumps(invalid))
        changed["assets"][0]["digest"] = "sha256:" + "0" * 64
        with self.assertRaises(API.ReleaseError):
            API.require_known_invalid_release(changed, API.KNOWN_INVALID_RELEASE_FINGERPRINT)

    def test_repair_stops_on_delete_or_upload_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            payload = Path(temporary) / "payload"
            payload.mkdir()
            for name in API.ASSET_NAMES:
                (payload / name).write_bytes(name.encode())
            args = mock.Mock(
                repo=REPO,
                release_id_int=RELEASE_ID,
                tag=TAG,
                source=SOURCE,
                gh="gh",
                expected_fingerprint=API.KNOWN_INVALID_RELEASE_FINGERPRINT,
                payload=payload,
                output=Path(temporary) / "release.json",
            )
            invalid = API.canonical_release(
                raw_release(assets=known_invalid_assets()),
                repo=REPO,
                release_id=RELEASE_ID,
                tag=TAG,
                source=SOURCE,
                state="staged",
            )
            with mock.patch.object(API, "fetch_release", return_value=invalid), mock.patch.object(
                API, "run_gh_empty", side_effect=API.ReleaseError("delete failed")
            ), mock.patch.object(API, "run_gh_json") as upload, self.assertRaises(API.ReleaseError):
                API.command_replace_known_invalid(args)
            upload.assert_not_called()

            empty = API.canonical_release(
                raw_release(),
                repo=REPO,
                release_id=RELEASE_ID,
                tag=TAG,
                source=SOURCE,
                state="empty",
            )
            with mock.patch.object(
                API, "fetch_release", side_effect=[invalid, empty]
            ), mock.patch.object(API, "run_gh_empty"), mock.patch.object(
                API, "run_gh_json", side_effect=API.ReleaseError("upload failed")
            ), self.assertRaises(API.ReleaseError):
                API.command_replace_known_invalid(args)

    def test_publish_patches_exact_id_then_refetches_public_object(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fingerprint = Path(temporary) / "fingerprint.json"
            staged = {"id": RELEASE_ID, "assets": [{"id": 1}]}
            fingerprint.write_text(json.dumps(staged))
            args = mock.Mock(
                repo=REPO,
                release_id_int=RELEASE_ID,
                tag=TAG,
                source=SOURCE,
                gh="gh",
                approved_fingerprint=fingerprint,
                output=Path("unused.json"),
            )
            public_raw = raw_release(
                assets=[raw_asset(name, index + 300) for index, name in enumerate(API.ASSET_NAMES)],
                draft=False,
            )
            public = {"id": RELEASE_ID, "assets": []}
            with mock.patch.object(API, "fetch_release", side_effect=[staged, public]), mock.patch.object(
                API, "run_gh_json", return_value=public_raw
            ) as api_call, mock.patch.object(API, "write_json") as write:
                API.command_publish(args)
            command = api_call.call_args.args[1]
            self.assertIn(f"repos/{REPO}/releases/{RELEASE_ID}", command)
            self.assertIn("PATCH", command)
            self.assertNotIn(TAG, command)
            write.assert_called_once_with(args.output, public)

            fingerprint.write_text(json.dumps({"id": RELEASE_ID, "assets": [{"id": 2}]}))
            with mock.patch.object(API, "fetch_release", return_value=staged), mock.patch.object(
                API, "run_gh_json"
            ) as no_patch, self.assertRaises(API.ReleaseError):
                API.command_publish(args)
            no_patch.assert_not_called()


if __name__ == "__main__":
    unittest.main()
